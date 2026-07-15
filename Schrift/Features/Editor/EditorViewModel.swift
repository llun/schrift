import Foundation

@MainActor
@Observable
final class EditorViewModel {
    enum Mode: Equatable {
        case reading
        case blocks
    }

    enum SaveState: Equatable {
        case idle
        case dirty
        case saving
        case saved
        /// Saved on-device; the server save failed transiently and is queued for
        /// the reconnect/foreground sync (mirrors the coordinator's `.pendingSync`).
        case pendingSync
        case failed(String)
    }

    /// A consume-once request to place the caret or selection; the token makes
    /// repeated requests for the same position distinct.
    struct CursorRequest: Equatable {
        let blockID: UUID
        let offset: Int
        let length: Int
        let token: UUID

        init(blockID: UUID, offset: Int, length: Int = 0) {
            self.blockID = blockID
            self.offset = offset
            self.length = length
            self.token = UUID()
        }
    }

    enum DisplaySource: Equatable {
        case none, pendingSave, draft, clean
    }

    /// A pending link sheet. `span` is nil when creating a link; non-nil when
    /// retargeting one the user tapped. `range` is what the new `[label](url)`
    /// replaces, in the block's source coordinates.
    struct LinkEditorRequest: Identifiable, Equatable {
        let id = UUID()
        let blockID: UUID
        let span: InlineLinkSpan?
        let label: String
        let url: String
        let range: NSRange
    }

    var title: String
    var blocks: [EditorBlock] = []
    var rawMarkdown: String = ""
    /// nil = no fetched *or cached* knowledge (the view must not claim "no
    /// subpages"); [] = a real result — fetched this session or restored from
    /// the children cache — with none existing.
    var subpages: [Document]? = nil
    var mode: Mode = .reading
    var isLoading = false
    var errorKey: L10nKey?
    /// The server's own words about the failure behind `errorKey`, when it had any.
    /// Every 404 maps to `.notFound` and reads as "deleted", so a missing route or a proxy
    /// hiccup is indistinguishable from a deletion without this.
    var errorDetail: String?
    var focusedBlockID: UUID?
    var cursorRequest: CursorRequest?
    var selection: NSRange?
    var slashQueryText: String?
    var lastSyncedAt: Date? = nil
    var hasLocalCopy = false
    var updateAvailable = false
    /// Drives the system photo picker. Set by the slash-menu photo item and the
    /// formatting-bar button; cleared by SwiftUI when the picker dismisses.
    var isPhotoPickerPresented = false
    /// True while a picked photo is being prepared, uploaded and confirmed. No
    /// placeholder block exists during this window — the `.image` block is only
    /// inserted on success.
    var isUploadingPhoto = false
    /// Drives the link sheet. Set by the formatting bar's link button and by a
    /// tap on a link's label; cleared on commit or cancel.
    var linkEditor: LinkEditorRequest?

    let client: DocsAPIClient
    let documentID: UUID
    let saveCoordinator: DocumentSaveCoordinator
    let contentCache: DocumentContentCacheStore
    let childrenCache: DocumentChildrenCacheStore
    let autosaveInterval: Duration
    /// Delay between media-check readiness polls. Tests pass `.zero`.
    let mediaCheckRetryInterval: Duration
    /// The same log the shared client records into — the screen that pushed this one hands
    /// it over. nil in previews and tests, which simply means no detail is offered.
    let diagnostics: APIDiagnosticsLog?

    private(set) var isDirty = false
    /// Editing is only allowed once content has loaded — otherwise autosave
    /// would overwrite the whole server document with an empty draft.
    private(set) var hasLoadedContent = false
    /// Set once the document is deleted locally. Unlike `becomeUnavailable()`, the
    /// delete path leaves `hasLoadedContent` true, so a late photo insert would
    /// otherwise re-save — and re-draft — a document that no longer exists.
    private(set) var isDocumentDiscarded = false
    private(set) var displaySource: DisplaySource = .none
    /// A 404/403 declared the document gone. Unlike a delete this is **recoverable**
    /// — the screen stays mounted with its pull-to-refresh, and a 404 can still be a proxy
    /// hiccup (only an *HTML* 404 is separated out, as `.routeNotFound`, and never lands
    /// here). So this is not a latch: it is
    /// discharged by a fetch whose body `apply` actually put on screen
    /// (`markAvailableAgain`, *after* `apply`, gated on `hasLoadedContent`).
    /// Neither weaker rule works — see that method for the two screens they stranded.
    /// While it holds, the local phase must not re-render the purged copy (or the
    /// draft the teardown just wrote) with the terminal message cleared.
    private(set) var isUnavailable = false
    private var savedMarkdown = ""
    private var savedTitle = ""
    private var autosaveTask: Task<Void, Never>?
    private var dirtySince: Date?
    /// `title` is the server's title as of the fetch that stashed this body — the same fetch
    /// `reconcileClean` already applied it from (titles are never stashed, only bodies) — so
    /// `applyPendingUpdate` can build a baseline that describes the server state it installs.
    private var pendingFreshContent: (markdown: String, title: String?, syncedAt: Date, serverUpdatedAt: Date)?
    /// The server state the on-screen content descends from: a fetched (or
    /// cache-restored) server body's own `updated_at`, or — when a draft is what's
    /// on screen — that draft's own recorded baseline (continuity across a reopen).
    /// Never advanced from `cacheServerCopy` (a dirty screen's edits don't descend
    /// from the just-observed server body) nor at flush time. Threaded into
    /// `enqueue` so a queued draft can later be reconciled against the server via
    /// `draftSyncDecision`. Cleared when the document is torn down.
    private var serverBaseline: DraftBaseline?
    /// Monotonic guard: a completing fetch applies its outcome only if no
    /// newer load()/refresh() superseded it (latest-wins; .task refires on
    /// pop-back and .refreshable re-enters).
    private var revalidationGeneration = 0
    /// Latest-wins guard for the children list: bumped by every loadChildren(),
    /// a successful addSubpage(), and the purge paths, so a stale in-flight
    /// listChildren snapshot can never overwrite (and durably cache) a newer
    /// mutation. Read-only outside the type so tests can pin the bumps whose
    /// interleaving can't be simulated (MockURLProtocol serializes requests).
    private(set) var childrenGeneration = 0
    /// The exact raw markdown the current display was installed from — the
    /// staleness comparison basis. NEVER compare fetched markdown against
    /// serializeMarkdown(blocks)/currentMarkdown(): the serializer
    /// canonicalizes (`*`→`-`, renumbering), which would give every
    /// non-byte-round-tripping document a permanent do-nothing banner.
    private var displayedSourceMarkdown = ""

    /// Continuous typing keeps restarting the trailing debounce; cap the total
    /// deferral so a long burst still persists periodically.
    private static let maxAutosaveDeferral: TimeInterval = 30

    /// How many times to poll media-check before falling back to the URL derived
    /// from the upload key. The default deployment's scanner is the dummy
    /// backend, so readiness is near-immediate.
    private static let mediaCheckMaxAttempts = 5

    /// Friendly copy for every failure in the photo-insert pipeline.
    private static let photoErrorKey: L10nKey = .editor_error_add_photo

    init(
        client: DocsAPIClient,
        documentID: UUID,
        title: String,
        saveCoordinator: DocumentSaveCoordinator,
        contentCache: DocumentContentCacheStore = DocumentContentCacheStore(),
        childrenCache: DocumentChildrenCacheStore = DocumentChildrenCacheStore(),
        autosaveInterval: Duration = .seconds(10),
        mediaCheckRetryInterval: Duration = .seconds(1),
        diagnostics: APIDiagnosticsLog? = nil
    ) {
        self.client = client
        self.documentID = documentID
        self.title = title
        self.saveCoordinator = saveCoordinator
        self.contentCache = contentCache
        self.childrenCache = childrenCache
        self.autosaveInterval = autosaveInterval
        self.mediaCheckRetryInterval = mediaCheckRetryInterval
        self.diagnostics = diagnostics
        self.savedTitle = title
    }

    var isEditing: Bool { mode != .reading }

    // MARK: - Error state

    /// `errorKey` and `errorDetail` must move together. The detail is only ever rendered
    /// beneath its message, so a detail that outlives one is invisible right up until some
    /// unrelated later message adopts it — a stale "HTTP 500" from a background revalidation
    /// appearing under "Couldn't add the subpage."
    private func showError(_ key: L10nKey, detail: String? = nil) {
        errorKey = key
        errorDetail = detail
    }

    private func clearError() {
        errorKey = nil
        errorDetail = nil
    }

    /// Caption rule 1: unsaved local content wins over "Synced X ago". A stored
    /// draft counts whatever `displaySource` says — a save failing mid-session
    /// leaves `.clean` on screen with the draft (the user's only copy) behind it.
    /// Nothing counts once the document is off screen: `becomeUnavailable` keeps
    /// the draft on purpose (a 403 is revoked access, not a deletion) and the
    /// caption must not claim unsaved content for a document that isn't there.
    ///
    /// This is read on every render of the reading surface (a 60 s `TimelineView`
    /// tick) and `storedDraft` decodes the whole draft store out of UserDefaults,
    /// so the in-memory checks come first. The two guarded reads below are
    /// *exhaustive*, not a shortcut: `enqueue` is the only thing that ever **creates**
    /// a draft, and it sets `pendingSave` synchronously, so
    /// `draft != nil && !isDirty && pendingSave == nil` implies either the save failed
    /// (`.failed`/`.pendingSync`), or the draft was stranded by an earlier session — and
    /// `restoreLocalContent` always installs *that* as `.draft`. The coordinator's other
    /// `draftStore.save` calls (`finish`'s surviving-draft stamp, `resolveConflictKeepingLocal`'s
    /// baseline advance, and `persistConflictOnDraft`'s mirror) only ever **rewrite an existing
    /// draft in place**, so they create nothing these guards could miss. Add a caller that
    /// *creates* one, or make `enqueue` async, and this stops being exhaustive: drop the
    /// guards and read the draft unconditionally.
    var hasUnsavedLocalContent: Bool {
        guard hasLoadedContent else { return false }
        if isDirty || saveCoordinator.pendingSave(documentID: documentID) != nil { return true }
        // A failed or pending-sync save leaves the draft as the user's only copy of
        // that edit (the server hasn't confirmed it), so it is unsaved local content
        // whatever `displaySource` says.
        // Exhaustive on purpose: this is one of the two save funnels the CLAUDE.md
        // invariants are written around, so a new coordinator state must be a compile
        // error here, not fall silently into the least-protective branch.
        switch saveCoordinator.state(for: documentID) {
        case .failed, .pendingSync:
            return saveCoordinator.storedDraft(documentID: documentID) != nil
        case .idle, .saving, .saved:
            return displaySource == .draft && saveCoordinator.storedDraft(documentID: documentID) != nil
        }
    }

    var saveState: SaveState {
        if isDirty { return .dirty }
        switch saveCoordinator.state(for: documentID) {
        case .idle: return .idle
        case .saving: return .saving
        case .saved: return .saved
        case .pendingSync: return .pendingSync
        case .failed(let message): return .failed(message)
        }
    }

    /// The detected sync conflict for this document, if any. The reading surface
    /// shows a "Sync conflict · tap to review" pill and the `ConflictSheetView`
    /// while this is non-nil (reading `@Observable` cross-object state re-renders
    /// live when the coordinator records or clears it).
    var syncConflict: DocumentSaveCoordinator.SyncConflict? {
        saveCoordinator.conflict(for: documentID)
    }

    // MARK: - Loading

