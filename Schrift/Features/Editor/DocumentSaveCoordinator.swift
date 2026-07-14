import UIKit

/// Begins/ends a system background-task assertion around each save so an
/// in-flight save gets background runtime to finish after the user leaves the
/// app. Injectable so tests (and previews) can avoid `UIApplication`.
struct BackgroundTaskProvider {
    let begin: @MainActor (String) -> Int
    let end: @MainActor (Int) -> Void

    static let uiApplication = BackgroundTaskProvider(
        begin: { name in
            UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: nil).rawValue
        },
        end: { rawValue in
            let identifier = UIBackgroundTaskIdentifier(rawValue: rawValue)
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
        }
    )

    static let noop = BackgroundTaskProvider(begin: { _ in 0 }, end: { _ in })
}

/// App-scoped save queue for document content.
///
/// Saves run in unstructured tasks owned by this object — not by any editor
/// screen — so navigating away, switching documents, or dismissing the editor
/// never cancels them. Per document, at most one save is in flight; newer
/// snapshots coalesce into a single "latest wins" queued slot. Every snapshot
/// is persisted to `PendingDraftStore` before any network call and cleared
/// only once that exact content has been saved, so edits survive suspension
/// and process death; the repeatable `syncPendingDrafts()` replays them on
/// reconnect, foreground and launch (`recoverDrafts()` is the once-per-process
/// launch wrapper over it).
@MainActor
@Observable
final class DocumentSaveCoordinator {
    struct PendingSave: Equatable, Sendable {
        let title: String
        let markdown: String
    }

    enum DocSaveState: Equatable, Sendable {
        case idle
        case saving
        case saved(Date)
        /// A save failed for a transient/transport reason (offline, 5xx, rate
        /// limit) — the content is saved on-device and its draft is queued to
        /// replay via `syncPendingDrafts` on reconnect/foreground/launch. A
        /// friendlier state than `.failed`, which is reserved for a save the
        /// server rejected on the merits (and which the user must retry).
        case pendingSync
        case failed(String)
    }

    /// A fingerprint of a document's save activity, taken when a revalidation
    /// fetch is issued. Carries its own `documentID` so it can't be checked
    /// against the wrong document. See `mayPredateSave(_:)`.
    struct SaveMarker: Equatable, Sendable {
        fileprivate let documentID: UUID
        fileprivate let settledSaves: Int
        fileprivate let hadPendingSave: Bool
    }

    /// A detected conflict: the server changed under a queued offline draft. Carries
    /// only what the conflict UI needs — the server's `updated_at`, which the sheet
    /// shows so the user can tell *when* the other copy changed before choosing a
    /// winner — and deliberately **no server markdown**, so "Keep the server version"
    /// re-fetches through the view model's guarded funnel rather than installing a
    /// body the coordinator squirreled away.
    struct SyncConflict: Equatable, Sendable {
        let serverUpdatedAt: Date
    }

    private let client: DocsAPIClient
    private let draftStore: PendingDraftStore
    private let contentCache: DocumentContentCacheStore
    private let backgroundTasks: BackgroundTaskProvider

    private var states: [UUID: DocSaveState] = [:]
    private var inFlight: [UUID: Task<Void, Never>] = [:]
    private var inFlightContent: [UUID: PendingSave] = [:]
    private var queued: [UUID: PendingSave] = [:]
    /// Monotonic per-document count of saves that have settled (landed or failed).
    private var settledSaves: [UUID: Int] = [:]
    /// Documents deleted while one of their saves was in flight. That save must not
    /// resurrect any local copy when it lands.
    private var discardedDuringSave: Set<UUID> = []
    private var hasRecoveredDrafts = false
    /// Re-entrancy guard for `syncPendingDrafts()`: it is repeatable (reconnect,
    /// foreground, launch), and overlapping triggers must not double-replay a draft.
    private var isSyncingDrafts = false
    /// Documents whose queued draft conflicts with the server (the sync path or the
    /// editor detected the server moved on). The push is **held** until the user
    /// resolves it via `resolveConflictKeeping{Local,Server}`.
    private var conflicts: [UUID: SyncConflict] = [:]
    /// The markdown of the last save this coordinator confirmed for each document,
    /// so `draftSyncDecision` rule 1 ("the server's most recent writer was us") can
    /// fire — including across a relaunch, via the persisted `lastPushedMarkdown`
    /// that `enqueue`/`finish` copy from and to this map.
    private var lastConfirmedPushMarkdown: [UUID: String] = [:]

