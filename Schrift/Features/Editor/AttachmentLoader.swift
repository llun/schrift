import Foundation

/// Where an attachment's bytes have got to.
///
/// Top-level rather than nested in `AttachmentLoader` so it carries no actor
/// isolation: the card's pure display resolver takes one, and pure value code in
/// this codebase never has concurrency annotations.
enum AttachmentLoadState: Equatable, Sendable {
    case downloading
    /// Bytes are on disk at this file URL — previewable, offline included.
    case cached(URL)
    /// The download failed and can be retried. Deliberately not carrying the
    /// error: nothing in the UI branches on which failure it was, and a retry
    /// re-derives it anyway.
    case failed
}

/// Downloads and caches attachment bytes for the document surfaces.
///
/// **Why this exists rather than a fetch inside the card view.** Views never do
/// networking or persistence directly; `MarkdownImageView`'s `AsyncImage` is the
/// one sanctioned exception, and it earns it by being a system component that
/// owns its own cache. An attachment has neither — it needs the app's
/// origin-pinned client (for cookies, error mapping and the diagnostics hook)
/// and a disk cache that must survive the view. So the view asks this object,
/// which owns both.
///
/// **Why it is app-scoped** (built once per authenticated server session in
/// `RootView`'s `AuthenticatedHomeContainer`, alongside the collaboration
/// manager, and injected through the environment): the same attachment can be on
/// screen in more than one place, and a per-view loader would race two downloads
/// of the same bytes and let two writers fight over one cache file. One owner
/// gives in-flight de-duplication and a single disk authority for free. It dies
/// with the session, which is also when its cache is cleared.
///
/// State is keyed by the attachment's **url string**, not by block identity:
/// `applyLiveRemoteChange` reuses a surviving `EditorBlock.id` across a content
/// change, so a live edit can swap the url under a card that never re-rendered
/// from scratch.
@MainActor @Observable final class AttachmentLoader {
    private(set) var states: [String: AttachmentLoadState] = [:]

    private let client: DocsAPIClient
    private let serverOrigin: String
    private let cache: AttachmentCacheStore
    /// Download handles, not just keys: a concurrent caller **joins** the
    /// running download instead of returning, and the loader owns the task so
    /// a torn-down card cannot cancel it.
    private var inFlight: [String: Task<Void, Never>] = [:]

    init(client: DocsAPIClient, serverOrigin: String, cache: AttachmentCacheStore = AttachmentCacheStore()) {
        self.client = client
        self.serverOrigin = serverOrigin
        self.cache = cache
    }

    func state(for display: AttachmentDisplay) -> AttachmentLoadState? {
        states[display.urlString]
    }

