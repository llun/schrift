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
        /// Non-nil ⇒ a **live-collaboration full-state Yjs snapshot** to PATCH verbatim
        /// (tagged `"websocket": true`) via `client.saveLiveSnapshot`, instead of re-deriving
        /// bytes from `markdown` through `MarkdownYjs.encode`. `markdown` still carries the
        /// **projected** markdown (what the server renders from the snapshot), so every
        /// reconcile/baseline/cache rule in `finish` is byte-for-byte identical between the
        /// two paths — only which network primitive `start` calls differs.
        let liveSnapshot: Data?

        init(title: String, markdown: String, liveSnapshot: Data? = nil) {
            self.title = title
            self.markdown = markdown
            self.liveSnapshot = liveSnapshot
        }
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
    private let createStore: PendingDocumentCreateStore
    /// The list caches the replay has to move a document into once the server owns it.
    /// Without them a just-created document vanishes from Home between the POST landing
    /// (which stops it being listed as local) and the next successful list fetch.
    private let listCache: DocumentCacheStore
    private let childrenCache: DocumentChildrenCacheStore
    /// The server this session is signed in to (`siteOrigin`). Create records carry the
    /// origin they were minted against; it decides what may be **listed and sent**, never
    /// what is protected — see `isPendingCreate` vs `isReplayable`.
    private let serverOrigin: String
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
    /// Documents created on this device that the server has never seen, keyed by their
    /// client-minted local id and mirrored from `createStore` so the hot predicate
    /// (`isPendingCreate`, read on every enqueue and every sync pass) is a dictionary
    /// lookup rather than a UserDefaults decode. **Every** record is mirrored, whatever
    /// origin or user minted it — protection is unconditional; see `isPendingCreate`.
    private var pendingCreates: [UUID: PendingDocumentCreate] = [:]
    /// Documents whose editor is on screen, reference-counted. The create replay **defers**
    /// for these: migration re-keys the draft, the coordinator's maps and the caches onto the
    /// server id, and `EditorViewModel.documentID` is a `let` captured by four sibling view
    /// models and by the pushed `NavigationPath` values — so an open screen cannot follow the
    /// id and would keep writing drafts under one the holds no longer cover. Deferring makes
    /// mid-swap edit loss unrepresentable rather than merely unlikely: there is no moment at
    /// which a live screen and a migration are both in progress.
    private var openEditors: [UUID: Int] = [:]
    /// True when the create store held data that would not decode. The records are then
    /// unknown, so *any* draft might belong to a local document — and `runSyncPass`'s
    /// 404 branch deletes drafts. Suppresses that branch entirely rather than deleting on
    /// an assumption: a schema slip must degrade to "nothing is cleaned up", never to
    /// "every offline-created document is destroyed".
    ///
    /// Read once, which is sound: nothing can make the blob undecodable mid-process
    /// (`persist` only ever writes encoder output), and the store's own flag is **sticky**
    /// — it stays true while a quarantine exists — so a repair does not silently re-arm the
    /// delete on the next launch either. Suppression outlives the session by design; see
    /// `holdsUnreadableData`.
    private let createStoreUnreadable: Bool

    init(
        client: DocsAPIClient,
        draftStore: PendingDraftStore = PendingDraftStore(),
        contentCache: DocumentContentCacheStore = DocumentContentCacheStore(),
        createStore: PendingDocumentCreateStore = PendingDocumentCreateStore(),
        listCache: DocumentCacheStore = DocumentCacheStore(),
        childrenCache: DocumentChildrenCacheStore = DocumentChildrenCacheStore(),
        serverOrigin: String = "",
        backgroundTasks: BackgroundTaskProvider = .uiApplication
    ) {
        self.client = client
        self.draftStore = draftStore
        self.contentCache = contentCache
        self.createStore = createStore
        self.listCache = listCache
        self.childrenCache = childrenCache
        self.serverOrigin = serverOrigin
        self.backgroundTasks = backgroundTasks
        createStoreUnreadable = createStore.holdsUnreadableData
        // Same reasoning as the conflict rehydration below: the holds these records drive
        // must be in force from this process's very first `enqueue`, because the editor
        // renders a stored draft synchronously and unblocks editing before anything else
        // runs. A local document whose record was forgotten would be PATCHed at an id the
        // server has never seen, land on `.failed`, and be skipped by the very sync pass
        // meant to create it.
        //
        // **Every record is mirrored, whatever origin it was minted against.** The holds
        // are about "this id does not exist on any server we can talk to", which is true
        // regardless of *which* server minted it — and `runSyncPass` walks
        // `draftStore.allDrafts()`, which is not origin-scoped either. Mirroring only the
        // matching ones left a foreign record's draft with no hold at all: the pass GET
        // 404ed and **deleted it**, so signing in elsewhere destroyed the content while
        // leaving the record pointing at nothing. Dormant has to mean *no requests and no
        // deletion*. Origin decides what is **listed** (below) and, once the replay lands,
        // what may be **POSTed** — never whether the content is protected.
        for create in createStore.allCreates() {
            pendingCreates[create.localID] = create
            // `states` is in-memory, so without this every local document reads `.idle`
            // after a relaunch until something enqueues — i.e. the reading surface would
            // show "Edited just now" for a document that exists nowhere but here. The
            // truthful state is the one `createLocalDocument` set.
            states[create.localID] = .pendingSync
        }
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

    // MARK: - Documents created on this device

    /// Whether this id names a document no server has ever seen — the predicate the holds
    /// key off. Deliberately **not** origin-scoped: a record minted elsewhere still names
    /// an id that would 404 here, and the holds exist to keep anything from addressing it.
    ///
    /// Not yet consulted by the editor: opening a local document names its id from several
    /// places this coordinator does not own (`formattedContent`, the children fetch, the
    /// collaboration room, Options' delete and version history). Those are the create UI's
    /// to gate — the invariant is broader than the enforcement in this file.
    func isPendingCreate(documentID: UUID) -> Bool {
        pendingCreates[documentID] != nil
    }

    /// Whether this record belongs to the session in front of us — the same test for
    /// **listing** it and for **sending** it, because seeing and editing someone else's
    /// unsynced document is the same disclosure as POSTing it into their account (worse,
    /// in fact: the edit lands in *their* document when they sign back in).
    ///
    /// Separate from `isPendingCreate` on purpose: protection is unconditional, ownership
    /// is not. `serverOrigin` alone is necessary but **not sufficient** — it identifies the
    /// server, not the account, and records survive sign-out. An **unattributable** record
    /// (nil owner) belongs to nobody we can name, so it is kept and protected but neither
    /// shown nor sent; `createLocalDocument` requires an owner, so nil can only arrive from
    /// data written by some future or damaged schema.
    private func belongsToSession(_ create: PendingDocumentCreate, currentUserID: UUID?) -> Bool {
        guard create.serverOrigin == serverOrigin, let owner = create.ownerUserID else { return false }
        return owner == currentUserID
    }

    /// Whether this record may be **POSTed** by the session in front of us. The replay
    /// asks; it can await `/users/me/`, which this coordinator cannot — it is built before
    /// that returns.
    func isReplayable(_ create: PendingDocumentCreate, currentUserID: UUID?) -> Bool {
        belongsToSession(create, currentUserID: currentUserID)
    }

    /// Mint a document locally: a create record (so it is POSTed even if never typed
    /// into), a seed draft (so the editor's existing draft precedence renders it with no
    /// changes), and `.pendingSync` — nothing is syncing, but the work *is* on the device.
    ///
    /// `parentID` is a **server** id or nil; v1 never creates under a parent that is itself
    /// pending, so a replay needs no dependency ordering (`localDocument`'s
    /// `abilities.childrenCreate` is false, which is what enforces that).
    ///
    /// `ownerUserID` is **required, not defaulted**: an unattributable record can be neither
    /// listed nor replayed (see `belongsToSession`), so a caller that could not name the
    /// user would silently mint a document that never appears and never syncs. Making the
    /// parameter mandatory forces that problem to the surface at the mint site, where the
    /// session exists to answer it.
    ///
    /// Dormant until the UI calls it: nothing in the app does yet.
    @discardableResult
    func createLocalDocument(title: String, parentID: UUID?, ownerUserID: UUID) -> Document {
        let record = PendingDocumentCreate(
            localID: UUID(), title: title, parentID: parentID, createdAt: Date(), serverOrigin: serverOrigin,
            ownerUserID: ownerUserID)
        createStore.save(record)
        pendingCreates[record.localID] = record
        // The seed draft is what makes the document readable after the editor is dismissed:
        // `DocumentContentCacheStore` is only ever written by a confirmed save or a fetch,
        // so a document that has never been to the server has no entry there — and must not
        // get one, since that store is backup-excluded and cleared on sign-out.
        //
        // **It carries no `DraftBaseline`, and the replay must stamp one.** There is no
        // server state to descend from yet, so nil is the only honest value here — but a
        // baseline-less draft routes to `draftSyncDecision` rule 3, the 120 s clock
        // tolerance. The instant the create POST lands, the new document's `updated_at` is
        // *now* while this draft's `updatedAt` is whenever the user last typed — hours ago,
        // which is the whole point of creating offline. Rule 3 would answer
        // `.discardServerWins` and the launch pass would **delete the body**, leaving the
        // empty document the POST just made. Migration must write
        // `DraftBaseline(serverUpdatedAt: <POST response updatedAt>, markdown: "", title:)`
        // — the create response *is* the known server state — before the draft is replayed.
        draftStore.save(
            PendingDraft(documentID: record.localID, title: title, markdown: "", updatedAt: record.createdAt))
        states[record.localID] = .pendingSync
        return localDocument(from: record)
    }

    /// Documents created on this device under `parentID` (nil = root), newest first — what
    /// a list merges in at read time via `mergedWithLocalDocuments`.
    ///
    /// Scoped to the session, unlike the holds (`belongsToSession`): you must not see —
    /// and therefore cannot edit — a document belonging to another server *or another
    /// account*. Listing another user's unsynced document would be the worse half of the
    /// disclosure `ownerUserID` exists to prevent: their content on screen, and any edit
    /// landing in their document when they sign back in.
    ///
    /// A record checkpointed by the replay (`syncedServerID != nil`) is also withheld — the
    /// server has it now, so the fetched list is where it belongs, and surfacing it here
    /// too would duplicate the row under an id nothing can reconcile.
    ///
    /// The title comes from the **draft** when there is a non-blank one: the record's is
    /// the title at creation time, so a document renamed since would otherwise read
    /// "Untitled document" in every list until the replay landed. Blank falls back to the
    /// record's, because every list renders `title ?? untitled` — a nil check, not an
    /// emptiness one — so overlaying "" (or "   ") would produce a blank row.
    func pendingLocalDocuments(parentID: UUID?, currentUserID: UUID?) -> [Document] {
        let listed = pendingCreates.values
            .filter {
                belongsToSession($0, currentUserID: currentUserID) && $0.syncedServerID == nil
                    && $0.parentID == parentID
            }
            .sorted { orderedByCreation($1, $0) }
        guard !listed.isEmpty else { return [] }
        // One decode for the whole list: `draftStore.draft(for:)` re-decodes every draft —
        // document bodies included — on each call, and this is a main-actor list path.
        let draftTitles = Dictionary(
            draftStore.allDrafts().map { ($0.documentID, $0.title) }, uniquingKeysWith: { _, latest in latest })
        return listed.map { create in
            var document = localDocument(from: create)
            if let draftTitle = draftTitles[create.localID],
                !draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                document.title = draftTitle
            }
            return document
        }
    }

    /// Drop a local document's record. **A record may only be removed together with a
    /// decision about its draft**: discard it (the delete flow, via `discardPendingWork`)
    /// or migrate it (the replay, once the POST has landed and the draft has been rewritten
    /// under the server id). A record dropped on its own strands the draft — the holds key
    /// off the record, so the very next sync pass would GET the dead id and delete the only
    /// copy of the content.
    ///
    /// Private because the two routes that exist — `discardPendingWork` (delete) and
    /// `migrateCreatedDocument` (replay) — are the only ones that pair it with a decision
    /// about the draft.
    private func removePendingCreate(documentID: UUID) {
        guard pendingCreates[documentID] != nil else { return }
        pendingCreates[documentID] = nil
        createStore.remove(localID: documentID)
    }

    /// The one way to rewrite a mirrored record. Both the disk copy and the in-memory mirror
    /// move together, because `isPendingCreate` — the predicate every gate keys off — reads
    /// the mirror while the replay's resume path reads the disk. Letting them drift means a
    /// document that is protected in one process and unprotected in the next.
    private func updatePendingCreate(_ record: PendingDocumentCreate) {
        createStore.save(record)
        pendingCreates[record.localID] = record
    }

    // MARK: - The open-editor registry

    /// Called while an editor for this document is on screen. Balanced by
    /// `releaseOpenEditor`; the create replay skips any document held here.
    func retainOpenEditor(documentID: UUID) {
        openEditors[documentID, default: 0] += 1
    }

    /// Balances `retainOpenEditor`. When the last hold on a *local* document goes, kick the
    /// sync funnel: on iPhone that is the moment popping back makes the document replayable,
    /// and waiting for the next reconnect or foreground would be an arbitrary delay.
    func releaseOpenEditor(documentID: UUID) {
        guard let held = openEditors[documentID] else { return }
        if held <= 1 {
            openEditors[documentID] = nil
            if isPendingCreate(documentID: documentID) {
                Task { await syncPendingDrafts() }
            }
        } else {
            openEditors[documentID] = held - 1
        }
    }

    private func hasOpenEditor(documentID: UUID) -> Bool {
        (openEditors[documentID] ?? 0) > 0
    }

    // MARK: - Create replay

    /// POST the documents this device created, then hand their content to the ordinary draft
    /// replay. Runs **before** `runSyncPass` inside the same coalesced pass, so a document
    /// migrated here has its body pushed by the very same pass rather than waiting for the
    /// next trigger.
    ///
    /// Dormant until something mints a record: `allCreates()` is empty, so this returns
    /// after one `/users/me/` round trip that itself only happens when there is work.
    private func runCreatePass() async {
        let records = createStore.allCreates()
        // Cheap gate before the round trip: a record from another server, or one nothing can
        // attribute, can never be replayed here (see `belongsToSession`) and nothing deletes
        // it — so without this every reconnect, foreground and launch would pay a
        // `/users/me/` request that cannot produce work, forever.
        guard records.contains(where: { $0.serverOrigin == serverOrigin && $0.ownerUserID != nil }) else { return }
        // Which account is in front of us. Asked once per pass, and only when there is
        // something to send: `isReplayable` needs it, and this is the layer that *can* await
        // it — the coordinator is constructed long before `/users/me/` returns. A failure
        // (offline, or a server that omits the id) leaves every record unreplayable, which
        // is the correct answer rather than a reason to guess.
        guard let currentUserID = try? await client.currentUser().id else { return }

        for snapshot in records {
            // Re-read rather than trusting the snapshot: the loop awaits, and a delete
            // (`discardPendingWork`) or a previous iteration can have removed or rewritten
            // this record since. Acting on the stale copy would POST a document the user
            // threw away — and `updatePendingCreate` would then write the snapshot back,
            // *resurrecting* the record the delete removed.
            guard let record = pendingCreates[snapshot.localID] else { continue }
            guard isReplayable(record, currentUserID: currentUserID) else { continue }
            // A save the *server* rejected on the merits is a retry candidate the user can
            // see; leave it to them, exactly as `runSyncPass` does.
            if case .failed = state(for: record.localID) { continue }
            // Never migrate under a live screen — see `openEditors`.
            guard !hasOpenEditor(documentID: record.localID) else { continue }
            await replayCreate(record)
        }
    }

    private func replayCreate(_ record: PendingDocumentCreate) async {
        var record = record
        if record.syncedServerID == nil {
            // The draft carries any rename made since the document was minted, so it wins.
            let title = draftStore.draft(for: record.localID)?.title ?? record.title
            let created: Document
            do {
                if let parentID = record.parentID {
                    created = try await client.createChild(documentID: parentID, title: title)
                } else {
                    created = try await client.createDocument(title: title)
                }
            } catch {
                await handleCreateFailure(error, for: record)
                return
            }
            // **Persist the server id before anything else.** This is the whole idempotency
            // story: the backend offers no idempotency key, so the window between the POST
            // landing and this write is what would produce a duplicate. With it, the next pass
            // sees a checkpointed record and resumes at migration instead of POSTing again —
            // at worst one empty duplicate document, never duplicated content.
            //
            // It narrows that window rather than closing it: this goes through UserDefaults,
            // which is write-behind, so a crash in the milliseconds after can still lose the
            // checkpoint. Same durability as `PendingDraftStore`, which the whole offline path
            // already rests on — worth knowing, not worth a different store.
            //
            // Written even if the document was deleted while the POST was in flight: the
            // server object exists either way, and a record that says so is what stops the
            // next pass creating a second one. `finishMigration` decides what to do with it.
            record.syncedServerID = created.id
            if pendingCreates[record.localID] != nil { updatePendingCreate(record) }
            finishMigration(record, created: created)
            return
        }
        // Resuming after a death between the checkpoint and the migration. The document
        // exists server-side; fetch what it looks like so the baseline is the server's own
        // state rather than a guess.
        guard let serverID = record.syncedServerID else { return }
        do {
            let created = try await client.document(documentID: serverID)
            finishMigration(record, created: created, isResume: true)
        } catch let error as DocsAPIError where error == .notFound || error == .forbidden {
            // The checkpointed document is gone or no longer ours, so resuming can never
            // succeed — and silently retrying it forever would leave this document in no
            // list (`pendingLocalDocuments` withholds a checkpointed record) and never
            // pushed, i.e. unreachable by every route the app offers. Drop the checkpoint so
            // the next pass creates it afresh; there is nothing left to duplicate.
            record.syncedServerID = nil
            if pendingCreates[record.localID] != nil { updatePendingCreate(record) }
        } catch {
            // Transient — leave it for the next pass.
        }
    }

    /// The migration, guarded by the two things that can have changed while the POST or the
    /// resume GET was in flight.
    private func finishMigration(_ record: PendingDocumentCreate, created: Document, isResume: Bool = false) {
        // An editor can have opened during the await, and migrating under a live screen is
        // exactly what `openEditors` exists to prevent: the screen's `documentID` is a `let`,
        // so it would keep enqueueing under an id the holds no longer cover — and the next
        // sync pass would 404 and delete that draft. The checkpoint is already persisted, so
        // bailing out here is free: the next pass resumes at migration.
        guard !hasOpenEditor(documentID: record.localID) else { return }
        // The user deleted the document while the POST was in flight. `discardPendingWork`
        // has already removed the record and the draft; migrating would re-materialise a
        // document they threw away.
        guard pendingCreates[record.localID] != nil else { return }
        migrateCreatedDocument(record, to: created, isResume: isResume)
    }

    /// Move a local document onto the id the server just gave it, then hand its content to
    /// the ordinary replay.
    ///
    /// Order is the safety property. The record is removed **last**, because it is what keeps
    /// the holds in force: dropping it first and dying would leave a draft under a dead local
    /// id that the very next sync pass GETs, 404s, and deletes.
    private func migrateCreatedDocument(
        _ record: PendingDocumentCreate, to created: Document, isResume: Bool = false
    ) {
        let localID = record.localID
        let serverID = created.id
        // The create response *is* the known server state, and stamping it is mandatory: a
        // baseline-less draft routes to `draftSyncDecision` rule 3's 120 s clock tolerance,
        // and a document created hours ago offline is far outside it — the replay would
        // answer `.discardServerWins` and the launch pass would delete the body, leaving the
        // empty document this POST just made.
        let baseline = DraftBaseline(
            serverUpdatedAt: created.updatedAt, markdown: "", title: created.title)
        let draft = draftStore.draft(for: localID)
        // The partially-migrated draft, if a previous attempt died between writing it and
        // removing the local one. Without this fallback a resume reads an already-removed
        // local draft as empty and overwrites the good content with "".
        let migrated = draftStore.draft(for: serverID)
        let body = queued[localID]?.markdown ?? draft?.markdown ?? migrated?.markdown ?? ""
        // The **local** title wins on both paths, for the same reason the body does: it is the
        // newer one. On a resume the server's is the pre-death title while the draft may hold
        // a rename from the intervening launch; on a fresh POST the server's is what we sent
        // moments ago, which a rename landing *during* the POST has already superseded. Either
        // way nothing downstream would flag the difference — the baseline is stamped with the
        // server's title, so `draftTitleOutcome` would see draft == baseline and silently keep
        // the old name. There is no co-author to protect: this device made the document.
        let title =
            queued[localID]?.title ?? draft?.title ?? migrated?.title ?? created.title ?? record.title

        // **Write the content under the new id before taking it off the old one.** These are
        // synchronous, but the body between them lives only in the local `body` binding, and
        // a process death in that window would leave the draft removed, the replacement
        // unwritten, and the server holding the empty document this POST just created. The
        // final `enqueue` rewrites this same draft; the point is that no instant exists where
        // the content is on disk nowhere.
        draftStore.save(
            PendingDraft(
                documentID: serverID, title: title, markdown: body, updatedAt: Date(), baseline: baseline))
        draftStore.remove(documentID: localID)
        // Every per-document map the coordinator keys by id. `queued` matters most: it holds
        // the user's newest keystrokes, and leaving it behind would strand them under an id
        // nothing will ever push.
        states[localID] = nil
        queued[localID] = nil
        settledSaves[localID] = nil
        lastConfirmedPushMarkdown[localID] = nil
        knownServerTitles[localID] = nil
        knownServerTitles[serverID] = created.title
        // `conflicts` is provably nil for a local id today — every `recordConflict` caller
        // needs a *successful* server interaction with it, which a client-minted id cannot
        // get. Cleared anyway, because that is an assumption about code elsewhere: if it ever
        // stopped holding, the entry would leak under a dead id *and* the hold would be lost,
        // since the `enqueue` below reads `conflicts[serverID]` and would push unchecked.
        conflicts[localID] = nil
        // `inFlight`, `inFlightContent`, `discardedDuringSave` and `serverObservedDuringSave`
        // need nothing: all four are only ever written once a save is in flight, and the four
        // gates make `start` unreachable for a pending-create id.
        //
        // A local document never reached the content cache (only a confirmed save or a fetch
        // writes one), but purge defensively so a stale entry can never outlive the id.
        contentCache.remove(documentID: localID)

        // Make it visible under its real id before the record disappears, or the document
        // drops out of Home between here and the next successful list fetch.
        insertIntoListCaches(created, parentID: record.parentID)

        removePendingCreate(documentID: localID)

        // Now an ordinary document with an ordinary queued edit: rule 2 sees a server no
        // newer than the baseline we just stamped and answers `.push`.
        enqueue(documentID: serverID, title: title, markdown: body, baseline: baseline)
    }

    private func insertIntoListCaches(_ created: Document, parentID: UUID?) {
        // Only into a list that has actually been fetched. `nil` (never cached) is
        // deliberately distinct from a cached empty list — `HomeViewModel` reads exactly that
        // to decide whether to show the first-run skeleton and whether the list is "known".
        // Fabricating one here would make a sign-in whose first fetch failed render a single
        // row, no skeleton, and `isCurrentListKnown = true`, as though the server held one
        // document. Same rule as the children cache below.
        //
        // Roots only. A sub-page belongs to its parent's level, and Home's list is fetched
        // without a parent filter — so whether a sub-page appears there is the server's
        // answer to give, not ours to assume. Inserting one would write a row into the cache
        // that the next fetch might not return, which is a worse error than a row arriving
        // one fetch late.
        if parentID == nil, var recents = listCache.loadRecentDocuments(),
            !recents.contains(where: { $0.id == created.id })
        {
            recents.insert(created, at: 0)
            listCache.saveRecentDocuments(recents)
        }
        // Only into a level that has actually been fetched — the same rule `addSubpage`
        // follows, so a cached "no children yet" is never fabricated from a create.
        if let parentID, var siblings = childrenCache.children(for: parentID),
            !siblings.contains(where: { $0.id == created.id })
        {
            siblings.append(created)
            childrenCache.save(siblings, for: parentID)
        }
    }

    /// A create that did not land. The document stays local and keeps its content whatever
    /// happens here — the only question is whether to try again, and where.
    private func handleCreateFailure(_ error: Error, for record: PendingDocumentCreate) async {
        guard let docsError = error as? DocsAPIError else { return }
        if retryableSaveFailure(docsError) || docsError == .sessionExpired {
            // Transport, 5xx, rate limit — or a re-login the shared client has already
            // raised. Leave everything; the next trigger retries.
            return
        }
        if record.parentID != nil, docsError == .routeNotFound {
            // This deployment has no `documents/{id}/children/` route at all, so retrying as
            // a sub-page is hopeless however healthy the parent is. Promote rather than
            // stranding the body — and skip the probe, which asks about the wrong thing.
            guard pendingCreates[record.localID] != nil else { return }
            var promoted = record
            promoted.parentID = nil
            updatePendingCreate(promoted)
            return
        }
        if let parentID = record.parentID, docsError == .forbidden || docsError == .notFound {
            // Maybe the parent is gone or no longer ours — but a 403 on a POST is **not**
            // only that. Django answers a bad `Origin` with `403 CSRF Failed`, which flattens
            // to `.forbidden` here, and that is the documented symptom of the capitalised-host
            // bug: every sub-page create would be silently promoted to a root, irreversibly.
            // So ask about the parent specifically, and promote only on evidence.
            let parentIsGone: Bool
            do {
                _ = try await client.document(documentID: parentID)
                parentIsGone = false
            } catch let probe as DocsAPIError where probe == .notFound || probe == .forbidden {
                parentIsGone = true
            } catch {
                // The probe itself failed to answer. "I couldn't ask" must never read as
                // "it isn't there" — leave the record alone and try again next pass.
                return
            }
            guard parentIsGone else { return }
            // Retry as a **root** document rather than stranding the content: placement is
            // recoverable by the user, a lost body is not.
            guard pendingCreates[record.localID] != nil else { return }
            var promoted = record
            promoted.parentID = nil
            updatePendingCreate(promoted)
            return
        }
        // Rejected on the merits (a validation 400, a decoding bug). Stop retrying every
        // trigger — `runCreatePass` skips `.failed` — and let a relaunch try once more, since
        // `states` is in-memory and `init` re-seeds every record to `.pendingSync`.
        //
        // Note this is **not** the reading surface's "tap to retry", despite reusing the
        // state: `saveNow` early-returns while `pendingSave` is non-nil, and a local document
        // the user has typed into always has its content parked in `queued`. So for those the
        // tap is a no-op and a relaunch is the only escape. Giving the create pass its own
        // retry affordance belongs with the UI that can present it.
        states[record.localID] = .failed("Couldn't save changes. Please try again.")
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
        enqueue(documentID: documentID, save: PendingSave(title: title, markdown: markdown), baseline: baseline)
    }

    /// Queue a **live-collaboration full-state snapshot** save. `snapshot` is the Yjs bytes
    /// to PATCH verbatim (tagged `"websocket": true`); `projectedMarkdown` is what the server
    /// will render from them and is the value **every** reconcile/baseline/cache rule keys
    /// off — it becomes the write-ahead draft body, the `lastConfirmedPushMarkdown` stamp on
    /// success, and the content-cache body, exactly as a classic save's markdown does. This
    /// reuses the identical write-ahead draft, enqueue-hold, single-writer, and latest-wins
    /// machinery as the classic `enqueue` (they share the private core below); the only
    /// difference reaches `start`, which sees a non-nil `liveSnapshot` and calls
    /// `saveLiveSnapshot` instead of `saveDocumentContent`.
    ///
    /// Dormant until C2c: nothing calls it yet (C2b is the mechanism, not the wiring).
    func enqueueLiveSnapshot(
        documentID: UUID, snapshot: Data, projectedMarkdown: String, title: String, baseline: DraftBaseline? = nil
    ) {
        enqueue(
            documentID: documentID,
            save: PendingSave(title: title, markdown: projectedMarkdown, liveSnapshot: snapshot),
            baseline: baseline)
    }

    /// The shared core of both public entry points. Classic and live saves differ only in the
    /// `PendingSave` handed here (a live save carries `liveSnapshot` bytes and a projected
    /// `markdown`); the draft write, enqueue-hold, and latest-wins logic below are identical.
    private func enqueue(documentID: UUID, save: PendingSave, baseline: DraftBaseline?) {
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
                documentID: documentID, title: save.title, markdown: save.markdown, updatedAt: Date(),
                baseline: baseline,
                lastPushedMarkdown: lastPushed,
                // Carry the hold through: `enqueue` rebuilds the whole draft, so omitting this
                // would silently erase a persisted conflict on the next keystroke.
                conflictServerUpdatedAt: conflicts[documentID]?.serverUpdatedAt))
        // Enqueue-hold: while a conflict is recorded, persist the draft and the
        // queued slot (write-ahead, so `pendingSave()` still sees it and the editor's
        // dirty short-circuit / `hasUnsavedLocalContent` keep working) but do NOT
        // start a save — an autosave flush would otherwise push unchecked over the
        // conflicting server copy the instant a conflict lands. "Keep mine" starts it.
        // The same hold, for a third reason: this document has no server id yet, so
        // `saveDocumentContent` would PATCH `documents/<local-uuid>/content/`, take a 404,
        // and — since a 404 is not retryable — land on `.failed`, which `runSyncPass`
        // skips. The document would be wedged out of the very replay meant to create it.
        // Write-ahead and latest-wins still apply; only `start` is withheld.
        if isPendingCreate(documentID: documentID) || conflicts[documentID] != nil || inFlight[documentID] != nil {
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
            //
            // A pending create is the same truth for the same reason: the work is on the
            // device and nothing is being sent. `createLocalDocument` already set it, but
            // set it here too rather than relying on that — `finish` can reset a state to
            // `.idle`, and this must not be the one path that leaves a held save reading
            // as saved.
            if isPendingCreate(documentID: documentID) || conflicts[documentID] != nil {
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
            // Creates first, inside the same pass: a document migrated here becomes an
            // ordinary draft under a real id, which `runSyncPass` then pushes immediately
            // rather than leaving until the next trigger. Both inherit this funnel's
            // re-entrancy guard and coalescing — the create replay must never get its own
            // triggers, or two passes could POST the same record twice.
            await runCreatePass()
            await runSyncPass(isLaunchRecovery: launchPass)
        } while needsAnotherSyncPass
    }

    private func runSyncPass(isLaunchRecovery: Bool) async {
        for draft in draftStore.allDrafts() {
            // A document the server has never seen cannot be reconciled against it: the GET
            // below would 404, and the catch at the bottom of this loop removes the draft on
            // a 404 — which for a locally-created document is the user's only copy. This
            // guard is why creating offline is safe at all; the create replay (a separate
            // pass) is what actually POSTs these.
            guard !isPendingCreate(documentID: draft.documentID) else { continue }
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
                // Belt and braces. The guard at the top of the loop means a pending create
                // never reaches this GET, but this is the line that would delete the only
                // copy of a locally-created document if it ever did — so it states the
                // invariant rather than relying on a caller ten lines above.
                guard !isPendingCreate(documentID: draft.documentID) else { continue }
                // And if the create store would not decode, we do not *know* which drafts
                // belong to local documents — so delete none of them. Cleaning up nothing
                // is a recoverable failure; deleting every offline-created document's only
                // copy because a schema slip read as "there are no local documents" is not.
                guard !createStoreUnreadable else { continue }
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
        // **The third gate of "no save may name a pending-create id"**, and one of the two
        // paths that reach `start` without passing through `enqueue`'s hold (the other is
        // `finish`'s queued restart, which carries the same guard). `clearResolvedConflict`
        // calls this, and the editor clears conflicts from five places — so releasing a hold on
        // a document the server has never seen would PATCH a nonexistent id, take a 404, and
        // land on `.failed`, which `runSyncPass` skips: the document wedged out of the replay
        // meant to create it. The save stays parked; the create replay is what sends it.
        //
        // Ordering matters: this returns **before** `removeValue`, so the held save is kept,
        // not silently dropped.
        guard !isPendingCreate(documentID: documentID) else { return }
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
        // A locally-created document is deleted purely locally (there is no server object
        // to DELETE), so its record must go with its draft — otherwise the create replay
        // would resurrect a document the user threw away. Its `.pendingSync` goes with it:
        // nothing is on the device to sync any more, and unlike a server document there is
        // no `finish` coming to reset it (the hold means no save was ever started).
        //
        // Scoped to that case deliberately. Resetting unconditionally *looks* tidier and
        // silently broke `testSaveLandingAfterADeleteNeverRecreatesTheCacheEntry`, which
        // synchronizes on `state != .saving` to wait out an in-flight PATCH: with the state
        // cleared synchronously the wait returned instantly and the assertions ran while
        // the save was still on the wire. The test stayed green while no longer pinning
        // invariant 0b at all. A server document's state stays `finish`'s to settle.
        if isPendingCreate(documentID: documentID) {
            removePendingCreate(documentID: documentID)
            states[documentID] = .idle
        }
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
                let titleFailure: DocsAPIError?
                if let snapshot = save.liveSnapshot {
                    // Live-collaboration snapshot: PATCH the CRDT bytes verbatim (websocket:true).
                    titleFailure = try await client.saveLiveSnapshot(
                        documentID: documentID, title: save.title, yjsUpdate: snapshot)
                } else {
                    // Classic full-overwrite: re-derive Yjs bytes from the markdown.
                    titleFailure = try await client.saveDocumentContent(
                        documentID: documentID, title: save.title, markdown: save.markdown)
                }
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
            // The pending-create half is unreachable today — `start` is only reached from
            // `enqueue`, `releaseHeldSave` and here, and the first two refuse, so no save can
            // be in flight for a local id — but this is the third path to `start` (and the
            // fourth place the invariant is enforced, counting `runSyncPass`), and the only
            // one where it would otherwise be asserted asymmetrically. The id migration is
            // exactly the change that could make it reachable.
            guard conflicts[documentID] == nil, !isPendingCreate(documentID: documentID) else {
                queued[documentID] = next
                states[documentID] = .pendingSync
                return
            }
            start(documentID: documentID, save: next)
        }
    }
}