    init(
        client: DocsAPIClient,
        draftStore: PendingDraftStore = PendingDraftStore(),
        contentCache: DocumentContentCacheStore = DocumentContentCacheStore(),
        backgroundTasks: BackgroundTaskProvider = .uiApplication
    ) {
        self.client = client
        self.draftStore = draftStore
        self.contentCache = contentCache
        self.backgroundTasks = backgroundTasks
    }

    func state(for documentID: UUID) -> DocSaveState {
        states[documentID] ?? .idle
    }

    /// Content handed to the coordinator this session that the server hasn't
    /// confirmed yet (queued or in flight).
    func pendingSave(documentID: UUID) -> PendingSave? {
        queued[documentID] ?? inFlightContent[documentID]
    }

    /// Draft persisted by a previous session (or a failed save) that hasn't
    /// been replayed yet.
    func storedDraft(documentID: UUID) -> PendingDraft? {
        draftStore.draft(for: documentID)
    }

    /// The recorded conflict for a document, if the server changed under its queued
    /// draft. `@Observable` cross-object reads track this, so the editor's conflict
    /// pill appears/disappears live.
    func conflict(for documentID: UUID) -> SyncConflict? {
        conflicts[documentID]
    }

    func saveMarker(documentID: UUID) -> SaveMarker {
        SaveMarker(
            documentID: documentID,
            settledSaves: settledSaves[documentID] ?? 0,
            // "Did a save actually reach the network?" — NOT `pendingSave(...) != nil`.
            // The two were equivalent until the conflict enqueue-hold existed: `queued`
            // was only ever filled *behind an in-flight save* (coalescing), so a queued
            // save implied a sent one. The hold broke that: it parks a save in `queued`
            // that is never started, and nothing drains it until the user resolves. Using
            // `pendingSave` here therefore pinned `mayPredateSave` to true forever, which
            // permanently wedged "Keep the server version" (it snapshots a marker before
            // its fetch) the moment the user typed once more after a conflict was
            // recorded — leaving the destructive "Keep mine" as the only way out of a
            // dialog they had already declined. A never-sent save cannot have raced the
            // fetch, so it must not count here.
            hadPendingSave: inFlightContent[documentID] != nil
        )
    }

    /// True when a save for the marker's document was already in flight when it was
    /// taken, or settled after it. Either way a fetch issued at `marker` may have
    /// been answered from the server's **pre-save** state, so its body must never
    /// be installed or cached: it would resurrect exactly the content the save
    /// replaced, and — because saves are a full overwrite — the next save would
    /// push that stale body back to the server.
    func mayPredateSave(_ marker: SaveMarker) -> Bool {
        marker.hadPendingSave || (settledSaves[marker.documentID] ?? 0) != marker.settledSaves
    }