    /// Makes the attachment's bytes available, doing the least work that
    /// achieves it: nothing if they are already cached or a download is already
    /// running, a disk read if a previous session cached them, otherwise one GET.
    ///
    /// Never throws and never surfaces an error to the caller — a failure is a
    /// `.failed` state the card renders as a retry affordance.
    ///
    /// A previous failure is **not** retried here. The card's `.task` re-fires
    /// whenever it reappears, so auto-retrying would hammer a failing server as
    /// the user scrolls past a document full of attachments. `retry` is the way
    /// back, and it is one tap on the card the user is already looking at.
    ///
    /// Concurrent callers **join** the running download rather than returning:
    /// returning early let a superseded task's late `catch` clear the state
    /// after its successor had already given up, leaving a card spinning on
    /// `.downloading` with nothing left to resolve it.
    /// `allowsNetwork` false means "answer from disk or not at all" — what the
    /// card passes while the app believes it is offline.
    ///
    /// The distinction is the whole offline story and it is easy to get wrong:
    /// skipping this call entirely while offline (the obvious reading of "don't
    /// ask the network") also skips the **disk** read, and since this table is
    /// the only source of `.cached`, a cold launch in airplane mode would render
    /// "Available when online" over an attachment whose bytes are sitting in the
    /// cache. A disk read costs no request, which is the only thing offline is
    /// meant to suppress.
    func loadIfNeeded(_ display: AttachmentDisplay, allowsNetwork: Bool = true) async {
        let key = display.urlString
        if case .failed = states[key] { return }
        if let running = inFlight[key] {
            await running.value
            return
        }

        // The disk is consulted even when the state is already `.cached`, for
        // two reasons. Eviction can delete the file out from under a card that
        // is still on screen — a long document can push a hundred attachments
        // through the cache in one session — and a stale `.cached` would open
        // QuickLook on a file that no longer exists, with no way back because
        // this method would keep short-circuiting on it. And the same call
        // bumps the file's modification date, which is what makes eviction
        // least-recently-*used* for an attachment the reader keeps returning
        // to rather than merely least-recently-first-loaded.
        if let url = cache.cachedFileURL(for: display) {
            states[key] = .cached(url)
            return
        }
        // The disk has no copy, so a `.cached` entry naming an evicted file must
        // not survive this call: offline it would never be replaced by a
        // download, and the tap path would hand QuickLook a deleted path. Nil
        // reads as "nothing here yet", which offline renders honestly as
        // `.offlineAndUncached`.
        if case .cached = states[key] { states[key] = nil }
        guard allowsNetwork else { return }
        await download(display)
    }

    /// Re-attempts a download the user asked for again. Unlike `loadIfNeeded`
    /// this does not short-circuit on `.failed` — it is the deliberate way back
    /// from one.
    func retry(_ display: AttachmentDisplay) async {
        if let running = inFlight[display.urlString] {
            await running.value
            return
        }
        if let url = cache.cachedFileURL(for: display) {
            states[display.urlString] = .cached(url)
            return
        }
        await download(display)
    }

    // MARK: - Private

    /// Runs the GET in a task the **loader** owns, so the work outlives the view
    /// that asked for it.
    ///
    /// A card is torn down routinely — tapping a block swaps the reading surface
    /// for the editing one — and a structured download died with it, which
    /// recorded a cancellation the card could not tell from a real failure. This
    /// is the same reason `DocumentSaveCoordinator` owns its save tasks, and it
    /// costs nothing: the bytes were already on the wire, and finishing means
    /// the next appearance finds them cached.
    private func download(_ display: AttachmentDisplay) async {
        let key = display.urlString
        // Defense in depth. `parseAttachmentLink` already proved this url is on
        // the user's own server — an off-origin url never becomes an
        // `AttachmentDisplay` at all — but this is the layer that issues the
        // request, and the type it takes is freely constructible.
        guard let path = attachmentMediaPath(for: display, serverOrigin: serverOrigin) else {
            states[key] = .failed
            return
        }

        states[key] = .downloading
        let task = Task { [weak self] () -> Void in
            await self?.fetch(display, path: path)
        }
        inFlight[key] = task
        await task.value
        inFlight[key] = nil
    }

    private func fetch(_ display: AttachmentDisplay, path: String) async {
        let key = display.urlString
        do {
            let data = try await client.mediaData(path: path)
            // A cache write that fails (a full disk) costs the offline copy, not
            // the download: `.failed` so the card offers a retry rather than
            // claiming a file that isn't there.
            states[key] = cache.store(data, for: display).map(AttachmentLoadState.cached) ?? .failed
        } catch {
            states[key] = .failed
        }
    }
}

extension AttachmentLoader {
    /// A loader that can never download — for `#Preview`s (and any view test)
    /// that only needs the environment value present, mirroring
    /// `DocumentCollaborationManager.inert()`. Its empty `serverOrigin` makes
    /// `attachmentMediaPath` refuse every attachment, so no request is issued
    /// and no cache directory is created.
    static func inert() -> AttachmentLoader {
        AttachmentLoader(
            client: DocsAPIClient(baseURL: URL(string: "https://example.com/api/v1.0/")!),
            serverOrigin: "")
    }
}