    func load() async {
        // The terminal 404/403 message survives until a fetch actually puts content
        // back on screen (`markAvailableAgain`). Clearing it here would leave the
        // user staring at revoked content — or at nothing — with no warning.
        if !isUnavailable { clearError() }
        // The local phase runs once per installed document: load() re-fires
        // on pop-back (.task) — reinstalling would clobber a dirty editing
        // session with the cached copy. After the first install, load() is
        // revalidate-only. It is skipped entirely for a document declared gone:
        // the purge removed its cache, but the teardown's write-ahead flush may
        // have just written a draft holding the full (revoked) body, and
        // `restoreLocalContent` would happily put it back on screen.
        if !hasLoadedContent {
            updateAvailable = false
            pendingFreshContent = nil
            if !isUnavailable {
                // Sub pages restore alongside the content so the Subpages section
                // renders instantly (and offline); loadChildren revalidates after
                // each successful content fetch.
                if let cachedChildren = childrenCache.children(for: documentID) {
                    subpages = cachedChildren
                }
                restoreLocalContent()
            }
            // No spinner for a document declared gone: `readingSurface` owns the
            // only `.refreshable`, and swapping it for a `ProgressView` mid-refresh
            // would tear down the very gesture the terminal message invites.
            if displaySource == .none, !isUnavailable {
                isLoading = true
            }
        }
        revalidationGeneration += 1
        await revalidate(generation: revalidationGeneration)
        isLoading = false
    }

    /// Local phase: synchronous, no network, no spinner. Chooses the display
    /// source by precedence — in-flight save, stored draft, cached copy.
    private func restoreLocalContent() {
        if let pending = saveCoordinator.pendingSave(documentID: documentID) {
            install(markdown: pending.markdown, title: pending.title, syncedAt: nil)
            // Continuity: the in-flight/queued content descends from the same server
            // state its draft recorded (enqueue writes both together).
            serverBaseline = saveCoordinator.storedDraft(documentID: documentID)?.baseline
            displaySource = .pendingSave
        } else if let draft = saveCoordinator.storedDraft(documentID: documentID) {
            // New: shown before any fetch (fixes drafts being unreachable
            // offline). The server-wins staleness rule runs at revalidation.
            install(markdown: draft.markdown, title: draft.title, syncedAt: nil)
            serverBaseline = draft.baseline
            displaySource = .draft
        } else if let cached = contentCache.content(for: documentID) {
            install(markdown: cached.markdown, title: cached.title, syncedAt: cached.syncedAt)
            serverBaseline = DraftBaseline(
                serverUpdatedAt: cached.serverUpdatedAt, markdown: cached.markdown, title: cached.title)
            displaySource = .clean
        } else {
            displaySource = .none
        }
        hasLocalCopy = displaySource != .none
    }

    /// Revalidation: the awaited structured tail of load() — no unstructured
    /// Task. Classification of the outcome happens when the fetch completes.
    /// `generation` guards against a superseded fetch (an earlier load() or
    /// refresh()) applying its outcome after a newer one has already run.
    private func revalidate(generation: Int) async {
        let diagnosticsMarker = diagnostics?.marker()
        do {
            // Snapshot before issuing: only the coordinator's state at *issue*
            // time can tell us whether the response might predate our own save.
            let saveMarker = saveCoordinator.saveMarker(documentID: documentID)
            let formatted = try await client.formattedContent(documentID: documentID)
            guard generation == revalidationGeneration, !Task.isCancelled else { return }
            apply(
                formatted: formatted,
                mayPredateLocalSave: saveCoordinator.mayPredateSave(saveMarker)
            )
            markAvailableAgain()
            await loadChildren()
        } catch let error as DocsAPIError where error == .notFound || error == .forbidden {
            guard generation == revalidationGeneration else { return }
            becomeUnavailable()
            // "No longer available" is a guess: a 404 also means a route this server does
            // not have, or a proxy hiccup. Say what the server actually answered.
            errorDetail = requestFailureDetail(after: diagnosticsMarker, in: diagnostics)
        } catch {
            guard generation == revalidationGeneration else { return }
            // Transient (.network, .routeNotFound, .server, .rateLimited, .sessionExpired —
            // cookie expiry must not purge the cache): keep the local copy.
            // For .sessionExpired specifically, the shared client's
            // onSessionExpired hook has already raised the app-level re-login
            // sheet; the editor recovers on its next refresh or save.
            // A document already declared gone keeps its terminal message: a
            // transient failure is no evidence that it came back.
            // `.routeNotFound` lands here — a misconfigured server or a proxy eating the
            // path — and that is precisely the failure whose reason nobody can guess. But
            // attach it only where a message actually appears: a silent background failure
            // over a local copy must not leave a detail behind for a later message to adopt.
            let detail = requestFailureDetail(after: diagnosticsMarker, in: diagnostics)
            if isUnavailable {
                showError(unavailableMessageKey, detail: detail)
            } else if displaySource == .none {
                showError(.editor_error_load, detail: detail)
            }
        }
    }

    /// Explicit pull-to-refresh. It applies the same content rules as the
    /// passive on-open revalidation — a clean document always shows the latest
    /// server body — and differs only in that it surfaces failures instead of
    /// swallowing them (the user asked, so silence would read as a no-op).
    func refresh() async {
        guard hasLoadedContent else {
            await load()  // error-state retry: full initial flow, as today
            return
        }
        clearError()
        revalidationGeneration += 1
        let generation = revalidationGeneration
        let diagnosticsMarker = diagnostics?.marker()
        do {
            let saveMarker = saveCoordinator.saveMarker(documentID: documentID)
            let formatted = try await client.formattedContent(documentID: documentID)
            guard generation == revalidationGeneration, !Task.isCancelled else { return }
            apply(
                formatted: formatted,
                mayPredateLocalSave: saveCoordinator.mayPredateSave(saveMarker)
            )
            // Unreachable while `isUnavailable` — that implies `!hasLoadedContent`, so
            // `refresh()`'s guard already diverted into `load()`. Kept because nothing
            // enforces that invariant and an undischarged terminal state is a dead
            // screen; the invariant itself is pinned by
            // `testUnavailableAlwaysImpliesNoLoadedContent`.
            markAvailableAgain()
            await loadChildren()
        } catch let error as DocsAPIError where error == .notFound || error == .forbidden {
            guard generation == revalidationGeneration else { return }
            becomeUnavailable()
            errorDetail = requestFailureDetail(after: diagnosticsMarker, in: diagnostics)
        } catch {
            guard generation == revalidationGeneration else { return }
            showError(
                .editor_error_refresh,
                detail: requestFailureDetail(after: diagnosticsMarker, in: diagnostics))
        }
    }

    /// A 200 whose body `apply` actually put on screen is the server saying the
    /// document is back. Two near-misses, both of which stranded a real screen:
    /// discharging inside `install(...)` misses `reconcileDraft`'s draft-wins exits
    /// (which never install), and discharging *before* `apply` clears the terminal
    /// message for a response `apply` then declines — `mayPredateLocalSave` is true
    /// whenever a save was in flight when the fetch was issued, and this teardown's
    /// own write-ahead flush starts one — leaving a blank body with no error and no
    /// spinner. So: after `apply`, and only if content actually landed.
    private func markAvailableAgain() {
        guard isUnavailable, hasLoadedContent else { return }
        isUnavailable = false
        clearError()
    }

    /// The terminal 404/403 copy. Mentions the draft only when one exists, so it
    /// never promises changes that were never written.
    private var unavailableMessageKey: L10nKey {
        saveCoordinator.storedDraft(documentID: documentID) != nil
            ? .editor_unavailable_with_draft
            : .editor_unavailable
    }

    /// Definitive 404/403: the document is gone or access was revoked. Purge
    /// the durable copy (privacy), disable editing, show the terminal state.
    private func becomeUnavailable() {
        // Persist the in-flight edit **first**, while the blocks still hold it.
        // `enqueue` is write-ahead: it stores the draft before any network call, so
        // even a PATCH that 404s leaves the user's text on disk, and
        // `recoverDrafts()` replays it next launch if the 404/403 turns out to have
        // been transient (a proxy hiccup, a brief permission flap — every 404 maps
        // to `.notFound`). Flushing *after* the teardown below would serialize the
        // emptied block list and overwrite that draft with an empty document.
        flushPendingChanges()
        // An in-flight save can still land after this purge and write the full body
        // back into the cache — on a 403, revoked content reappearing on disk.
        saveCoordinator.suppressLocalWriteThrough(documentID: documentID)
        isUnavailable = true
        contentCache.remove(documentID: documentID)
        childrenCache.remove(parentID: documentID)
        childrenCache.removeDocument(documentID)
        // Discard any in-flight children snapshot — landing after the purge,
        // it would re-cache the list for a revoked document.
        childrenGeneration += 1
        subpages = nil
        hasLocalCopy = false
        lastSyncedAt = nil
        updateAvailable = false
        pendingFreshContent = nil
        // End the editing session before the content goes. `startEditing` guards
        // the *entry* on hasLoadedContent; nothing guards the exit otherwise, and a
        // live autosave timer over an emptied block list is exactly how the flush
        // above would have been undone.
        autosaveTask?.cancel()
        autosaveTask = nil
        dirtySince = nil
        isDirty = false
        mode = .reading
        focusedBlockID = nil
        cursorRequest = nil
        selection = nil
        slashQueryText = nil
        blocks = []
        rawMarkdown = ""
        displayedSourceMarkdown = ""
        displaySource = .none
        serverBaseline = nil
        hasLoadedContent = false  // startEditing guards on this
        errorKey = unavailableMessageKey
        errorDetail = nil
    }

