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
    /// Scopes `replayBlockedAt` — see `PendingDocumentCreate.isReplayBlocked(forBuild:)`.
    private let appBuild: String
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
    /// Bumped on every mutation of `pendingCreates`, so an `@Observable` consumer can track
    /// "the set of local documents changed" without the dictionary itself being visible.
    ///
    /// `HomeViewModel.recentDocuments` merges local documents in at *read* time — a synthetic
    /// `Document` must never enter a persisted metadata cache, since a list load replaces its
    /// array and its cache entry wholesale and a cached synthetic would afterwards be
    /// indistinguishable from a real one. Reading this in that computed property is what makes
    /// a migrated row vanish from a live Home the moment `removePendingCreate` runs, rather
    /// than at the next successful fetch.
    private(set) var pendingCreatesVersion = 0
    /// Fired after a locally-created document has been re-keyed onto its server id.
    ///
    /// The list that was showing it needs to *refetch*, not merely re-derive: the local row is
    /// correctly withheld the instant the record is dropped, but the real row exists only in a
    /// server response, and the one the list is holding predates the create. Pinning that
    /// refetch to particular sync triggers does not work — the pass is also started by
    /// `recoverDrafts` at launch and by `releaseOpenEditor` when an editor closes (the
    /// designed completion path, and the *only* one on iPad), and an overlapping trigger is
    /// coalesced into a no-op that returns before the migration happens. So it hangs off the
    /// migration itself, which is the event that actually invalidates the list.
    ///
    /// Carries the **created document**, because a refetch alone is not enough: a fresh
    /// install used offline first has no recents cache for `insertIntoListCaches` to write
    /// into (it refuses to fabricate one), so if the refetch then fails the row is in no list
    /// at all. The subscriber can put the real document straight into its in-memory list —
    /// never into the cache, which stays the server's to fill.
    ///
    /// Fired **last**, after the terminal `enqueue`, so a subscriber sees a fully settled
    /// state. Firing mid-function would expose a diverged resume with its draft on disk, its
    /// state `.idle` and *no conflict recorded yet* — a synchronous handler that enqueued
    /// there would go straight to `start` and full-overwrite the co-author.
    @ObservationIgnored
    var onDocumentMigrated: (@MainActor (Document?) -> Void)?
    /// Documents whose editor is on screen, reference-counted. The create replay **defers**
    /// for these: migration re-keys the draft, the coordinator's maps and the caches onto the
    /// server id, and `EditorViewModel.documentID` is a `let` captured by four sibling view
    /// models and by the pushed `NavigationPath` values — so an open screen cannot follow the
    /// id and would keep writing drafts under one the holds no longer cover. Deferring is meant
    /// to make mid-swap edit loss unrepresentable rather than merely unlikely.
    ///
    /// Wired from `EditorView`'s `onAppear`, for **every** document rather than only
    /// locally-created ones — the server-id guards' motivating case is an ordinary document
    /// opened from Home whose id a checkpointed record is about to migrate *onto*. The view
    /// hold is released when the *view model* is deallocated, not on `onDisappear` — that
    /// fires on mere invisibility (a tab switch), and the replay must not re-key a document
    /// whose screen is about to return. Six readers: four `guard` deferrals, the take-back's conjunct, and
    /// `discardPendingWork`'s checkpointed branch — the one that is *not* a deferral, since
    /// it clears the checkpoint and restarts the record instead of returning.
    ///
    /// The cost is broader than an iPad split view: any editor left pushed in a tab's
    /// navigation stack holds its document until the user pops back, so a create-type-switch-
    /// tabs flow leaves it unreplayed while the indicator reads "syncs when online". Bounded
    /// by user action rather than by connectivity, and popping back kicks the funnel.
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
        appBuild: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
        backgroundTasks: BackgroundTaskProvider = .uiApplication
    ) {
        self.client = client
        self.draftStore = draftStore
        self.contentCache = contentCache
        self.createStore = createStore
        self.listCache = listCache
        self.childrenCache = childrenCache
        self.serverOrigin = serverOrigin
        self.appBuild = appBuild
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
        // deletion*. Origin decides what is **listed** (below) and, with the owning user,
        // what the replay may **POST** (`isReplayable`) — never whether the content is
        // protected.
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
    /// **The one exemption is `migrateCreatedDocument`'s `conflicts[localID] = nil`**, and it
    /// is one precisely because there is no mirror to diverge from: it runs after the local
    /// draft has been removed, so `persistConflictOnDraft` would no-op, and the entry it
    /// clears is provably nil anyway (every `recordConflict` caller needs a *successful*
    /// server interaction with that id, which a client-minted one cannot get). It is written
    /// as a direct clear rather than routed through here so that the id is guaranteed to carry
    /// nothing forward — stating the exemption beats leaving a silent fourth writer.
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
    /// Consulted by the editor via `EditorViewModel.isLocalDocument`: opening a local document names its id from several
    /// places this coordinator does not own (`formattedContent`, the children fetch, the
    /// collaboration room, Options' delete and version history). Those are gated in `EditorViewModel`/`EditorView`/`OptionsSheetView`, not here.
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
    /// `parentID` is a server id, nil for a root, **or another pending record's `localID`** —
    /// a sub-page created under a document this device has also not sent yet. Nothing needs
    /// to be true of the parent at mint time; ordering is the replay's problem, and it solves
    /// it in two pieces that must be read together: `runCreatePass` refuses to POST a record
    /// whose parent is still pending, and `migrateCreatedDocument` repoints every such child
    /// at the server id the parent was just given, immediately before dropping its record.
    /// Between them a child can never address `documents/{local-uuid}/children/`, which the
    /// server answers with a 404 that the probe then mistakes for "the parent is gone" and
    /// silently re-roots the document.
    ///
    /// `ownerUserID` is **required, not defaulted**: an unattributable record can be neither
    /// listed nor replayed (see `belongsToSession`), so a caller that could not name the
    /// user would silently mint a document that never appears and never syncs. Making the
    /// parameter mandatory forces that problem to the surface at the mint site, where the
    /// session exists to answer it.
    ///
    /// Called from Home's `+` and from the two sub-page affordances, whenever a create
    /// cannot reach the server (or Work Offline forbids trying).
    @discardableResult
    func createLocalDocument(title: String, parentID: UUID?, ownerUserID: UUID) -> Document {
        let record = PendingDocumentCreate(
            localID: UUID(), title: title, parentID: parentID, createdAt: Date(), serverOrigin: serverOrigin,
            ownerUserID: ownerUserID)
        createStore.save(record)
        pendingCreates[record.localID] = record
        pendingCreatesVersion += 1
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
        // empty document the POST just made. Migration must stamp one before the draft is
        // replayed, saying what the body **descends from** — the create response on an
        // undiverged fresh POST, a `formattedContent` fetch on an undiverged resume, and a
        // nil clock with an empty body when the two have **diverged**, where claiming the
        // observed state would prove the very push the conflict is holding. See
        // `migrateCreatedDocument`.
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
        removePendingCreates(documentIDs: [documentID])
    }

    /// The same, for a whole set at once — what the sub-page delete needs. Batched rather than
    /// looped because the store is one blob: see `PendingDocumentCreateStore.remove(localIDs:)`
    /// for why a partially-removed subtree is the one state that must not exist.
    private func removePendingCreates(documentIDs: [UUID]) {
        let present = documentIDs.filter { pendingCreates[$0] != nil }
        guard !present.isEmpty else { return }
        for documentID in present { pendingCreates[documentID] = nil }
        pendingCreatesVersion += 1
        createStore.remove(localIDs: present)
    }

    /// Whether any document created on this device is filed under this one — the question the
    /// delete confirmation asks, so it can say that sub-pages go with it.
    ///
    /// Resolves **both** ids, because the two are used at different moments in a record's life:
    /// a sub-page names its parent's `localID`, but once that parent is checkpointed
    /// `pendingLocalDocuments` withholds the local row and the user meets — and deletes — the
    /// document under its *server* id. Asking only about `documentID` would answer "no
    /// sub-pages" for precisely the parent whose sub-pages are about to be deleted.
    ///
    /// Direct children only: a grandchild implies a child, so the copy is right either way.
    func hasPendingLocalChildren(documentID: UUID) -> Bool {
        let localID = checkpointedRecord(forServerID: documentID)?.localID
        return pendingCreates.values.contains { child in
            // Unwrapped rather than compared as Optionals. `child.parentID == localID` with
            // both nil — an ordinary document, so no checkpointed record, against a record that
            // is a root — is `true`, which would announce sub-pages for every document on the
            // device the moment one root existed.
            guard let parentID = child.parentID else { return false }
            return parentID == documentID || parentID == localID
        }
    }

    /// The local documents filed under this one, **parents before their own children**, with
    /// any whose editor is open promoted out of the subtree instead of listed.
    ///
    /// Iterative and `visited`-guarded on purpose. This walks data decoded from disk, where the
    /// shape is a tree only by construction — a damaged blob naming a cycle would otherwise
    /// recurse until the stack ran out, and `createLocalDocument` is not the only thing that
    /// could ever write these records.
    ///
    /// **A child whose editor is open is re-parented to the root rather than deleted.** Every
    /// other record remover in this file defers to an open editor, and this is the only one
    /// that would take a live screen's draft — the disk backing of content the user can see —
    /// out from under it. Unreachable through navigation today (a parent's Options sheet can
    /// only open while the parent's own editor is topmost, and a child is pushed above it), but
    /// promoting is what keeps that from mattering. Promoting rather than merely skipping,
    /// because a skipped record left naming a deleted parent is one no gate holds any more: it
    /// would POST under a dead local id and be re-rooted by the probe anyway, just later and
    /// without the user's screen surviving intact. Its own sub-pages stay with it.
    private func localDescendantsToDiscard(of parentLocalID: UUID) -> [UUID] {
        var ordered: [UUID] = []
        var visited: Set<UUID> = [parentLocalID]
        var frontier = [parentLocalID]
        while let next = frontier.popLast() {
            for child in pendingCreates.values.filter({ $0.parentID == next }) {
                guard visited.insert(child.localID).inserted else { continue }
                if hasOpenEditor(documentID: child.localID) {
                    var promoted = child
                    promoted.parentID = nil
                    updatePendingCreate(promoted)
                    continue
                }
                ordered.append(child.localID)
                frontier.append(child.localID)
            }
        }
        return ordered
    }

    /// Throw away a local document's whole subtree: the sub-pages created under it, theirs, and
    /// so on. Deleting a document created on this device deletes what was filed inside it, the
    /// same as deleting one on the server does — and the alternative is worse than it sounds,
    /// since an orphaned record is listed by nothing (`pendingLocalDocuments` filters on an
    /// exact `parentID`, and Home asks for `nil`) yet still holds a full document body.
    ///
    /// **Every record goes in one write — the root's included — and only then the drafts.**
    /// That single write is what stops a partial subtree existing (see `removePendingCreates`);
    /// taking the root out separately would reintroduce it, since a crash in between leaves the
    /// document the user deleted still holding a record that replays it back onto the server.
    /// Record-before-draft is then the same ordering `discardPendingWork` already uses for the
    /// document itself: a draft left with no record is inert and gets reaped by the sync pass's
    /// ordinary 404 rule, where a record left with no draft POSTs an empty document under its
    /// mint title.
    ///
    /// The **root's** draft and state stay with the caller, whose two branches handle them
    /// differently; only the descendants are this method's to clean up.
    ///
    /// Nothing here purges the content cache, and that is not an omission: a descendant is
    /// provably un-checkpointed — the dependency gate held it back for as long as this parent's
    /// record existed, which is exactly the window in which this runs — so it has never had a
    /// confirmed save or a fetch under its own id, and only those write that cache.
    private func discardLocalSubtree(rootedAt rootLocalID: UUID) {
        let descendants = localDescendantsToDiscard(of: rootLocalID)
        removePendingCreates(documentIDs: descendants + [rootLocalID])
        for documentID in descendants.reversed() {
            // Reversed, so a document is only ever cleaned up after everything filed inside it.
            states[documentID] = .idle
            draftStore.remove(documentID: documentID)
            queued[documentID] = nil
            settledSaves[documentID] = nil
            lastConfirmedPushMarkdown[documentID] = nil
            knownServerTitles[documentID] = nil
            // Assigned directly rather than through `clearResolvedConflict`, which is
            // `releaseHeldSave`'s route: that method's own guard is `isPendingCreate`, which
            // the removal above has just made false, so it would pop the parked save and PATCH
            // an id the server has never seen. (A client-minted id cannot acquire a conflict in
            // the first place — `recordConflict` needs a successful server interaction — so
            // this is defensive, and defensive is exactly why it must not take a route that
            // sends a request.)
            conflicts[documentID] = nil
        }
    }

    /// Test seams for staging a *checkpointed* record, which only the replay can otherwise
    /// produce. Both go through the same mirror+disk pair every other writer uses, so a test
    /// cannot construct a state the production code could not.
    func pendingCreateForTesting(localID: UUID) -> PendingDocumentCreate? {
        pendingCreates[localID]
    }

    func savePendingCreateForTesting(_ record: PendingDocumentCreate) {
        updatePendingCreate(record)
    }

    /// Test seam: whether any screen currently holds this document. The registration is
    /// released from a `deinit` that hops to the main actor, so a test needs to observe the
    /// hop rather than assume it.
    func hasOpenEditorForTesting(documentID: UUID) -> Bool {
        hasOpenEditor(documentID: documentID)
    }

    /// The server id a locally-created document has already been POSTed under, if any.
    ///
    /// The delete path needs this and cannot infer it: `isPendingCreate` stays true for a
    /// **checkpointed** record — the POST has landed and a real server document exists — so
    /// "this is a local document" is not the same question as "is there anything on the server
    /// to delete". Without it, deleting a checkpointed document would drop the record and the
    /// draft while leaving the server copy alive, and it would reappear in Home on the next
    /// list fetch with nothing on the device that knows about it.
    func syncedServerID(forLocalID localID: UUID) -> UUID? {
        pendingCreates[localID]?.syncedServerID
    }

    /// The one way to rewrite a mirrored record. Both the disk copy and the in-memory mirror
    /// move together, because `isPendingCreate` — the predicate every gate keys off — reads
    /// the mirror while the replay's resume path reads the disk. Letting them drift means a
    /// document that is protected in one process and unprotected in the next.
    private func updatePendingCreate(_ record: PendingDocumentCreate) {
        createStore.save(record)
        pendingCreates[record.localID] = record
        // A rewrite counts: the checkpoint being stamped is what withholds the local row from
        // `pendingLocalDocuments`, so a live Home must re-read.
        pendingCreatesVersion += 1
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
            // The local id — the ordinary case. Also the **server** id of a checkpointed
            // record: once checkpointed the local row is withheld and the user meets the
            // document under its real id, which is exactly the editor `finishMigration`'s
            // `serverID` guards now defer to. Without this the deferred migration would wait
            // for an unrelated foreground or reconnect.
            if isPendingCreate(documentID: documentID) || checkpointedRecord(forServerID: documentID) != nil {
                Task { await syncPendingDrafts() }
            }
        } else {
            openEditors[documentID] = held - 1
        }
    }

    private func hasOpenEditor(documentID: UUID) -> Bool {
        (openEditors[documentID] ?? 0) > 0
    }

    /// The record waiting to migrate onto this **server** id, if any — i.e. the id the user
    /// actually meets that document under while it sits checkpointed, since
    /// `pendingLocalDocuments` withholds the local row from that moment on.
    private func checkpointedRecord(forServerID documentID: UUID) -> PendingDocumentCreate? {
        pendingCreates.values.first { $0.syncedServerID == documentID }
    }

    // MARK: - Create replay

    /// POST the documents this device created, then hand their content to the ordinary draft
    /// replay. Runs **before** `runSyncPass` inside the same coalesced pass, so that a
    /// migration *deferred* by the server-id guards has the draft blocking it cleared within
    /// the same pass. (Not that this saves a trigger — the migration itself waits for the next
    /// one either way, as `finishMigration` and `syncPendingDrafts` both note.)
    ///
    /// Costs nothing on a device with no local documents: `allCreates()` is empty, so the gate
    /// returns before issuing any request at all.
    private func runCreatePass() async {
        let records = createStore.allCreates()
        // Cheap gate before the round trip: a record from another server, or one nothing can
        // attribute, can never be replayed here (see `belongsToSession`) and nothing deletes
        // it — so without this every reconnect, foreground and launch would pay a
        // `/users/me/` request that cannot produce work, forever.
        guard
            records.contains(where: {
                $0.serverOrigin == serverOrigin && $0.ownerUserID != nil
                    && !$0.isReplayBlocked(forBuild: appBuild)
            })
        else { return }

        // Placed **after** the cheap gate above deliberately: this reads and decodes every
        // draft on the device, bodies included, on the main actor. Nothing below reads a
        // draft until `replayCreate`, so deferring it past the gate costs no safety and
        // keeps the no-local-documents case —
        // free of a full draft decode on every launch, foreground and reconnect.
        // **Never replay while the drafts are unknown.** `PendingDraftStore.loadAll` is
        // all-or-nothing, so one undecodable blob makes every `draft(for:)` answer nil — and
        // this pass reads that as "the body is empty". It would then POST each record under
        // its mint title, sail through `finishMigration`'s both-drafts guard (which reads the
        // same nil), enqueue `""`, and `removePendingCreate` — deleting the one thing that
        // could have driven a recovery after a shipped decode fix. N unrecoverable empty
        // documents from a single schema slip.
        //
        // Before the replay existed, an undecodable blob merely made unsaved work invisible;
        // this pass is what turns it into destroyed content, so this is where it is asked.
        // (Not the *only* irreversible consumer, though — `init`'s conflict rehydration reads
        // the same empty answer and silently drops every persisted hold, after which `enqueue`
        // takes the `start` path against a server the user was warned about. That one predates
        // this PR and is untouched here.)
        //
        // **This buys less than `createStoreUnreadable` does, and the difference matters.**
        // That flag is read once at init and is sticky, backed by a quarantine key. This one is
        // recomputed per pass over bytes that two very ordinary callers overwrite: `enqueue`'s
        // `draftStore.save` on any keystroke for *any* document, and `discardPendingWork`'s
        // `remove`. Both are read-modify-writes through `loadAll`, which answers `[:]` for a
        // corrupt blob — so the first of them replaces the damaged bytes, this flag goes false,
        // and the next pass does exactly what the guard exists to prevent: POST under the mint
        // title, pass the both-drafts guard on the same nil, enqueue `""`, and delete the
        // records. The hold lasts until the first save on any document, not until the schema is
        // fixed. Strictly better than firing at launch, but the thing that would make it mean
        // anything past that write is the quarantine `PendingDraftStore` still owes.
        guard !draftStore.holdsUnreadableData else { return }
        // Which account is in front of us. Asked once per pass, and only when there is
        // something to send: `isReplayable` needs it, and this is the layer that *can* await
        // it — the coordinator is constructed long before `/users/me/` returns. A failure
        // (offline, or a server that omits the id) leaves every record unreplayable, which
        // is the correct answer rather than a reason to guess.
        guard let currentUserID = try? await client.currentUser().id else { return }

        for snapshot in records {
            // Re-read rather than trusting the snapshot: the loop awaits, and a delete
            // (`discardPendingWork`) or a previous iteration can have removed or rewritten
            // this record since. Acting on the stale copy would POST a document the user threw
            // away, leaving an orphan on the server that nothing here will ever reference.
            // (It would not *resurrect* the record — every `updatePendingCreate` on this path
            // is already guarded on the record still existing — so this guard is about the
            // wasted create, not the write-back.)
            guard let record = pendingCreates[snapshot.localID] else { continue }
            // **A sub-page waits for its parent to become a real document.** A child created
            // under a parent this device has not yet POSTed carries that parent's *local* id
            // in its own `parentID`, and POSTing it would name `documents/{local-uuid}/
            // children/` — a 404, then a parent probe that 404s too, then a silent re-root.
            // `migrateCreatedDocument` rewrites these to the server id the instant the parent
            // lands, and the loop below re-reads each record from the mirror, so a parent and
            // its sub-pages replay in *this* pass, in order.
            //
            // Keyed on `isPendingCreate`, which stays true through checkpointing: the child
            // waits for the parent's **full** migration, because it is the migration — not the
            // POST — that does the rewrite.
            //
            // What a waiting child inherits, and how each state clears:
            //
            //   parent's POST failed retryably   → next trigger retries the parent first
            //   parent `.failed` (on the merits) → relaunch re-seeds it `.pendingSync`
            //   parent replay-blocked            → a build that can read the response retries
            //   parent's editor open             → `releaseOpenEditor` kicks the funnel
            //   parent checkpointed, deferred    → that deferral's own escape
            //   parent foreign/unattributable    → the owner signs back in
            //
            // In every one of them the child's body stays on disk and protected: this costs a
            // sub-page its sync, never its content. The one cost is that a permanently stranded
            // parent strands its children with it — the same recovery the docs already record as
            // owed for the parent alone.
            if let parentID = record.parentID, isPendingCreate(documentID: parentID) { continue }
            guard isReplayable(record, currentUserID: currentUserID) else { continue }
            // A create *this build* could not read the response of. Retrying it POSTs a
            // duplicate and abandons whatever the server already built — see
            // `replayBlockedAt`. A stamp from another build is spent, so a shipped fix
            // recovers the record on its first launch.
            guard !record.isReplayBlocked(forBuild: appBuild) else { continue }
            // A save the *server* rejected on the merits is left to the user, exactly as
            // `runSyncPass` does. Note the caption is visible but the affordance is inert here:
            // `saveNow` no-ops while `pendingSave` is non-nil, which a local document with
            // content always has — so a relaunch is the escape until a create-specific affordance offers one.
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
            // Persisted **only if the record still exists.** A delete during the POST await
            // has already removed it, and `updatePendingCreate` writes through to disk — so
            // dropping this guard would write the deleted record *back*, checkpoint attached,
            // and the next pass would re-materialise in Home a document the user threw away.
            // The local `record` copy still carries the id, which is what lets
            // `finishMigration` run its own re-checks rather than deciding here.
            record.syncedServerID = created.id
            record.postedTitle = title
            // A successful POST proves any earlier block spent, and **this** is where the wedge
            // is created — the start-over path is reachable only on a build the stamp does not
            // match, i.e. never for the record it actually wedges. Carried forward, a
            // checkpointed record keeps a stamp from an older build, and reverting to that build
            // skips it forever with the local row withheld and the body unmigrated.
            record.replayBlockedAt = nil
            record.replayBlockedBuild = nil
            if pendingCreates[record.localID] != nil { updatePendingCreate(record) }
            // `""` is provable here, not assumed: this POST created the document a moment ago.
            finishMigration(
                record, serverID: created.id, serverTitle: created.title,
                serverUpdatedAt: created.updatedAt, serverMarkdown: "", document: created)
            return
        }
        // Resuming after a death between the checkpoint and the migration.
        guard let serverID = record.syncedServerID else { return }
        // **The cosmetic fetch goes first, and may fail.** It exists only to give the list
        // caches a `Document`; nothing in the safety argument reads it. Ordering it first is
        // load-bearing twice over. (a) It must not sit *between* reading the server's body and
        // acting on that reading: a full round trip is 100s of milliseconds in which a
        // co-author can save, and the conflict guard below would then be deciding from a body
        // the server no longer holds. (b) Its failure must never discard the checkpoint — a
        // 403 here (ACL propagation, a proxy, a bad `Origin`) would otherwise send the next
        // pass off to POST a *second* document, orphaning the first along with anything
        // written into it. `try?`: the document just doesn't join the cached list until the
        // next ordinary fetch.
        // **Snapshot before reading, because a save can start *and settle* inside the await.**
        // `finishMigration`'s `inFlight`/`queued` check is the boolean this coordinator
        // already documents as insufficient: a save for `serverID` that completes during the
        // fetch leaves both nil *and* removes its draft, so all three guards pass and the
        // migration decides from a body the server no longer holds — pushing the older local
        // one straight over content the user just saw confirmed as saved. `mayPredateSave`
        // is the instrument for exactly this, and the sibling read-then-act in `runSyncPass`
        // already re-checks its draft after the await for the same reason.
        let marker = saveMarker(documentID: serverID)
        let document = try? await client.document(documentID: serverID)
        let formatted: FormattedDocumentContent
        do {
            // **`formattedContent`, not `document`.** The latter carries no body, so using it
            // meant stamping `markdown: ""` into the baseline — asserting the server was empty
            // when nothing had checked. The migration then enqueues straight into `start`, so
            // a document that had *acquired* a body would be silently full-overwritten, and
            // the lying baseline would mislead every later `draftSyncDecision` too. That is no
            // longer only a theoretical path: "checkpointed but not migrated" is a state the
            // document is visible and editable on the web in. (It no longer needs a process death — the checkpoint-to-migration stretch has no suspension point, so the
            // server-id guards cannot *create* it, only prolong it.)
            formatted = try await client.formattedContent(documentID: serverID)
        } catch let error as DocsAPIError where error == .notFound {
            // The checkpointed document is gone, so resuming can never succeed — and silently
            // retrying forever would leave it in no list (`pendingLocalDocuments` withholds a
            // checkpointed record) and never pushed, i.e. unreachable by every route the app
            // offers. Drop the checkpoint so the next pass creates it afresh — but only once
            // nothing is left under that server id (the guard below). "There is nothing left
            // to duplicate" is the *premise* of this branch, not a fact it has established:
            // a bare `.notFound` covers a proxy hiccup too, so where the clear does fire the
            // residual is a re-POST that orphans a document still alive on the server. That
            // residual is accepted; what the guard narrows is the case where a local body
            // would have been destroyed along the way.
            //
            // **`.notFound` only — never `.forbidden`.** A bare 403 is not evidence a document
            // is gone: an ancestor access recompute can 403 transiently. (Not the bad-`Origin`
            // argument that applies on a POST — `performRequest` attaches `Origin`/`Referer`
            // only to non-GETs, so a CSRF 403 cannot reach *this* call. `handleCreateFailure`
            // is the mirror image: there the 403 arrives on the POST and the probe is the GET.)
            // Acting on one here would create a duplicate and orphan the original, which is
            // unrecoverable. `.routeNotFound` falls to the transient branch too: it is a fact
            // about the route, not about this document.
            //
            // The cost is real and is **not** "merely stuck": a genuinely revoked document
            // ends up in exactly the state the branch below calls unreachable — withheld from
            // `pendingLocalDocuments`, never pushed, two GETs per trigger, forever — with its
            // body alive only in the local draft. The trade is deliberate (unrecoverable
            // duplicate vs. recoverable invisibility), and making such a record visible and dischargeable is still owed.
            // **Take the body back to the local id *before* clearing the checkpoint.** A
            // process death inside the migration can leave the only copy under `serverID` —
            // that draft is written before the local one is removed, precisely so no instant
            // exists with the content nowhere. The checkpoint is the last thing associating it
            // with this record, so once that is gone the body is **orphaned**: the re-POST
            // mints a different server id and its body chain looks under the local id and the
            // *new* one, never the old, so it builds an *empty* document in place of the
            // user's text — and the stranded draft is separately reaped by `runSyncPass`, which
            // GETs it and takes the same 404. (Note the draft under `serverID` is never covered
            // by the pending-create hold in *either* ordering — that guard is keyed on the
            // local id. What the ordering decides is whether the body is still reachable at
            // all, not whether it is protected from that sweep — the checkpointed window has its own
            // server-id suppression there, and this branch is about the state after the checkpoint is
            // cleared.)
            //
            // **Order is the whole point, and getting it backwards reproduces exactly that.**
            // These are two independent UserDefaults keys, so a kill between them is a real
            // state: clear-then-move leaves an un-checkpointed record with the body still
            // stranded under `serverID`, which is the loss above reached through this branch.
            // Move-then-clear is self-healing instead — the record is still checkpointed and
            // the local draft is back, so the next resume takes the local-present guard below
            // and simply clears the checkpoint. Same discipline `migrateCreatedDocument`
            // applies one function above: write under the new id before taking it off the old.
            //
            // The guard is on the local draft being absent, the discriminator `finishMigration`
            // uses: with one present this is not the partial-migration window, so the `serverID`
            // draft is the user's own separate work and must not overwrite the local body.
            // (Not "work against a real document" — that clause is `finishMigration`'s, where
            // the fetch *succeeded*. Here it 404'd, so the document is probably gone.) That
            // case is no longer a loss: with both drafts present the start-over below declines,
            // the checkpoint stays, and the checkpoint is what stops `runSyncPass` reaping the
            // `serverID` draft. Both bodies survive. Note "retries next pass" means it
            // re-asks, not that it converges: if the document really is gone this re-takes
            // the same 404 on every trigger, indefinitely. That standoff is deliberate —
            // `runCreatePass` will not clear the checkpoint while the draft exists, and
            // `runSyncPass` will not delete the draft while the record is checkpointed — and
            // it is bounded by the recovery affordance recorded as owed in the docs.
            //
            // The take-back carries the concurrency conjuncts for its own reason. It shares
            // `!mayPredateSave(marker)` with the start-over below, but the two are not
            // redundant: this one is skipped outright whenever a local draft is present, and
            // that is exactly the shape in which the start-over still runs — so neither can
            // stand in for the other. It shares `!hasOpenEditor(serverID)` with the
            // start-over too; `inFlight[serverID] == nil` is the one conjunct that is this
            // guard's alone. `runCreatePass` only guards `hasOpenEditor(record.localID)`,
            // so this branch can run with a live editor — or an in-flight save — on `serverID`,
            // and removing that draft yanks the disk backing out from under it; the editor's
            // next flush would recreate it while the re-POST mints a *second* document holding
            // the same body. It would also split the conflict mirror
            // `persistConflictOnDraft` exists to keep whole: the persisted
            // `conflictServerUpdatedAt` dies with the draft while `conflicts[serverID]` lives
            // on in memory, unrepairable (that method needs a draft to write to), so the hold
            // is silently lost at the next relaunch.
            if draftStore.draft(for: record.localID) == nil, let orphan = draftStore.draft(for: serverID),
                !mayPredateSave(marker), inFlight[serverID] == nil, !hasOpenEditor(documentID: serverID)
            {
                draftStore.save(
                    PendingDraft(
                        documentID: record.localID, title: orphan.title, markdown: orphan.markdown,
                        updatedAt: orphan.updatedAt, baseline: nil))
                draftStore.remove(documentID: serverID)
            }
            // **Discharge whatever is left, now that nothing is left to protect.** The guards
            // below establish exactly that: no save may predate the fetch, no screen is
            // writing under this id, and no draft survives it. So a conflict record still
            // sitting here — rehydrated by `init`, or left in memory by the take-back that
            // just moved its draft away — protects nothing, and a `queued` slot holds a copy
            // of a body now on disk under the local id.
            //
            // The reachable shape is the take-back path: it removes the draft that mirrored
            // the conflict, so `persistConflictOnDraft` can no longer repair the record, which
            // would otherwise outlive its draft and park every future save behind a pill
            // nothing can answer. Drop `queued` first, or `clearResolvedConflict` →
            // `releaseHeldSave` pops the parked save and PATCHes the id that just 404'd.
            //
            // An earlier revision discharged here *unconditionally*, arguing that
            // `runSyncPass` skips a conflicted draft, so the reap it defers to could never run
            // and the record would strand permanently. True, and beside the point: it ranked
            // stranding above losing the body, which is backwards. The guards below are the
            // correction, and this discharge now runs only once they have all passed.
            //
            // (Those statements are ~45 lines down, past the three guards and their own
            // rationale. This block is here because it explains why the *branch* ends the way
            // it does; the next paragraph starts a separate argument.)
            //
            // **Do not start over while work survives under the server id.** The checkpoint is
            // the *only* thing protecting that draft: `isPendingCreate` is keyed on the local
            // id, so `runSyncPass`'s delete branch skips it solely because
            // `checkpointedRecord(forServerID:)` answers non-nil. Clearing `syncedServerID`
            // disarms that — and `runSyncPass` runs next in the same pass, takes the same 404,
            // and removes the draft. That is content loss from one bare 404, with no process
            // death and no editor open.
            //
            // Gating on *concurrent* activity (a live save, an open editor) is not enough,
            // because the user who typed under `serverID` and then navigated away leaves no
            // such witness — and theirs is exactly the work at stake. The only sufficient
            // evidence is whether anything is still there to lose.
            //
            // So: take the body back if this is the partial-migration window (above), and
            // otherwise start over only when nothing remains under `serverID`. If something
            // does, leave the checkpoint — the record stays protected and the next pass
            // re-asks. A genuinely gone document then sticks in that state, which is the same
            // stuck-but-lossless outcome the `.forbidden` branch already accepts and the same recovery still owed; a spurious 404 simply resolves next pass.
            //
            // **And the absence of a draft is not, by itself, evidence there was none.** A
            // save for `serverID` that started *and settled successfully* inside the fetch
            // window has `finish` remove its draft on the way out — so it manufactures the
            // very emptiness this gate reads as "nothing to lose", while the 404 that reached
            // us may well have been answered from the state before it. Starting over there
            // re-POSTs a document that exists and holds the body the user just watched save.
            // The marker is the only thing that still remembers, which is why it is snapshotted
            // before both fetches; bailing is free, since the checkpoint is persisted and the
            // next trigger re-asks with a fresh one. (The take-back above carries this same
            // conjunct, but it is skipped entirely whenever a local draft is present, so it
            // cannot stand in for this one.)
            guard !mayPredateSave(marker) else { return }
            // And not under a live screen on that id. This branch removes no draft, so the
            // take-back's rationale does not apply — but clearing the checkpoint *disarms*
            // `runSyncPass`'s server-id suppression, and `runCreatePass` only ever guarded
            // `hasOpenEditor(record.localID)`. A user reading the document under `serverID`
            // (the only id they are offered once checkpointed) can type immediately after,
            // take a transient save failure, and have the next pass meet the same 404 with
            // nothing left to hold its draft back. The checkpoint is the app's own record
            // that it believed this document alive; a bare `.notFound` is not the evidence
            // to retract it while a screen is still writing under it.
            guard !hasOpenEditor(documentID: serverID) else { return }
            guard draftStore.draft(for: serverID) == nil else { return }
            // Nothing is left under that id, so the conflict record and any parked save are
            // moot by construction — there is no work left for them to protect.
            queued[serverID] = nil
            clearResolvedConflict(documentID: serverID)
            record.syncedServerID = nil
            // Cleared with the checkpoint it was stamped beside, or a persisted record would
            // carry a `postedTitle` with no `syncedServerID` — which is what its own doc
            // comment says cannot happen.
            record.postedTitle = nil
            record.replayBlockedAt = nil
            record.replayBlockedBuild = nil
            if pendingCreates[record.localID] != nil { updatePendingCreate(record) }
            return
        } catch {
            // Transient — leave it for the next pass.
            return
        }
        // Bailing is free: the checkpoint is persisted, so the next trigger re-fetches and
        // decides from a body that is actually current.
        guard !mayPredateSave(marker) else { return }
        finishMigration(
            record, serverID: serverID, serverTitle: formatted.title,
            serverUpdatedAt: formatted.updatedAt, serverMarkdown: formatted.content ?? "",
            document: document)
    }

    /// The migration, guarded by everything that can have changed while the POST or the resume
    /// GET was in flight: an editor opening on either id, the record being deleted, a save
    /// starting or being parked for the server id, and the both-drafts window. Five guards —
    /// the first two keyed on `localID`, the next two on `serverID`, and the last on both.
    private func finishMigration(
        _ record: PendingDocumentCreate, serverID: UUID, serverTitle: String?, serverUpdatedAt: Date,
        serverMarkdown: String, document: Document?
    ) {
        // An editor can have opened during the await, and migrating under a live screen is
        // exactly what `openEditors` exists to prevent: the screen's `documentID` is a `let`,
        // so it would keep enqueueing under an id the holds no longer cover — and the next
        // sync pass would 404 and delete that draft. The checkpoint is already persisted, so
        // bailing out on *this* guard is free: the next pass resumes at migration.
        guard !hasOpenEditor(documentID: record.localID) else { return }
        // The user deleted the document while the POST was in flight. `discardPendingWork`
        // has already removed the record and the draft; migrating would re-materialise a
        // document they threw away. Note bailing here is **not** free the way the guard above
        // is: the POST landed, so an empty document is left on the server that nothing on this
        // device now references — see the delete-branch obligation in `docs/offline-and-sync.md`.
        // The *checkpoint*, not merely the record. `discardPendingWork`'s open-editor branch
        // creates a state that did not previously exist — record present, checkpoint cleared —
        // and migrating on a captured `syncedServerID` would re-key onto a server id the user
        // has just deleted.
        guard pendingCreates[record.localID]?.syncedServerID == serverID else { return }
        // **The two guards above are keyed on `localID`; the rest are keyed on `serverID` —
        // except the last, which reads both, since it fires on the complement of the
        // partial-migration window: the local draft gone while the server-id one remains.**
        //
        // That asymmetry is a content-loss path on its own. Once a record is
        // checkpointed, `pendingLocalDocuments` withholds it, so the local row disappears and
        // the *server* document comes back in an ordinary list fetch — indistinguishable from
        // any other document. The user can open it, type, and have a save on the wire, all
        // under `serverID`, while this migration still believes only `localID` matters. It
        // would then overwrite that draft (dropping its `lastPushedMarkdown` and any conflict
        // stamp), replace its `queued` keystrokes, and record a conflict against a save that
        // is in flight — which is also the one thing the conflict invariant forbids.
        //
        // Bailing is free here too. The **both-drafts** guard is the one this same pass
        // clears: `runSyncPass` pushes that draft and `finish` removes it. The `inFlight`/
        // `queued` guard is not — `runSyncPass` skips a document with either set, so it is
        // `finish` alone that drains them. Either way the migration
        // itself waits for the *next* trigger though — `finish` does not kick the funnel and
        // the `repeat` loop only re-runs when `needsAnotherSyncPass` is set — i.e. a
        // foreground, a reconnect, or the editor release below.
        //
        // Two shapes do **not** clear themselves: a draft whose push was rejected on the
        // merits (`.failed`, which `runSyncPass` skips) and one behind a recorded **conflict**
        // — which waits on the user answering the pill and, unlike the in-memory `.failed`, is
        // persisted on the draft, so it outlives relaunches and is the more durable of the
        // two. (A `queued` slot on its own is not one of them: filled behind an in-flight
        // save, `finish` drains and starts it, and the obstruction goes with no trigger. The
        // self-perpetuating queued slot *is* the conflict hold, already counted.) In both
        // cases the bodies stay on disk: this costs the local document its sync, never its
        // content.
        guard !hasOpenEditor(documentID: serverID) else { return }
        guard inFlight[serverID] == nil, queued[serverID] == nil else { return }
        // A draft under the server id is *ours* only in the partial-migration window — the
        // one `migrated` exists for — and that window is defined by the local draft already
        // being gone (it is removed immediately after the server-id one is written). With the
        // local draft still present, any server-id draft was authored by the user against the
        // real document, and overwriting it would destroy work.
        if draftStore.draft(for: record.localID) != nil, draftStore.draft(for: serverID) != nil {
            return
        }
        migrateCreatedDocument(
            record, serverID: serverID, serverTitle: serverTitle, serverUpdatedAt: serverUpdatedAt,
            serverMarkdown: serverMarkdown, document: document)
    }

    /// Move a local document onto the id the server just gave it, then hand its content to
    /// the ordinary replay.
    ///
    /// Order is the safety property. The record is removed **last**, because it is what keeps
    /// the holds in force: dropping it first and dying would leave a draft under a dead local
    /// id that the very next sync pass GETs, 404s, and deletes.
    private func migrateCreatedDocument(
        _ record: PendingDocumentCreate, serverID: UUID, serverTitle: String?, serverUpdatedAt: Date,
        serverMarkdown: String, document: Document?
    ) {
        let localID = record.localID
        let draft = draftStore.draft(for: localID)
        // The partially-migrated draft: a previous attempt died **after** removing the local
        // draft and before removing the record. (Not the window between the two draft writes —
        // there both drafts exist, `body` stops at the local one, and the server-id guard above
        // defers the migration entirely rather than reaching here.) Without this fallback a
        // resume reads an already-removed local draft as empty and overwrites good content
        // with "".
        let migrated = draftStore.draft(for: serverID)
        // First **non-nil**, not first non-empty — and that distinction is load-bearing if a
        // second draft remover is ever added. `carriedPush` below keys off
        // `draft == nil && queued[localID] == nil`, which concedes that `draft == nil` with
        // `queued` populated is representable; in that shape a present-but-*empty* `queued`
        // would win over a non-empty `migrated`, set `willAdoptServer`, and delete the migrated
        // body. `finishMigration`'s both-drafts guard does *not* cover it, since it keys on
        // draft presence rather than on `queued`.
        //
        // Unreachable today — but not for the reason it is tempting to give. There *is* a
        // remover that leaves `queued` populated, and it is already wired in production:
        // `discardStoredDraft`, from `EditorViewModel.reconcileDraft`. What makes it
        // unreachable is narrower: `reconcileDraft` is only ever entered past `apply`'s
        // `pendingSave != nil` divert, so `queued` is provably nil there — and, now that the
        // create UI does open editors on local ids, `revalidate` and `refresh` both guard on
        // `!isLocalDocument`, which makes `reconcileDraft` unreachable for one. The site to
        // watch is a change to either of those two guards.
        let body = queued[localID]?.markdown ?? draft?.markdown ?? migrated?.markdown ?? ""
        // **The title is a merge, not a race.** The body's "newest wins" rule does not carry
        // over: on a resume the document has been an ordinary Home row under its server id for
        // the whole deferral, so a rename made there is newer than anything the local draft
        // holds — while a local rename made after the POST is newer than the server's. The
        // discriminator below is which side moved *since the server learned the name*.
        //
        // What this does not attempt: if **both** sides renamed, local wins and the remote one
        // is lost. That is the accepted residual — scope is only the title, the body is
        // protected by the conflict below, and `draftTitleOutcome` (which does escalate a
        // two-sided rename to a conflict) is not reachable here, since the migration owns the
        // draft outright at this point.
        let localTitle = queued[localID]?.title ?? draft?.title ?? migrated?.title
        // Compared against **what the POST sent**, not the mint title. A rename made before
        // the POST is already the server's name, so treating it as a local rename would push
        // it back over a newer one made under the server id — the same loss this
        // discriminator exists to prevent, one step over. On the fresh-POST path it is already
        // stamped and equals what the draft holds, so the `else` arm takes `serverTitle` —
        // the same value, since the POST just set it. Nil only for records written before the
        // field existed, where the mint title is the right fallback.
        let knownToServer = record.postedTitle ?? record.title
        let title: String
        if let localTitle, localTitle != knownToServer {
            title = localTitle  // renamed since the server learned the name, so the newer one
        } else {
            title = serverTitle ?? localTitle ?? record.title
        }

        // **The baseline says what this body descends from — and on the conflict path that is
        // not what we just observed.** Stamping one is mandatory either way: a baseline-less
        // draft routes to `draftSyncDecision` rule 3's 120 s clock tolerance, and a document
        // created hours ago offline is far outside it, so the replay would answer
        // `.discardServerWins` and the launch pass would delete the body.
        //
        // But the two paths descend from different things, and stamping the observed state on
        // both is self-defeating. When the server has moved to a body we have never seen, ours
        // descends from the **empty document this device created**, not from theirs. Claiming
        // otherwise hands `draftSyncBodyDecision` rule 2 a proof — `serverUpdatedAt <=
        // baselineDate` is trivially true of the state it was copied from — so the very next
        // revalidation answers `.push(.descendsFromBaseline)`, `releaseConflictIfProven` clears
        // the conflict this function is about to record, and `releaseHeldSave` starts the held
        // save: a silent full overwrite of the co-author's body, by way of the conflict meant
        // to prevent it. That is also the baseline advance `resolveConflictKeepingLocal`
        // performs as the user's *answer*; doing it here answers the question destructively
        // before asking it.
        //
        // So: `nil` clock and `""` body when diverged — both honest, and together they reach
        // rule 2's `.conflict` while staying non-nil, so rule 3 can never discard. (One
        // reachable exception, benign: if the co-author *empties* the document before the user
        // answers, rule 2's body tiebreak matches `"" == ""` and releases. The pill vanishes
        // unanswered and their deletion is undone — but the server held nothing, so no content
        // is destroyed.) **And the baseline is not the only proof that must be withheld** —
        // rule 1 is consulted first; see the push-evidence clear below.
        // `serverTitle` rides along on both paths; with a nil clock `draftTitleOutcome`
        // reaches `serverTitle == baselineTitle` and keeps the draft's.
        //
        // **Both emptiness tests are canonical, matching the inequality below.** A raw
        // `isEmpty` disagrees with `canonicalMarkdown` on whitespace: `"\n"` is raw-non-empty
        // and canonically empty. Raw, a server body of `"\n"` records a conflict that the
        // next evaluation immediately releases (rule 2's body tiebreak matches `"" == ""`),
        // and a *local* body of `" "` skips the adopt branch below and arms a "Keep my
        // version" that PATCHes whitespace over the co-author — the exact wipe that branch
        // exists to prevent.
        let canonicalBody = canonicalMarkdown(body)
        let canonicalServer = canonicalMarkdown(serverMarkdown)
        // The `!canonicalServer.isEmpty` conjunct has an arm worth naming, since its mirror
        // image is spelled out above: a co-author who *empties* the document does not count as
        // diverged, so the offline body is pushed over their deletion without asking. That is
        // the same accepted trade — an emptied server holds nothing, so there is nothing to
        // lose by writing, whereas treating it as a divergence would raise a conflict against
        // a document with no content in it.
        // Note this is a rule-0 (body equality) test, not `draftSyncBodyDecision`. It can
        // therefore disagree with rule 1: the diverged arm clears
        // `lastConfirmedPushMarkdown[serverID]` precisely so rule 1 cannot release the conflict
        // it records, yet it still carries `carriedPush` onto the same draft — so if the server
        // happens to hold exactly that body, the very next evaluation releases on
        // `.serverHoldsOurLastPush`. That release is *correct* (we were the last writer), and
        // no content is at risk either way; the cost is a pill that can appear and then vanish
        // on its own. Consulting rule 1 here would remove the disagreement, at the price of
        // giving this branch a second decision procedure to keep in step.
        let diverged = !canonicalServer.isEmpty && canonicalServer != canonicalBody
        let baseline =
            diverged
            ? DraftBaseline(serverUpdatedAt: nil, markdown: "", title: serverTitle)
            : DraftBaseline(serverUpdatedAt: serverUpdatedAt, markdown: serverMarkdown, title: serverTitle)

        // **Write the content under the new id before taking it off the old one.** These are
        // synchronous, and in the window between them the body is on disk **twice** — which is
        // the point. The reverse order is what would leave a death with the draft removed,
        // the replacement unwritten, and the server holding the empty document this POST just created. The
        // final `enqueue` rewrites this same draft; the point is that no instant exists where
        // the content is on disk nowhere.
        // Carry the partially-migrated draft's push evidence forward **when the body came from
        // it**. That body is not the offline one — it is whatever a previous attempt already
        // wrote under the server id — so the diverged path's "the local body provably does not
        // descend from that push" is false of it, and dropping the stamp would raise a conflict
        // no evidence can ever release against the user's own earlier write.
        //
        // The condition is `draft == nil && queued[localID] == nil` — **both conjuncts**, and
        // the `queued` one is not decoration. It exactly characterises "the body came from
        // `migrated`", because `queued[localID]` *outranks* `migrated` in the body chain
        // above: drop it and the stamp rides along with a body that came from the offline
        // draft instead, which is precisely the false rule-1 evidence this is meant to avoid —
        // `releaseConflictIfProven` could then discharge the conflict the diverged arm just
        // recorded and let the held save full-overwrite the co-author. The both-drafts guard
        // does **not** rule that shape out; it keys on draft presence, not on `queued`. This
        // conjunct is the only thing that does.
        let carriedPush = (draft == nil && queued[localID] == nil) ? migrated?.lastPushedMarkdown : nil
        // **Load-bearing and unstated until now:** this rebuild carries no
        // `conflictServerUpdatedAt`, so it *erases* a stamp `init` rehydrated from disk while
        // `conflicts[serverID]` is still set in memory. Every exit below repairs it — diverged
        // re-persists via `recordConflict`, undiverged via `enqueue`'s own stamp write, adopt
        // removes the draft and the record together — so the mirror never splits today. Any
        // early return inserted between here and those exits would silently drop a persisted
        // conflict hold.
        // No test can observe this write. Deleting it leaves the whole replay suite green,
        // because every assertion that reads the server-id draft is satisfied by a later
        // write — the terminal `enqueue`, or the adopt branch's removal. That is not a
        // coverage gap to be papered over with a contrived test: the write exists so that no
        // *instant* has the body on disk nowhere, and an in-process test cannot sample an
        // instant between two synchronous statements. What it guards against is a process
        // death here, which is exactly what the suite cannot stage.
        draftStore.save(
            PendingDraft(
                documentID: serverID, title: title, markdown: body, updatedAt: Date(),
                baseline: baseline, lastPushedMarkdown: carriedPush))
        draftStore.remove(documentID: localID)
        // Every per-document map the coordinator keys by id. `queued` matters most: it holds
        // a copy of the user's newest keystrokes. (Hygiene rather than a rescue: for a pending
        // create it always agrees with the draft, since `enqueue` write-ahead-saves from the
        // same `save` it parks and no save is ever in flight to make them diverge — the body
        // chain would find it in the draft either way.) Leaving it behind would strand it under an id
        // nothing will ever push.
        states[localID] = nil
        queued[localID] = nil
        settledSaves[localID] = nil
        lastConfirmedPushMarkdown[localID] = nil
        knownServerTitles[localID] = nil
        // Note this *removes* the entry when the resume's fetch omitted a title — assigning
        // nil to a dictionary key is a delete, not a no-op. That is deliberate rather than
        // sloppy: this is `adoptQueuedTitleIfUnseen`'s backstop, and "the server's title is
        // unknown" is the honest state after a fetch that did not carry one. It must not be
        // changed to a conditional write without checking that caller first.
        knownServerTitles[serverID] = serverTitle
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
        // Historical: the editor/drawer used to persist a synthetic row into the parent's
        // cached level, and no longer do (that carve-out leaked a local sub-page into the next
        // account). Kept because a cache written by an older build still holds one, and
        // because `insertIntoListCaches` appends the *real* child below, and its
        // de-dupe is by id — a different id — so without this the level holds both: two rows
        // in Subpages and the Pages drawer, one of which reports "no longer available" for a
        // document that has just synced. Same API `handleDidDelete` uses for the same ghost.
        childrenCache.removeDocument(localID)

        // **This paragraph is about the `insertIntoListCaches` call further down**, not the
        // statements immediately below it — the adopt branch's draft removal sits in between.
        //
        // Put it under its real id before the record disappears. Note what this does and does
        // not buy: it feeds the *next* Home construction and the work-offline read, which are
        // the only two places `HomeViewModel` re-seeds from the cache. An online `load()`
        // reads it for a Bool and then overwrites from the network, and the reconnect edge
        // calls `syncPendingDrafts()` without `load()` — so a **live** Home is not repopulated
        // here by the *cache* write alone. The read-time merge plus `pendingCreatesVersion`
        // covers it directly instead — a migrated row leaves a live Home at once. Absent when the
        // resume's cosmetic fetch failed — the document simply waits for the next list fetch.
        // **Take the server-id draft off before the record goes**, when the adopt branch below
        // will fire. Removing the record first and dying leaves an unprotected draft holding a
        // canonically empty body and a `(nil, "")` baseline — `runSyncPass` picks it up, rule 2
        // answers `.conflict`, and "Keep my version" PATCHes `""` over the co-author: verbatim
        // the wipe that branch refuses. This order is idempotent instead — record still
        // checkpointed, both drafts gone, so the next resume re-derives `body = ""` and
        // re-enters the same branch.
        let willAdoptServer = canonicalBody.isEmpty && !canonicalServer.isEmpty
        if willAdoptServer { draftStore.remove(documentID: serverID) }
        if let document { insertIntoListCaches(document, parentID: record.parentID) }

        // **Re-key the sub-pages created under this document before the record goes.** They
        // carry its *local* id in their own `parentID` — an id the server has never seen —
        // and `runCreatePass`'s dependency gate is what has kept them unsent. Pointing them
        // at the real id is what opens that gate, and because the pass re-reads every record
        // from the mirror, a parent and its sub-pages replay in the same pass.
        //
        // **Before `removePendingCreate`, and that ordering is the whole safety argument.**
        // The record and its children live in one blob under one UserDefaults key, so these
        // are two successive whole-store writes and a crash lands on one of exactly three
        // states: nothing written (the record still gates the children, and the next pass
        // redoes the migration); rewritten but the record still present (the gate opens, and
        // `POST documents/{serverID}/children/` is valid because the checkpoint proves that
        // document exists); or both (the ordinary end state). The reverse order adds a fourth
        // — record gone while a child still names the dead local id — in which nothing gates
        // the child any more: it POSTs `documents/{local-uuid}/children/`, 404s, probes the
        // parent, 404s again, and is silently re-rooted. That is the one outcome the gate
        // exists to prevent, so it must not be reachable through a kill either.
        //
        // Snapshot first rather than iterating `pendingCreates.values` live, since
        // `updatePendingCreate` writes back into the dictionary being read.
        //
        // Deliberately **not** scoped to replayable records, matching `isPendingCreate`:
        // a child nothing here may send still must not be left naming an id that no longer
        // exists, or it becomes the re-root above the moment anything does send it.
        for var child in pendingCreates.values.filter({ $0.parentID == localID }) {
            child.parentID = serverID
            updatePendingCreate(child)
        }

        removePendingCreate(documentID: localID)
        // **Fire on every exit from here, and only at exit.** `defer` rather than a call site,
        // for both halves of that. Placed after `removePendingCreate` because dropping the
        // record is what withholds the local row and so what obliges a refetch; deferred
        // because two paths leave before the end — the adopt branch returns early, and a
        // resume whose cosmetic fetch failed carries no document — and pinning the call to
        // the last statement silently skipped both, reproducing the vanishing row this
        // exists to prevent. Exit-time is also the only safe point: mid-function a diverged
        // resume has its draft on disk, its state `.idle` and no conflict recorded yet, so a
        // synchronous handler that enqueued there would full-overwrite the co-author.
        //
        // `document` is nil when that cosmetic fetch failed: there is no real row to hand
        // over, but the refetch is still owed, so the callback fires with nil rather than not
        // at all.
        defer { onDocumentMigrated?(document) }

        // **If the server already holds a body, ask — do not push over it.** Reachable only
        // on a resume: between the checkpoint and here the document has been live on the web,
        // and "checkpointed but not migrated" is a state to design for (previously crash-only), so a co-author (or the same
        // user on another client) can have written to it. The enqueue below goes straight to
        // `start` — the record is gone, so nothing holds it — which would silently
        // full-overwrite that body. Recording a conflict first engages the ordinary
        // enqueue-hold and the pill, so the user chooses. `serverMarkdown` is `""` on the
        // fresh-POST path and on the overwhelmingly common resume, so this is inert there.
        //
        // Compared canonically, because the local body has been through the parser and the
        // server's has not — a formatting-only difference is not a conflict.
        // **An empty local body is never worth a conflict.** If we have nothing and the server
        // has something, the local side has nothing to contribute, and arming the pill would
        // offer a "Keep my version" that PATCHes `""` — wiping the document outright. Adopt
        // the server instead: drop the draft written above and enqueue nothing, leaving an
        // ordinary, fully in-sync document.
        //
        // **The test is emptiness — canonical emptiness — not absence, and must not be
        // "tightened" into a nil check.** Two different states reach it. The sources can all
        // be *absent*, so the chain falls
        // through to `""` (a death inside the partial-migration window plus an intervening
        // `runSyncPass` that pushes and removes the server-id draft). Or — the ordinary case —
        // a source is **present and empty**: `createLocalDocument` writes a seed draft with
        // `markdown: ""`, and a rename before the replay fills `queued[localID]` with an empty
        // body too, so a document created, renamed and never typed into arrives here with the
        // first source populated. An absence test would let exactly that document fall through
        // to `enqueue`, arming the very "Keep my version" wipe this branch exists to prevent.
        // (Precisely: the conflict check below would fire and the enqueue would take the
        // hold, so nothing is PATCHed unasked — the damage is that the user is offered a
        // destructive choice against a document they have no local version of.)
        if willAdoptServer {
            // **Release any conflict on the way out.** This branch deletes every trace of local
            // work for `serverID`, so a record rehydrated by `init` from a persisted
            // `conflictServerUpdatedAt` is now moot — and the lifecycle invariant is that a
            // record outliving the work it protects parks every future save for that document.
            // Narrow to reach (it needs a server-id draft carrying a stamp and an empty body),
            // but the invariant is stated absolutely, so this discharges it rather than
            // claiming an exemption.
            clearResolvedConflict(documentID: serverID)
            // And reset the state, exactly as `resolveConflictKeepingServer` does for this same
            // "the local side is gone" transition. Left at `.failed` — reachable when a save
            // under the server id was rejected on the merits *and* left a canonically empty
            // body, in the partial-migration window where the local draft is already gone
            // (with it present the both-drafts guard defers before reaching here) — the
            // editing surface keeps a live **retry** button whose `saveNow` enqueues the
            // *server's own* re-fetched body with `baseline: nil`, a full overwrite re-encoded
            // through `MarkdownYjs`: precisely the flattening this branch refuses to perform.
            states[serverID] = .idle
            // **The title is adopted with the body — the local one is not written back.** Two
            // earlier attempts here were both wrong and are worth recording. Pushing the
            // server's markdown back to carry our title re-encodes it through `MarkdownYjs`,
            // where a co-author's table is an `.unknown` block that round-trips as literal
            // paragraphs — flattening their document to carry our name. A title-only PATCH
            // avoids that, and since `postedTitle` landed the evidence objection no longer
            // holds: `localTitle != knownToServer` *does* prove the local side moved after the
            // server learned the name. What remains is a scope trade, and it is the reason this
            // branch still writes nothing. Sending a title here means an unowned `Task` outside
            // every piece of ordering bookkeeping the coordinator maintains — `knownServerTitles`,
            // `settledSaves`, the list-cache row written moments earlier — which is what made the
            // first attempt at it a defect rather than a feature. The residual is therefore
            // sharper than it was: a rename this code **can** show is newer is still dropped,
            // for a document whose body it is adopting wholesale. Recorded as owed: an affordance that can present the choice rather than guessing at it.
            return
        }
        if diverged {
            // **Clear the push evidence for the same reason as the baseline, or rule 1 arms
            // the identical release one rule earlier.** `enqueue` stamps the draft's
            // `lastPushedMarkdown` from `lastConfirmedPushMarkdown[serverID]`, and that map
            // can hold the very body we just recorded a conflict against: a checkpointed
            // document is met under its server id, so the user can have opened it, typed, and
            // had that save land — `finish` records it — before this migration runs. Rule 1
            // (`serverHoldsOurLastPush`) is consulted *before* rule 2, so an honest baseline
            // is never even reached; `releaseConflictIfProven` clears the conflict and the
            // held save overwrites them. The local body provably does not descend from that
            // push, so the evidence is as false as the baseline would have been. (The draft
            // written above usually carries none. Not sufficient alone: `enqueue` falls back to
            // the draft's own stamp, which the partial-migration path deliberately carries
            // forward — see `carriedPush`, honest exactly where it fires, since the body came
            // from that draft and so does descend from its push.)
            lastConfirmedPushMarkdown[serverID] = nil
            recordConflict(documentID: serverID, serverUpdatedAt: serverUpdatedAt)
        }

        // **Release a conflict this migration has *proved* moot — equality only.** Nothing above
        // clears it — `recordConflict` only fires on the diverged arm and `clearResolvedConflict`
        // only on the adopt one — so a stamp persisted by an earlier session would park the
        // enqueue below, `runSyncPass` would then skip the document on that same record, and it
        // would self-perpetuate until the user happened to open the editor (where
        // `releaseConflictIfProven` clears it on rule 0). The lifecycle invariant is stated
        // absolutely: a record is meaningful only while local work would overwrite the observed
        // server body, and here we have just observed a server that either equals our body or
        // holds nothing — so there is nothing left for it to protect.
        //
        // Safe precisely because `finishMigration` proved `queued[serverID] == nil` before this
        // ran: `clearResolvedConflict` → `releaseHeldSave` therefore has no parked save to
        // start, and this is a pure clear plus the draft-stamp rewrite the enqueue below
        // redoes anyway.
        //
        // **Non-empty equality, not `!diverged`.** `!diverged` is two arms and only one of
        // them proves anything — and the emptiness check is part of that arm, not a leftover
        // from the other. `willAdoptServer` above requires `!canonicalServer.isEmpty`, so a
        // *both*-canonically-empty state falls through to here, where `"" == ""` would release
        // on exactly the `formatted.content ?? ""` fallback the next paragraph calls
        // insufficient evidence — and then push an empty body unheld, which is more
        // destructive than the arm this condition was narrowed to exclude. Nobody made
        // anything match there; the fallback did.
        //
        // On a *non-empty* `canonicalServer == canonicalBody` a conflict is moot by
        // construction:
        // it was recorded because local and server differed, so equality now means someone
        // made the server match us, and the enqueue below is a content no-op. The other arm —
        // an *empty* server with a non-empty body — proves nothing of the sort, and releasing
        // there would discharge a pill the user has already been shown and then immediately
        // full-overwrite: `serverMarkdown` is `formatted.content ?? ""`, so a response that
        // simply carried no body reads as "the server is empty", and nothing here compares the
        // observed `updated_at` against the stamp the conflict was recorded with. The
        // empty-server carve-out in `diverged` is an accepted trade for *detection*; extending
        // it to discharging a persisted hold and starting a destructive write is a strictly
        // stronger claim, and one this branch cannot make.
        //
        // **But be honest about what keeping it buys: a delay, not a decision.** The
        // empty-server arm is undiverged, so the baseline stamped above is the undiverged one
        // — `serverUpdatedAt: <observed>` — and the next revalidation hands
        // `draftSyncBodyDecision` rule 2 a proof that is trivially true of the state it was
        // copied from, answering `.push(.descendsFromBaseline)`; `releaseConflictIfProven`
        // then clears the record and the held save goes. No baseline fixes that: a
        // `(nil, "")` one, as the diverged path uses, meets rule 2's body tiebreak against an
        // empty server and releases too. So the hold survives this pass and not much longer.
        // It is still worth keeping — this branch has no business spending evidence it does
        // not have, and the release it declines to make is the one that would push
        // *immediately*, unheld, from inside a background pass with no screen open.
        if !canonicalServer.isEmpty, canonicalServer == canonicalBody {
            clearResolvedConflict(documentID: serverID)
        }

        // Undiverged, this is an ordinary document with an ordinary queued edit: rule 2 sees a
        // server no newer than the baseline we just stamped and answers `.push`. Diverged, the
        // baseline deliberately proves nothing, so the same enqueue is parked by the hold the
        // `recordConflict` above just engaged, and every later re-evaluation reaches
        // `.conflict` again rather than releasing it.
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
        guard let docsError = error as? DocsAPIError else {
            // Not one of ours (a `CancellationError`, anything a future networking change lets
            // escape). Classify it rather than returning silently, which would be the one exit
            // from this function that leaves the record POSTing on every trigger with nothing
            // recorded. In-memory `.failed`, so a relaunch still retries once.
            markCreateRejected(record)
            return
        }
        if retryableSaveFailure(docsError) || docsError == .sessionExpired {
            // Transport, 5xx, rate limit — or a re-login the shared client has already
            // raised. Leave everything; the next trigger retries.
            return
        }
        // **A missing *route* is a fact about the server, not about this document — root or
        // sub-page.** Retry rather than parking, the same reading the resume path gives it.
        // Scoping this to roots was an asymmetry with real cost: a proxy swallowing
        // `documents/{p}/children/` for the length of a deploy would park every offline
        // sub-page for the session, while an identically-affected root create recovered on the
        // next trigger — and the probe below cannot speak to it either, since it tests
        // `documents/{p}/`, a different path.
        if docsError == .routeNotFound { return }
        if let parentID = record.parentID, docsError == .forbidden || docsError == .notFound {
            // Maybe we may not create children under that parent — but a 403 on a POST is
            // **not** only that. Django answers a bad `Origin` with `403 CSRF Failed`, which
            // flattens to `.forbidden` here, and that is the documented symptom of the
            // capitalised-host bug: every sub-page create would be silently promoted to a
            // root, irreversibly. So ask about the parent, and let the answer decide.
            //
            // Note what is deliberately *not* consulted: `parent.abilities.childrenCreate`.
            // `Document` decodes it `decodeIfPresent(...) ?? false`, so an `abilities` object
            // that merely **omits** the key is indistinguishable from one denying it — and this
            // would be the app's first and only read of that field, on a route whose serializer
            // it has never depended on (the repo has already been bitten by exactly that
            // variance with `is_favorite`). A reachable parent means the create was rejected on
            // its own merits whatever the abilities dict says, and that is the same outcome
            // either way, so reading it would buy a distinction the code does not act on.
            do {
                _ = try await client.document(documentID: parentID)
            } catch let probe as DocsAPIError where probe == .notFound {
                // The parent is **gone** — the one answer that justifies re-parenting, which is
                // irreversible (the old parent is stored nowhere, and there is no move
                // feature). Never a bare 403: an ancestor-access recompute 403s transiently and
                // would 403 the create too, so the pair is one transient seen twice, not
                // corroboration. Same rule the resume path states for the same evidence.
                //
                // Retry as a **root** rather than stranding the content: placement is
                // recoverable by the user, a lost body is not.
                guard pendingCreates[record.localID] != nil else { return }
                var promoted = record
                promoted.parentID = nil
                updatePendingCreate(promoted)
                return
            } catch let probe as DocsAPIError where probe == .forbidden {
                // The server answered, just not dispositively. The create error is
                // non-retryable, so it still owes a terminal state — exactly what a root create
                // gets for the same error. Without this the record pays a POST plus a probe on
                // every reconnect, foreground and launch, forever, while the caption reads
                // "syncs when online".
                markCreateRejected(record)
                return
            } catch {
                // The probe could not answer at all (transport, 5xx). "I couldn't ask" must
                // never read as "it isn't there" — leave the record alone and try next pass.
                return
            }
            // The parent is reachable, so the failure was about the create itself, and it is
            // non-retryable — every retryable class returned above, and `.routeNotFound`, the
            // one error the probe cannot speak to, returned before we got here. Terminal, as
            // the root path treats the same error.
            markCreateRejected(record)
            return
        }
        // A `.decoding` failure is the one rejection where "the POST failed" is provably the
        // wrong inference: it arrives *after* a 2xx, so the server very likely built the document and we
        // merely couldn't read the response — and no checkpoint could be written, because the
        // id was in the body we failed to decode. Left to the in-memory rule below it would
        // POST a fresh document on every launch, forever, abandoning each one. So this
        // rejection is persisted on the record.
        // Note what this does and does not prove: `.decoding` means the response was 2xx and
        // unreadable, not specifically that a document was created — a gateway answering `200`
        // with HTML created nothing. Blocking is still the right default (a duplicate is
        // unrecoverable, a delayed retry is not), which is exactly why the stamp is scoped to
        // this build rather than permanent.
        if case .decoding = docsError {
            guard var blocked = pendingCreates[record.localID] else { return }
            blocked.replayBlockedAt = Date()
            blocked.replayBlockedBuild = appBuild
            updatePendingCreate(blocked)
        }
        markCreateRejected(record)
    }

    /// The terminal state for a create the server rejected on the merits.
    ///
    /// In-memory on purpose: `runCreatePass` skips `.failed`, which stops the retry-per-trigger
    /// loop, while `init` re-seeds every record to `.pendingSync` so a relaunch tries once
    /// more. That is the right trade for a validation 400 — nothing was created, so the retry
    /// is free. The one rejection it is *wrong* for is handled by `replayBlockedAt`.
    ///
    /// Note this is **not** the reading surface's "tap to retry", despite reusing the state:
    /// `saveNow` early-returns while `pendingSave` is non-nil, and a local document the user
    /// has typed into always has its content parked in `queued`. So for those the tap is a
    /// no-op and a relaunch is the only escape. Giving the create pass its own retry
    /// affordance belongs with the UI that can present it.
    private func markCreateRejected(_ record: PendingDocumentCreate) {
        // Re-read: this runs after the POST await, and a delete during it has already removed
        // the record and reset the state. Writing here would leave a `.failed` entry keyed to
        // an id nothing owns.
        guard pendingCreates[record.localID] != nil else { return }
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
    /// Called by `LiveEditingBridge`'s snapshot debounce (C2c wired what C2b built).
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
        // A local document's *displayed* title comes from its draft (`pendingLocalDocuments`
        // overlays it, so a rename shows in lists before the replay lands), and this is the
        // write that changes it. Without the bump, `HomeViewModel`'s memo — keyed on the
        // record version — would keep serving the creation title until an unrelated create or
        // delete happened to move it.
        if isPendingCreate(documentID: documentID) { pendingCreatesVersion += 1 }
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
            // Creates first, inside the same pass. Note what that ordering does and does not
            // buy: a *successful* migration ends in an `enqueue` that `runSyncPass` then skips
            // — undiverged it went straight to `start` and set `inFlight`; diverged it is
            // parked in `queued` behind the conflict hold; and the adopt branch returns before
            // enqueueing at all. Either way the pass is not the one pushing it. What the
            // ordering serves is a migration the server-id guards
            // **deferred**: `runSyncPass` clears the draft standing in its way, so the next
            // trigger can complete it. Both inherit this funnel's
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
                        // The loop's *other* deleting line. Its local-id half is covered by the
                        // `isPendingCreate` guard before the fetch, but the server-id half is
                        // not — so state the same invariant here rather than relying on a
                        // caller, exactly as the 404/403 branch does. Unreachable today
                        // (`.discardServerWins` is rule 3, which needs a nil baseline, and every
                        // writer of a draft under a freshly-minted server id stamps one), but a
                        // hand-built baseline-less draft is what that shape naturally looks
                        // like, which is how it would become reachable.
                        guard !createStoreUnreadable else { continue }
                        guard checkpointedRecord(forServerID: draft.documentID) == nil else { continue }
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
                // **And never the server-id half of a checkpointed record.** `isPendingCreate`
                // is keyed on the *local* id, so it does not cover the draft the migration
                // writes under `serverID` before removing the local one — and in that window
                // that draft is the **only copy** of the body. The `.notFound` start-over
                // rescues it by moving it back; `.forbidden` has no such branch and would land
                // here, as would any pass where the record is simply not replayable this
                // session — a foreign origin, another account, an unknown owner, a failing
                // `/users/me/`, or an open editor — since `runCreatePass` skips those before
                // the take-back can run. (Not a build-scoped block or a `.failed` state:
                // neither can coexist with a checkpoint, since `replayCreate` clears both
                // stamps in the same write that sets it and `markCreateRejected` only ever
                // fires pre-checkpoint.) Deleting it makes
                // the later migration find an all-nil body chain and build an *empty* document
                // in place of the user's text — the same loss the take-back exists to prevent,
                // reached one error over. Only the **delete** is withheld: the push path above
                // must keep running, since it is what clears `finishMigration`'s both-drafts
                // guard.
                guard checkpointedRecord(forServerID: draft.documentID) == nil else { continue }
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
    /// a question that no longer has anything to ask about. The detection sites call this
    /// only on a non-`.conflict` decision, so they cannot discard a live one. Two create-replay sites
    /// discard deliberately: the adopt-the-server branch, which has just removed every local
    /// trace for that id, and the start-over, whose id the server has just 404'd. In both the
    /// rehydrated record is moot by construction.
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
    /// The create migration is a third recording site, and it holds by an explicit check
    /// rather than by an argument about the id. "Nothing has ever addressed that id" is
    /// **not** true and must not be relied on: it only records on the **resume** path — the
    /// fresh-POST path is guarded by `!canonicalServer.isEmpty` and `""` is proven there — so
    /// the id may have been minted by a *previous* process, come back in an ordinary list
    /// fetch since, and be carrying a save this process started. What actually holds the
    /// invariant is `finishMigration`'s `guard inFlight[serverID] == nil, queued[serverID] ==
    /// nil`, followed by `recordConflict` with no await in between. **Do not delete that
    /// guard on the strength of the id being freshly learned.** (`finish`'s deferred
    /// re-decision is a fourth site, and holds because it runs from the settling save itself.)
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
                    //
                    // A `""` baseline body no longer implies fabrication, though: the create
                    // migration's diverged path stamps one deliberately (with a nil clock).
                    // Carrying it forward here inherits the same tiebreak — so if a co-author
                    // later empties the document, this pushes instead of re-conflicting.
                    // Narrow, and "keep mine" is the answer the user already gave, so the
                    // push is what they asked for; noted because the reasoning above assumes
                    // a `""` body can only have been invented.
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
        // A locally-created document's record must go with its draft, or the create replay
        // would resurrect a document the user threw away.
        //
        // **A checkpointed record breaks that in both directions, and each needs its own
        // answer.** Once `syncedServerID` is set the POST has landed and a real server object
        // exists, while `isPendingCreate` is still true (the migration only clears it at
        // `removePendingCreate`) — and `pendingLocalDocuments` withholds the local row, so the
        // user meets the document under its **server** id.
        //
        //  - Deleted by its *local* id: the local traces must go either way, but the caller
        //    owes the server `DELETE` too, or the document survives and reappears in Home with
        //    nothing on the device that knows about it. `OptionsViewModel.delete()` does that
        //    half via `syncedServerID(forLocalID:)` — treating a 404 there as "already gone"
        //    rather than as a failure, since keeping the record would let the resume re-POST
        //    the document the user just deleted.
        //  - Deleted by its *server* id — reachable through the Options
        //    sheet, since that is the only id the user is offered. `isPendingCreate` is keyed
        //    on the local id and answers false, so without the branch below the record and the
        //    local draft both survive a successful DELETE. The next pass resumes, the resume
        //    GET 404s, `.notFound` clears the checkpoint, and the pass after that **re-POSTs
        //    the document from that draft** — the deleted document comes back, first as a
        //    local row and then as a new server document with the old body. The 404 there is
        //    indistinguishable from a co-author's delete, which is exactly why the record has
        //    to be cleared here, where the intent is still known.
        //
        // Its `.pendingSync` goes with it:
        // nothing is on the device to sync any more, and unlike a server document there is
        // no `finish` coming to reset it (the hold means no save was ever started).
        //
        // Scoped to that case deliberately. Resetting unconditionally *looks* tidier and
        // silently broke `testSaveLandingAfterADeleteNeverRecreatesTheCacheEntry`, which
        // synchronizes on `state != .saving` to wait out an in-flight PATCH: with the state
        // cleared synchronously the wait returned instantly and the assertions ran while
        // the save was still on the wire. The test stayed green while no longer pinning
        // invariant 0b at all. A server document's state stays `finish`'s to settle.
        //
        // **And what was filed inside it goes too.** Sub-pages created on this device under a
        // local document are its subtree, exactly as they would be on the server; leaving them
        // is not the conservative option, since an orphaned record is listed by nothing yet
        // still holds a whole document body. `discardLocalSubtree` is where that happens, and
        // where the one document it refuses to take — a sub-page whose editor is open — is
        // re-parented out of the subtree instead.
        if isPendingCreate(documentID: documentID) {
            discardLocalSubtree(rootedAt: documentID)
            states[documentID] = .idle
        } else if let checkpointed = checkpointedRecord(forServerID: documentID) {
            // Clear it under the id it is actually keyed by, and take the local draft with it
            // — that draft is what a later pass would rebuild the document from. The rest
            // mirrors `migrateCreatedDocument`'s id-keyed sweep for the same transition, minus
            // the two it does that are inert here (`conflicts[localID]`, which a client-minted
            // id can never acquire since `recordConflict` needs a *successful* server
            // interaction, and the content cache, which a local document never reaches). Of
            // the four, only `queued` is actually writable — by `enqueue`'s own pending-create
            // hold. `settledSaves` and `lastConfirmedPushMarkdown` need `start`, which the four
            // gates make unreachable for a pending-create id; `knownServerTitles` has a second
            // writer in `noteServerTitle`, but its call sites fire only past
            // `mayPredateLocalSave` on a *successful* fetch, which a client-minted id can never
            // get. Cleared anyway so the asymmetry cannot become load-bearing once the create
            // UI lands.
            // **Not while a screen is writing under the local id.** Every other record remover
            // defers to an open editor (`runCreatePass`, `finishMigration`); this one did not,
            // and it is the only one that also deletes the local draft. Reachable without a
            // process death: an editor reopened *during* the POST leaves the record
            // checkpointed-but-unmigrated, so Home shows the server document — empty, since
            // the body is enqueued only at migration — and deleting that stray as a duplicate
            // took the live editor's only copy with it. The screen kept rendering a body that
            // no longer existed on disk, and the next launch's sweep removed what its flush
            // rewrote.
            //
            // Clear only the checkpoint instead. The record starts over, so the document the
            // user actually has open re-POSTs as a fresh create carrying its body — which is
            // what they meant by deleting an empty stray, not "throw away what I am typing".
            if hasOpenEditor(documentID: checkpointed.localID) {
                var restarted = checkpointed
                restarted.syncedServerID = nil
                restarted.postedTitle = nil
                updatePendingCreate(restarted)
                // Deliberately an `if`, not an early `return`. The statements after this
                // branch are about the document being **deleted** — the server id — not about
                // the record, and returning cancelled them: the `serverID` draft survived, and
                // `discardedDuringSave` never learned about an in-flight save, so `finish`
                // took its success path and re-created the content cache entry for a document
                // that had just been DELETEd. That is invariant 0b, reintroduced by a guard
                // scoped to one concern that also swallowed another.
            } else {
                // Keyed on the **local** id, which is what a sub-page names — the record is
                // checkpointed, so the user met and deleted this document under its server id,
                // but nothing filed under it ever learned that id.
                discardLocalSubtree(rootedAt: checkpointed.localID)
                states[checkpointed.localID] = .idle
                draftStore.remove(documentID: checkpointed.localID)
                queued[checkpointed.localID] = nil
                settledSaves[checkpointed.localID] = nil
                lastConfirmedPushMarkdown[checkpointed.localID] = nil
                knownServerTitles[checkpointed.localID] = nil
            }
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