    /// `baseline` is the server state the enqueued edit descends from (supplied by
    /// the editor). It is persisted on the draft so the sync/replay path can detect
    /// a conflict; it defaults to nil so legacy call sites (and tests) route to the
    /// tolerance rule exactly as before.
    func enqueue(documentID: UUID, title: String, markdown: String, baseline: DraftBaseline? = nil) {
        let save = PendingSave(title: title, markdown: markdown)
        // The draft carries the last-confirmed-push so `draftSyncDecision` rule 1 can
        // recognise our own writes on the next replay (even across a relaunch).
        //
        // `lastConfirmedPushMarkdown` is in-memory, so on a fresh process it is EMPTY.
        // Writing it straight through would erase the stamp `finish` persisted onto the
        // draft in the previous process — destroying rule 1 with the very first
        // post-relaunch enqueue, which is exactly the replay it exists to serve. The
        // document would then report our *own* earlier save as a "sync conflict" and the
        // enqueue-hold would wedge its save pipeline until the user answered a dialog
        // about their own write. So fall back to what the stored draft already carries.
        // Carrying it forward can never be wrong: the stamp only goes stale when someone
        // *else* writes the server, and rule 1 compares against the server body, so a
        // stale stamp simply stops matching and rule 2 takes over.
        let lastPushed =
            lastConfirmedPushMarkdown[documentID] ?? draftStore.draft(for: documentID)?.lastPushedMarkdown
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: title, markdown: markdown, updatedAt: Date(), baseline: baseline,
                lastPushedMarkdown: lastPushed))
        // Enqueue-hold: while a conflict is recorded, persist the draft and the
        // queued slot (write-ahead, so `pendingSave()` still sees it and the editor's
        // dirty short-circuit / `hasUnsavedLocalContent` keep working) but do NOT
        // start a save — an autosave flush would otherwise push unchecked over the
        // conflicting server copy the instant a conflict lands. "Keep mine" starts it.
        if conflicts[documentID] != nil || inFlight[documentID] != nil {
            queued[documentID] = save
            return
        }
        start(documentID: documentID, save: save)
    }

    /// The once-per-process launch wrapper (HomeViewModel calls it from `load()`).
    /// Delegates to the repeatable `syncPendingDrafts()`; the once-guard keeps that
    /// single call site's semantics unchanged.
    func recoverDrafts() async {
        guard !hasRecoveredDrafts else { return }
        hasRecoveredDrafts = true
        await syncPendingDrafts()
    }

    /// Replays drafts left behind by a previous session (or a save that failed /
    /// was queued offline) against the current server copy. A draft is re-saved
    /// unless the document changed on the server after the draft was written —
    /// fresher edits made elsewhere win over a stale draft.
    ///
    /// Unlike `recoverDrafts()` this is **repeatable**: it is the funnel for the
    /// reconnect, foreground and launch triggers, so it self-guards against
    /// overlapping runs (`isSyncingDrafts`) rather than running once per process.
    func syncPendingDrafts() async {
        guard !isSyncingDrafts else { return }
        isSyncingDrafts = true
        defer { isSyncingDrafts = false }
        for draft in draftStore.allDrafts() {
            guard inFlight[draft.documentID] == nil, queued[draft.documentID] == nil else { continue }
            // A save that FAILED this session is a retry candidate the user may still
            // be looking at (its draft is their only copy), owned by the reading
            // surface's "Couldn't save · tap to retry". Reconciling it here would
            // silently delete visible content — skip it.
            if case .failed = state(for: draft.documentID) { continue }
            // A recorded conflict waits for the user's explicit choice — never push
            // over it and never discard it here.
            if conflicts[draft.documentID] != nil { continue }
            do {
                let formatted = try await client.formattedContent(documentID: draft.documentID)
                // The session may have started editing/saving this document
                // while we awaited — a stale replay would clobber the newer
                // content and its draft. Re-check before acting.
                guard inFlight[draft.documentID] == nil,
                    queued[draft.documentID] == nil,
                    draftStore.draft(for: draft.documentID) == draft
                else { continue }
                let decision = draftSyncDecision(
                    baseline: draft.baseline,
                    lastPushedMarkdown: draft.lastPushedMarkdown,
                    draftUpdatedAt: draft.updatedAt,
                    serverUpdatedAt: formatted.updatedAt,
                    serverMarkdown: formatted.content ?? "")
                switch decision {
                case .push:
                    enqueue(
                        documentID: draft.documentID, title: draft.title, markdown: draft.markdown,
                        baseline: draft.baseline)
                case .conflict:
                    // Record it and keep the draft: the pill/sheet asks the user.
                    conflicts[draft.documentID] = SyncConflict(serverUpdatedAt: formatted.updatedAt)
                case .discardServerWins:
                    // Legacy (baseline-less) draft only. Never discard a queued offline
                    // save (`.pendingSync`) even so — leave it for the user / a later
                    // sync — matching the pre-decision protection.
                    if case .pendingSync = state(for: draft.documentID) { continue }
                    draftStore.remove(documentID: draft.documentID)
                }
            } catch let error as DocsAPIError where error == .notFound || error == .forbidden {
                draftStore.remove(documentID: draft.documentID)
            } catch {
                // Leave the draft for a later sync (e.g. offline right now).
            }
        }
    }

    /// Record a conflict the editor's own revalidation (`reconcileDraft`) detected,
    /// so the pill/sheet and the enqueue-hold apply just as they do for a conflict
    /// found by `syncPendingDrafts`.
    func recordConflict(documentID: UUID, serverUpdatedAt: Date) {
        conflicts[documentID] = SyncConflict(serverUpdatedAt: serverUpdatedAt)
    }

    /// **Invariant both resolvers rely on: while a conflict is recorded, no save for
    /// that document is in flight.** Nothing can record one during a save — `apply`
    /// diverts to `cacheServerCopy` whenever `pendingSave(documentID:) != nil`, so
    /// `reconcileDraft` is unreachable then, and `syncPendingDrafts` guards on both
    /// `inFlight` and `queued` — and nothing can *start* one afterwards, because the
    /// enqueue-hold below only ever fills the queued slot. So a resolver never has to
    /// reason about a save landing underneath it and resurrecting the losing body.
    ///
    /// Keep-mine: clear the record and push the held work (unchecked, last-writer-
    /// wins — an accepted race, recoverable from the server's version history).
    func resolveConflictKeepingLocal(documentID: UUID) {
        let resolved = conflicts[documentID]
        conflicts[documentID] = nil
        // Defensive only, per the invariant above: were a save somehow in flight, its
        // `finish` would pick the held slot up anyway, so dropping out here is safe.
        guard inFlight[documentID] == nil else { return }
        // The choice has to **stick on the draft**, not just in the in-memory map. The
        // released push very often fails (a conflict is usually reviewed on the same
        // flaky connection that produced it), and the draft would then survive carrying
        // its original, now-superseded baseline — so the next sync trigger would re-run
        // `draftSyncDecision`, re-detect the *identical* conflict and hold the push
        // again. The user's answer would silently evaporate, and they would be asked the
        // same question forever. Advancing the baseline to the server state they chose to
        // overwrite makes rule 2 (`serverUpdatedAt <= baselineDate`) return `.push` on the
        // retry. Only the timestamp is needed — and only the timestamp is knowable, since
        // `SyncConflict` deliberately carries no server markdown. If the server moves on
        // *again* the timestamp advances past it once more: a genuinely new conflict,
        // which is exactly what should be asked about.
        if let resolved, let draft = draftStore.draft(for: documentID) {
            draftStore.save(
                PendingDraft(
                    documentID: documentID, title: draft.title, markdown: draft.markdown,
                    updatedAt: draft.updatedAt,
                    baseline: DraftBaseline(
                        serverUpdatedAt: resolved.serverUpdatedAt, markdown: draft.baseline?.markdown ?? ""),
                    lastPushedMarkdown: draft.lastPushedMarkdown))
        }
        if let held = queued.removeValue(forKey: documentID) {
            start(documentID: documentID, save: held)
        } else if let draft = draftStore.draft(for: documentID) {
            // Re-read: the draft above may have just had its baseline advanced.
            enqueue(
                documentID: documentID, title: draft.title, markdown: draft.markdown, baseline: draft.baseline)
        }
    }

    /// Keep-server: clear the record and drop the local draft/queued work. Safe to drop
    /// unconditionally by the invariant above — no in-flight save can land afterwards and
    /// write the discarded body back into the content cache (or push it to the server).
    ///
    /// The caller must already hold the winning server body: the editor fetches it
    /// **before** calling this and installs it after, so a failed fetch costs the user
    /// nothing. The conflict record deliberately carries no server markdown, so there is
    /// nothing to install from here.
    func resolveConflictKeepingServer(documentID: UUID) {
        conflicts[documentID] = nil
        queued[documentID] = nil
        draftStore.remove(documentID: documentID)
        // The conflict is almost always reached from a `.failed`/`.pendingSync` draft, and
        // discarding it leaves nothing to save — so the state must not keep claiming one.
        // Left alone it strands the reading surface's "Couldn't save · tap to retry" (or
        // "syncs when online") caption on a document with no unsaved work, offering a retry
        // that `saveNow` would no-op. Mirrors `finish`'s discarded branch.
        states[documentID] = .idle
    }

    /// Removes a stored draft only if it is still exactly the given draft —
    /// the user may have produced a newer one while the caller awaited
    /// (mirrors the draft-replay re-check in `syncPendingDrafts`).
    func discardStoredDraft(_ draft: PendingDraft) {
        guard draftStore.draft(for: draft.documentID) == draft else { return }
        draftStore.remove(documentID: draft.documentID)
    }

    /// Drops all queued/stored work for a document (delete flow). An already
    /// in-flight PATCH cannot be meaningfully cancelled — but it can still *land*
    /// before the server processes the DELETE, and `finish`'s success path would
    /// then write-through the content cache, recreating the entry the delete just
    /// purged. Nothing purges it again. Remembering the id keeps that write out.
    func discardPendingWork(documentID: UUID) {
        queued[documentID] = nil
        conflicts[documentID] = nil  // the document is gone — the conflict is moot
        lastConfirmedPushMarkdown[documentID] = nil
        draftStore.remove(documentID: documentID)
        if inFlight[documentID] != nil {
            discardedDuringSave.insert(documentID)
        }
    }

    /// The document became unavailable (404/403) and the editor purged its local
    /// copy. An in-flight save can still land afterwards and, on the success path,
    /// write the full body straight back into the content cache — on a 403 that is
    /// revoked content reappearing on disk. Unlike `discardPendingWork`, the draft
    /// stays: it is the user's only copy of unsaved work, and `recoverDrafts()`
    /// decides its fate next launch (replay if reachable, purge on a real 404/403).
    func suppressLocalWriteThrough(documentID: UUID) {
        queued[documentID] = nil
        // Clear any conflict record: on a 404/403 the draft survives (it's the user's
        // only unsaved work), and `syncPendingDrafts` re-detects a conflict after the
        // document becomes reachable again — a stale record must not linger.
        conflicts[documentID] = nil
        guard inFlight[documentID] != nil else { return }
        discardedDuringSave.insert(documentID)
    }

    private func start(documentID: UUID, save: PendingSave) {
        inFlightContent[documentID] = save
        states[documentID] = .saving
        let taskToken = backgroundTasks.begin("SchriftDocumentSave")
        inFlight[documentID] = Task {
            do {
                try await client.saveDocumentContent(documentID: documentID, title: save.title, markdown: save.markdown)
                finish(documentID: documentID, save: save, error: nil)
            } catch {
                finish(documentID: documentID, save: save, error: error)
            }
            backgroundTasks.end(taskToken)
        }
    }

    private func finish(documentID: UUID, save: PendingSave, error: Error?) {
        inFlight[documentID] = nil
        inFlightContent[documentID] = nil
        // Any revalidation fetch still in flight was issued before this save
        // settled, so its response may predate it (see `mayPredateSave`).
        settledSaves[documentID, default: 0] += 1
        // Deleted or revoked while this save was on the wire: write no local copy,
        // whatever the server made of the PATCH. `discardPendingWork` (delete) already
        // removed the draft; `suppressLocalWriteThrough` (404/403) kept it as the
        // user's only copy of unsaved work — but only while it *is* unsaved. A PATCH
        // that landed puts the content on the server, so keeping its draft would let
        // the editor's stranded-draft replay push already-acknowledged bytes back over
        // a co-author's newer write, and would leave a revoked document's body in
        // UserDefaults indefinitely.
        if discardedDuringSave.remove(documentID) != nil {
            queued[documentID] = nil
            states[documentID] = .idle
            if error == nil, let draft = draftStore.draft(for: documentID),
                draft.title == save.title, draft.markdown == save.markdown
            {
                draftStore.remove(documentID: documentID)
            }
            return
        }
        if error == nil {
            states[documentID] = .saved(Date())
            // The server's most recent writer is now us. Remember what we pushed so a
            // later replay recognises it (rule 1 of `draftSyncDecision`).
            lastConfirmedPushMarkdown[documentID] = save.markdown
            if let draft = draftStore.draft(for: documentID) {
                if draft.title == save.title, draft.markdown == save.markdown {
                    draftStore.remove(documentID: documentID)
                } else {
                    // A newer draft survives (the user kept editing during the save):
                    // its edits descend from what this save just landed, so stamp that
                    // as its `lastPushedMarkdown` to kill a cross-relaunch false
                    // conflict against our own write.
                    draftStore.save(
                        PendingDraft(
                            documentID: documentID, title: draft.title, markdown: draft.markdown,
                            updatedAt: draft.updatedAt, baseline: draft.baseline, lastPushedMarkdown: save.markdown))
                }
            }
            // Keep the local copy consistent with what the server now holds.
            // The save PATCHes are void, so there is no server `updated_at` to
            // record: `serverUpdatedAt` is nil (truthfully "unknown after a void
            // save") and `syncedAt` is the client wall-clock of the confirmed save.
            contentCache.save(
                CachedDocumentContent(
                    documentID: documentID,
                    title: save.title,
                    markdown: save.markdown,
                    syncedAt: Date(),
                    serverUpdatedAt: nil
                ))
        } else if let docsError = error as? DocsAPIError, retryableSaveFailure(docsError) {
            // Transient/transport failure (offline, 5xx, rate limit): the edit is
            // safely on-device as a draft; mark it queued for sync rather than a
            // scary failure. `.sessionExpired` is NOT retryable — the shared client's
            // hook already raised the re-login sheet — so it lands in `.failed`.
            states[documentID] = .pendingSync
        } else {
            states[documentID] = .failed("Couldn't save changes. Please try again.")
        }
        if let next = queued.removeValue(forKey: documentID) {
            if error == nil, next == save {
                return
            }
            start(documentID: documentID, save: next)
        }
    }
}