    /// `mayPredateLocalSave` is the coordinator's verdict, taken when the fetch
    /// was *issued*, on whether this response could have been served from the
    /// server's pre-save state (see `DocumentSaveCoordinator.mayPredateSave`).
    private func apply(formatted: FormattedDocumentContent, mayPredateLocalSave: Bool) {
        // This fetch raced one of our own saves, so its body may be the one that
        // save just replaced. Take nothing from it — not the body, not the cache
        // entry, and not the server baseline (the early return leaves
        // `serverBaseline` untouched) — since a later full-overwrite save would
        // push the resurrected body to the server. Only the display source is
        // settled, so the next fetch isn't stranded.
        if mayPredateLocalSave {
            unpinSettledPendingSave()
            return
        }
        // Past that guard this response postdates our own saves, so its title is the newest the
        // server is known to hold. Record it here — the one point every branch below passes
        // through — so `adoptQueuedTitleIfUnseen` can never prefer a title older than one we
        // have actually seen. It is *not* applied to the screen here: which branch may touch the
        // on-screen title, and when, is the subject of the rules below.
        if let serverTitle = formatted.title {
            saveCoordinator.noteServerTitle(documentID: documentID, title: serverTitle)
        }
        // Classify against *current* state: edits may have begun while the
        // fetch was in flight.
        if saveCoordinator.pendingSave(documentID: documentID) != nil || isDirty {
            // **Detect before caching.** This branch used to return without ever consulting
            // `draftSyncDecision`, which made the entire safety net depend on *keystroke
            // timing*: a queued offline draft whose revalidation proved the server had moved
            // on would be reconciled (and the push held) — unless the user happened to type
            // one character while that fetch was in flight, in which case `isDirty` diverted
            // here, no conflict was recorded, and the next autosave full-overwrote the web
            // edit the app had just fetched. Whether a destructive push got checked must not
            // hinge on a race with the user's fingers.
            //
            // Recording is non-destructive — nothing is installed, the edits and the draft
            // stay exactly where they are — and it engages the enqueue-hold, so the pending
            // autosave parks instead of pushing and the pill (which renders while editing)
            // asks. Restricted to `pendingSave == nil` to preserve the coordinator's
            // invariant that a conflict is only ever recorded with no save in flight.
            //
            // Rule 1 is what keeps this from firing against *our own* write: right after our
            // save lands there is no draft, so the stamp has to come from the coordinator —
            // hence `lastConfirmedPush(documentID:)`. Without it, `serverBaseline` (which a
            // save deliberately does not advance) would make our own just-pushed body read
            // as a diverged server.
            // A save **on the wire** is the only thing that blocks detection (a conflict may
            // only be recorded with no save in flight). Note that this is *not* the same as
            // `pendingSave != nil`: a save sitting in `queued` with nothing in flight can only
            // be one the conflict hold parked, and gating on `pendingSave` would then block
            // detection for exactly the documents that already have a conflict — so they could
            // never have it released.
            if saveCoordinator.hasSaveInFlight(documentID: documentID) {
                // **Do not throw the observation away.** If that save fails, nothing reached the
                // server, the draft survives with a stale baseline, and the next flush would
                // full-overwrite the body we just fetched and cached. Hand it to the coordinator,
                // which re-decides in `finish` once the invariant holds again.
                saveCoordinator.noteServerObservedDuringSave(
                    documentID: documentID, serverUpdatedAt: formatted.updatedAt,
                    markdown: formatted.content ?? "")
            } else {
                // **Do not require a baseline.** `serverBaseline` is nil exactly for a *legacy*
                // (baseline-less) draft — one written by a build from before `DraftBaseline`
                // existed, which persists across the app update that adds it. Bailing out on nil
                // meant such a draft, once dirty, got **no detection at all**: the fetch proved
                // the server had moved on, nothing was recorded, no hold engaged, and the next
                // autosave full-overwrote the co-author's edit the app had just fetched. That is
                // the very keystroke-timing hole this branch exists to close, still open on the
                // one class of draft that has no baseline to protect it. `draftSyncDecision`
                // takes an Optional baseline and falls to rule 3 (the legacy clock tolerance) —
                // which needs the **draft's own clock**, not `Date()`: `Date()` is always within
                // tolerance of the server, so rule 3 would answer `.push` unconditionally and the
                // `else` below would clear a live conflict.
                // The title the decision weighs here is the **on-screen** one, because that is
                // what the pending autosave would PATCH: a live typist who renamed the document
                // while a co-author renamed it differently is a genuine conflict, exactly as a
                // queued draft's two renames are.
                let draft = saveCoordinator.storedDraft(documentID: documentID)
                switch draftSyncDecision(
                    baseline: serverBaseline,
                    lastPushedMarkdown: saveCoordinator.lastConfirmedPush(documentID: documentID),
                    localMarkdown: currentMarkdown(),
                    draftTitle: title,
                    draftUpdatedAt: draft?.updatedAt ?? dirtySince ?? Date(),
                    serverTitle: formatted.title,
                    serverUpdatedAt: formatted.updatedAt,
                    serverMarkdown: formatted.content ?? "")
                {
                case .conflict, .discardServerWins:
                    // `.discardServerWins` is not "no conflict" — it is rule 3 firing for a
                    // legacy draft the server has moved past, which is visible unsaved work.
                    // `runSyncPass` and `reconcileDraft` both record a conflict for it.
                    saveCoordinator.recordConflict(documentID: documentID, serverUpdatedAt: formatted.updatedAt)
                case .push(let pushTitle, let evidence):
                    // Nothing left to ask about — but only if the push is *proven*, not merely
                    // clock-tolerated. See `releaseConflictIfProven`.
                    _ = releaseConflictIfProven(evidence, serverUpdatedAt: formatted.updatedAt)
                    // A one-sided rename must be merged here, not left to the flush.
                    // `reconcileDraft` — the other adopter — is unreachable while the screen is
                    // dirty (this branch returns first), so a stored draft would keep its
                    // pre-rename title; and `adoptQueuedTitleIfUnseen` prefers a draft's title
                    // over the server's, because unsaved local work normally *is* the newer one.
                    // The rename would then be PATCHed away by the very flush meant to merge it.
                    adoptServerTitle(pushTitle)
                }
            }
            cacheServerCopy(formatted)
            return
        }
        // A draft outliving its save (the save failed) is unsaved work no matter
        // which source installed the screen — a save failing mid-session leaves
        // `.clean` on screen with the draft behind it. The rules in
        // `reconcileDraft`, never `displaySource`, decide whether the server may
        // replace it.
        if let draft = saveCoordinator.storedDraft(documentID: documentID) {
            displaySource = .draft
            reconcileDraft(formatted, draft: draft)
            return
        }
        switch displaySource {
        case .pendingSave, .clean, .draft:
            // `.pendingSave` reaching here means the save that owned the screen
            // landed (a failed one leaves the draft caught above) and this fetch
            // postdates it. `.draft` means the draft is gone but nothing reset the
            // source — a save cleared it (the marker is per-fetch, so a fetch
            // issued *after* that save reads a fresh count and arrives here),
            // `recoverDrafts` discarded it, or the document was deleted. Either way
            // nothing local is left to protect, so the screen holds an ordinary
            // clean copy. Leaving the source pinned would strand it forever: every
            // later revalidation *and* every pull-to-refresh would no-op in silence.
            displaySource = .clean
            reconcileClean(formatted)
        case .none:
            installFetched(formatted)
        }
    }

    /// The save that owned the screen has settled, so `.pendingSave` no longer
    /// describes it. Reclassify without touching content — the response that
    /// triggered this is untrustworthy — so the next fetch reconciles normally.
    /// A dirty screen is left alone: no source describes it, and the dirty rule
    /// short-circuits every later `apply` until it flushes anyway.
    private func unpinSettledPendingSave() {
        guard displaySource == .pendingSave, !isDirty,
            saveCoordinator.pendingSave(documentID: documentID) == nil
        else { return }
        displaySource = saveCoordinator.storedDraft(documentID: documentID) != nil ? .draft : .clean
    }

    /// An unsaved draft owns the screen. It only loses to a server copy written
    /// meaningfully later than the draft itself — never to the user's own
    /// refresh, because the draft is work that hasn't reached the server yet.
    private func reconcileDraft(_ formatted: FormattedDocumentContent, draft: PendingDraft) {
        // The on-screen content is the draft, so it descends from the draft's own
        // recorded baseline. The server-wins install below routes through
        // `installFetched`, which overrides this with the server state it actually
        // put on screen.
        serverBaseline = draft.baseline
        // Nothing is on screen: `becomeUnavailable` tore it down, and its own
        // write-ahead flush is what wrote this draft. The draft is the user's only
        // copy, so put it back — every branch below then reasons about content that
        // is actually displayed, as they all assume.
        let recovered = !hasLoadedContent
        if recovered {
            install(markdown: draft.markdown, title: draft.title, syncedAt: nil)
            displaySource = .draft
            hasLocalCopy = true
        }
        // A save that failed or is queued for sync *this session* leaves a draft the
        // user is looking at — the "Couldn't save" retry (`.failed`) or "syncs when
        // online" caption (`.pendingSync`) is on screen, and the draft is their only
        // copy of that edit. The clock-tolerance rule below is for drafts stranded by
        // an *earlier* session (`recoverDrafts`' job); applying it to either of these
        // silently deletes visible content — the exact mirror of the `.pendingSync`
        // preservation guard in `syncPendingDrafts`, and the reason a pull-to-refresh
        // must not discard a queued offline edit. The comparison mixes clocks —
        // `draft.updatedAt` is the device's, `formatted.updatedAt` the server's *last
        // write* — so a device running slow shrinks the window from the draft's side,
        // and even the user's own partially-landed save (content PATCH applied, title
        // PATCH failed) can then read as "newer than the draft".
        switch saveCoordinator.state(for: documentID) {
        case .failed, .pendingSync:
            // Keeping the draft is not the same as staying blind to the server. Skipping
            // *detection* here — not just the discard — left the one hole this whole PR
            // exists to close: this fetch has just proved the server moved on, but with
            // no conflict recorded the coordinator's enqueue-hold never engages, so the
            // user's next "tap to retry" (`saveNow`, which enqueues straight through)
            // full-overwrites the very web edit we already fetched. Recording is
            // non-destructive — the draft still stays on screen and nothing is installed —
            // and it is strictly more protective: the retry is held and the pill asks first.
            // Exhaustive, NOT `if case .conflict … else clear`. `.discardServerWins` is not
            // "no conflict": it is rule 3 firing for a **legacy** (baseline-less) draft the
            // server has moved past — and `runSyncPass` deliberately records a conflict for
            // exactly that state, because the draft is visible unsaved work and the only other
            // funnel is a retry tap that overwrites the newer server copy with no prompt.
            // Treating it as "resolved" here cleared that record on the next pull-to-refresh
            // and re-opened the very hole it was added to close.
            switch draftSyncDecision(
                baseline: draft.baseline,
                lastPushedMarkdown: draft.lastPushedMarkdown,
                localMarkdown: draft.markdown,
                draftTitle: draft.title,
                draftUpdatedAt: draft.updatedAt,
                serverTitle: formatted.title,
                serverUpdatedAt: formatted.updatedAt,
                serverMarkdown: formatted.content ?? "")
            {
            case .conflict, .discardServerWins:
                saveCoordinator.recordConflict(documentID: documentID, serverUpdatedAt: formatted.updatedAt)
            case .push(let pushTitle, let evidence):
                // Genuinely nothing left to ask about — but only on *proven* evidence.
                _ = releaseConflictIfProven(evidence, serverUpdatedAt: formatted.updatedAt)
                // A co-author renamed the document and the user didn't (the only way the resolved
                // title can differ from the draft's). The retry funnel for this state is
                // `saveNow`, which PATCHes `savedTitle` straight through with no reconcile of its
                // own — so without adopting here, tapping "retry" reverts their rename. Adopting
                // is non-destructive: it is *their* draft body that is retried, only under the
                // title the document actually has now.
                adoptServerTitle(pushTitle)
            }
            cacheServerCopy(formatted)
            return
        default:
            break
        }
        // Reconcile against the server the same way the coordinator's `syncPendingDrafts`
        // does: server-clock-to-server-clock with a content tiebreak for baseline-carrying
        // drafts, falling back to the legacy tolerance rule only for baseline-less ones.
        switch draftSyncDecision(
            baseline: draft.baseline,
            lastPushedMarkdown: draft.lastPushedMarkdown,
            localMarkdown: draft.markdown,
            draftTitle: draft.title,
            draftUpdatedAt: draft.updatedAt,
            serverTitle: formatted.title,
            serverUpdatedAt: formatted.updatedAt,
            serverMarkdown: formatted.content ?? "")
        {
        case .push(let pushTitle, let evidence):
            // No longer a conflict (if it ever was): release any stale hold before enqueuing,
            // or the enqueue below would simply park again behind it. But a **clock-only** push
            // is not proof the conflict is gone — releasing on that basis would push a full
            // overwrite over the co-author with no prompt. Keep the hold and re-record.
            guard releaseConflictIfProven(evidence, serverUpdatedAt: formatted.updatedAt) else {
                cacheServerCopy(formatted)
                return
            }
            // `pushTitle`, never `draft.title`: the replay PATCHes a title too, and pushing the
            // one the draft was made with is what silently reverted a co-author's rename. Take it
            // on screen as well, so the title the user sees is the title being pushed — and so
            // `flushPendingChanges`, which PATCHes `title`, can't put the stale one back on the
            // next keystroke.
            adoptServerTitle(pushTitle)
            // The draft still descends from the server (or the server's last writer is
            // us). Cache the fresh body and hand the draft back to the save pipeline —
            // otherwise a stored draft that wins with no save pushing it and no
            // `.failed`/`.pendingSync` affordance has **no funnel at all** (`flush`
            // needs `isDirty`, `recoverDrafts` runs once). Hand it back whichever screen
            // is looking. No storm: `enqueue` makes `pendingSave` non-nil, so `apply`
            // short-circuits before `reconcileDraft` on every later fetch.
            cacheServerCopy(formatted)
            // A save **on the wire** is the only thing that blocks detection (a conflict may
            // only be recorded with no save in flight). Note that this is *not* the same as
            // `pendingSave != nil`: a save sitting in `queued` with nothing in flight can only
            // be one the conflict hold parked, and gating on `pendingSave` would then block
            // detection for exactly the documents that already have a conflict — so they could
            // never have it released.
            if saveCoordinator.hasSaveInFlight(documentID: documentID) {
                // **Do not throw the observation away.** If that save fails, nothing reached the
                // server, the draft survives with a stale baseline, and the next flush would
                // full-overwrite the body we just fetched and cached. Hand it to the coordinator,
                // which re-decides in `finish` once the invariant holds again.
                saveCoordinator.noteServerObservedDuringSave(
                    documentID: documentID, serverUpdatedAt: formatted.updatedAt,
                    markdown: formatted.content ?? "")
            } else {
                saveCoordinator.enqueue(
                    documentID: documentID, title: pushTitle, markdown: draft.markdown,
                    baseline: adoptedBaseline(draft.baseline, draftTitle: draft.title, pushingTitle: pushTitle))
            }
        case .conflict:
            // The server moved on under a baseline-carrying draft. Record it so the
            // reading-surface pill and `ConflictSheetView` ask the user; keep the draft
            // on screen (never install), and let the coordinator's enqueue-hold block
            // any autosave push until the user resolves it. `markAvailableAgain` is
            // unaffected — this never installs, so `isUnavailable` gating is untouched.
            saveCoordinator.recordConflict(documentID: documentID, serverUpdatedAt: formatted.updatedAt)
            cacheServerCopy(formatted)
        case .discardServerWins:
            // **Never discard a draft the user is being asked about.** `runSyncPass` refuses to
            // touch a draft under a recorded conflict; this path had no such guard, and the
            // save *state* does not survive a relaunch even though the conflict now does — so a
            // legacy draft whose conflict was rehydrated came back as `.idle`, skipped the
            // `.failed`/`.pendingSync` branch above, fell to rule 3, and had the very work the
            // pill was asking about **deleted from under the question**. Keep it and re-record:
            // the conflict is exactly what `runSyncPass` records for this state.
            if saveCoordinator.conflict(for: documentID) != nil {
                saveCoordinator.recordConflict(documentID: documentID, serverUpdatedAt: formatted.updatedAt)
                cacheServerCopy(formatted)
                return
            }
            // Legacy (baseline-less) stranded draft the server has moved past — server
            // wins, and the draft goes. `discardStoredDraft` re-checks identity; install
            // only on success. Installing over a surviving draft would leave unsaved work
            // on disk that isn't on screen — the state every rule here exists to prevent.
            saveCoordinator.discardStoredDraft(draft)
            guard saveCoordinator.storedDraft(documentID: documentID) == nil else {
                cacheServerCopy(formatted)
                return
            }
            // The local work is gone, so no conflict record may outlive it (the lifecycle rule).
            saveCoordinator.clearResolvedConflict(documentID: documentID)
            installFetched(formatted)
        }
    }

