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
    private var inFlight: Set<String> = []

    /// `states` seeds the table without touching the network or the disk, so a
    /// `#Preview` (or a view test) can show a particular card. Production
    /// callers leave it empty.
    init(
        client: DocsAPIClient,
        serverOrigin: String,
        cache: AttachmentCacheStore = AttachmentCacheStore(),
        states: [String: AttachmentLoadState] = [:]
    ) {
        self.client = client
        self.serverOrigin = serverOrigin
        self.cache = cache
        self.states = states
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
    /// Concurrent callers do not join the download; they simply return. The
    /// state is observable, so every card watching this url re-renders when it
    /// resolves.
    func loadIfNeeded(_ display: AttachmentDisplay) async {
        let key = display.urlString
        if case .failed = states[key] { return }
        guard !inFlight.contains(key) else { return }

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
        await download(display)
    }

    /// Re-attempts a download the user asked for again. Unlike `loadIfNeeded`
    /// this does not short-circuit on `.failed` — it is the deliberate way back
    /// from one.
    func retry(_ display: AttachmentDisplay) async {
        guard !inFlight.contains(display.urlString) else { return }
        if let url = cache.cachedFileURL(for: display) {
            states[display.urlString] = .cached(url)
            return
        }
        await download(display)
    }

    // MARK: - Private

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
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        guard let data = try? await client.mediaData(path: path) else {
            states[key] = .failed
            return
        }
        // A cache write that fails (a full disk) costs the offline copy, not the
        // download: fall back to `.failed` so the card offers a retry rather than
        // claiming a file that isn't there.
        guard let url = cache.store(data, for: display) else {
            states[key] = .failed
            return
        }
        states[key] = .cached(url)
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
