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
    /// A trigger that arrived while a pass was running. Coalesced into another pass
    /// rather than dropped — see `syncPendingDrafts`.
    private var needsAnotherSyncPass = false
    /// Whether a coalesced pass still owes the launch-recovery semantics (the only
    /// place a stale legacy draft may be discarded outright).
    private var pendingLaunchRecovery = false
    /// Documents whose queued draft conflicts with the server (the sync path or the
    /// editor detected the server moved on). The push is **held** until the user
    /// resolves it via `resolveConflictKeeping{Local,Server}`.
    private var conflicts: [UUID: SyncConflict] = [:]
    /// A server body the editor **observed while one of our own saves was on the wire**.
    /// Detection is skipped in that window (a conflict may only be recorded with no save in
    /// flight — every resolver depends on it), but the observation must not be thrown away:
    /// if the save then FAILS, nothing reached the server, the draft survives with a stale
    /// baseline and no push stamp, and the very next flush would full-overwrite the body the
    /// app had already fetched and cached. Re-decided in `finish`, where the invariant holds
    /// again. Deliberately in-memory: it is only meaningful until that save settles.
    private var serverObservedDuringSave: [UUID: (serverUpdatedAt: Date, markdown: String)] = [:]
    /// The markdown of the last save this coordinator confirmed for each document,
    /// so `draftSyncDecision` rule 1 ("the server's most recent writer was us") can
    /// fire — including across a relaunch, via the persisted `lastPushedMarkdown`
    /// that `enqueue`/`finish` copy from and to this map.
    private var lastConfirmedPushMarkdown: [UUID: String] = [:]
    /// The newest title anything in the app knows the server holds: written by a save that
    /// landed (the server now holds *our* title) and by every editor fetch that postdates our
    /// saves (`noteServerTitle`). Not persisted — it is a this-session-only backstop for one
    /// thing: an **open editor that never refetches on foreground** (it only flushes) while a
    /// background replay adopts a co-author's rename behind it. Its next flush would otherwise
    /// PATCH the pre-rename title back. See `EditorViewModel.adoptQueuedTitleIfUnseen`.
    private var knownServerTitles: [UUID: String] = [:]

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
        // **Rehydrate the holds before anything can enqueue.** The coordinator is built once,
        // at app start, before any editor exists — so a conflict persisted by a previous
        // process is in force from the very first `enqueue` of this one, rather than only
        // after a revalidation happens to return. That ordering is the whole point: on launch
        // the editor renders a stored draft synchronously and unblocks editing immediately,
        // so a Done tap could otherwise beat the fetch and push a full overwrite over the body
        // the user was already warned about.
        for draft in draftStore.allDrafts() {
            if let serverUpdatedAt = draft.conflictServerUpdatedAt {
                conflicts[draft.documentID] = SyncConflict(serverUpdatedAt: serverUpdatedAt)
            }
        }
    }

    /// Mirror the in-memory conflict onto the stored draft so the hold outlives the process.
    ///
    /// **`conflicts` has exactly three writers: `init`'s rehydration (which reads *from* disk),
    /// `recordConflict`, and `clearResolvedConflict` — and the last two both come through here.
    /// Nothing else may touch the map.** That rule is the whole point: when `runSyncPass` and
    /// `suppressLocalWriteThrough` wrote it directly, the in-memory record and its on-disk
    /// mirror diverged, so a hold established by the *primary* detection path silently died at
    /// the next relaunch, and a hold explicitly dropped on a 404 came back from the dead. A
    /// mirror with several writers is not a mirror.
    ///
    /// Skips the UserDefaults round-trip when the stamp is already what it should be.
    private func persistConflictOnDraft(documentID: UUID) {
        guard let draft = draftStore.draft(for: documentID) else { return }
        let stamp = conflicts[documentID]?.serverUpdatedAt
        guard draft.conflictServerUpdatedAt != stamp else { return }
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: draft.title, markdown: draft.markdown,
                updatedAt: draft.updatedAt, baseline: draft.baseline,
                lastPushedMarkdown: draft.lastPushedMarkdown, conflictServerUpdatedAt: stamp))
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

    /// The markdown this coordinator last confirmed pushing for a document — i.e. what the
    /// server holds if we were its most recent writer. Exposed so the **editor** can run
    /// `draftSyncDecision` rule 1 for itself: without it, a decision taken while no draft
    /// exists (the state right after a save lands) has no stamp to match, and the fetched
    /// body — which is *our own* write — reads as a diverged server and raises a false
    /// conflict against the user. Falls back to the persisted draft stamp so it survives a
    /// relaunch, exactly as `enqueue` does.
    func lastConfirmedPush(documentID: UUID) -> String? {
        lastConfirmedPushMarkdown[documentID] ?? draftStore.draft(for: documentID)?.lastPushedMarkdown
    }

    /// The editor fetched a server body while a save was in flight, so it could not run the
    /// decision. Hand it over; `finish` re-decides once the save settles.
    func noteServerObservedDuringSave(documentID: UUID, serverUpdatedAt: Date, markdown: String) {
        guard hasSaveInFlight(documentID: documentID) else { return }
        serverObservedDuringSave[documentID] = (serverUpdatedAt: serverUpdatedAt, markdown: markdown)
    }

    /// Whether a save for this document is **on the wire** — which is what actually blocks
    /// detection, and is NOT the same as `pendingSave(_:) != nil`. A save sitting in `queued`
    /// with nothing in flight can only be one the conflict hold parked, so gating detection on
    /// `pendingSave` also blocked it for exactly the documents that already have a conflict:
    /// they could then never have it *released*, because no other site can decide while local
    /// work exists. `finish` is where an in-flight save's observation is re-decided.
    func hasSaveInFlight(documentID: UUID) -> Bool {
        inFlightContent[documentID] != nil
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
                lastPushedMarkdown: lastPushed,
                // Carry the hold through: `enqueue` rebuilds the whole draft, so omitting this
                // would silently erase a persisted conflict on the next keystroke.
                conflictServerUpdatedAt: conflicts[documentID]?.serverUpdatedAt))
        // Enqueue-hold: while a conflict is recorded, persist the draft and the
        // queued slot (write-ahead, so `pendingSave()` still sees it and the editor's
        // dirty short-circuit / `hasUnsavedLocalContent` keep working) but do NOT
        // start a save — an autosave flush would otherwise push unchecked over the
        // conflicting server copy the instant a conflict lands. "Keep mine" starts it.
        if conflicts[documentID] != nil || inFlight[documentID] != nil {
            queued[documentID] = save
            // **A held save is not a saved save.** Nothing else moves the state on this
            // path (`start` is never called), so it kept whatever it was — usually `.idle`
            // — while `isDirty` flipped to false on the flush. The save indicator then
            // rendered exactly as it does after a successful save, telling the user their
            // work was safely synced while it was in fact parked behind a conflict they
            // had not answered. It *is* on the device (the write-ahead draft above), so
            // `.pendingSync` is the truthful state. Only for the conflict hold: a save
            // queued behind an in-flight one is already `.saving`.
            //
            // The reading surface does NOT show `.pendingSync`'s usual "syncs when online ·
            // tap to retry" copy while a conflict stands — that would promise a sync that is
            // held and offer a retry that re-enqueues straight back into this hold.
            // `syncCaption` takes `hasConflict` and degrades to a passive "Saved on this
            // device", leaving the conflict pill as the sole affordance.
            if conflicts[documentID] != nil {
                states[documentID] = .pendingSync
            }
            return
        }
        // Latest-wins, and defence in depth for the invariant above: a stale slot parked by a
        // hold that was released some other way must never be resurrected by this save's
        // `finish` and pushed over the newer content.
        queued[documentID] = nil
        start(documentID: documentID, save: save)
    }

    /// The once-per-process launch wrapper (HomeViewModel calls it from `load()`).
    /// Delegates to the repeatable `syncPendingDrafts()`; the once-guard keeps that
    /// single call site's semantics unchanged.
    func recoverDrafts() async {
        guard !hasRecoveredDrafts else { return }
        hasRecoveredDrafts = true
        await syncPendingDrafts(isLaunchRecovery: true)
    }

    /// Replays drafts left behind by a previous session (or a save that failed /
    /// was queued offline) against the current server copy. A draft is re-saved
    /// unless the document changed on the server after the draft was written —
    /// fresher edits made elsewhere win over a stale draft.
    ///
    /// Unlike `recoverDrafts()` this is **repeatable**: it is the funnel for the
    /// reconnect, foreground and launch triggers, so it self-guards against
    /// overlapping runs rather than running once per process. An overlapping trigger is
    /// **coalesced, never dropped**: the run in flight may already have passed (and
    /// failed on) the very drafts the new trigger cares about — a reconnect landing
    /// mid-run is exactly that — so returning early would lose it until the next
    /// background→foreground cycle.
    func syncPendingDrafts(isLaunchRecovery: Bool = false) async {
        if isLaunchRecovery { pendingLaunchRecovery = true }
        guard !isSyncingDrafts else {
            needsAnotherSyncPass = true
            return
        }
        isSyncingDrafts = true
        defer { isSyncingDrafts = false }
        repeat {
            needsAnotherSyncPass = false
            let launchPass = pendingLaunchRecovery
            pendingLaunchRecovery = false
            await runSyncPass(isLaunchRecovery: launchPass)
        } while needsAnotherSyncPass
    }

    private func runSyncPass(isLaunchRecovery: Bool) async {
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
                    localMarkdown: draft.markdown,
                    draftTitle: draft.title,
                    draftUpdatedAt: draft.updatedAt,
                    serverTitle: formatted.title,
                    serverUpdatedAt: formatted.updatedAt,
                    serverMarkdown: formatted.content ?? "")
                switch decision {
                case .push(let title, _):
                    // `title` — never `draft.title`. A save PATCHes the title too, so a replay
                    // that pushed the draft's own would silently revert a rename made on the web
                    // while this draft was queued. The decision resolves which title wins
                    // (adopting the server's when the user never renamed); the baseline advances
                    // with it, or a *second* remote rename would read as "both renamed" (see
                    // `adoptedBaseline`).
                    enqueue(
                        documentID: draft.documentID, title: title, markdown: draft.markdown,
                        baseline: adoptedBaseline(draft.baseline, draftTitle: draft.title, pushingTitle: title))
                case .conflict:
                    // Record it and keep the draft: the pill/sheet asks the user. Through
                    // `recordConflict`, NOT a direct map write — this is the primary detection
                    // path for the offline-replay case, and a direct write skipped the on-disk
                    // mirror, so the hold it established silently died at the next relaunch.
                    recordConflict(documentID: draft.documentID, serverUpdatedAt: formatted.updatedAt)
                case .discardServerWins:
                    // Legacy (baseline-less) drafts only — rule 3's tolerance fallback.
                    switch state(for: draft.documentID) {
                    case .pendingSync:
                        // (`.failed` cannot reach here — it `continue`s at the top of the loop,
                        // owned by the reading surface's retry.)
                        // The user has *visible* unsaved work — the "syncs when online"
                        // caption is on screen — that the server has already
                        // moved past. Discarding it would delete content they are looking
                        // at. But silently skipping it (what this did) **stranded** them:
                        // never pushed, never discarded, and — because the decision is not
                        // `.conflict` — no pill either, so the only remaining funnel was a
                        // retry tap, which full-overwrites the newer server copy with no
                        // prompt at all. Give it the same funnel a real conflict gets.
                        recordConflict(documentID: draft.documentID, serverUpdatedAt: formatted.updatedAt)
                    case .idle, .saving, .saved, .failed:
                        // `recoverDrafts()` runs at launch, before any editor is on screen,
                        // so discarding there is safe — and that is the only place this used
                        // to run. It is now a **repeatable** trigger (reconnect, foreground),
                        // and the editor may be *displaying* this very draft: removing it
                        // would leave on-screen content with no disk backing, and the next
                        // keystroke would full-overwrite the newer server body. Off the
                        // launch path, leave it to the editor's own `reconcileDraft`, which
                        // discards **and installs** the winning body atomically, on the
                        // screen that is actually showing it.
                        guard isLaunchRecovery else { continue }
                        draftStore.remove(documentID: draft.documentID)
                    }
                }
            } catch let error as DocsAPIError where error == .notFound || error == .forbidden {
                draftStore.remove(documentID: draft.documentID)
            } catch {
                // Leave the draft for a later sync (e.g. offline right now).
            }
        }
    }

    /// Record a conflict the editor's own revalidation (`reconcileDraft`, or `apply`'s dirty
    /// branch) detected, so the pill/sheet and the enqueue-hold apply just as they do for a
    /// conflict found by `syncPendingDrafts`.
    func recordConflict(documentID: UUID, serverUpdatedAt: Date) {
        conflicts[documentID] = SyncConflict(serverUpdatedAt: serverUpdatedAt)
        persistConflictOnDraft(documentID: documentID)
    }

    /// A reconcile resolved that this document's queued work must carry the **server's**
    /// title — a co-author renamed it and the user didn't (`draftTitleOutcome`). Rewrite the
    /// stored draft so whichever funnel later replays it PATCHes the adopted title instead of
    /// reverting the rename. The **baseline's** title advances with it (`adoptedBaseline`), or
    /// a second remote rename would read as "both renamed".
    ///
    /// Deliberately does **not** start a save. Callers reach it in two states: holding a draft
    /// whose save failed or is queued for sync (pushing that is the user's decision, via the
    /// retry affordance, or a later sync trigger's), and about to `enqueue` the replay
    /// themselves. A title is not content, so this can never resurrect a body — `markdown` is
    /// untouched, as is the persisted conflict hold. Guarded on no save being in flight or held,
    /// because those carry their own title and nothing here has reconciled *them* against the
    /// server.
    func adoptServerTitle(documentID: UUID, title: String) {
        guard inFlight[documentID] == nil, queued[documentID] == nil,
            let draft = draftStore.draft(for: documentID), draft.title != title
        else { return }
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: title, markdown: draft.markdown, updatedAt: draft.updatedAt,
                baseline: adoptedBaseline(draft.baseline, draftTitle: draft.title, pushingTitle: title),
                lastPushedMarkdown: draft.lastPushedMarkdown,
                conflictServerUpdatedAt: draft.conflictServerUpdatedAt))
    }

    /// The editor observed the server's title on a response that `mayPredateSave` has cleared
    /// — i.e. one that postdates our own saves, so it cannot regress below a title we pushed.
    /// Recording it keeps `knownServerTitles` the newest of "what we last pushed" and "what we
    /// last fetched", in real time on the MainActor.
    func noteServerTitle(documentID: UUID, title: String) {
        knownServerTitles[documentID] = title
    }

    /// The newest title known to be on the server, if any. Unsaved local work is *not*
    /// consulted here — a caller weighing this against a draft must prefer the draft (see
    /// `EditorViewModel.adoptQueuedTitleIfUnseen`), which holds a title the server does not
    /// have yet.
    func knownServerTitle(documentID: UUID) -> String? {
        knownServerTitles[documentID]
    }

    /// A later decision proved the conflict is **gone** (the server came back to the
    /// baseline, or its current body is one we pushed), so the hold must be released. The
    /// record is otherwise only ever cleared by a user resolution or a purge — and the
    /// enqueue-hold would then park every save for this document *indefinitely*, waiting on
    /// a question that no longer has anything to ask about. Only the detection sites call
    /// this, and only on a non-`.conflict` decision, so it can never discard a live one.
    func clearResolvedConflict(documentID: UUID) {
        conflicts[documentID] = nil
        persistConflictOnDraft(documentID: documentID)
        releaseHeldSave(documentID: documentID)
    }

    /// **The enqueue-hold broke an invariant, and this restores it.** Before the hold existed,
    /// `queued[id] != nil` implied `inFlight[id] != nil` — the slot was only ever filled behind
    /// an in-flight save, and `finish` always drained it. The hold parks a save with *nothing*
    /// in flight, and only `resolveConflictKeepingLocal` ever drained that. So a conflict
    /// released any other way (a proven `.push` from a detection site — the co-author reverted,
    /// or the server holds a body we pushed) left the parked save stranded **forever**: nothing
    /// starts it (`saveNow` no-ops on a non-nil `pendingSave`; `runSyncPass` skips a document
    /// with a queued slot), so the user's edit silently never syncs while the caption offers a
    /// retry that does nothing.
    ///
    /// And then it gets worse. The next keystroke's `enqueue` sees no conflict and nothing in
    /// flight, so it takes the `start` path — which did **not** clear the slot. When that newer
    /// save lands, `finish` pops the **stale** one and starts it: a full overwrite of the
    /// server with the *older* body, which then write-throughs the cache and stamps
    /// `lastConfirmedPushMarkdown`. The user's newer text is gone from screen, disk and server.
    /// That is the full-overwrite save eating content — the one thing this subsystem exists to
    /// prevent. So: lift the hold, start the work it was holding.
    private func releaseHeldSave(documentID: UUID) {
        guard inFlight[documentID] == nil, let held = queued.removeValue(forKey: documentID) else { return }
        start(documentID: documentID, save: held)
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
        // Defensive only, per the invariant above: were a save somehow in flight, its
        // `finish` would pick the held slot up anyway, so dropping out here is safe.
        guard inFlight[documentID] == nil else {
            clearResolvedConflict(documentID: documentID)
            return
        }
        // Advance the baseline on disk **before** clearing the record — `clearResolvedConflict`
        // now starts the held save, and it must carry the advanced baseline, not the stale one.
        //
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
                    // A legacy draft has no baseline body to carry forward. Fabricating `""`
                    // made rule 2's content tiebreak match any *empty* server document — so
                    // use the draft's own body: if a later fetch shows the server holding it,
                    // that is our own push having landed (idempotent), and anything else is a
                    // genuinely new conflict, which is exactly the discrimination we want.
                    baseline: DraftBaseline(
                        serverUpdatedAt: resolved.serverUpdatedAt,
                        markdown: draft.baseline?.markdown ?? draft.markdown,
                        // The title rides along unchanged, and the advanced timestamp is what
                        // makes this answer stick for the title too: `draftTitleOutcome` keeps
                        // the draft's title whenever the server is no newer than the baseline,
                        // so a retry after a failed push cannot re-raise the same *title*
                        // conflict the user just answered. (Only the timestamp is knowable —
                        // `SyncConflict` carries no server content, titles included.)
                        title: draft.baseline?.title),
                    lastPushedMarkdown: draft.lastPushedMarkdown,
                    // The user answered: the hold is released, on disk as well as in memory
                    // (`clearResolvedConflict` below rewrites this to nil).
                    conflictServerUpdatedAt: nil))
        }
        // Releases the record AND starts whatever the hold was parking.
        clearResolvedConflict(documentID: documentID)
        // No held save (the conflict was recorded before any flush)? Then push the draft.
        if queued[documentID] == nil, inFlight[documentID] == nil,
            let draft = draftStore.draft(for: documentID)
        {
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
        // Drop the held work FIRST: `clearResolvedConflict` now *starts* whatever the hold was
        // parking, and this is the one resolution where that work must be thrown away, not sent.
        queued[documentID] = nil
        draftStore.remove(documentID: documentID)
        clearResolvedConflict(documentID: documentID)
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
        clearResolvedConflict(documentID: documentID)  // the document is gone — the conflict is moot
        lastConfirmedPushMarkdown[documentID] = nil
        knownServerTitles[documentID] = nil
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
        //
        // Through `clearResolvedConflict`, so the clear reaches **disk** too. This is the one
        // clear where the draft deliberately *survives*, so a bare in-memory nil left the
        // stamp on it: the next launch would rehydrate a conflict this path had explicitly
        // dropped, re-arming a destructive "Keep the server version" against a draft that has
        // no conflict, and wedging the sync pass (which skips any document that has one).
        clearResolvedConflict(documentID: documentID)
        guard inFlight[documentID] != nil else { return }
        discardedDuringSave.insert(documentID)
    }

    private func start(documentID: UUID, save: PendingSave) {
        inFlightContent[documentID] = save
        states[documentID] = .saving
        let taskToken = backgroundTasks.begin("SchriftDocumentSave")
        inFlight[documentID] = Task {
            do {
                // A non-nil return means the CONTENT PATCH landed and only the title failed:
                // the save still counts as failed (retryability is classified from the same
                // error) but the server holds our body, so `finish` must record the push.
                let titleFailure = try await client.saveDocumentContent(
                    documentID: documentID, title: save.title, markdown: save.markdown)
                finish(documentID: documentID, save: save, error: titleFailure, contentLanded: true)
            } catch {
                // A throw means the content PATCH was not **confirmed** — NOT that nothing
                // reached the server: a dropped or timed-out response can hide a PATCH the
                // server applied. All we know is that we cannot *record* the push, which is
                // exactly what `draftSyncDecision`'s rule 0 backstops.
                finish(documentID: documentID, save: save, error: error, contentLanded: false)
            }
            backgroundTasks.end(taskToken)
        }
    }

    private func finish(documentID: UUID, save: PendingSave, error: Error?, contentLanded: Bool) {
        inFlight[documentID] = nil
        inFlightContent[documentID] = nil
        // Scoped to the save that has just settled — so it must be dropped here, on EVERY branch,
        // not only the one that consumes it. Leaving it behind the `discardedDuringSave` early
        // return let an observation outlive its save and be replayed against an unrelated later
        // one, manufacturing a **phantom conflict**: the pill would tell the user the server had
        // changed at a timestamp that no longer means anything, park every further save behind
        // it, and let "Keep my version" advance the baseline to that bogus stamp.
        let observed = serverObservedDuringSave.removeValue(forKey: documentID)
        // Any revalidation fetch still in flight was issued before this save
        // settled, so its response may predate it (see `mayPredateSave`).
        settledSaves[documentID, default: 0] += 1
        // **Record the push the moment the CONTENT PATCH landed — before any early return.**
        // The server's body is now ours whether or not the *save* as a whole succeeded, and
        // whether or not the document was torn down while it was on the wire. Miss this and
        // the next replay's rule 1 has no stamp to match, rule 2 sees a body diverged from a
        // stale baseline, and the app raises a **sync conflict against the user's own
        // content** — parking every further autosave behind a dialog about their own write,
        // one answer to which discards their real unsaved work.
        //
        // Two paths reach it: a save whose title PATCH dropped (the content is on the server
        // regardless), and a save that lands while the document is temporarily 404/403 —
        // `suppressLocalWriteThrough` deliberately KEEPS the draft there, so a *newer* draft
        // survives the discarded branch below and must carry the stamp too. Doing this after
        // that branch's `return` left exactly that draft unstamped.
        if contentLanded {
            lastConfirmedPushMarkdown[documentID] = save.markdown
            // Stamp whatever draft is on disk: its content descends from what this save just
            // landed, whether it is a *newer* draft (the user kept typing) or the save's own
            // draft surviving a failure (a half-land keeps an **identical** draft — stamping
            // only a differing one missed exactly that case). The branches below remove it if
            // it should not survive; stamping first is harmless and keeps the rule one line.
            if let draft = draftStore.draft(for: documentID) {
                draftStore.save(
                    PendingDraft(
                        documentID: documentID, title: draft.title, markdown: draft.markdown,
                        updatedAt: draft.updatedAt, baseline: draft.baseline, lastPushedMarkdown: save.markdown,
                        conflictServerUpdatedAt: conflicts[documentID]?.serverUpdatedAt))
            }
        }
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
            // **Both** PATCHes landed, so the server now holds this title. An editor still on
            // screen may never have seen it (a background replay can adopt a co-author's rename
            // into this save without the editor refetching), and recording it is what stops that
            // editor's next flush pushing the pre-rename title back. A save that landed *after its
            // document was discarded mid-flight* takes the `discardedDuringSave` early return
            // above and never reaches here — deliberately: for a delete, the entry was cleared and
            // a landed PATCH must not resurrect it.
            knownServerTitles[documentID] = save.title
            if let draft = draftStore.draft(for: documentID), draft.title == save.title,
                draft.markdown == save.markdown
            {
                draftStore.remove(documentID: documentID)
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
        // A revalidation landed while this save was on the wire, so detection was skipped. Now
        // that it has settled the invariant holds again — so decide, before anything can push.
        // Only when the content did NOT land: if it did, the server holds *our* body and the
        // observation is superseded (comparing against it would manufacture a false conflict
        // against the user's own writing).
        if let observed, !contentLanded, let draft = draftStore.draft(for: documentID) {
            // A **body-only** conflict check — it acts on `.conflict`/`.discardServerWins` and
            // does nothing on `.push`. The observed copy carries no title, so `serverTitle` is
            // nil (unknown): the title rule stays inert and cannot turn a body `.push` into a
            // title `.conflict` here. Detection of a *title* divergence is the editor's job, on
            // a fetch that actually carries the server's title.
            switch draftSyncDecision(
                baseline: draft.baseline,
                lastPushedMarkdown: draft.lastPushedMarkdown ?? lastConfirmedPushMarkdown[documentID],
                localMarkdown: draft.markdown,
                draftTitle: draft.title,
                draftUpdatedAt: draft.updatedAt,
                serverTitle: nil,
                serverUpdatedAt: observed.serverUpdatedAt,
                serverMarkdown: observed.markdown)
            {
            case .conflict, .discardServerWins:
                recordConflict(documentID: documentID, serverUpdatedAt: observed.serverUpdatedAt)
            case .push:
                break
            }
        }
        if let next = queued.removeValue(forKey: documentID) {
            if error == nil, next == save {
                return
            }
            // **The queued restart calls `start` directly, so it bypasses `enqueue`'s hold.**
            // Re-apply it here, or a conflict detected while this save was failing (just above,
            // or by a sync pass) would be pushed straight over the moment the save settled.
            guard conflicts[documentID] == nil else {
                queued[documentID] = next
                states[documentID] = .pendingSync
                return
            }
            start(documentID: documentID, save: next)
        }
    }
}