    /// A `.push` releases a standing conflict **only when it carries content evidence.**
    ///
    /// Rules 0–2 prove something about the body (the server holds ours, or holds what we
    /// pushed, or ours descends from it), so a conflict really is gone. **Rule 3 proves
    /// nothing** — it only says the draft's *client* clock is within tolerance of the server's
    /// `updated_at`. And the user typing *after* a conflict was surfaced bumps that clock past
    /// the server's, so rule 3 then starts answering `.push` for a baseline-less draft whose
    /// conflict is still standing and still persisted. Releasing on that basis discarded the
    /// hold and full-overwrote the co-author with no pill and no prompt — the persisted hold's
    /// whole purpose is to survive exactly that relaunch. So a clock-only push re-records
    /// instead. Returns false when the conflict stands and the caller must not proceed.
    private func releaseConflictIfProven(_ evidence: PushEvidence, serverUpdatedAt: Date) -> Bool {
        if evidence == .clockToleranceOnly, saveCoordinator.conflict(for: documentID) != nil {
            saveCoordinator.recordConflict(documentID: documentID, serverUpdatedAt: serverUpdatedAt)
            return false
        }
        saveCoordinator.clearResolvedConflict(documentID: documentID)
        return true
    }

    /// Silent cache update while local edits own the screen — next open (or
    /// the coordinator's own conflict handling) deals with freshness.
    private func cacheServerCopy(_ formatted: FormattedDocumentContent) {
        // The cache entry records the fresh server body and its `updated_at`, so a
        // later open can build a baseline from it. The in-memory `serverBaseline` is
        // deliberately *not* advanced here: the on-screen edits do not descend from
        // this just-observed server body, and moving the baseline forward would let
        // a queued push sail past the conflict check over a web edit we just saw.
        contentCache.save(
            CachedDocumentContent(
                documentID: documentID,
                title: formatted.title,
                markdown: formatted.content ?? "",
                syncedAt: Date(),
                serverUpdatedAt: formatted.updatedAt
            ))
    }

    /// Clean content on screen — nothing local to protect, so a changed server
    /// body is simply installed. Titles are non-destructive and apply silently
    /// in BOTH branches (savedTitle follows so flushPendingChanges never
    /// enqueues a spurious save); applying only the title while stashing the
    /// body was the "remote edits never show up, only the title does" bug.
    ///
    /// The one exception is an open editing session: swapping the document out
    /// from under the caret is destructive, so the fetched body waits behind
    /// the "Updated" banner, which surfaces once editing ends. (A dirty session
    /// never reaches here — `apply` returns early — and `startEditing`/
    /// `markDirty` drop the stash, so local work always wins.)
    private func reconcileClean(_ formatted: FormattedDocumentContent) {
        // `apply` only reaches here with **no pending save, no stored draft, and not dirty** —
        // i.e. no local work exists at all. A conflict record therefore has nothing left to
        // protect and cannot be a live one, so release it. Nothing else would: every other
        // clear happens on a path that requires local work, so a conflict that has become moot
        // (the co-author reverted; our own push landed; the user discarded their edit) would
        // otherwise park every future save for this document forever behind a question with
        // nothing left to ask — and leave a destructive "Keep the server version" armed
        // against whatever the user typed next.
        saveCoordinator.clearResolvedConflict(documentID: documentID)
        let fetched = formatted.content ?? ""
        let now = Date()
        if let fetchedTitle = formatted.title, fetchedTitle != title {
            title = fetchedTitle
            savedTitle = fetchedTitle
        }
        contentCache.save(
            CachedDocumentContent(
                documentID: documentID,
                title: title,
                markdown: fetched,
                syncedAt: now,
                serverUpdatedAt: formatted.updatedAt
            ))
        if serverChanged(fetched: fetched) {
            if isEditing {
                // Stash behind the "Updated" banner without installing. The
                // on-screen (older) body still owns `serverBaseline` — the caret is
                // in it, so any edit descends from it, not from this stashed copy.
                // NOTE: `startEditing` *hides* the banner but deliberately **keeps** this stash
                // (destroying it there would blind `markDirty`); `markDirty` is what drops
                // it — and records a conflict as it does, since abandoning a server body we
                // fetched and showed the user is exactly what the next autosave would
                // otherwise overwrite unasked. See `abandonPendingFreshContent`.
                pendingFreshContent = (
                    markdown: fetched, title: formatted.title, syncedAt: now, serverUpdatedAt: formatted.updatedAt
                )
                updateAvailable = true
            } else {
                install(markdown: fetched, title: nil, syncedAt: now)
                serverBaseline = DraftBaseline(
                    serverUpdatedAt: formatted.updatedAt, markdown: fetched, title: formatted.title)
                updateAvailable = false
                pendingFreshContent = nil
            }
        } else {
            // Raw may differ only cosmetically — converge the comparison
            // basis on the fetched raw so future comparisons settle.
            displayedSourceMarkdown = fetched
            lastSyncedAt = now
            // The server holds what's on screen, so advance the baseline's server
            // timestamp; and any body stashed by an earlier fetch (server since
            // reverted) has nothing left to offer.
            serverBaseline = DraftBaseline(
                serverUpdatedAt: formatted.updatedAt, markdown: fetched, title: formatted.title)
            updateAvailable = false
            pendingFreshContent = nil
        }
    }

    private func serverChanged(fetched: String) -> Bool {
        guard fetched != displayedSourceMarkdown else { return false }
        // One definition of canonical form (shared with `draftSyncDecision`), so
        // the two can't drift; the byte-equal early-return above keeps the common
        // no-op case from re-parsing.
        return canonicalMarkdown(fetched) != canonicalMarkdown(displayedSourceMarkdown)
    }

    /// The "Updated" banner tap: swaps in the body stashed while an editing
    /// session held the screen. Guarded so a stray tap can never replace blocks
    /// mid-edit or clobber dirty content.
    ///
    /// The `storedDraft` guard is belt-and-braces: a stash implies no draft today
    /// (`apply` only reaches `reconcileClean` with none, and `markDirty` drops the
    /// stash before any enqueue can create one). It is the one remaining
    /// content-installing path that doesn't consult the draft store, and it has
    /// exactly the shape of the bug review found — install over a draft, then
    /// `saveNow()` pushes the server's own body back.
    func applyPendingUpdate() {
        guard saveCoordinator.storedDraft(documentID: documentID) == nil else { return }
        guard !isEditing, !isDirty, let pending = pendingFreshContent else { return }
        install(markdown: pending.markdown, title: nil, syncedAt: pending.syncedAt)
        // The stashed body is now on screen, so it becomes the baseline. Its title came from the
        // same fetch and `reconcileClean` applied it on the spot (titles are never stashed), so
        // the baseline records that server state whole.
        serverBaseline = DraftBaseline(
            serverUpdatedAt: pending.serverUpdatedAt, markdown: pending.markdown, title: pending.title)
        displaySource = .clean
        updateAvailable = false
        pendingFreshContent = nil
    }

    /// A successful local delete must purge every local copy — otherwise the
    /// document stays reachable from retained Search/Shared results and
    /// renders its full cached content indefinitely (transient revalidation
    /// failures are swallowed by design).
    func handleDidDelete() {
        contentCache.remove(documentID: documentID)
        childrenCache.remove(parentID: documentID)
        childrenCache.removeDocument(documentID)
        // Discard any in-flight children snapshot — landing after the purge,
        // it would re-cache the list for a deleted document.
        childrenGeneration += 1
        // …and the in-flight *content* fetch, for the same reason: a 200 landing
        // after this purge reaches `apply` → `reconcileClean`, which write-throughs
        // unconditionally, re-caching the body just removed. Every `revalidate` /
        // `refresh` path re-checks its captured generation before `apply` (and
        // before `becomeUnavailable`, so a delete racing a fetch that then 404s
        // doesn't tear down a document already being deleted), so bumping here is
        // all it takes.
        revalidationGeneration += 1
        // End the session before `.onDisappear`'s flush can write a fresh draft
        // (and PATCH) for a document that no longer exists.
        autosaveTask?.cancel()
        autosaveTask = nil
        dirtySince = nil
        isDirty = false
        saveCoordinator.discardPendingWork(documentID: documentID)
        serverBaseline = nil
        // A photo upload can still be in flight and would otherwise re-save (and
        // re-draft) the deleted document when it lands. `hasLoadedContent` stays
        // true here, so the insert needs its own gate.
        isDocumentDiscarded = true
    }

    /// Installs the fetched server copy and records it in the content cache.
    private func installFetched(_ formatted: FormattedDocumentContent) {
        let now = Date()
        install(markdown: formatted.content ?? "", title: formatted.title, syncedAt: now)
        serverBaseline = DraftBaseline(
            serverUpdatedAt: formatted.updatedAt, markdown: formatted.content ?? "", title: formatted.title)
        // …and record its title, because **not every install comes through `apply`**:
        // `resolveConflictKeepingServer` fetches and installs directly, and it is the one path
        // that also drops the draft — so `adoptQueuedTitleIfUnseen` would fall all the way
        // through to `knownServerTitle` on the next flush and PATCH a title from *before* the
        // copy the user just chose to keep, silently reverting the co-author's rename by way of
        // the very backstop that exists to preserve it. Idempotent for the `apply` paths, which
        // have already noted the same title.
        if let serverTitle = formatted.title {
            saveCoordinator.noteServerTitle(documentID: documentID, title: serverTitle)
        }
        displaySource = .clean
        hasLocalCopy = true
        contentCache.save(
            CachedDocumentContent(
                documentID: documentID,
                title: title,
                markdown: formatted.content ?? "",
                syncedAt: now,
                serverUpdatedAt: formatted.updatedAt
            ))
    }

    /// Installs content as the on-screen document. Every path that puts content on
    /// screen routes through here so the dirty baseline (`savedMarkdown`) and the
    /// authoritative reading-mode source (`rawMarkdown`) are never bypassed — skipping
    /// them risks a destructive full-overwrite save of non-round-trippable content.
    private func install(markdown: String, title contentTitle: String?, syncedAt: Date?) {
        if let contentTitle {
            title = contentTitle
        }
        savedTitle = title
        rawMarkdown = markdown
        blocks = parseEditorBlocks(markdown)
        // Every block gets a fresh identity here, so any caret state still
        // pointing into the outgoing blocks is now dangling. Clearing it in the
        // one funnel every content swap routes through makes that unrepresentable
        // — `reconcileDraft`'s server-wins install can land mid-edit.
        focusedBlockID = nil
        cursorRequest = nil
        selection = nil
        slashQueryText = nil
        // The dirty baseline uses the same representation currentMarkdown()
        // produces in blocks mode, so an unchanged document never triggers a save.
        // `rawMarkdown` keeps the authoritative loaded source for reading-mode
        // paths (see `currentMarkdown()`), which `blocks` may parse lossily.
        savedMarkdown = serializeMarkdown(blocks)
        displayedSourceMarkdown = markdown
        hasLoadedContent = true
        if let syncedAt {
            lastSyncedAt = syncedAt
        }
    }

    func loadChildren() async {
        childrenGeneration += 1
        let generation = childrenGeneration
        guard let results = try? await client.listChildren(documentID: documentID) else { return }
        // Superseded by a newer fetch or a createChild while in flight: a
        // pre-create snapshot must not overwrite (and durably cache) a list
        // missing the just-added child.
        guard generation == childrenGeneration else { return }
        subpages = results.results
        childrenCache.save(results.results, for: documentID)
    }

    func addSubpage() async -> Document? {
        clearError()
        let child: Document
        do {
            child = try await client.createChild(documentID: documentID, title: "Untitled subpage")
        } catch {
            // Deliberately not `becomeUnavailable()`, unlike the load/refresh paths: a 403
            // here means "you may not add children to this document", not "this document
            // was taken away from you". Tearing the editor down would discard the user's
            // open document over a failed sub-page.
            showError(.editor_error_add_subpage)
            return nil
        }
        // Any in-flight children fetch predates this child — invalidate it.
        childrenGeneration += 1
        // Reflect the new child immediately (and durably) so popping back —
        // possibly offline — shows it without waiting on a refetch. Only when
        // the current list is actually known (fetched or cached): appending to
        // a nil (unknown) list would persist a fabricated one-element "complete"
        // result that hides the document's real children.
        if var updated = subpages {
            updated.append(child)
            subpages = updated
            childrenCache.save(updated, for: documentID)
        }
        return child
    }

    /// Resolves a document link tapped in the reading surface (see `documentLinkAction`)
    /// into the `Document` the view pushes. Returns nil when it can't be reached, in which
    /// case nothing is navigated to.
    ///
    /// Clearing the error on entry is safe: a document declared unavailable renders no
    /// blocks, so it has no link to tap.
    func openLinkedDocument(_ linkedID: UUID) async -> Document? {
        clearError()
        // The reported case is a link to a sub-page, which the Subpages section is already
        // listing. That `Document` is exactly what tapping its `SubpageRow` would push, so
        // reuse it: the tap is instant, and it is the only way the link works offline.
        if let listed = subpages?.first(where: { $0.id == linkedID }) { return listed }
        do {
            return try await client.document(documentID: linkedID)
        } catch DocsAPIError.sessionExpired {
            // The shared client's `onSessionExpired` hook already raised the re-login
            // sheet. A second banner telling the user to "try again" would compete with it.
            return nil
        } catch {
            // Deliberately not `becomeUnavailable()`, unlike the load/refresh paths: a
            // 404/403 here is about the *linked* document and says nothing about the one on
            // screen. Tearing that down would discard it — and any unsaved edit — over a
            // dead link.
            showError(.editor_error_open_link)
            return nil
        }
    }

    // MARK: - Editing session

    func startEditing(focusing blockID: UUID? = nil) {
        guard hasLoadedContent else { return }
        clearError()
        // Hide the banner while the caret is in the document (`applyPendingUpdate` is guarded
        // on `!isEditing` anyway) — but **keep the stash, and record nothing**. Entering edit
        // mode is not local work: there is nothing yet that could overwrite the server's copy,
        // so a conflict recorded here would be a *phantom* — a pill and an enqueue-hold on a
        // document with no unsaved changes, which nothing on the clean path would clear and
        // whose "Keep my version" would have nothing to push. And destroying the stash here
        // would blind `markDirty`, which is where the real detection has to happen: it is the
        // moment local work first exists.
        updateAvailable = false
        if blocks.isEmpty {
            let seed = EditorBlock(kind: .paragraph)
            blocks = [seed]
            mode = .blocks
            focusBlock(seed.id, cursorAt: 0)
            return
        }
        mode = .blocks
        if let blockID, let index = blockIndex(blockID) {
            focusBlock(blockID, cursorAt: (blocks[index].text as NSString).length)
        }
    }

    func finishEditing() {
        flushPendingChanges()
        // Sync the reading-mode source to the edited blocks so its consumers (Options
        // "copy markdown", a late photo insert) reflect the session's work — but *only*
        // when the blocks diverged from the loaded source. An unedited session must
        // leave `rawMarkdown` as the original markdown, which the block model may parse
        // lossily: the reading-mode photo branch is reachable only after `finishEditing`,
        // so an unconditional resync would make a photo upload landing after Done save
        // `serializeMarkdown(blocks)` and silently normalize a non-round-tripping
        // document nobody edited. Comparing serializations (not raw strings) ignores the
        // canonicalization the parser always applies, so a genuine no-op stays a no-op.
        let serialized = serializeMarkdown(blocks)
        if serialized != serializeMarkdown(parseEditorBlocks(rawMarkdown)) {
            rawMarkdown = serialized
        }
        mode = .reading
        focusedBlockID = nil
        cursorRequest = nil
        selection = nil
        slashQueryText = nil
        clearError()
    }

    /// The markdown representation of whatever surface currently owns the content.
    /// Only **blocks** (editing) mode makes `blocks` authoritative. In reading mode
    /// `rawMarkdown` is the loaded source, kept in sync by `install`/`finishEditing`,
    /// while `blocks` may be a lossy parse of it — so a full-overwrite save triggered
    /// while reading (a late photo insert) must carry the source, not the
    /// serialization.
    func currentMarkdown() -> String {
        mode == .blocks ? serializeMarkdown(blocks) : rawMarkdown
    }

    // MARK: - Block mutations

    func updateText(blockID: UUID, text: String) {
        guard let index = blockIndex(blockID) else { return }
        guard blocks[index].text != text else { return }

        // Markdown typing shortcuts convert a paragraph as soon as its prefix lands.
        if blocks[index].kind == .paragraph, let match = detectMarkdownShortcut(text: text) {
            blocks[index].kind = match.kind
            blocks[index].text = match.remainderText
            slashQueryText = nil
            // The caret stays where the user was typing, shifted back by the
            // consumed prefix — not at the end of any pre-existing text.
            let prefixLength = (text as NSString).length - (match.remainderText as NSString).length
            let caretBefore = selection?.location ?? (text as NSString).length
            let caret = min(max(0, caretBefore - prefixLength), (match.remainderText as NSString).length)
            focusBlock(blockID, cursorAt: caret)
            markDirty()
            return
        }

        blocks[index].text = text
        slashQueryText = focusedBlockID == blockID ? slashQuery(text: text, kind: blocks[index].kind) : nil
        markDirty()
    }

    func splitBlock(blockID: UUID, at offset: Int) {
        guard let index = blockIndex(blockID) else { return }
        let block = blocks[index]
        slashQueryText = nil

        // "```swift" or "---" followed by Return converts instead of splitting.
        if block.kind == .paragraph, let match = detectEnterShortcut(text: block.text) {
            blocks[index].kind = match.kind
            blocks[index].text = match.remainderText
            if match.kind == .divider {
                let newBlock = EditorBlock(kind: .paragraph)
                blocks.insert(newBlock, at: index + 1)
                focusBlock(newBlock.id, cursorAt: 0)
            } else {
                focusBlock(block.id, cursorAt: 0)
            }
            markDirty()
            return
        }

        // Enter on an empty list item escapes back to a paragraph.
        if block.text.isEmpty, isListKind(block.kind) {
            blocks[index].kind = .paragraph
            focusBlock(block.id, cursorAt: 0)
            markDirty()
            return
        }

        let text = block.text as NSString
        let splitOffset = min(max(0, offset), text.length)
        blocks[index].text = text.substring(to: splitOffset)
        let newBlock = EditorBlock(
            kind: continuationKind(after: block.kind),
            text: text.substring(from: splitOffset)
        )
        blocks.insert(newBlock, at: index + 1)
        focusBlock(newBlock.id, cursorAt: 0)
        markDirty()
    }

    func mergeBlockWithPrevious(blockID: UUID) {
        guard let index = blockIndex(blockID) else { return }
        let block = blocks[index]

        // A styled block first converts back to a paragraph.
        if block.kind != .paragraph {
            blocks[index].kind = .paragraph
            focusBlock(block.id, cursorAt: 0)
            markDirty()
            return
        }

        guard index > 0 else { return }
        let previous = blocks[index - 1]
        switch previous.kind {
        case .divider, .image:
            // Leaf blocks (divider, image) have no text to merge into; backspace
            // at the start of the following block removes the leaf as a unit.
            blocks.remove(at: index - 1)
            focusBlock(block.id, cursorAt: 0)
            markDirty()
        case .codeBlock, .unknown:
            let caret = (previous.text as NSString).length
            if !block.text.isEmpty {
                blocks[index - 1].text += previous.text.isEmpty ? block.text : "\n" + block.text
            }
            blocks.remove(at: index)
            focusBlock(previous.id, cursorAt: caret)
            markDirty()
        default:
            let caret = (previous.text as NSString).length
            blocks[index - 1].text += block.text
            blocks.remove(at: index)
            focusBlock(previous.id, cursorAt: caret)
            markDirty()
        }
    }

    func toggleChecklist(blockID: UUID) {
        guard let index = blockIndex(blockID),
            case .checklistItem(let checked) = blocks[index].kind
        else { return }
        blocks[index].kind = .checklistItem(checked: !checked)
        markDirty()
    }

    func convertBlock(blockID: UUID, to kind: BlockKind) {
        guard let index = blockIndex(blockID) else { return }
        // An image's data lives in its kind's associated values; converting would
        // silently destroy the image, so images are never converted.
        if case .image = blocks[index].kind { return }
        if blocks[index].kind == kind {
            blocks[index].kind = .paragraph
        } else {
            blocks[index].kind = kind
            if kind == .divider {
                blocks[index].text = ""
            }
        }
        markDirty()
    }

    func insertBlock(after blockID: UUID?, kind: BlockKind) {
        let newBlock = EditorBlock(kind: kind)
        let insertionIndex: Int
        if let blockID, let index = blockIndex(blockID) {
            insertionIndex = index + 1
        } else {
            insertionIndex = blocks.count
        }
        blocks.insert(newBlock, at: insertionIndex)
        if kind != .divider {
            focusBlock(newBlock.id, cursorAt: 0)
        }
        markDirty()
    }

    // MARK: - Formatting bar actions

    /// Wraps (or unwraps) the current selection in an inline markdown marker.
    /// With no selection, inserts a marker pair and places the caret between.
    func applyInlineMarker(_ marker: String) {
        guard let focusedBlockID, let index = blockIndex(focusedBlockID) else { return }
        switch blocks[index].kind {
        case .codeBlock, .unknown, .divider, .image:
            return
        default:
            break
        }
        let range = selection ?? NSRange(location: (blocks[index].text as NSString).length, length: 0)
        let result = wrapInlineMarker(text: blocks[index].text, range: range, marker: marker)
        blocks[index].text = result.text
        cursorRequest = CursorRequest(
            blockID: focusedBlockID, offset: result.selection.location, length: result.selection.length)
        selection = result.selection
        markDirty()
    }

    /// Converts the focused block's type (blocks mode).
    func convertFocusedBlock(to kind: BlockKind) {
        guard let focusedBlockID else { return }
        convertBlock(blockID: focusedBlockID, to: kind)
    }

    // MARK: - Links

    /// Whether the link button can act: a focused block whose text is read as
    /// inline markdown. A code block's text is literal, so a link written into
    /// it would never become one.
    var canEditLink: Bool {
        guard hasLoadedContent, mode == .blocks, let focusedBlockID, let index = blockIndex(focusedBlockID) else {
            return false
        }
        return rendersInlineMarkdown(blocks[index].kind)
    }

    /// The link button. Retargets the link under the caret if there is one,
    /// otherwise creates one from the selection (whose text becomes the label).
    func beginLinkEditing() {
        guard canEditLink, let focusedBlockID, let index = blockIndex(focusedBlockID) else { return }
        let text = blocks[index].text
        let source = text as NSString
        var range = selection ?? NSRange(location: source.length, length: 0)
        range.location = min(max(0, range.location), source.length)
        range.length = min(max(0, range.length), source.length - range.location)

        if let span = linkSpan(in: text, containing: range.location) {
            beginLinkEditing(blockID: focusedBlockID, span: span)
            return
        }
        linkEditor = LinkEditorRequest(
            blockID: focusedBlockID,
            span: nil,
            label: source.substring(with: range),
            url: "",
            range: range
        )
    }

    /// A tap on a link's label.
    func beginLinkEditing(blockID: UUID, span: InlineLinkSpan) {
        guard hasLoadedContent, blockIndex(blockID) != nil else { return }
        linkEditor = LinkEditorRequest(
            blockID: blockID, span: span, label: span.label, url: span.url, range: span.range)
    }

    func cancelLinkEditing() {
        linkEditor = nil
    }

    /// Writes the link into the block's markdown. Returns false — leaving the
    /// sheet open for correction — when the destination cannot be embedded
    /// safely; `sanitizedLinkURL` explains which spellings those are. An empty
    /// label falls back to the destination, since `[](url)` is not a link.
    @discardableResult
    func commitLinkEditing(label: String, url: String) -> Bool {
        guard let request = linkEditor, let index = blockIndex(request.blockID) else { return false }
        guard let safeURL = sanitizedLinkURL(url) else { return false }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalLabel = trimmedLabel.isEmpty ? safeURL : trimmedLabel

        let text = blocks[index].text
        // Re-locate the span: the sheet is async, and the block's text may have
        // been replaced underneath it by a revalidation. A stale range would
        // splice the link into the middle of unrelated words.
        let edit: MarkdownLinkEdit
        if let span = request.span {
            guard let current = linkSpan(in: text, containing: span.range.location), current == span else {
                linkEditor = nil
                return false
            }
            edit = replaceMarkdownLink(in: text, span: current, label: finalLabel, url: safeURL)
        } else {
            guard NSMaxRange(request.range) <= (text as NSString).length else {
                linkEditor = nil
                return false
            }
            edit = insertMarkdownLink(in: text, range: request.range, label: finalLabel, url: safeURL)
        }

        linkEditor = nil
        blocks[index].text = edit.text
        cursorRequest = CursorRequest(blockID: request.blockID, offset: edit.selection.location)
        selection = edit.selection
        markDirty()
        return true
    }

    /// "Remove link" — keeps the label, drops the syntax.
    func removeLink(blockID: UUID, span: InlineLinkSpan) {
        guard let index = blockIndex(blockID) else { return }
        let text = blocks[index].text
        guard let current = linkSpan(in: text, containing: span.range.location), current == span else { return }
        let edit = removeMarkdownLink(in: text, span: current)
        blocks[index].text = edit.text
        cursorRequest = CursorRequest(blockID: blockID, offset: edit.selection.location)
        selection = edit.selection
        markDirty()
    }

    /// Inserts a divider below the focused block (or at the end), keeping an
    /// editable paragraph after it.
    func insertDividerBelowFocused() {
        let anchorID = focusedBlockID ?? blocks.last?.id
        let insertionIndex: Int
        if let anchorID, let index = blockIndex(anchorID) {
            insertionIndex = index + 1
        } else {
            insertionIndex = blocks.count
        }
        let divider = EditorBlock(kind: .divider)
        blocks.insert(divider, at: insertionIndex)
        if insertionIndex == blocks.count - 1 {
            let paragraph = EditorBlock(kind: .paragraph)
            blocks.insert(paragraph, at: insertionIndex + 1)
            focusBlock(paragraph.id, cursorAt: 0)
        }
        markDirty()
    }

    /// Applies a block type chosen from the slash menu to the focused block,
    /// consuming the "/query" text.
    func applySlashSelection(_ item: SlashMenuItem) {
        guard let focusedBlockID, let index = blockIndex(focusedBlockID) else { return }
        // Photo is the one item that can decline: while an upload is in flight the
        // picker won't open. Bail out *before* consuming the "/photo" text, or the
        // selection would silently eat what the user typed and do nothing.
        if case .insertPhoto = item.action, !canInsertPhoto { return }
        blocks[index].text = ""
        slashQueryText = nil
        switch item.action {
        case .convert(.divider):
            blocks[index].kind = .divider
            let newBlock = EditorBlock(kind: .paragraph)
            blocks.insert(newBlock, at: index + 1)
            focusBlock(newBlock.id, cursorAt: 0)
        case .convert(let kind):
            blocks[index].kind = kind
            focusBlock(focusedBlockID, cursorAt: 0)
        case .insertPhoto:
            // The block stays an empty paragraph; `insertImageBlock` replaces it
            // in place once the upload succeeds (and leaves it alone if it
            // doesn't, so a failed pick never strands a placeholder).
            focusBlock(focusedBlockID, cursorAt: 0)
            requestPhotoInsertion()
        }
        markDirty()
    }

    // MARK: - Photo insertion

    /// Editing may only begin once content has loaded, and one upload at a time.
    /// Both photo entry points share this gate.
    var canInsertPhoto: Bool { hasLoadedContent && !isUploadingPhoto }

    /// Entry point for both the formatting-bar button and the slash-menu item.
    func requestPhotoInsertion() {
        guard canInsertPhoto else { return }
        isPhotoPickerPresented = true
    }

    /// Runs the picked photo through prepare → upload → readiness poll and
    /// inserts the resulting `.image` block. A cancelled pick (`nil` data) is a
    /// silent no-op; any failure sets friendly copy and inserts nothing, so a
    /// broken upload can never leave a placeholder in the document.
    func insertPhoto(loadingData: @Sendable () async throws -> Data?) async {
        guard canInsertPhoto else { return }
        // Clear a previous failure's copy, like every other async intent method —
        // otherwise a successful retry leaves the red banner on screen.
        clearError()
        isUploadingPhoto = true
        defer { isUploadingPhoto = false }
        do {
            guard let originalData = try await loadingData() else { return }
            // Decoding a 48 MP HEIC and re-encoding it must not block the main
            // thread (the uploading spinner would freeze). `preparedJPEGData` is a
            // pure function over Sendable values, so it can run anywhere.
            let prepared = await Task.detached(priority: .userInitiated) {
                preparedJPEGData(from: originalData)
            }.value
            guard let jpegData = prepared else {
                reportPhotoFailure()
                return
            }
            let mediaCheckPath = try await client.uploadAttachment(
                documentID: documentID, fileName: "photo.jpg", contentType: "image/jpeg", data: jpegData)
            guard let urlString = await readyMediaURLString(fromMediaCheckPath: mediaCheckPath) else {
                reportPhotoFailure()
                return
            }
            insertImageBlock(url: urlString)
        } catch {
            reportPhotoFailure()
        }
    }

    /// The document can go away mid-upload (404 revalidation, or a delete). Its
    /// terminal message must not be masked by copy inviting a retry that the now
    /// disabled button can't perform.
    private func reportPhotoFailure() {
        guard hasLoadedContent, !isDocumentDiscarded else { return }
        showError(Self.photoErrorKey)
    }

    /// Polls media-check until the attachment is ready and returns the absolute
    /// media URL to embed (matching what the web client persists). Falls back to
    /// the URL derived from the upload key if readiness can't be confirmed in
    /// time — the upload already succeeded, so the URL must never be lost.
    private func readyMediaURLString(fromMediaCheckPath path: String) async -> String? {
        for attempt in 0..<Self.mediaCheckMaxAttempts {
            if attempt > 0 { try? await Task.sleep(for: mediaCheckRetryInterval) }
            if let response = try? await client.checkMedia(path: path),
                response.status == MediaCheckResponse.readyStatus, let file = response.file,
                let absolute = await client.absoluteServerURL(for: file)
            {
                return absolute.absoluteString
            }
        }
        guard let key = attachmentKey(fromMediaCheckPath: path),
            let absolute = await client.absoluteServerURL(for: "/media/" + key)
        else { return nil }
        return absolute.absoluteString
    }

    /// Mirrors the divider slash behavior: replace a focused empty paragraph in
    /// place, otherwise insert below the focused block, and always leave an
    /// editable paragraph after the image (an image is a non-editable leaf).
    ///
    /// The upload can outlive the editing session: neither Done nor a navigation
    /// pop cancels the picker's `Task`. **Every** path therefore persists
    /// immediately rather than through `markDirty`'s debounce, whose `autosaveTask`
    /// is owned by this view model — a pop releases the last strong reference, so
    /// the debounced `self?.flushPendingChanges()` no-ops and the finished upload
    /// is silently lost. A pop also leaves `mode` untouched (only `finishEditing`
    /// sets `.reading`), so this must not be keyed off the mode. Flushing enqueues
    /// on the app-scoped save coordinator, which owns its `Task`s precisely so
    /// navigating away can never cancel a save.
    private func insertImageBlock(url: String) {
        // The document may have been deleted, or gone 404, while the photo was
        // uploading. Saving now would resurrect it — `discardPendingWork` has
        // already removed its draft, and `enqueue` would write a fresh one.
        guard hasLoadedContent, !isDocumentDiscarded else { return }
        defer { flushPendingChanges() }

        // The session already ended (Done was tapped while the upload was in
        // flight). Append to the authoritative source — `blocks` may be a lossy
        // parse of it — rather than to a serialization that would rewrite what the
        // user actually wrote.
        if mode == .reading {
            let source = currentMarkdown()
            let appended = markdownAppendingImage(to: source, url: url)
            // A source whose tail is an unterminated code fence swallows anything
            // appended to it (`closesCodeFence` never matches a blank line), so the
            // image would render as literal code. Never rewrite the source to make
            // room, and never report success without producing an image.
            guard addsImage(to: source, after: appended, url: url) else {
                reportPhotoFailure()
                return
            }
            rawMarkdown = appended
            blocks = parseEditorBlocks(appended)
            markDirty()
            return
        }

        let image = EditorBlock(kind: .image(alt: "", url: url))
        let trailing = EditorBlock(kind: .paragraph)
        var updated = blocks
        if let focusedBlockID, let index = blockIndex(focusedBlockID) {
            if updated[index].kind == .paragraph, updated[index].text.isEmpty {
                updated[index] = image
                updated.insert(trailing, at: index + 1)
            } else {
                updated.insert(image, at: index + 1)
                updated.insert(trailing, at: index + 2)
            }
        } else {
            updated.append(image)
            updated.append(trailing)
        }
        // Blocks mode saves `serializeMarkdown(blocks)`, and `MarkdownYjs.encode`
        // re-parses exactly that — so a neighbouring paragraph holding a bare "```"
        // turns the serialized image line into code and the photo never reaches the
        // server, even though the editor still shows it. Verify against the *saved*
        // representation, not the block array.
        guard addsImage(to: currentMarkdown(), after: serializeMarkdown(updated), url: url) else {
            reportPhotoFailure()
            return
        }
        blocks = updated
        focusBlock(trailing.id, cursorAt: 0)
        markDirty()
    }

    /// Whether the edit actually *added* an image. **All three** insertion paths
    /// (markdown, reading, blocks) must check this: none may report success without
    /// producing an image. A fenced code block — open at the end of the source,
    /// wrapping the caret, or formed by a neighbouring block on serialization —
    /// swallows the image line whole.
    ///
    /// Counts rather than asking `contains`: a document that already held a
    /// byte-identical `![](url)` would satisfy `contains` even when the new line was
    /// swallowed. Fresh attachment UUIDs make that unreachable today, but that is an
    /// invariant of the *server*, not of this function.
    private func addsImage(to before: String, after: String, url: String) -> Bool {
        imageCount(in: after, url: url) > imageCount(in: before, url: url)
    }

    private func imageCount(in markdown: String, url: String) -> Int {
        parseEditorBlocks(markdown).filter { $0.kind == .image(alt: "", url: url) }.count
    }

    /// Appends a standalone, blank-line-separated image line. That keeps it out of
    /// a trailing paragraph — but it does **not** guarantee an `.image` block: a
    /// source ending in an unterminated code fence swallows everything after it.
    /// The caller must verify the result rather than assume.
    private func markdownAppendingImage(to source: String, url: String) -> String {
        let imageLine = "![](\(url))\n"
        guard !source.isEmpty else { return imageLine }
        // Compare the trailing *byte*, not the trailing Character: Swift treats
        // "\r\n" as one extended grapheme cluster, so `hasSuffix("\n")` is false for
        // a CRLF-terminated source and we'd add a newline that is already there.
        let endsWithNewline = source.utf8.last == 0x0A
        return source + (endsWithNewline ? "" : "\n") + "\n" + imageLine
    }

    /// Tap on the empty canvas below the last block: reuse a trailing empty
    /// paragraph if there is one, otherwise append a new one.
    func appendParagraphAtEnd() {
        if let last = blocks.last, last.kind == .paragraph, last.text.isEmpty {
            focusBlock(last.id, cursorAt: 0)
            return
        }
        insertBlock(after: blocks.last?.id, kind: .paragraph)
    }

    func updateTitle(_ text: String) {
        guard title != text else { return }
        title = text
        markDirty()
    }

    // MARK: - Saving

    /// Cancels the debounce and hands the current content to the save
    /// coordinator, which persists a draft immediately and saves in the
    /// background, outliving this screen.
    func flushPendingChanges() {
        autosaveTask?.cancel()
        autosaveTask = nil
        dirtySince = nil
        // `hasLoadedContent` mirrors `startEditing`'s invariant at the exit: with
        // no content loaded, `currentMarkdown()` is the empty document, and a
        // full-overwrite save of that destroys the server copy. `isDocumentDiscarded`
        // (delete only — never the recoverable 404/403 state) keeps a deleted
        // document from acquiring a fresh draft and a doomed PATCH. This is the
        // funnel that must never be bypassed.
        guard !isDocumentDiscarded, hasLoadedContent, isDirty else { return }
        adoptQueuedTitleIfUnseen()
        isDirty = false
        let markdown = currentMarkdown()
        if markdown == savedMarkdown, title == savedTitle {
            return
        }
        savedMarkdown = markdown
        savedTitle = title
        displayedSourceMarkdown = markdown
        saveCoordinator.enqueue(documentID: documentID, title: title, markdown: markdown, baseline: serverBaseline)
    }

    /// Manual save: flushes dirty edits, and retries the last content after a
    /// failure. The two are not exclusive — typing and undoing after a failed save
    /// leaves `isDirty` true with content that matches `savedMarkdown`, so the
    /// flush enqueues nothing. Returning there would swallow the retry and strand
    /// the document behind its failed save (`reconcileDraft` pins the screen while
    /// a failed save's draft survives).
    func saveNow() {
        guard !isDocumentDiscarded else { return }
        if isDirty {
            flushPendingChanges()
        }
        guard saveCoordinator.pendingSave(documentID: documentID) == nil else { return }
        adoptQueuedTitleIfUnseen()
        // Retry a hard failure (`.failed`) or a queued transient one (`.pendingSync`).
        // The latter matters when the failure happened while online (a 5xx / rate
        // limit / HTTP-3 stall): the reconnect/foreground auto-sync triggers won't
        // fire, so this manual retry is the only resync without a background cycle.
        // The retry re-pushes the draft's content, so it descends from that draft's
        // own recorded baseline.
        // Exhaustive on purpose — see `hasUnsavedLocalContent`.
        switch saveCoordinator.state(for: documentID) {
        case .failed, .pendingSync:
            saveCoordinator.enqueue(
                documentID: documentID, title: savedTitle, markdown: savedMarkdown,
                baseline: saveCoordinator.storedDraft(documentID: documentID)?.baseline)
        case .idle, .saving, .saved:
            break
        }
    }

    /// Puts a title resolved by `draftSyncDecision` on screen, and on the stored draft so every
    /// replay funnel pushes the same one.
    ///
    /// Call sites pass the title of **any** `.push`; the guard below is what makes it an adopt.
    /// A push that keeps the draft's own title resolves to the title already on screen and no-ops
    /// — so the only thing that ever gets through is a title the decision took from the server,
    /// i.e. a co-author's rename the user's draft has no claim on (they never renamed it
    /// themselves; had they, the decision would say `.conflict` or keep theirs).
    ///
    /// `savedTitle` follows, so this can't read as an unsaved title edit and enqueue a spurious
    /// save: the adopted title is already in the draft (and in the push that carries it).
    private func adoptServerTitle(_ resolved: String) {
        guard resolved != title else { return }
        title = resolved
        savedTitle = resolved
        saveCoordinator.adoptServerTitle(documentID: documentID, title: resolved)
    }

    /// A background `syncPendingDrafts` replay can adopt a co-author's rename into this
    /// document's queued work while this screen is open — and the editor **never refetches on
    /// foreground** (it only flushes), which is exactly when that replay runs. Both save funnels
    /// PATCH a title, so pushing the on-screen one would revert the rename the replay just
    /// adopted.
    ///
    /// Unsaved local work outranks the server: a queued save (or the draft behind it) holds a
    /// title the server does not have yet, written either by this editor or by a replay that has
    /// just resolved it. Only when there is none does the newest **known server** title apply —
    /// which is how the rename still survives once the adopted save has landed and taken its
    /// draft with it. The one thing that outranks both is an **unflushed local rename** (`title
    /// != savedTitle`): the user's own edit, and what makes a reconcile call two titles a
    /// conflict rather than a merge.
    private func adoptQueuedTitleIfUnseen() {
        guard title == savedTitle,
            let newestTitle = saveCoordinator.pendingSave(documentID: documentID)?.title
                ?? saveCoordinator.storedDraft(documentID: documentID)?.title
                ?? saveCoordinator.knownServerTitle(documentID: documentID),
            newestTitle != title
        else { return }
        title = newestTitle
        savedTitle = newestTitle
    }

    // MARK: - Conflict resolution

    /// "Keep my version": flush any in-progress edit first (so the held push captures
    /// the newest content), then release the coordinator's enqueue-hold and push —
    /// an unchecked, last-writer-wins overwrite the user chose (the overwritten
    /// server version is recoverable from the web's version history).
    func resolveConflictKeepingMine() {
        guard let conflict = saveCoordinator.conflict(for: documentID) else { return }
        // The sheet promises "Overwrites the server copy", so it must never be a silent no-op.
        // By the lifecycle rule a conflict only stands while local work exists, so this is a
        // belt-and-braces check rather than an expected branch — but if there is genuinely
        // nothing to push, the record is moot and pushing the *on-screen* body would overwrite
        // the co-author with the server's own older copy. Release it instead.
        guard
            isDirty || saveCoordinator.pendingSave(documentID: documentID) != nil
                || saveCoordinator.storedDraft(documentID: documentID) != nil
        else {
            saveCoordinator.clearResolvedConflict(documentID: documentID)
            return
        }
        // Advance the **editor's** baseline too, not just the draft's. The coordinator's
        // `resolveConflictKeepingLocal` rewrites the stored draft so a failed push isn't
        // re-detected as the same conflict forever — but `enqueue` rebuilds the draft from
        // whatever baseline its *caller* passes, and `flushPendingChanges` passes this one.
        // So a stale `serverBaseline` here would clobber that advance on the very next
        // autosave (the likely sequence: the released push fails offline, the user keeps
        // typing) and the identical conflict would be re-detected and re-held — silently
        // undoing the answer they just gave. The user acknowledged the server's copy and
        // chose to overwrite it, so the on-screen content now descends from *that* server
        // state. Only the timestamp is knowable (`SyncConflict` carries no server markdown),
        // and only the timestamp is needed: rule 2's date check short-circuits first.
        // Mirror the coordinator's `?? draft.markdown` fallback exactly — do NOT fabricate `""`.
        // A legacy (baseline-less) draft leaves `serverBaseline == nil` here, and an empty
        // baseline body makes rule 2's content tiebreak match any **empty server document**:
        // a co-author who deliberately empties the doc would then be silently full-overwritten
        // instead of raising a new conflict. And this value *wins*: `flushPendingChanges()`
        // below re-enqueues with it, and `enqueue` persists the caller's baseline verbatim — so
        // the coordinator's protection is dead code on exactly the path (a dirty editor
        // resolving a conflict) it was written for. `currentMarkdown()` is precisely the body
        // the flush is about to push, so the tiebreak can only ever match our own writing.
        //
        // The **title** rides along unchanged, and the advanced timestamp is what makes the
        // answer stick for it too: `draftTitleOutcome` keeps the draft's title whenever the
        // server is no newer than the baseline, so the retry after a failed push pushes the title
        // the user chose rather than re-raising the title conflict they just answered.
        let baselineBeforeResolving = serverBaseline
        serverBaseline = DraftBaseline(
            serverUpdatedAt: conflict.serverUpdatedAt, markdown: serverBaseline?.markdown ?? currentMarkdown(),
            title: serverBaseline?.title)
        flushPendingChanges()
        // **Re-check after the flush.** `isDirty` is not proof there is anything to push:
        // `flushPendingChanges` enqueues nothing when the content serializes back to
        // `savedMarkdown` (the user edited and then undid it). The pre-flush guard passed, the
        // flush no-opped, `resolveConflictKeepingLocal` found no queued slot and no draft and
        // started nothing — yet the conflict was cleared, so the next clean revalidation
        // installed the co-author's body. The sheet promised "Overwrites the server copy" and
        // the user got precisely the outcome they declined. With nothing to push, the record is
        // simply moot: release it and leave the baseline alone.
        guard
            saveCoordinator.pendingSave(documentID: documentID) != nil
                || saveCoordinator.storedDraft(documentID: documentID) != nil
        else {
            // Nothing was pushed, so do not pretend we overwrote anything: put the baseline back.
            serverBaseline = baselineBeforeResolving
            saveCoordinator.clearResolvedConflict(documentID: documentID)
            return
        }
        saveCoordinator.resolveConflictKeepingLocal(documentID: documentID)
    }

    /// "Keep the server version": the one sanctioned discard. In order: **flush** any
    /// in-progress edit into the (held) draft, end the editing session, **fetch** the
    /// server body, re-check that nothing changed under the await, and only then discard
    /// the local work and install what was fetched. Nothing is destroyed until the body
    /// that replaces it is in hand, and no content is ever taken from the conflict record
    /// itself — it carries none by design.
    func resolveConflictKeepingServer() async {
        guard saveCoordinator.conflict(for: documentID) != nil else { return }
        // **End the editing session properly, and do it before the fetch.** `finishEditing()`
        // is that teardown — flush, resync `rawMarkdown` to the edited blocks (only when they
        // diverged), reset mode/focus/selection, clear the error — and reusing it is what
        // keeps this in step with it. Hand-rolling the same steps had already drifted twice:
        //
        // 1. It cleared `isDirty` **without flushing**, so text typed after the pill appeared
        //    lived only in `blocks`. On every non-success exit below (the failed fetch — the
        //    *common* case here; `mayPredateSave`; a superseded generation) the screen went on
        //    rendering it while it existed in no draft, and with `isDirty` false
        //    `flushPendingChanges` early-returns forever, so navigating away lost it silently.
        // 2. It omitted the `rawMarkdown` resync, leaving the reading-mode source stale after
        //    a flushed edit.
        //
        // Flushing here costs nothing: the conflict is still recorded, so `enqueue` takes the
        // hold — nothing is pushed, the edit merely lands in the draft/queued slot, which the
        // snapshot below already treats as "part of what the user chose to discard". The
        // success path discards it as intended; every failure path leaves the screen exactly
        // backed by disk.
        finishEditing()

        // **Fetch before discarding.** Deleting the draft first and *then* refreshing
        // meant a failed fetch — the common case, since a conflict is usually reviewed
        // on the same flaky connection that caused it — left the discarded body still on
        // screen with nothing backing it on disk, the conflict record cleared, and the
        // stale baseline intact. The next keystroke would then full-overwrite the server
        // copy the user had explicitly chosen to keep. The draft may only be destroyed
        // once the body that replaces it is actually in hand.
        clearError()
        revalidationGeneration += 1
        let generation = revalidationGeneration
        let diagnosticsMarker = diagnostics?.marker()
        // The exact local work the user chose to discard. Only *this* may be destroyed —
        // note the held save is part of it (the enqueue-hold parks one whenever they kept
        // typing after the conflict landed), so this is a snapshot to compare against, not
        // an expectation of "nothing pending".
        let discardedDraft = saveCoordinator.storedDraft(documentID: documentID)
        let discardedSave = saveCoordinator.pendingSave(documentID: documentID)
        do {
            let saveMarker = saveCoordinator.saveMarker(documentID: documentID)
            let formatted = try await client.formattedContent(documentID: documentID)
            guard generation == revalidationGeneration, !Task.isCancelled else { return }
            // A body that may predate one of our own saves must never be installed (it
            // would resurrect what that save replaced, and the next full-overwrite save
            // would push it back). Keep the draft and the conflict so the user can retry.
            guard !saveCoordinator.mayPredateSave(saveMarker) else {
                showError(.editor_error_refresh)
                return
            }
            // The user can tap straight back into the document while this fetch is in
            // flight — ending the editing session above does not lock the screen. Work
            // made *after* they chose the server copy was never part of that choice, so
            // installing over it would destroy an edit they never agreed to discard (on
            // screen *and* on disk). Compare against the snapshot rather than demanding
            // "nothing pending": a save already held by the enqueue-hold *is* part of what
            // they chose to discard. Bail out and leave the conflict standing; the pill is
            // still there, so they can decide again with the new edit in hand.
            guard !isDirty,
                saveCoordinator.pendingSave(documentID: documentID) == discardedSave,
                saveCoordinator.storedDraft(documentID: documentID) == discardedDraft
            else { return }
            // The winning body is in hand: now it is safe to cost the user their draft.
            saveCoordinator.resolveConflictKeepingServer(documentID: documentID)
            installFetched(formatted)
            markAvailableAgain()
            await loadChildren()
        } catch let error as DocsAPIError where error == .notFound || error == .forbidden {
            guard generation == revalidationGeneration else { return }
            becomeUnavailable()
            errorDetail = requestFailureDetail(after: diagnosticsMarker, in: diagnostics)
        } catch {
            guard generation == revalidationGeneration else { return }
            // The draft and the conflict record both survive, so the pill and sheet stay
            // available and everything on screen is still backed by disk.
            showError(
                .editor_error_refresh,
                detail: requestFailureDetail(after: diagnosticsMarker, in: diagnostics))
        }
    }

    /// The user is about to make local work that will full-overwrite a server body the app
    /// has **already fetched and shown them** (the "Updated" banner's stash). Dropping that
    /// stash silently is the same defect as skipping detection in `apply`'s dirty branch,
    /// just on the other side of the race: type one character *before* the fetch resolves and
    /// the push is held and the user is asked; type one character *after* it resolves and the
    /// identical push used to go through unchecked — no pill, no prompt, and the co-author's
    /// edit gone. Whether a destructive push is checked must not depend on when the finger
    /// lands, so record the conflict as the stash is abandoned.
    ///
    /// Guarded exactly like the other detection sites: no save may be in flight (the
    /// coordinator's invariant), and rule 1 is fed from `lastConfirmedPush(documentID:)` so a
    /// body that is *our own* confirmed write never conflicts against the user.
    private func abandonPendingFreshContent() {
        guard let pending = pendingFreshContent else {
            updateAvailable = false
            return
        }
        updateAvailable = false
        pendingFreshContent = nil
        guard !saveCoordinator.hasSaveInFlight(documentID: documentID) else {
            // Same rule as `apply`: a stash abandoned while a save is on the wire is still an
            // observed server body. Hand it over rather than dropping it — this was the one
            // detection site left that discarded an observation instead of deferring it.
            saveCoordinator.noteServerObservedDuringSave(
                documentID: documentID, serverUpdatedAt: pending.serverUpdatedAt, markdown: pending.markdown)
            return
        }
        // Optional baseline, and the draft's own clock for rule 3 — see `apply`'s dirty branch:
        // a legacy (baseline-less) draft must not be the one case that gets no detection.
        // The stash carries the title of the fetch that produced it, and `reconcileClean` already
        // applied that title on the spot (titles are never stashed, only bodies) — so an
        // untouched on-screen title still equals it and nothing here conflicts. If the user
        // renamed it since, the two disagree against a baseline older than both: the "renamed on
        // both sides" conflict, asked about rather than full-overwritten. Nothing is adopted
        // here: the title is already on screen.
        let draft = saveCoordinator.storedDraft(documentID: documentID)
        switch draftSyncDecision(
            baseline: serverBaseline,
            lastPushedMarkdown: saveCoordinator.lastConfirmedPush(documentID: documentID),
            localMarkdown: currentMarkdown(),
            draftTitle: title,
            draftUpdatedAt: draft?.updatedAt ?? dirtySince ?? Date(),
            serverTitle: pending.title,
            serverUpdatedAt: pending.serverUpdatedAt,
            serverMarkdown: pending.markdown)
        {
        case .conflict, .discardServerWins:
            saveCoordinator.recordConflict(documentID: documentID, serverUpdatedAt: pending.serverUpdatedAt)
        case .push:
            break  // nothing to ask about; the stash is simply abandoned
        }
    }

    private func markDirty() {
        // `dirtySince` FIRST: `abandonPendingFreshContent` feeds it to rule 3 as the local clock
        // for a baseline-less document, and a nil `dirtySince` there falls back to `Date()` —
        // which is always within tolerance of the server, so rule 3 would answer `.push`
        // unconditionally and drop the fetched server body with no conflict recorded.
        let now = Date()
        if dirtySince == nil {
            dirtySince = now
        }
        abandonPendingFreshContent()
        isDirty = true
        if let dirtySince, now.timeIntervalSince(dirtySince) >= Self.maxAutosaveDeferral {
            flushPendingChanges()
            return
        }
        let interval = autosaveInterval
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self?.flushPendingChanges()
        }
    }

    // MARK: - Helpers

    private func blockIndex(_ blockID: UUID) -> Int? {
        blocks.firstIndex { $0.id == blockID }
    }

    private func focusBlock(_ blockID: UUID, cursorAt offset: Int) {
        focusedBlockID = blockID
        cursorRequest = CursorRequest(blockID: blockID, offset: offset)
        // Programmatic caret moves don't echo back through the text view's
        // delegate, so keep the tracked selection in sync here.
        selection = NSRange(location: offset, length: 0)
    }

    private func isListKind(_ kind: BlockKind) -> Bool {
        switch kind {
        case .bulletItem, .numberedItem, .checklistItem:
            return true
        default:
            return false
        }
    }

    private func continuationKind(after kind: BlockKind) -> BlockKind {
        switch kind {
        case .bulletItem:
            return .bulletItem
        case .numberedItem:
            return .numberedItem
        case .checklistItem:
            return .checklistItem(checked: false)
        default:
            return .paragraph
        }
    }
}
