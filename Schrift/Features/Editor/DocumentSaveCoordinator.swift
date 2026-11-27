import Synchronization
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
        /// Non-nil ⇒ a **live-collaboration full-state Yjs snapshot** to write verbatim via
        /// `client.saveLiveSnapshot` (yhub on Docs 6, the legacy `"websocket": true` PATCH
        /// before it), instead of re-deriving bytes from `markdown` through
        /// `MarkdownYjs.encode`. `markdown` still carries the **projected** markdown (our replica's
        /// render of the snapshot), so every reconcile/baseline/cache rule in
        /// `finish` is byte-for-byte identical between the
        /// two paths — only which network primitive `start` calls differs.
        let liveSnapshot: Data?
        let replicaRequest: ReplicaSaveRequest?

        init(title: String, markdown: String, liveSnapshot: Data? = nil, replicaRequest: ReplicaSaveRequest? = nil) {
            self.title = title
            self.markdown = markdown
            self.liveSnapshot = liveSnapshot
            self.replicaRequest = replicaRequest
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

    /// Backoff schedule for online retries of transiently-failed native replica saves:
    /// `base` doubled per attempt up to `cap`, floored by any server `Retry-After` on 429.
    struct NativeSaveRetryBackoff: Sendable {
        var base: Duration = .seconds(2)
        var cap: Duration = .seconds(60)
        var maxRetryAfter: Duration = .seconds(300)

        func delay(attempt: Int, retryAfter: TimeInterval? = nil) -> Duration {
            let exponential = min(cap, base * (1 << min(max(attempt, 0), 16)))
            guard let retryAfter, retryAfter.isFinite, retryAfter > 0 else { return exponential }
            return max(exponential, min(maxRetryAfter, .seconds(retryAfter)))
        }
    }

    private let client: DocsAPIClient
    private let draftStore: PendingDraftStore
    /// Also carries the durable "native replica owns this document" marker. A
    /// document it names must never be written by the classic or live editor,
    /// even after a successful save removed its draft. The native open route
    /// restores from this same store.
    let replicaStore: ReplicaStore
    let replicaAccessStore: ReplicaAccessStore
    let cleanReplicaByteLimit: Int
    /// The remembered signed-in account, available offline. A raw draft is
    /// rewritten or queued only for its own account; nil fails closed.
    private let signedInUser: SignedInUserStore
    private let contentCache: DocumentContentCacheStore
    private let createStore: PendingDocumentCreateStore
    let pins: DocumentPinCoordinator
    private let deleteStore: PendingDocumentDeleteStore
    /// Photos queued on this device, with their bytes. Mirrored like `pendingCreates` so the
    /// hot predicates never decode UserDefaults.
    private let attachmentStore: PendingAttachmentStore
    private let attachmentCache: AttachmentCacheStore
    /// The list caches the replay has to move a document into once the server owns it.
    /// Without them a just-created document vanishes from Home between the POST landing
    /// (which stops it being listed as local) and the next successful list fetch.
    private let listCache: DocumentCacheStore
    private let childrenCache: DocumentChildrenCacheStore
    let serverConfigStore: ServerConfigStore
    /// The Docs capability proved for this server, written beside `serverConfigStore` so the
    /// launch gate and the save path read one answer rather than two that can drift.
    private let serverCapabilityStore: ServerCapabilityStore
    /// The server this session is signed in to (`siteOrigin`). Create records carry the
    /// origin they were minted against; it decides what may be **listed and sent**, never
    /// what is protected — see `isPendingCreate` vs `isReplayable`.
    private let serverOrigin: String
    /// Scopes `replayBlockedAt` — see `PendingDocumentCreate.isReplayBlocked(forBuild:)`.
    private let appBuild: String
    /// Media-check poll budget for the attachment replay, injectable so tests need no real waits.
    private let mediaCheckMaxAttempts: Int
    private let mediaCheckRetryInterval: Duration
    private let backgroundTasks: BackgroundTaskProvider
    private let isLiveReplicaHeld: @MainActor (UUID) -> Bool
    private let isOnline: @MainActor () -> Bool
    private let nativeSaveRetryBackoff: NativeSaveRetryBackoff
    private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var isForegrounded = true
    @ObservationIgnored private var nativeRetryTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var nativeRetryTokens: [UUID: UUID] = [:]
    @ObservationIgnored private var nativeRetryAttempts: [UUID: Int] = [:]

    private var states: AccountScoped<DocSaveState>
    /// The same log the shared client records into; nil in previews and tests that don't need detail.
    private let diagnostics: APIDiagnosticsLog?
    /// The non-2xx response behind a document's `.failed` state, for the save-failure alert.
    /// Method, path, status and body prefix only — `RequestFailure` carries no credential.
    private var failureDetails: AccountScoped<RequestFailure>
    /// Why a document's save is `.failed` even when no HTTP response says so (a decoding failure,
    /// a refused guard). Set by `markFailed` only, from `safeErrorSummary` or a fixed phrase:
    /// never content, a header, a cookie or a token.
    private var failureReasons: AccountScoped<String>
    /// Failed documents whose "Retry" would do nothing (`saveNow` is a no-op for a rejected create
    /// and for a native capture that froze authoring), so their alert offers Cancel only.
    private var failuresWithoutRetry: AccountScoped<Bool>
    private var inFlight: [UUID: Task<Void, Never>] = [:]
    private var inFlightContent: AccountScoped<PendingSave>
    private var queued: AccountScoped<PendingSave>
    /// Monotonic per-document count of saves that have settled (landed or failed).
    private var settledSaves: [UUID: Int] = [:]
    /// Documents deleted while one of their saves was in flight. That save must not
    /// resurrect any local copy when it lands.
    private final class BackupDirtyIDsBox: Sendable {
        let mutex = Mutex<Set<UUID>>([])
        func replace(_ ids: Set<UUID>) { mutex.withLock { $0 = ids } }
        func contains(_ id: UUID) -> Bool { mutex.withLock { $0.contains(id) } }
        func snapshot() -> Set<UUID> { mutex.withLock { $0 } }
    }

    private var discardedDuringSave: Set<UUID> = []
    /// Thread-safe mirror of document IDs with unsynced coordinator metadata
    /// (pending creates, stored drafts, queued/in-flight saves, conflicts, or
    /// pending attachments) consulted by `ReplicaStore` before setting
    /// `isExcludedFromBackup = true`.
    private let backupDirtyDocumentIDs = BackupDirtyIDsBox()
    private var hasRecoveredDrafts = false
    /// Re-entrancy guard for `syncPendingDrafts()`: it is repeatable (reconnect,
    /// foreground, launch), and overlapping triggers must not double-replay a draft.
    private var isSyncingDrafts = false
    /// A trigger that arrived while a pass was running. Coalesced into another pass
    /// rather than dropped — see `syncPendingDrafts`.
    private var needsAnotherSyncPass = false
    /// Callers that need to know when the current (and any coalesced) sync pass has
    /// finished (`retryClassicDraft` / waiting-edits drain), without changing
    /// `syncPendingDrafts()`'s immediate coalesced return for existing triggers.
    @ObservationIgnored private var syncPassWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Bumped on every `draftStore` mutation so SwiftUI views and `NativeEditorOpen`
    /// observe UserDefaults-backed draft changes live.
    private(set) var draftsVersion = 0
    /// Documents whose queued draft conflicts with the server (the sync path or the
    /// editor detected the server moved on). The push is **held** until the user
    /// resolves it via `resolveConflictKeeping{Local,Server}`.
    private var conflicts: AccountScoped<SyncConflict>
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
    private var lastConfirmedPushMarkdown: AccountScoped<String>
    /// The newest title anything in the app knows the server holds: written by a save that
    /// landed (the server now holds *our* title) and by every editor fetch that postdates our
    /// saves (`noteServerTitle`). Not persisted — it is a this-session-only backstop for one
    /// thing: an **open editor that never refetches on foreground** (it only flushes) while a
    /// background replay adopts a co-author's rename behind it. Its next flush would otherwise
    /// PATCH the pre-rename title back. See `EditorViewModel.adoptQueuedTitleIfUnseen`.
    private var knownServerTitles: AccountScoped<String>
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
    /// Queued photos, mirrored from the store so the hot predicates never decode UserDefaults.
    private var pendingAttachments: [UUID: PendingAttachment] = [:]
    /// Bumped on every mutation, so an `@Observable` consumer (the image leaf's pending/failed
    /// state) re-reads. Same role `pendingCreatesVersion` plays for local documents.
    private(set) var pendingAttachmentsVersion = 0
    /// Callbacks that rewrite an *open editor's* in-memory copy in the same turn the draft is
    /// rewritten. See `commitResolvedAttachment` for why that turn must not be split.
    ///
    /// Keyed by document **and** by a per-registration token, so several editors on one document
    /// (two tabs, iPad split view) each get called. A single slot per document was last-write-
    /// wins: the second screen's registration silently disabled the first, and a pop-then-push
    /// could have the first screen's deferred teardown clear the second's — after which that
    /// editor's next flush would reintroduce a placeholder whose record is gone, which is
    /// precisely the wedge this observer exists to prevent.
    private var attachmentRewriteObservers: [UUID: [UUID: @MainActor (String, String) -> Void]] = [:]
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

    /// Fired when a save that **`runSyncPass` replayed** has landed its content on the server.
    ///
    /// Why this and not a counter bumped by every `finish`: the replay's pushes are
    /// unstructured `start` tasks that usually outlive `syncPendingDrafts()`, so a list that
    /// reloads when the pass returns still reads the pre-push server state and re-caches it
    /// (old titles and order for documents edited offline). Firing on the landing is the
    /// first moment a refetch can see the edit. Scoped to replayed pushes (`replayedPushes`)
    /// so ordinary editor autosaves, which fire on every pause in typing, cause no list churn.
    ///
    /// `@ObservationIgnored` and fired last in `finish`, on the same terms as
    /// `onDocumentMigrated`.
    @ObservationIgnored
    var onReplayedPushLanded: (@MainActor () -> Void)?

    /// Documents whose newest enqueue came from `runSyncPass`'s `.push`. Consumed by `finish`
    /// (success or not, so a stale entry cannot make a later autosave look like a replay).
    private var replayedPushes: Set<UUID> = []

    /// Fired when a queued deletion has actually landed on the server, so a list holding the
    /// row in memory can drop it.
    ///
    /// The caches are purged by `completePendingDelete`, but a list already on screen holds
    /// its own array — and the row does not merely linger there, it **un-strikes**: the
    /// tombstone is gone, so the pending-delete predicate answers false and the row silently
    /// reverts to looking like a live document. That reads as "my deletion was cancelled",
    /// which is the opposite of what happened, and tapping it pushes an editor that 404s.
    ///
    /// **A fan-out, unlike `onDocumentMigrated`**, because four screens hold their own arrays
    /// of the same documents — Home, Shared, Search and the editor's Subpages. A single
    /// closure would let the second subscriber silently overwrite the first, and the row would
    /// go on un-striking everywhere but one list.
    ///
    /// `@ObservationIgnored` and fired last, on the same terms as `onDocumentMigrated`.
    @ObservationIgnored
    private var documentDeletedObservers: [ObjectIdentifier: DocumentDeletedObserver] = [:]

    /// Subscribe to landed deletions.
    ///
    /// The owner is held **weakly** and its entry pruned on the next announcement, because
    /// this coordinator is app-scoped and outlives every screen: a strong closure per
    /// `EditorViewModel` would accumulate one entry for every document ever opened, for the
    /// life of the process. Weak storage also makes `ObjectIdentifier` reuse harmless — a new
    /// object allocated at a dead one's address simply replaces its entry, and a dead entry
    /// can never be called.
    ///
    /// Keyed on identity, so re-registering replaces rather than duplicates.
    func observeDocumentDeleted(_ owner: AnyObject, _ handler: @escaping @MainActor (UUID) -> Void) {
        // Prune here as well as on announce: in a session where no queued deletion ever lands
        // — the common case — announcing never happens, and both `EditorViewModel` and
        // `PagesTreeViewModel` register from `init`, which SwiftUI re-evaluates on every
        // re-creation of the destination closures.
        documentDeletedObservers = documentDeletedObservers.filter { $0.value.owner != nil }
        documentDeletedObservers[ObjectIdentifier(owner)] = DocumentDeletedObserver(
            owner: owner, handler: handler)
    }

    /// Test seam: drive the announcement directly, for subscribers whose own reaction is the
    /// thing under test rather than the pass that triggers it.
    func announceDocumentDeletedForTesting(_ documentID: UUID) {
        announceDocumentDeleted(documentID)
    }

    /// Test seam: that the pruning really prunes, rather than the dictionary growing for the
    /// life of the process.
    var documentDeletedObserverCountForTesting: Int { documentDeletedObservers.count }

    private func announceDocumentDeleted(_ documentID: UUID) {
        // Prune as we go: an observer whose owner is gone is not merely skipped but dropped,
        // so the dictionary tracks live screens rather than every screen there has ever been.
        documentDeletedObservers = documentDeletedObservers.filter { $0.value.owner != nil }
        // Iterate a snapshot: a handler may re-enter this coordinator (the editor's own
        // reaction is `handleDidDelete`, which calls `discardPendingWork`), and one that
        // registered or dropped an observer would otherwise mutate the collection being walked.
        let observers = documentDeletedObservers.values
        for observer in observers { observer.handler(documentID) }
    }

    /// Fired when a move has actually landed, so every screen holding the row can put it where
    /// it now belongs.
    ///
    /// A fan-out on the same terms as the deletion one, and for the same reason: several
    /// screens keep their own arrays of the same documents, and a single closure would let one
    /// subscriber silently overwrite another.
    ///
    /// It carries a `DocumentMoveEvent` rather than a bare id, because unlike a deletion a move
    /// gives some surface a row to *insert* — the new parent's children list, or Home when the
    /// document is promoted. `onDocumentMigrated` carries one for the same reason.
    @ObservationIgnored
    private var documentMovedObservers: [ObjectIdentifier: DocumentMovedObserver] = [:]

    /// Subscribe to landed moves. Owners are held weakly and pruned, exactly as
    /// `observeDocumentDeleted` does and for the same reason.
    func observeDocumentMoved(
        _ owner: AnyObject, _ handler: @escaping @MainActor (DocumentMoveEvent) -> Void
    ) {
        documentMovedObservers = documentMovedObservers.filter { $0.value.owner != nil }
        documentMovedObservers[ObjectIdentifier(owner)] = DocumentMovedObserver(
            owner: owner, handler: handler)
    }

    /// Test seam: drive the announcement directly, for subscribers whose own reaction is the
    /// thing under test rather than the move that triggers it.
    func announceDocumentMovedForTesting(_ event: DocumentMoveEvent) {
        announceDocumentMoved(event)
    }

    /// Test seam: that the pruning really prunes.
    var documentMovedObserverCountForTesting: Int { documentMovedObservers.count }

    private func announceDocumentMoved(_ event: DocumentMoveEvent) {
        documentMovedObservers = documentMovedObservers.filter { $0.value.owner != nil }
        let observers = documentMovedObservers.values
        for observer in observers { observer.handler(event) }
    }
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
    /// Subset of `openEditors` whose screen can write or flush content under this id.
    /// A read-only waiting-classic screen holds `openEditors` (so deletes still defer)
    /// without holding `writableOpenEditors`, so checkpointed-create migration and
    /// attachment cleanup can complete while the waiting screen is open.
    private var writableOpenEditors: [UUID: Int] = [:]
    /// Local documents whose create POST is on the wire right now.
    ///
    /// `replayCreate` copies its record before the await and writes that copy back after, so
    /// any rewrite made in between is lost — and `moveLocalDocument` is the one rewrite a user
    /// can trigger at an arbitrary moment. Refusing the move for the width of the POST keeps
    /// the record and the request that is already acting on it from disagreeing.
    private var createPostsInFlight: Set<UUID> = []
    /// True when the create store held data that would not decode. The records are then
    /// unknown, so *any* draft might belong to a local document — and `runSyncPass`'s
    /// 404/403 refusal and `.discardServerWins` branches mark classic drafts `.failed` or
    /// conflicted (nothing is deleted). Suppresses both branches for classic drafts while
    /// create records are unknown: a schema slip must degrade to leaving classic drafts
    /// untouched, never to stamping `.failed` or conflicts across offline-created documents.
    ///
    /// Read once, which is sound: nothing can make the blob undecodable mid-process
    /// (`persist` only ever writes encoder output), and the store's own flag is **sticky**
    /// — it stays true while a quarantine exists — so a repair does not silently re-arm those
    /// branches on the next launch either. Suppression outlives the session by design; see
    /// `holdsUnreadableData`.
    private let createStoreUnreadable: Bool
    /// True when the **delete** store held data that would not decode, so the tombstones are
    /// unknown rather than absent.
    ///
    /// Far milder than `createStoreUnreadable` — unknown tombstones mean queued deletions stop
    /// replaying and rows stop being struck through, which costs nothing and is recoverable by
    /// deleting again. Two consequences are *not* mild (see
    /// `PendingDocumentDeleteStore.holdsUnreadableData`): with every tombstone unknown,
    /// `runCreatePass`'s resume guard is disarmed, so a checkpointed record whose DELETE landed
    /// in a pass that died before its cleanup ran resumes, reads the 404 as "gone", clears its
    /// checkpoint, and the next pass **re-POSTs the document the user deleted** (which comes
    /// back under a new id); and `runSyncPass`'s 404/403 and `.discardServerWins` branches
    /// would mark a tombstoned classic draft `.failed` or conflicted while its deletion is
    /// unknown. So both paths gate on this flag.
    ///
    /// Read once, which is sound for the same reasons `createStoreUnreadable` is: nothing can
    /// make the blob undecodable mid-process, and the store's own flag is sticky.
    ///
    /// It gates the **start-over**, not the resume as a whole. Withholding the whole resume
    /// would be the safe-looking choice and is the wrong one: nothing clears the quarantine,
    /// so every checkpointed record on the install would be blocked from migrating *forever*
    /// — its body safe on disk but its server document empty, with no recovery short of a
    /// reinstall. The resume's other outcomes are harmless; only the branch that reads a 404
    /// as "start over" can re-POST a document the user deleted, so only that one waits.
    private let deleteStoreUnreadable: Bool
    /// Deletions the user has asked for that the server has not been told about, keyed by the
    /// **server** id the DELETE will address and mirrored from `deleteStore` so the hot
    /// predicate (`isPendingDelete`, read on every sync pass and every row) is a dictionary
    /// lookup rather than a UserDefaults decode. **Every** tombstone is mirrored, whatever
    /// origin or user queued it — protection is unconditional, exactly as for
    /// `pendingCreates`; see `isPendingDelete`.
    private var pendingDeletes: [UUID: PendingDocumentDelete] = [:]
    /// Bumped on every mutation of `pendingDeletes`, so an `@Observable` consumer can track
    /// "the set of queued deletions changed" without the dictionary itself being visible.
    /// The rows that strike a document through read it via `isListablePendingDelete`, which
    /// is what makes a row strike (and un-strike, on undo) the moment the tombstone moves
    /// rather than at the next successful list fetch.
    private(set) var pendingDeletesVersion = 0

    init(
        client: DocsAPIClient,
        draftStore: PendingDraftStore = PendingDraftStore(),
        replicaStore: ReplicaStore? = nil,
        replicaAccessStore: ReplicaAccessStore? = nil,
        cleanReplicaByteLimit: Int = ReplicaStore.defaultCleanReplicaByteLimit,
        contentCache: DocumentContentCacheStore = DocumentContentCacheStore(),
        createStore: PendingDocumentCreateStore = PendingDocumentCreateStore(),
        deleteStore: PendingDocumentDeleteStore = PendingDocumentDeleteStore(),
        pinStore: PendingDocumentPinStore? = nil,
        attachmentStore: PendingAttachmentStore = PendingAttachmentStore(),
        attachmentCache: AttachmentCacheStore = AttachmentCacheStore(),
        listCache: DocumentCacheStore = DocumentCacheStore(),
        childrenCache: DocumentChildrenCacheStore = DocumentChildrenCacheStore(),
        serverOrigin: String = "",
        appBuild: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
        mediaCheckMaxAttempts: Int = 5,
        mediaCheckRetryInterval: Duration = .seconds(1),
        backgroundTasks: BackgroundTaskProvider = .uiApplication,
        isLiveReplicaHeld: @escaping @MainActor (UUID) -> Bool = { _ in false },
        isOnline: @escaping @MainActor () -> Bool = { true },
        isForegrounded: Bool = true,
        nativeSaveRetryBackoff: NativeSaveRetryBackoff = NativeSaveRetryBackoff(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        diagnostics: APIDiagnosticsLog? = nil
    ) {
        self.client = client
        self.diagnostics = diagnostics
        self.pins = DocumentPinCoordinator(
            client: client, store: pinStore ?? PendingDocumentPinStore(userDefaults: listCache.userDefaults),
            cache: listCache, serverOrigin: client.serverOrigin,
            signedInUser: SignedInUserStore(userDefaults: listCache.userDefaults), userDefaults: listCache.userDefaults)
        self.draftStore = draftStore
        self.inFlightContent = AccountScoped(draftStore)
        self.queued = AccountScoped(draftStore)
        self.conflicts = AccountScoped(draftStore)
        self.lastConfirmedPushMarkdown = AccountScoped(draftStore)
        // A save state, a failure and a known title are one account's too: another account's
        // `.failed` would hold this one's replay and show it a failure it cannot act on.
        self.states = AccountScoped(draftStore)
        self.failureDetails = AccountScoped(draftStore)
        self.failureReasons = AccountScoped(draftStore)
        self.failuresWithoutRetry = AccountScoped(draftStore)
        self.knownServerTitles = AccountScoped(draftStore)
        self.replicaStore =
            replicaStore ?? ReplicaStore(ownershipStore: ReplicaOwnershipStore(userDefaults: listCache.userDefaults))
        self.replicaAccessStore = replicaAccessStore ?? ReplicaAccessStore(userDefaults: listCache.userDefaults)
        self.cleanReplicaByteLimit = cleanReplicaByteLimit
        self.signedInUser = SignedInUserStore(userDefaults: listCache.userDefaults)
        self.contentCache = contentCache
        self.createStore = createStore
        self.deleteStore = deleteStore
        self.attachmentStore = attachmentStore
        self.attachmentCache = attachmentCache
        self.listCache = listCache
        self.childrenCache = childrenCache
        self.serverConfigStore = ServerConfigStore(userDefaults: listCache.userDefaults)
        self.serverCapabilityStore = ServerCapabilityStore(userDefaults: listCache.userDefaults)
        self.serverOrigin = serverOrigin
        self.appBuild = appBuild
        self.mediaCheckMaxAttempts = mediaCheckMaxAttempts
        self.mediaCheckRetryInterval = mediaCheckRetryInterval
        self.backgroundTasks = backgroundTasks
        self.isLiveReplicaHeld = isLiveReplicaHeld
        self.isOnline = isOnline
        self.isForegrounded = isForegrounded
        self.nativeSaveRetryBackoff = nativeSaveRetryBackoff
        self.sleep = sleep
        createStoreUnreadable = createStore.holdsUnreadableData
        deleteStoreUnreadable = deleteStore.holdsUnreadableData
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
        // 404ed and marked it `.failed` while leaving the record pointing at nothing.
        // Dormant has to mean *no requests and no failure stamp*. Origin decides what is
        // **listed** (below) and, with the owning user, what the replay may **POST**
        // (`isReplayable`) — never whether the content is protected.
        for create in createStore.allCreates() {
            pendingCreates[create.localID] = create
            // `states` is in-memory, so without this every local document reads `.idle`
            // after a relaunch until something enqueues — i.e. the reading surface would
            // show "Edited just now" for a document that exists nowhere but here. The
            // truthful state is the one `createLocalDocument` set.
            states[create.localID] = .pendingSync
        }
        // Tombstones, on the same terms and for the same reason: the suppressions they drive
        // must be in force from this process's first sync pass, which `recoverDrafts()` starts
        // as soon as Home loads. A forgotten tombstone would let `runSyncPass` push the draft
        // of a document the user has already deleted, and let a checkpointed record resume
        // and re-POST it.
        //
        // **Every tombstone is mirrored, whatever origin or account queued it** — the same
        // rule as the records above, and for the same reason: `runSyncPass` walks
        // `draftStore.allDrafts()`, which is not origin-scoped, so a foreign tombstone that
        // was not mirrored would leave its document's draft unsuppressed. Origin and owner
        // decide what may be **sent** and **shown** (`isListablePendingDelete`), never what is
        // protected.
        //
        // No `states` seeding, unlike the records: nothing renders a save state for a
        // tombstoned document. Its editor is gated before it loads, and its rows are drawn by
        // the pending-delete predicate rather than by a save state.
        for pendingDelete in deleteStore.allDeletes() {
            pendingDeletes[pendingDelete.documentID] = pendingDelete
        }
        // Same reasoning for queued photos: the save hold is content-keyed and works without
        // this, but every affordance that explains *why* a document is held reads the mirror.
        for attachment in attachmentStore.allAttachments() {
            pendingAttachments[attachment.localID] = attachment
        }
        // **Rehydrate the holds before anything can enqueue.** The coordinator is built once,
        // at app start, before any editor exists — so a conflict persisted by a previous
        // process is in force from the very first `enqueue` of this one, rather than only
        // after a revalidation happens to return. That ordering is the whole point: on launch
        // the editor renders a stored draft synchronously and unblocks editing immediately,
        // so a Done tap could otherwise beat the fetch and push a full overwrite over the body
        // the user was already warned about. Every account's: a hold is a protection, and a
        // fresh sign-in builds this coordinator before `/users/me/` names the account.
        for draft in draftStore.allDraftsOfEveryAccount() {
            if let serverUpdatedAt = draft.conflictServerUpdatedAt, let owner = draft.owner {
                conflicts[draft.documentID, in: SignedInSession(userID: owner, epoch: 0)] =
                    SyncConflict(serverUpdatedAt: serverUpdatedAt)
            }
        }
        updateBackupProtection()
        let dirtyIDs = backupDirtyDocumentIDs
        self.replicaStore.setCoordinatorHasUnsyncedMetadata { documentID in
            dirtyIDs.contains(documentID)
        }
        for documentID in dirtyIDs.snapshot() {
            if let scope = anyAccountReplicaScope(documentID: documentID)
                ?? nativeOwnership(documentID: documentID).scope
            {
                self.replicaStore.refreshBackupExclusion(for: scope)
            }
        }
    }

    private func computeBackupDirtyDocumentIDs() -> Set<UUID> {
        var ids = Set(pendingCreates.keys)
        ids.formUnion(pendingCreates.values.compactMap(\.syncedServerID))
        ids.formUnion(draftStore.allDraftsOfEveryAccount().map(\.documentID))
        ids.formUnion(queued.keys)
        ids.formUnion(inFlight.keys)
        ids.formUnion(inFlightContent.keys)
        ids.formUnion(conflicts.keys)
        ids.formUnion(pendingAttachments.values.map(\.documentID))
        return ids
    }

    private func updateBackupProtection() {
        backupDirtyDocumentIDs.replace(computeBackupDirtyDocumentIDs())
    }

    private func syncBackupExclusion(for documentID: UUID, scope: ReplicaScope? = nil) {
        updateBackupProtection()
        if let resolvedScope = scope
            ?? anyAccountReplicaScope(documentID: documentID)
            ?? nativeOwnership(documentID: documentID).scope
        {
            replicaStore.refreshBackupExclusion(for: resolvedScope)
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
    private func saveDraft(_ draft: PendingDraft, setAsideIn epoch: Int? = nil) {
        draftStore.save(draft, setAsideIn: epoch)
        draftsVersion &+= 1
    }

    private func removeDraft(documentID: UUID, in session: SignedInSession? = nil) {
        if let session {
            draftStore.remove(documentID: documentID, in: session)
        } else {
            draftStore.remove(documentID: documentID)
        }
        draftsVersion &+= 1
    }

    /// The sign-in drafts and the in-memory per-account state are scoped to. Work that starts
    /// under it carries it, so what settles after a switch is filed under the account that did
    /// the work and is never sent under another.
    var signedInSession: SignedInSession { draftStore.session }

    /// Some account's classic edits for this document are waiting on the device. A native
    /// replica seeded over them would leave that account's classic draft unsyncable. Drafts set
    /// aside for nobody are left out: nothing would ever sync them anyway.
    func hasClassicDraftOfAnyAccount(documentID: UUID) -> Bool {
        draftStore.allDraftsOfEveryAccount().contains {
            $0.documentID == documentID && $0.replica == nil && $0.owner != nil
        }
    }

    /// The live `/users/me/` and the account drafts are scoped to name the same account. A replay
    /// pass reads and writes drafts through the second, so it changes nothing while they differ
    /// — after an unconfirmed handover, a `/users/me/` blip, or a switch during one of its awaits
    /// — or it would read the owner's body as absent and act on that.
    private func draftsAreScoped(to liveUserID: UUID?) -> Bool {
        liveUserID != nil && signedInSession.userID == liveUserID && (DocsAPIClient.saveIsCurrent?() ?? true)
    }

    private func persistConflictOnDraft(documentID: UUID) {
        // The session's own draft, so an unnamed sign-in's hold is mirrored onto its set-aside slot.
        let session = signedInSession
        guard let draft = draftStore.draft(for: documentID, in: session) else { return }
        let stamp = conflicts[documentID]?.serverUpdatedAt
        guard draft.conflictServerUpdatedAt != stamp else { return }
        saveDraft(
            PendingDraft(
                documentID: documentID, title: draft.title, markdown: draft.markdown,
                updatedAt: draft.updatedAt, baseline: draft.baseline,
                lastPushedMarkdown: draft.lastPushedMarkdown, conflictServerUpdatedAt: stamp, replica: draft.replica,
                ownerUserID: draft.owner),
            setAsideIn: draft.owner == nil ? session.epoch : nil)
        syncBackupExclusion(for: documentID, scope: draft.replica?.scope)
    }

    func state(for documentID: UUID) -> DocSaveState {
        states[documentID] ?? .idle
    }

    /// The response that made this document's save land on `.failed`, or nil (transport or decoding
    /// failure, or not failed).
    func failureDetail(for documentID: UUID) -> RequestFailure? {
        guard case .failed = state(for: documentID) else { return nil }
        return failureDetails[documentID]
    }

    /// Everything the "Couldn't save" alert can say about a `.failed` document: the local reason
    /// (every `.failed` carries one), then the rejecting request when there was one. Nil when the
    /// document is not failed.
    func failureReport(for documentID: UUID) -> String? {
        guard case .failed = state(for: documentID), let reason = failureReasons[documentID] else { return nil }
        return [reason, failureDetail(for: documentID)?.saveFailureDetail].compactMap { $0 }.joined(separator: "\n\n")
    }

    /// The one way into `.failed`, so no failure lacks a reason and none keeps a stale one.
    /// `detail` is the request behind *this* failure; callers that have none pass nil, which
    /// also drops a previous failure's request rather than quoting it under the new reason.
    /// `session` files the failure under the account whose save failed (default: the one signed in).
    private func markFailed(
        _ documentID: UUID, reason: String, detail: RequestFailure? = nil, offersRetry: Bool = true,
        in session: SignedInSession? = nil
    ) {
        let session = session ?? signedInSession
        resetNativeSaveRetry(documentID: documentID)
        states[documentID, in: session] = .failed("Couldn't save changes. Please try again.")
        failureReasons[documentID, in: session] = reason
        failureDetails[documentID, in: session] = detail
        failuresWithoutRetry[documentID, in: session] = offersRetry ? nil : true
    }

    /// Whether the failure alert should offer Retry; false where a retry would silently do nothing.
    func failureOffersRetry(for documentID: UUID) -> Bool { failuresWithoutRetry[documentID] != true }

    /// Whether any failure reason or request is still held for the document (tests only: it is how
    /// a reset that forgot `clearFailure` shows, since `failureReport` hides a stale one).
    func holdsFailureRecord(for documentID: UUID) -> Bool {
        failureReasons[documentID] != nil || failureDetails[documentID] != nil
            || failuresWithoutRetry[documentID] == true
    }

    /// Forgets why a document last failed; for every place its state is reset or dropped.
    private func clearFailure(_ documentID: UUID, in session: SignedInSession? = nil) {
        let session = session ?? signedInSession
        failureReasons[documentID, in: session] = nil
        failureDetails[documentID, in: session] = nil
        failuresWithoutRetry[documentID, in: session] = nil
    }

    // MARK: - Native replica ownership

    /// Whether the durable marker says the native replica owns this document.
    /// Unreadable or lost marker data answers true for every document: ownership
    /// is unknown, so the classic writer must not be allowed to guess.
    func isNativeOwned(documentID: UUID) -> Bool {
        nativeOwnership(documentID: documentID) != .none
    }

    /// Keyed by the client's origin, the one every replica scope is checked
    /// against — not the separately injected `serverOrigin` of pending creates.
    /// A native draft owns its document even when the marker does not name it
    /// (a repair that could not read its folder): its Markdown is only a shadow.
    func nativeOwnership(documentID: UUID) -> ReplicaOwnership {
        let marker = replicaStore.ownership(documentID: documentID, serverOrigin: client.serverOrigin)
        guard marker == .none, let scope = anyAccountReplicaScope(documentID: documentID) else { return marker }
        return scope.serverOrigin == client.serverOrigin ? .owned(scope) : .unreadable
    }

    /// Whichever account's native draft names this document: what keeps it read-only and out of
    /// backups and purges, so another account's draft counts too.
    private func anyAccountReplicaScope(documentID: UUID) -> ReplicaScope? {
        draftStore.allDraftsOfEveryAccount().last { $0.documentID == documentID && $0.replica != nil }?.replica?.scope
    }

    var hasUnreadableDrafts: Bool { draftStore.holdsUnreadableData }

    /// Marker data is missing or does not decode while replica files exist, so
    /// every document is read-only until the marker is rebuilt.
    var needsOwnershipRepair: Bool { replicaStore.needsOwnershipRepair }

    func noteServerConfig(_ config: ServerConfig) {
        serverConfigStore.remember(config, forServerOrigin: client.serverOrigin)
        serverCapabilityStore.record(config, forServerOrigin: client.serverOrigin)
    }

    func cachedServerConfig() -> ServerConfig? {
        serverConfigStore.config(forServerOrigin: client.serverOrigin)
    }

    func isCachedDocs6Server() -> Bool {
        cachedServerConfig()?.usesCollaborationYDocServer == true
    }

    /// True when a local create would have no collaboration org to seed a native replica from,
    /// so the caller must ask the user to go online rather than mint a classic draft.
    var localCreateNeedsServerSetup: Bool { nativeEditorEnabled() && cachedDocs6Org() == nil }

    private func cachedDocs6Org() -> String? {
        guard let config = cachedServerConfig(), config.usesCollaborationYDocServer else { return nil }
        return config.collaborationOrg
    }

    /// Fail-closed guard shared by sign-out purge and LRU eviction: if any store tracking
    /// unsynced local work or replica ownership is unreadable (including quarantined drafts),
    /// no replica may be removed.
    private var canSafelyRemoveCleanReplicas: Bool {
        !draftStore.holdsUnreadableData
            && !createStoreUnreadable
            && !deleteStoreUnreadable
            && !attachmentStore.holdsUnreadableData
            && !replicaStore.needsOwnershipRepair
    }

    /// Document IDs with unsynced coordinator state (drafts, creates, deletes, in-flight,
    /// queued, conflicts, or pending attachments) that must never be removed by purge or LRU.
    private func protectedReplicaDocumentIDs() -> Set<UUID> {
        var keeping = Set(draftStore.allDraftsOfEveryAccount().map(\.documentID))
        keeping.formUnion(pendingCreates.keys)
        keeping.formUnion(pendingCreates.values.compactMap(\.syncedServerID))
        keeping.formUnion(pendingDeletes.keys)
        keeping.formUnion(inFlight.keys)
        keeping.formUnion(inFlightContent.keys)
        keeping.formUnion(queued.keys)
        keeping.formUnion(conflicts.keys)
        keeping.formUnion(pendingAttachments.values.map(\.documentID))
        return keeping
    }

    func recordReplicaOpened(scope: ReplicaScope, at date: Date = Date()) {
        replicaAccessStore.recordOpened(scope, at: date)
    }

    /// Evicts least-recently-opened clean replicas when total replica storage exceeds
    /// `cleanReplicaByteLimit`. Reuses the sign-out purge's fail-closed guards and
    /// protected-document set, and also protects every scope currently open in `nativeSessions`
    /// or `additionalKeepingScopes`.
    @discardableResult
    func evictCleanNativeReplicasIfNeeded(keepingScopes additionalKeepingScopes: Set<ReplicaScope> = [])
        -> [ReplicaScope]
    {
        guard canSafelyRemoveCleanReplicas else { return [] }
        var keepingScopes = additionalKeepingScopes
        if let open = nativeSessions?.busyScopes {
            keepingScopes.formUnion(open)
        }
        let evicted = replicaStore.evictCleanReplicas(
            overByteLimit: cleanReplicaByteLimit,
            keepingDocumentIDs: protectedReplicaDocumentIDs(),
            keepingScopes: keepingScopes,
            lastOpened: replicaAccessStore.snapshot())
        for scope in evicted {
            replicaAccessStore.remove(scope)
        }
        return evicted
    }

    /// Removes clean, synced replica folders for the leaving account/origin while keeping every
    /// dirty, provisional, conflicted, active, or unreadable replica untouched.
    func purgeCleanNativeReplicasOnSignOut(ownerUserID: UUID? = nil) {
        cancelNativeSaveRetries()
        guard let resolvedOwner = ownerUserID ?? signedInUser.userID,
            canSafelyRemoveCleanReplicas
        else { return }
        let removed = replicaStore.purgeCleanReplicas(
            serverOrigin: client.serverOrigin,
            ownerUserID: resolvedOwner,
            keepingDocumentIDs: protectedReplicaDocumentIDs())
        for scope in removed {
            replicaAccessStore.remove(scope)
        }
    }

    /// Rebuild the owner marker from the scoped manifests on disk. The only
    /// production caller is the Profile recovery row; routine writes never
    /// overwrite unreadable marker data.
    /// Native drafts name their scope too, so an unreadable draft store refuses.
    @discardableResult
    func repairReplicaOwnership() -> Bool {
        guard !draftStore.holdsUnreadableData else { return false }
        return replicaStore.repairOwnership(
            draftScopes: draftStore.allDraftsOfEveryAccount().compactMap { $0.replica?.scope })
    }

    /// A replica folder the repair cannot read (quarantined, damaged, newer format)
    /// keeps every document read-only; Profile then offers to set them aside.
    var hasUnreadableReplicaFolders: Bool { replicaStore.hasUnreadableFolders }

    /// Move the unreadable folders out of use, keeping their bytes on the device,
    /// then repair. A drafted document stays read-only through its draft.
    @discardableResult
    func setAsideUnreadableReplicasAndRepair() -> Bool {
        // The move is one-way: never make it when the repair cannot follow.
        guard !draftStore.holdsUnreadableData, replicaStore.setAsideUnreadableFolders() else { return false }
        return repairReplicaOwnership()
    }

    /// Clear a marker left by a crash between marking and writing the manifest,
    /// only while nothing unsynced exists anywhere: no replica manifest or
    /// quarantine, no draft, no queued or in-flight save, no checkpointed create
    /// for any account on this server ID, and a matching signed-in owner with a
    /// readable draft store. Anything else keeps the document read-only.
    @discardableResult
    func clearNativeOwnership(scope: ReplicaScope) -> Bool {
        let id = scope.documentID
        guard scope.serverOrigin == client.serverOrigin,
            signedInUser.userID == scope.ownerUserID,
            !draftStore.holdsUnreadableData,
            !draftStore.allDraftsOfEveryAccount().contains(where: { $0.documentID == id }),
            inFlight[id] == nil, queued[id] == nil,
            anyCheckpointedRecord(forServerID: id) == nil
        else { return false }
        return replicaStore.clearOwnership(for: scope)
    }

    /// Whether a live collaboration replica currently owns this document. A
    /// native session never uses the live write path, so it must not author
    /// while the live owner holds the document.
    func isLiveHeld(documentID: UUID) -> Bool { isLiveReplicaHeld(documentID) }

    /// A native capture that could not be prepared. The journal bytes are
    /// durable, but nothing can send them until the refusal clears; report it
    /// rather than claiming a save. Authoring is frozen by the caller.
    func noteReplicaCaptureFailure(documentID: UUID, error: Error) {
        guard inFlight[documentID] == nil, queued[documentID] == nil else { return }
        markFailed(
            documentID, reason: "Native capture refused: \(safeErrorSummary(error))", offersRetry: false)
    }

    /// Retry the quarantined draft blobs. On success, rehydrate the conflict
    /// holds from the recovered drafts so a hold that was invisible while the
    /// store was unreadable is in force again. Returns whether recovery
    /// succeeded; a failure keeps the hold and every blob.
    @discardableResult
    func recoverQuarantinedDrafts() -> Bool {
        guard draftStore.recoverQuarantinedDrafts() else { return false }
        draftsVersion &+= 1
        for draft in draftStore.allDraftsOfEveryAccount() {
            if let serverUpdatedAt = draft.conflictServerUpdatedAt, let owner = draft.owner {
                conflicts[draft.documentID, in: SignedInSession(userID: owner, epoch: 0)] =
                    SyncConflict(serverUpdatedAt: serverUpdatedAt)
            }
            syncBackupExclusion(for: draft.documentID, scope: draft.replica?.scope)
        }
        updateBackupProtection()
        return true
    }

    /// Remove a native replica the user explicitly discarded. The marker is
    /// cleared by the store only after the replica is unreachable; a failure
    /// leaves the document read-only rather than classic-editable.
    ///
    /// Only the signed-in owner's: another account's replica and native draft
    /// (a shared device, where B's DELETE of A's document 404s as "already
    /// gone") are that account's unsynced work and stay. Returns false when the
    /// caller must keep the draft for that reason.
    @discardableResult
    private func discardNativeReplica(documentID: UUID) -> Bool {
        let reference = draftStore.draft(for: documentID)?.replica
        let ownership = nativeOwnership(documentID: documentID)
        if case .unreadable = ownership { return false }
        guard let scope = reference?.scope ?? ownership.scope else { return true }
        guard let currentUserID = signedInUser.userID, scope.ownerUserID == currentUserID else {
            return reference == nil
        }
        do {
            try replicaStore.remove(for: scope)
            return true
        } catch {
            // Keep the marker and draft: failure removing the replica must not
            // leave behind orphaned local data or claim discard succeeded.
            return false
        }
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

    // MARK: - Deletions queued on this device

    /// Whether a deletion of this **server** id is queued and unsent — the predicate the
    /// suppressions key off. Deliberately **not** scoped, exactly like `isPendingCreate`:
    /// protection is unconditional. A tombstone queued by another account still names a
    /// document this session must not push a draft to, must not mark failed or conflicted, and
    /// must not resume a checkpointed record onto.
    ///
    /// Its scoped sibling `isListablePendingDelete` is what the rows and the undo affordance
    /// ask; never use this one for UI.
    func isPendingDelete(documentID: UUID) -> Bool {
        pendingDeletes[documentID] != nil
    }

    /// Whether this session may be *shown* a struck-through row for this document, and
    /// offered the undo that cancels it.
    ///
    /// Scoped for the same reason `pendingLocalDocuments` is, and the disclosure runs the
    /// same way round: tombstones survive sign-out, so an unscoped predicate would strike
    /// user A's document through user B's lists on the same device — B's lists still hold
    /// the document, because metadata caches are neither account-scoped nor cleared — and
    /// then offer B a button that cancels A's deletion. An **unattributable** tombstone (nil
    /// owner) is kept and protected but neither shown nor sent; `recordPendingDelete`
    /// requires an owner, so nil can only arrive from a future or damaged schema.
    ///
    /// Reads `pendingDeletesVersion` first, so a SwiftUI body calling this registers the
    /// dependency and re-renders when a tombstone is queued or undone — the same mechanism
    /// `mergedSubpages` uses for `pendingCreatesVersion`.
    func isListablePendingDelete(documentID: UUID, currentUserID: UUID?) -> Bool {
        _ = pendingDeletesVersion
        guard let queued = pendingDeletes[documentID] else { return false }
        guard queued.serverOrigin == serverOrigin, let owner = queued.ownerUserID else { return false }
        return owner == currentUserID
    }

    /// Queue a deletion the server could not be told about, so it replays on the next
    /// trigger and every list strikes the document through meanwhile.
    ///
    /// `documentID` must be a **server** id. A document that exists only here has nothing to
    /// DELETE — `OptionsViewModel` completes that case locally and never reaches this.
    ///
    /// `ownerUserID` is **required, not defaulted**, for the same reason
    /// `createLocalDocument`'s is: an unattributable tombstone can be neither shown nor sent,
    /// so a caller that could not name the user would silently queue a deletion that never
    /// happens and never appears — while the row it left behind looks alive. Making the
    /// parameter mandatory forces that at the call site, which is where the session is.
    ///
    /// Idempotent: re-queueing overwrites, keeping the newer request.
    func recordPendingDelete(documentID: UUID, ownerUserID: UUID) {
        resetNativeSaveRetry(documentID: documentID)
        let tombstone = PendingDocumentDelete(
            documentID: documentID, requestedAt: Date(), serverOrigin: serverOrigin, ownerUserID: ownerUserID)
        deleteStore.save(tombstone)
        pendingDeletes[documentID] = tombstone
        pendingDeletesVersion += 1
    }

    /// Undo: the deletion is no longer wanted, so the document returns to ordinary life.
    ///
    /// Nothing else is restored because nothing else was taken — that is the whole point of
    /// the queue-time split. `OptionsViewModel` records the tombstone *instead of* clearing
    /// the local work, and `EditorViewModel.handleDidQueueDelete` ends the editing session
    /// without purging, so the draft, the create record and the caches are all still where
    /// they were. Dropping the tombstone un-suppresses them.
    ///
    /// Deliberately does not kick the sync funnel: the caller does, because it also knows
    /// whether a screen is waiting on the result.
    func cancelPendingDelete(documentID: UUID) {
        guard pendingDeletes[documentID] != nil else { return }
        deleteStore.remove(documentID: documentID)
        pendingDeletes[documentID] = nil
        pendingDeletesVersion += 1
        unwedgeHeldSave(documentID: documentID)
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
    ///
    /// `seedMarkdown` is normally empty — a new document starts blank. The one caller that
    /// passes a body is `reviveAsLocalDocument`, which is carrying content over from a
    /// document whose id has just died; seeding it here rather than overwriting the draft
    /// afterwards is what keeps that body from existing at only the dead id for two writes.
    @discardableResult
    func createLocalDocument(
        title: String, parentID: UUID?, ownerUserID: UUID, seedMarkdown: String = ""
    ) -> Document {
        let record = PendingDocumentCreate(
            localID: UUID(), title: title, parentID: parentID, createdAt: Date(), serverOrigin: serverOrigin,
            ownerUserID: ownerUserID)
        createStore.save(record)
        pendingCreates[record.localID] = record
        pendingCreatesVersion += 1
        updateBackupProtection()
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
        // `.discardServerWins`, raising a false conflict against the empty document the POST
        // just made. Migration must stamp one before the draft is replayed, saying what the
        // body **descends from** — the create response on an undiverged fresh POST, a
        // `formattedContent` fetch on an undiverged resume, and a nil clock with an empty body
        // when the two have **diverged**, where claiming the observed state would prove the
        // very push the conflict is holding. See `migrateCreatedDocument`.
        var draft = PendingDraft(
            documentID: record.localID, title: title, markdown: seedMarkdown,
            updatedAt: record.createdAt, ownerUserID: ownerUserID)
        var createdScope: ReplicaScope?
        if nativeEditorEnabled(), !client.serverOrigin.isEmpty, let org = cachedDocs6Org() {
            let scope = ReplicaScope(
                serverOrigin: client.serverOrigin, ownerUserID: ownerUserID, org: org,
                documentID: record.localID)
            let checkpoint = MarkdownYjs.encode(markdown: seedMarkdown, serverOrigin: client.serverOrigin)
            do {
                let manifest = try replicaStore.create(for: scope, checkpoint: checkpoint)
                createdScope = scope
                draft = PendingDraft(
                    documentID: record.localID, title: title, markdown: seedMarkdown,
                    updatedAt: record.createdAt,
                    replica: ReplicaDraftReference(manifest: manifest, markdown: seedMarkdown))
            } catch {
                // Only a partial create that left no manifest falls back to classic; preserve
                // an intact replica if a manifest landed despite the thrown error.
                if (try? replicaStore.manifest(for: scope)) == nil {
                    try? replicaStore.remove(for: scope)
                    _ = replicaStore.clearOwnership(for: scope)
                }
            }
        }
        saveDraft(draft)
        syncBackupExclusion(for: record.localID, scope: createdScope)
        if let createdScope {
            recordReplicaOpened(scope: createdScope)
            evictCleanNativeReplicasIfNeeded(keepingScopes: [createdScope])
        }
        states[record.localID] = .pendingSync
        return localDocument(from: record)
    }

    // MARK: - Classic local-create conversion (PR07b)

    /// Converts every eligible classic local create to a native replica, so a page created on
    /// this device before the native editor was switched on opens natively instead of waiting
    /// for its classic draft to sync. Runs at the start of each replay pass, before
    /// `runCreatePass`.
    ///
    /// A page whose editor is on screen is skipped: its in-memory blocks still name the classic
    /// draft, and converting under it would make its next flush a refused classic save. The
    /// single form is called by the open route itself, which is about to replace that screen's
    /// content with the replica.
    func convertUnsentClassicCreates() {
        guard nativeEditorEnabled(), cachedDocs6Org() != nil else { return }
        for documentID in Array(pendingCreates.keys) where !hasOpenEditor(documentID: documentID) {
            convertUnsentClassicCreate(documentID: documentID)
        }
    }

    /// Converts one classic local create to a native replica, or leaves it classic when anything
    /// about it cannot carry over safely.
    ///
    /// **Synchronous on the main actor, and that is the safety argument.** The classic replay and
    /// the attachment collector are async passes, so neither can run against the page between the
    /// steps below; a suspension point would let one rewrite the draft or collect a photo the
    /// conversion is mid-way through re-keying.
    ///
    /// Crash safety without a journal, and the order is what makes it safe: the photo records are
    /// re-keyed first (step 1), then the replica is created (step 2), then the draft is rewritten
    /// (step 3). A death after step 1 leaves native records on a classic page — the classic
    /// collector never touches a native record, so the bytes survive — and the next pass finishes
    /// from them. A death after step 2 leaves a manifest with a classic draft, which the resume
    /// path finishes from the existing replica rather than re-encoding it — a replica with journal
    /// entries beyond its checkpoint is never overwritten.
    func convertUnsentClassicCreate(documentID: UUID) {
        guard nativeEditorEnabled(), let org = cachedDocs6Org() else { return }
        guard let record = pendingCreates[documentID], record.syncedServerID == nil,
            record.serverOrigin == client.serverOrigin,
            let ownerUserID = record.ownerUserID, ownerUserID == signedInUser.userID,
            !isPendingDelete(documentID: documentID),
            !createPostsInFlight.contains(documentID),
            !draftStore.holdsUnreadableData, !attachmentStore.holdsUnreadableData
        else { return }
        guard let draft = draftStore.draft(for: documentID), draft.replica == nil else { return }
        let scope = ReplicaScope(
            serverOrigin: client.serverOrigin, ownerUserID: ownerUserID, org: org, documentID: documentID)
        guard scope.isValid else { return }
        guard
            let photos = classicPhotosForConversion(
                markdown: draft.markdown, documentID: documentID, ownerUserID: ownerUserID, org: org)
        else { return }

        let existing: ReplicaManifest?
        do {
            existing = try replicaStore.manifest(for: scope)
        } catch {
            return
        }
        if let existing {
            // Resume after a death past step 2: the replica is the authority, so it is never
            // re-encoded. Every expected photo block must already be there, or nothing is
            // touched — the classic draft, the records and the replica all stay.
            guard existing.formatVersion == ReplicaManifest.currentFormat,
                replicaHoldsPhotoBlocks(photos, scope: scope)
            else { return }
            rekeyPhotos(photos, org: org)
        } else {
            let checkpoint = MarkdownYjs.encode(
                markdown: draft.markdown, serverOrigin: client.serverOrigin,
                pendingImages: Dictionary(uniqueKeysWithValues: photos.map { ($0.placeholderURL, $0.blockID) }))
            // A page the native editor could only show read-only (a photo nested in a list, for
            // one: its empty-url block has no typeable spelling) stays classic. Converting it
            // would lock it read-only and leave its photo with nothing to commit into.
            guard isTypeable(checkpoint: checkpoint) else { return }
            // Step 1: re-key before the replica exists, so a death here leaves records the
            // classic collector skips rather than a replica whose photos it would collect. A
            // classic migration that later finds them native turns them back (see
            // `migrateCreatedDocument`).
            rekeyPhotos(photos, org: org)
            do {
                _ = try replicaStore.create(for: scope, checkpoint: checkpoint)
            } catch {
                // Only a partial create that left no manifest falls back to classic; preserve an
                // intact replica if a manifest landed despite the thrown error.
                if (try? replicaStore.manifest(for: scope)) == nil {
                    try? replicaStore.remove(for: scope)
                    _ = replicaStore.clearOwnership(for: scope)
                    // The page stays classic, so its photos must too: a native record with no
                    // replica to commit into would be dropped with its bytes.
                    for photo in photos {
                        updatePendingAttachment(
                            PendingAttachment(
                                localID: photo.record.localID, documentID: photo.record.documentID,
                                createdAt: photo.record.createdAt, serverOrigin: photo.record.serverOrigin,
                                ownerUserID: photo.record.ownerUserID))
                    }
                }
                return
            }
        }

        // The projection is read before the draft is rewritten, so a replica that cannot be
        // projected leaves the draft classic — the records are already native and safe.
        let adapter = ReplicaSaveAdapter(store: replicaStore, scope: scope)
        guard let prepared = try? adapter.prepare() else { return }

        // Step 3: the draft takes the replica reference and the replica's own projection as its
        // shadow, so `ReplicaDraftReference.matches` holds and no placeholder reaches a save.
        saveDraft(
            PendingDraft(
                documentID: documentID, title: draft.title, markdown: prepared.markdown,
                updatedAt: draft.updatedAt, baseline: draft.baseline,
                lastPushedMarkdown: draft.lastPushedMarkdown,
                conflictServerUpdatedAt: draft.conflictServerUpdatedAt,
                replica: prepared.request.reference))
        // A classic save parked for this page names the classic body; left queued it blocks the
        // native capture, `saveNow` and failure reporting until the create migrates.
        if queued[documentID]?.replicaRequest == nil { queued[documentID] = nil }
        syncBackupExclusion(for: documentID, scope: scope)
        recordReplicaOpened(scope: scope)
        evictCleanNativeReplicasIfNeeded(keepingScopes: [scope])
    }

    /// Re-keys each still-classic record onto its block, keeping the localID (the bytes are keyed
    /// by it) and every replay field.
    private func rekeyPhotos(_ photos: [ClassicPhotoConversion], org: String) {
        for photo in photos where photo.record.native == nil {
            updatePendingAttachment(
                PendingAttachment(
                    localID: photo.record.localID, documentID: photo.record.documentID,
                    createdAt: photo.record.createdAt, serverOrigin: photo.record.serverOrigin,
                    ownerUserID: photo.record.ownerUserID,
                    native: NativeMediaTarget(
                        org: org, blockID: photo.blockID,
                        slot: MediaBlock.Slot(node: "image", url: ""),
                        fileName: "photo.jpg", contentType: "image/jpeg")))
        }
    }

    /// A queued photo a classic draft names, validated for a native conversion.
    private struct ClassicPhotoConversion {
        let localID: UUID
        let blockID: String
        let placeholderURL: String
        let record: PendingAttachment
    }

    /// The photos a classic draft names, or nil when any of them cannot carry over safely — the
    /// page then stays classic and syncs through the classic replay as before.
    ///
    /// Every placeholder must be exactly one image block's url: one that appears twice, or
    /// anywhere else (alt text, a paragraph), cannot be mapped to one block. A record must be
    /// this document's, this server's and this account's, unuploaded, unfailed, with its bytes
    /// still on disk. A record already re-keyed by a resume must target the block this
    /// conversion derives. And MarkdownYjs spells an `.unknown` block as plain paragraphs, which
    /// loses its structure, so a page holding one is not converted.
    private func classicPhotosForConversion(
        markdown: String, documentID: UUID, ownerUserID: UUID, org: String
    ) -> [ClassicPhotoConversion]? {
        let blocks = parseEditorBlocks(markdown, serverOrigin: client.serverOrigin)
        guard !blocks.contains(where: { $0.kind == .unknown }) else { return nil }
        let placeholders = blocks.compactMap { block -> String? in
            guard case .image(_, let url) = block.kind, pendingAttachmentID(fromPlaceholderURL: url) != nil
            else { return nil }
            return url
        }
        // Counted case-insensitively, because the parser accepts either case: a case-sensitive
        // count would read `SCHRIFT-ATTACHMENT://…` as zero occurrences and refuse the page.
        let occurrences = markdown.lowercased().components(separatedBy: pendingAttachmentURLPrefix).count - 1
        guard occurrences == placeholders.count else { return nil }
        var seen = Set<UUID>()
        var photos: [ClassicPhotoConversion] = []
        for url in placeholders {
            guard let localID = pendingAttachmentID(fromPlaceholderURL: url), seen.insert(localID).inserted,
                let record = pendingAttachments[localID],
                record.documentID == documentID, record.serverOrigin == client.serverOrigin,
                record.ownerUserID == ownerUserID, record.uploadedURLString == nil, record.failedAt == nil,
                attachmentStore.data(for: localID) != nil
            else { return nil }
            let blockID = localID.uuidString.lowercased()
            if let native = record.native {
                guard native.org == org, native.blockID == blockID,
                    native.slot == MediaBlock.Slot(node: "image", url: "")
                else { return nil }
            }
            photos.append(
                ClassicPhotoConversion(localID: localID, blockID: blockID, placeholderURL: url, record: record))
        }
        return photos
    }

    /// Whether a freshly encoded checkpoint opens typeable in the native editor.
    private func isTypeable(checkpoint: Data) -> Bool {
        let doc = YDoc(clientID: 0)
        defer { doc.destroy() }
        guard (try? doc.applyUpdate(YUpdateDecoder.decode(checkpoint), origin: .remote)) != nil else { return false }
        return NativeBlockProjection.typability(doc, interlinkingOrigin: client.serverOrigin).canType
    }

    /// Whether the replica already holds an image block for every expected photo — the resume
    /// path's precondition for finishing from it.
    private func replicaHoldsPhotoBlocks(_ photos: [ClassicPhotoConversion], scope: ReplicaScope) -> Bool {
        let restored: ReplicaRestore?
        do {
            restored = try replicaStore.restore(for: scope)
        } catch {
            return false
        }
        guard let restored else { return false }
        let doc = YDoc(clientID: 0)
        defer { doc.destroy() }
        do {
            try doc.applyUpdate(YUpdateDecoder.decode(restored.checkpoint), origin: .remote)
            for update in restored.updates { try doc.applyUpdate(YUpdateDecoder.decode(update), origin: .remote) }
        } catch {
            return false
        }
        guard doc.store.pendingStructs == nil, doc.store.pendingDs == nil else { return false }
        let ids = Set(
            NativeBlockProjection.project(doc, nativeMarks: false, inlineObjects: true).blocks
                .filter { $0.block.node == "image" }.map(\.id))
        return photos.allSatisfy { ids.contains($0.blockID) }
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
        let keys = parentIDAliases(parentID)
        let listed = pendingCreates.values
            .filter {
                guard isListable($0, currentUserID: currentUserID) else { return false }
                guard let recordParent = $0.parentID else { return parentID == nil }
                return keys.contains(recordParent)
            }
            .sorted { orderedByCreation($1, $0) }
        guard !listed.isEmpty else { return [] }
        let draftTitles = draftTitlesByDocument()
        return listed.map { listedLocalDocument($0, draftTitles: draftTitles) }
    }

    /// The same listing grouped by parent — what the Pages drawer needs, since it draws many
    /// levels at once and must also know which **collapsed** rows have local children, to give
    /// them a disclosure arrow. Asking `pendingLocalDocuments` per visible row would mean one
    /// full draft decode each.
    ///
    /// Roots are excluded: they are nobody's children, and the drawer's own root is the
    /// document behind it rather than the top of the account.
    func pendingLocalDocumentsByParent(currentUserID: UUID?) -> [UUID: [Document]] {
        // Filed under **every** id its parent can be asked about, not one of them. This
        // dictionary is looked up by whatever id the asking screen happens to hold, and unlike
        // `pendingLocalDocuments` it has no requested id to resolve — so picking a side is
        // picking which caller to fail. See `parentIDAliases`.
        var grouped: [UUID: [PendingDocumentCreate]] = [:]
        let checkpointedLocalIDs = localIDsByCheckpointedServerID()
        for create in pendingCreates.values where isListable(create, currentUserID: currentUserID) {
            guard let parentID = create.parentID else { continue }
            for key in aliases(of: parentID, checkpointedLocalID: checkpointedLocalIDs[parentID]) {
                grouped[key, default: []].append(create)
            }
        }
        guard !grouped.isEmpty else { return [:] }
        let draftTitles = draftTitlesByDocument()
        return grouped.mapValues { records in
            records
                .sorted { orderedByCreation($1, $0) }
                .map { listedLocalDocument($0, draftTitles: draftTitles) }
        }
    }

    /// Shown to this session, and not yet the server's — the filter both listings share.
    private func isListable(_ create: PendingDocumentCreate, currentUserID: UUID?) -> Bool {
        belongsToSession(create, currentUserID: currentUserID) && create.syncedServerID == nil
    }

    /// Every id one level can be known by — **a union, never a substitution.**
    ///
    /// For one window a document has two: a sub-page names its parent's `localID` until the
    /// migration re-keys it, but the moment that parent is checkpointed `pendingLocalDocuments`
    /// withholds its local row, so the *server* id is the one the user is offered. A strict
    /// `parentID` match therefore blanks the level for the whole window, which is usually
    /// microseconds but is stretched indefinitely by a crash and by every guard that defers
    /// `finishMigration` (an open editor on either id, an in-flight or queued save, the
    /// both-drafts window).
    ///
    /// **Resolving to one id does not fix that, it only moves it**, and both directions were
    /// tried and were wrong. Mapping server→local hides a sub-page created *during* the window,
    /// which names the server id because that is the screen the user was on. Mapping local→server
    /// hides every sub-page from a screen still holding the local id — the editor's `documentID`
    /// is a `let`, and an editor open on that id is itself one of the things deferring the
    /// migration, so it is not a rare pairing but the *characteristic* one. Two cohorts exist at
    /// once, so the level is the union of both.
    ///
    /// Costs nothing to over-answer: the two ids never appear as separate nodes in one tree,
    /// since the local row is withheld exactly while the server one is available.
    ///
    /// Deliberately **not** used by `hasPendingLocalChildren` or the cascade. Those ask what a
    /// delete would *take*, which is only ever the `localID` cohort; this asks what a level
    /// *contains*. Conflating them would have the confirmation promise sub-pages the cascade
    /// leaves behind — the false sentence round one removed.
    private func parentIDAliases(_ parentID: UUID?) -> Set<UUID> {
        guard let parentID else { return [] }
        return aliases(of: parentID, checkpointedLocalID: anyCheckpointedRecord(forServerID: parentID)?.localID)
    }

    /// The alias set with the server→local half already looked up, so a caller that needs it for
    /// **many** parents can resolve that half once instead of per parent.
    ///
    /// `checkpointedRecord` is a linear scan, and `pendingLocalDocumentsByParent` asks for every
    /// record it lists — which made the grouping quadratic, on a main-actor path a SwiftUI body
    /// reads more than once per evaluation. `localIDsByCheckpointedServerID` is that scan done
    /// once. The local→server half needs no index: it is already a dictionary subscript.
    private func aliases(of parentID: UUID, checkpointedLocalID: UUID?) -> Set<UUID> {
        var aliases: Set<UUID> = [parentID]
        if let checkpointedLocalID { aliases.insert(checkpointedLocalID) }
        if let serverID = pendingCreates[parentID]?.syncedServerID { aliases.insert(serverID) }
        return aliases
    }

    /// Reverse index of the checkpoint: the id the server gave a record → the id it is keyed by
    /// here. `uniquingKeysWith` keeps the first, matching `checkpointedRecord`'s own `.first` —
    /// two records sharing a `syncedServerID` would need the server to reissue an id.
    private func localIDsByCheckpointedServerID() -> [UUID: UUID] {
        Dictionary(
            pendingCreates.values.compactMap { record in record.syncedServerID.map { ($0, record.localID) } },
            uniquingKeysWith: { first, _ in first })
    }

    /// One read for a whole listing rather than a `draftStore.draft(for:)` per row: these are
    /// main-actor list paths, and the first read after any draft write decodes every body.
    private func draftTitlesByDocument() -> [UUID: String] {
        Dictionary(
            draftStore.allDrafts().map { ($0.documentID, $0.title) }, uniquingKeysWith: { _, latest in latest })
    }

    private func listedLocalDocument(_ create: PendingDocumentCreate, draftTitles: [UUID: String]) -> Document {
        var document = localDocument(from: create)
        if let draftTitle = draftTitles[create.localID],
            !draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            document.title = draftTitle
        }
        return document
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
        for documentID in present {
            syncBackupExclusion(for: documentID)
        }
    }

    /// Whether any document created on this device is filed under this one **and would be
    /// deleted with it** — the question the delete confirmation asks.
    ///
    /// That is narrower than "has local children", and it has to be. A sub-page created offline
    /// under an ordinary **server** document is an ordinary record too — `addSubpage` mints one
    /// whenever the POST fails retryably (with the native editor on, only if a server setup is
    /// saved) — but deleting that server document takes *neither* cascade branch in
    /// `discardPendingWork`, so the sub-page survives and the replay's probe eventually re-roots
    /// it into Home. Announcing a deletion there would put a false sentence in a destructive
    /// confirmation. So this resolves the id the way the cascade does, and answers false wherever
    /// the cascade would not run.
    ///
    /// Both ids, because the two are used at different moments in a record's life: a sub-page
    /// names its parent's `localID`, but once that parent is checkpointed
    /// `pendingLocalDocuments` withholds the local row and the user meets — and deletes — the
    /// document under its *server* id.
    ///
    /// Direct children only: a grandchild implies a child, so the copy is right either way.
    ///
    /// Three shapes answer true where the cascade in fact takes nothing, all benign — and all
    /// in the over-warning direction, which is the safe one for a destructive confirmation.
    ///
    ///  - The checkpointed branch declines to cascade while an editor holds the local id. Note
    ///    what it does **not** decline: the server document has already been deleted by the time
    ///    `discardPendingWork` runs, since `OptionsViewModel.delete` takes the plain server path
    ///    for a server id. What it declines is dropping the *record*, which restarts instead —
    ///    so the still-open screen's document re-POSTs as a fresh create carrying its body and
    ///    its sub-pages. Nothing is lost, but by the restart, not by a delete that did happen.
    ///  - A sub-page whose own editor is open is promoted out of the subtree rather than
    ///    deleted, so a subtree of exactly one such child warns and then takes nothing.
    ///  - A sub-page minted against a checkpointed parent's **server** id is covered by neither
    ///    this nor the cascade, the same residual as the plain server parent above.
    func hasPendingLocalChildren(documentID: UUID) -> Bool {
        let localID: UUID
        if isPendingCreate(documentID: documentID) {
            localID = documentID
        } else if let checkpointed = anyCheckpointedRecord(forServerID: documentID) {
            localID = checkpointed.localID
        } else {
            return false
        }
        return pendingCreates.values.contains { $0.parentID == localID }
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
    ///
    /// **Unscoped, like `isPendingCreate` and unlike the two listings** — it matches on
    /// `parentID` alone, with no owner or origin test. Safe because the relation it follows can
    /// only be built by `createLocalDocument`, which stamps the minting session's own account on
    /// the child: a record belonging to someone else cannot name one of this session's local ids
    /// as its parent. Scoping it would be worse than redundant, since a record it then declined
    /// to visit would be left naming a parent this call is about to remove — the dangling-record
    /// re-root the cascade exists to prevent.
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
    /// no level keyed by a dead id, and Home asks for `nil`) yet still holds a full document body.
    ///
    /// **Every record goes in one write — the root's included — and only then the drafts.**
    /// That single write is what stops a partial subtree existing (see `removePendingCreates`);
    /// taking the root out separately would reintroduce it, since a crash in between leaves the
    /// document the user deleted still holding a record that replays it back onto the server.
    /// Record-before-draft is then the same ordering `discardPendingWork` already uses for the
    /// document itself: a draft left with no record is inert (only hitting 404 and marking failed
    /// if synced), where a record left with no draft POSTs an empty document under its mint title.
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
            clearFailure(documentID)
            removeDraft(documentID: documentID)
            // The draft that referenced them is going, so nothing would ever collect these.
            discardPendingAttachments(documentID: documentID)
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
            syncBackupExclusion(for: documentID)
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

    func hasWritableOpenEditorForTesting(documentID: UUID) -> Bool {
        hasWritableOpenEditor(documentID: documentID)
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

    /// Where a locally-created document currently sits — nil for one at the top level, and nil
    /// too when there is no record, which is the same answer every caller wants for a document
    /// this store knows nothing about.
    ///
    /// The move picker asks so it can tell "already at the top level" (nothing to promote)
    /// from "filed under something" without needing a `depth` the server has never assigned.
    func pendingCreateParentID(forLocalID localID: UUID) -> UUID? {
        pendingCreates[localID]?.parentID
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
        syncBackupExclusion(for: record.localID)
    }

    // MARK: - Queued photos

    /// Store a picked photo and mint the placeholder its block will carry, or nil if the bytes
    /// could not be written — in which case nothing was queued and the caller must not insert a
    /// block, since a placeholder naming no bytes can never resolve.
    ///
    /// **Bytes before the record**, so a crash between the two leaves an orphaned file (inert,
    /// collected by the pass) rather than a record whose photo does not exist. Kicks the funnel
    /// because a photo queued while the network is *up* — an upload that failed transiently —
    /// has no reconnect edge coming to start it.
    func queuePendingAttachment(documentID: UUID, ownerUserID: UUID, jpegData: Data) -> String? {
        guard !attachmentStore.holdsUnreadableData else { return nil }
        let localID = UUID()
        guard attachmentStore.saveData(jpegData, for: localID) else { return nil }
        updatePendingAttachment(
            PendingAttachment(
                localID: localID, documentID: documentID, createdAt: Date(),
                serverOrigin: serverOrigin, ownerUserID: ownerUserID))
        Task { await syncPendingDrafts() }
        return pendingAttachmentPlaceholderURL(for: localID)
    }

    func pendingAttachment(localID: UUID) -> PendingAttachment? {
        pendingAttachments[localID]
    }

    func pendingAttachmentData(localID: UUID) -> Data? {
        attachmentStore.data(for: localID)
    }

    /// Clear a terminal failure so the next pass tries the upload again — the user's answer to
    /// the failed state, alongside removing the image.
    func retryPendingAttachment(localID: UUID) {
        guard var record = pendingAttachments[localID], record.failedAt != nil else { return }
        record.failedAt = nil
        updatePendingAttachment(record)
        Task { await syncPendingDrafts() }
    }

    /// Drop a queued photo and its bytes — the user removed the image, or the insert that would
    /// have referenced it failed.
    func discardPendingAttachment(localID: UUID) {
        guard pendingAttachments[localID] != nil else { return }
        removePendingAttachment(localID: localID)
    }

    /// Drop every queued photo for a document, bytes included. Used where the body that named
    /// them is being thrown away, so nothing would ever collect them.
    /// Only this session's account's records on this server (review Y2): another account's copy of
    /// the same document keeps its photos, as `isAttachmentReplayable` keeps them dormant.
    func discardPendingAttachments(documentID: UUID) {
        let owner = signedInUser.userID
        let localIDs = pendingAttachments.values.filter {
            $0.documentID == documentID && owner != nil && $0.ownerUserID == owner
                && ($0.serverOrigin == serverOrigin || $0.serverOrigin == client.serverOrigin)
        }.map(\.localID)
        guard !localIDs.isEmpty else { return }
        attachmentStore.remove(localIDs: localIDs)
        for localID in localIDs { pendingAttachments[localID] = nil }
        pendingAttachmentsVersion += 1
        syncBackupExclusion(for: documentID)
    }

    /// Whether any queued photo names this document — what the funnel kick and the editor's
    /// affordances key off.
    func hasPendingAttachments(documentID: UUID) -> Bool {
        pendingAttachments.values.contains { $0.documentID == documentID }
    }

    // MARK: - Native media queue (PR13b)

    /// The app's replica registry: a native upload commits through a headless lease of it, so it
    /// lands whether or not its editor is still open. Nil (tests, previews): native records wait.
    weak var nativeSessions: NativeSessionRegistry?
    /// `SignInGenerationClock.isCurrent` (RootView): a native upload is bound to the sign-in
    /// generation its run started in, checked when each request is built (PR13a review V1/W1).
    var signInIsCurrent: (() -> @Sendable () -> Bool)?
    /// The headless commit's retry budget while the block is busy (tests shorten it).
    var nativeCommitAttempts = 50
    var nativeCommitInterval: Duration = .milliseconds(100)
    /// The native editor switch, one input of the headless typing gate (review X2; tests set it).
    var nativeEditorEnabled: @MainActor () -> Bool = { NativeEditorPreference.isEnabled() }
    /// The largest replayed file (review X4): the picker's own limit, so bytes on disk are never
    /// read past what a pick could have stored (tests shorten it).
    var nativeAttachmentByteLimit = attachmentImportByteLimit
    /// Native records whose run is under way: one runner per record, so a pass and a queue kick
    /// never upload the same bytes twice.
    private var nativeRuns: Set<UUID> = []
    /// Native records a run left behind for a later pass (offline, a gate, a busy block): their
    /// cards say they wait rather than upload (review Y3). In memory: a relaunch runs them anyway.
    private(set) var nativeWaiting: Set<UUID> = []

    /// Queues a native media upload (PR13b), online or offline alike: bytes, then the record, then
    /// the run starts at once. Nil when nothing was queued (the store is unreadable, the bytes did
    /// not write, or the scope is not this session's).
    @discardableResult
    func queueNativeAttachment(scope: ReplicaScope, target: NativeMediaTarget, data: Data) -> UUID? {
        guard !attachmentStore.holdsUnreadableData, scope.serverOrigin == client.serverOrigin,
            scope.ownerUserID == signedInUser.userID, scope.org == target.org
        else { return nil }
        let localID = UUID()
        guard attachmentStore.saveData(data, for: localID) else { return nil }
        updatePendingAttachment(
            PendingAttachment(
                localID: localID, documentID: scope.documentID, createdAt: Date(), serverOrigin: scope.serverOrigin,
                ownerUserID: scope.ownerUserID, native: target))
        let isCurrent = signInIsCurrent?()
        Task { await runNativeAttachment(localID, isCurrent: isCurrent) }
        return localID
    }

    /// The newest native record for media block `blockID` of `scope`'s document: what its card
    /// and inspector show (waiting or failed). Only `scope`'s account's records (review X5).
    func nativeAttachment(scope: ReplicaScope, blockID: String) -> PendingAttachment? {
        nativeAttachments(scope: scope).last { $0.native?.blockID == blockID }
    }

    /// Every native record of `scope`'s account for its document, oldest first.
    func nativeAttachments(scope: ReplicaScope) -> [PendingAttachment] {
        pendingAttachments.values.filter { $0.native != nil && $0.nativeScope == scope }
            .sorted(by: orderedByAttachmentCreation)
    }

    /// Runs `scope`'s waiting native records now: an editor began typing into the document, so a
    /// record held back because nothing could write it may land.
    func replayNativeAttachments(scope: ReplicaScope) {
        guard !isPendingCreate(documentID: scope.documentID) else { return }
        let isCurrent = signInIsCurrent?()
        for record in nativeAttachments(scope: scope) where record.failedAt == nil {
            Task { await runNativeAttachment(record.localID, isCurrent: isCurrent) }
        }
    }

    /// May this native record be sent or committed now? Its server and the remembered account.
    private func isNativeReplayable(_ record: PendingAttachment) -> Bool {
        record.native != nil && record.serverOrigin == client.serverOrigin && record.ownerUserID != nil
            && record.ownerUserID == signedInUser.userID
            && !isPendingCreate(documentID: record.documentID)
    }

    /// One native record's replay, two-phase like the classic one: the slot checked headlessly
    /// (a block deleted, retyped or filled meanwhile drops the record before anything is sent),
    /// the upload, the URL **checkpointed** before any commit, then the headless commit, whose slot
    /// check decides commit or drop. A death anywhere resumes from the record: before the
    /// checkpoint it uploads again (no idempotency key exists), after it only commits, and a commit
    /// that landed before the record went is refused by its own slot (the url changed), so a block
    /// never gets a second photo.
    private func runNativeAttachment(_ localID: UUID, isCurrent: (@Sendable () -> Bool)?) async {
        guard !nativeRuns.contains(localID) else { return }
        nativeRuns.insert(localID)
        nativeWaiting.remove(localID)
        defer {
            nativeRuns.remove(localID)
            if let left = pendingAttachments[localID], left.failedAt == nil { nativeWaiting.insert(localID) }
        }
        guard let record = pendingAttachments[localID], let target = record.native, record.failedAt == nil,
            isNativeReplayable(record), isCurrent?() != false
        else { return }
        // Read before any await: a sign-out that clears the attachment cache meanwhile refuses the seed below.
        let attachmentGeneration = attachmentCache.generation
        var resolved = record.uploadedURLString
        var uploadedBytes: Data?
        if resolved == nil {
            switch await nativeLease(nil, record, isCurrent: isCurrent) {
            case .gone: return removeNativeAttachment(localID)
            case .matches: break
            case .committed, .unavailable: return
            }
            // Never read past the picker's limit (review X4): a file grown or planted on disk fails.
            guard let size = attachmentStore.byteCount(for: localID), size <= nativeAttachmentByteLimit,
                let bytes = attachmentStore.data(for: localID), bytes.count <= nativeAttachmentByteLimit
            else { return markAttachmentFailed(localID: localID) }
            uploadedBytes = bytes
            // Re-read after the await: a delete, a discard or a sign-out may have come between.
            guard pendingAttachments[localID] != nil, isNativeReplayable(record) else { return }
            let upload = client.mediaUploader(
                maxAttempts: mediaCheckMaxAttempts, retryInterval: mediaCheckRetryInterval, isCurrent: isCurrent)
            let answered: String?
            do {
                answered = try await upload(record.documentID, target.fileName, target.contentType, bytes)
            } catch let error as DocsAPIError {
                // Transient (offline, a 5xx, an expired session): the next pass carries it.
                if retryableSaveFailure(error) || error == .sessionExpired { return }
                return markAttachmentFailed(localID: localID)
            } catch {
                // A sign-in switch refused the request: nothing was sent.
                return
            }
            guard let url = answered, isDocumentMediaURL(url, documentID: record.documentID) else {
                return markAttachmentFailed(localID: localID)
            }
            guard var checkpointed = pendingAttachments[localID] else { return }
            checkpointed.uploadedURLString = url
            updatePendingAttachment(checkpointed)
            resolved = url
        }
        guard let url = resolved, pendingAttachments[localID] != nil, isNativeReplayable(record), isCurrent?() != false
        else { return }
        // Checked again right before the commit (review X3): a checkpoint restored from disk is
        // only as trustworthy as the disk.
        guard isDocumentMediaURL(url, documentID: record.documentID) else {
            return markAttachmentFailed(localID: localID)
        }
        // Seed the attachment cache for uploaded videos before committing the lease
        // so the open editor extracts posters locally with zero extra download.
        if target.slot.node == "video",
            let display = parseAttachmentLink("[video](\(url))", serverOrigin: client.serverOrigin),
            let bytes = uploadedBytes ?? attachmentStore.data(for: localID)
        {
            _ = attachmentCache.store(bytes, for: display, ifGeneration: attachmentGeneration)
        }
        let props = [
            ProjectedProp(key: "name", value: .string(target.fileName)), ProjectedProp(key: "url", value: .string(url)),
        ]
        switch await nativeLease(props, record, isCurrent: isCurrent) {
        case .committed, .gone: removeNativeAttachment(localID)
        case .matches, .unavailable: break
        }
    }

    private func removeNativeAttachment(_ localID: UUID) {
        guard pendingAttachments[localID] != nil else { return }
        removePendingAttachment(localID: localID)
    }

    /// The headless lease for `record`'s block; without a registry nothing is decided.
    private func nativeLease(
        _ props: [ProjectedProp]?, _ record: PendingAttachment, isCurrent: (@Sendable () -> Bool)?
    ) async -> NativeSessionRegistry.MediaCommit {
        guard let registry = nativeSessions, let target = record.native, let scope = record.nativeScope else {
            return .unavailable
        }
        return await registry.commitMedia(
            props, into: target.blockID, expecting: target.slot, scope: scope, store: replicaStore,
            attempts: nativeCommitAttempts, interval: nativeCommitInterval,
            mayWrite: { [weak self] in await self?.nativeMayWrite(scope, isCurrent: isCurrent) ?? false }
        ) { [weak self, weak registry] in
            NativeReplicaSaveScheduler(
                enqueue: { try self?.enqueueNativeReplica(scope) ?? false },
                onFailure: { error in
                    for surface in registry?.surfaces(of: scope) ?? [] { surface.freezeAuthoring() }
                    self?.noteReplicaCaptureFailure(documentID: scope.documentID, error: error)
                })
        }
    }

    /// Only this server's media URL for this very document is ever written.
    private func isDocumentMediaURL(_ url: String, documentID: UUID) -> Bool {
        guard let display = parseAttachmentLink("[file](\(url))", serverOrigin: client.serverOrigin) else {
            return false
        }
        return display.documentUUID.lowercased() == documentID.uuidString.lowercased() && MediaBlock.isAuthoredURL(url)
    }

    /// The editor open's typing gate, for a headless journal (review X2, Y1, Y3): the native
    /// switch, `mayType`'s holds (no pending create or delete, no live owner, no classic draft),
    /// and `abilities.update`:
    /// - a scope the server said this account only reads (`noteNativeReader`, or this check's own
    ///   answer) is refused offline, whatever a cache says, until the server says otherwise;
    /// - online, the server is asked once (`documents/{id}/`, bound to the run's sign-in
    ///   generation), so a document outside the Home lists (a folder, a deep link) commits too;
    /// - a 403, an API 404 or an answer naming another document is a denial, remembered the same
    ///   way; a missing route, an unreadable body, a timeout, a 5xx, offline or an expired session
    ///   is no answer (review R1), so a writer is never made a reader by a rollout's HTML 404;
    /// - with no answer, the account's own Home lists decide; unknown is no, and the record waits.
    /// The session's `canType` is the lease's.
    private func nativeMayWrite(_ scope: ReplicaScope, isCurrent: (@Sendable () -> Bool)?) async -> Bool {
        let documentID = scope.documentID
        func holds() -> Bool {
            nativeEditorEnabled() && signedInUser.userID == scope.ownerUserID
                && !isPendingCreate(documentID: documentID)
                && !isPendingDelete(documentID: documentID) && !isLiveHeld(documentID: documentID)
                && (draftStore.draft(for: documentID).map { $0.replica != nil } ?? true)
        }
        guard holds() else { return false }
        let answer: Bool?
        do {
            let document = try await DocsAPIClient.$saveIsCurrent.withValue(isCurrent) {
                try await client.document(documentID: documentID)
            }
            // Another document's answer says nothing about this one: a denial (review Z3).
            answer = DocumentAbilityAnswer.classify(document, asked: documentID).writer
        } catch {
            // A 403 or an API 404 is the server's answer about the document (review Z1); a
            // missing route, an unreadable body, a timeout, a 5xx, offline or an expired
            // session is no answer at all (review R1).
            answer = DocumentAbilityAnswer.classify(error).writer
        }
        // Re-read after the await: a sign-out, a delete or a reader answer may have come between.
        guard holds(), isCurrent?() != false else { return false }
        if let answer {
            if answer { clearNativeReader(scope) } else { noteNativeReader(scope) }
            return answer
        }
        // Offline: a remembered reader is no; only the account's own Home lists may say yes
        // (review Z1: the subpage cache is neither account- nor origin-scoped).
        guard !isNativeReader(scope) else { return false }
        return listCache.documents(fetchedFor: scope.ownerUserID).first { $0.id == documentID }?.abilities.update
            == true
    }

    private static let nativeReadersKey = "dev.llun.Schrift.nativeMediaReaderScopes"

    /// The server said this account may only read `scope`'s document (an editor's reader answer,
    /// or the headless gate's): no headless media commit writes it until the server says it may.
    /// Persisted, so an offline relaunch never trusts a stale cached `update: true`.
    func noteNativeReader(_ scope: ReplicaScope) {
        // An authoritative denial ends the scope's shared writability too (review Z2b): every
        // surface stops writing, as an editor's own reader answer makes it (`becomeReader`).
        nativeSessions?.setWritable(nil, for: scope)
        nativeSessions?.liveBinding(for: scope, create: false)?.disconnect()
        guard let key = try? scope.directoryName() else { return }
        var readers = Set(listCache.userDefaults.stringArray(forKey: Self.nativeReadersKey) ?? [])
        guard readers.insert(key).inserted else { return }
        listCache.userDefaults.set(Array(readers), forKey: Self.nativeReadersKey)
    }

    func clearNativeReader(_ scope: ReplicaScope) {
        guard let key = try? scope.directoryName(),
            let readers = listCache.userDefaults.stringArray(forKey: Self.nativeReadersKey), readers.contains(key)
        else { return }
        listCache.userDefaults.set(readers.filter { $0 != key }, forKey: Self.nativeReadersKey)
    }

    func isNativeReader(_ scope: ReplicaScope) -> Bool {
        // An unreadable scope digest is treated as a reader: fail closed.
        guard let key = try? scope.directoryName() else { return true }
        return listCache.userDefaults.stringArray(forKey: Self.nativeReadersKey)?.contains(key) == true
    }

    /// The headless save: what `NativeEditorOpen.installTyping`'s scheduler hands over, without an
    /// editor. The title is the server copy on disk (the save PATCHes it, so it is never guessed):
    /// with none known the journal stays on the device and the next editor open hands it over.
    private func enqueueNativeReplica(_ scope: ReplicaScope) throws -> Bool {
        guard signedInUser.userID == scope.ownerUserID else { return false }
        let cached = contentCache.content(for: scope.documentID)
        let draft = draftStore.draft(for: scope.documentID)
        guard let title = cached?.title ?? draft?.title ?? knownServerTitles[scope.documentID] else { return false }
        try enqueueReplica(
            adapter: ReplicaSaveAdapter(store: replicaStore, scope: scope), title: title,
            baseline: draft?.baseline
                ?? cached.map {
                    DraftBaseline(serverUpdatedAt: $0.serverUpdatedAt, markdown: $0.markdown, title: $0.title)
                })
        return true
    }

    /// Moves queued photos back onto the id their page now lives under (a take-back of a create
    /// the server lost). Left on the dead server id, a native one's commit would find no replica,
    /// answer `.gone` and delete the bytes; a classic one would upload to a document that is gone.
    /// Only the page owner's records on this server: another account may have queued a photo on
    /// the same shared server id, and moving it would strand it under a page it cannot see. Called
    /// before the server-id draft is removed, so a death between the two leaves both on disk.
    private func rekeyAttachments(from oldID: UUID, to newID: UUID, ownerUserID: UUID?) {
        guard let ownerUserID else { return }
        let owned = pendingAttachments.values.filter {
            $0.documentID == oldID && $0.ownerUserID == ownerUserID && $0.serverOrigin == client.serverOrigin
        }
        for var attachment in owned {
            attachment.documentID = newID
            // Both answered the dead document: its media URL cannot be committed into the next
            // one the re-POST makes, and its 404 says nothing about that one.
            attachment.uploadedURLString = nil
            attachment.failedAt = nil
            updatePendingAttachment(attachment)
        }
    }

    private func updatePendingAttachment(_ record: PendingAttachment) {
        attachmentStore.save(record)
        pendingAttachments[record.localID] = record
        pendingAttachmentsVersion += 1
        syncBackupExclusion(for: record.documentID)
    }

    private func removePendingAttachment(localID: UUID) {
        let documentID = pendingAttachments[localID]?.documentID
        attachmentStore.remove(localID: localID)
        pendingAttachments[localID] = nil
        pendingAttachmentsVersion += 1
        if let documentID {
            syncBackupExclusion(for: documentID)
        }
    }

    /// May this record be uploaded or collected in this session? Same shape as
    /// `belongsToSession` for creates, and fails closed on an unknown owner for the same reason:
    /// origin identifies the *server*, not the account, and records survive sign-out.
    ///
    /// A record failing this is **kept, silent, and untouched** — not uploaded, and crucially not
    /// collected. Dormant means no requests *and* no deletion; collecting another account's
    /// record would delete the only copy of their photo.
    private func isAttachmentReplayable(_ record: PendingAttachment, currentUserID: UUID?) -> Bool {
        guard record.serverOrigin == serverOrigin, let owner = record.ownerUserID else { return false }
        return owner == currentUserID
    }

    /// Whether anything this device holds still names this photo — the draft, a parked save, or
    /// a save on the wire. What decides whether collecting the record would strand a placeholder.
    private func referencesPendingAttachment(_ record: PendingAttachment) -> Bool {
        // Every account's draft: collecting a photo another account's draft still names would
        // strand its placeholder.
        let drafts = draftStore.allDraftsOfEveryAccount().filter { $0.documentID == record.documentID }
        let bodies =
            drafts.map(\.markdown)
            + [queued[record.documentID]?.markdown, inFlightContent[record.documentID]?.markdown].compactMap { $0 }
        return bodies.contains {
            markdownReferencesPendingAttachment($0, localID: record.localID)
        }
    }

    // MARK: - The open-editor registry

    /// Called while an editor for this document is on screen. Balanced by
    /// `releaseOpenEditor`; the create replay skips any document held here.
    func retainOpenEditor(documentID: UUID, isWritable: Bool = true) {
        openEditors[documentID, default: 0] += 1
        if isWritable {
            writableOpenEditors[documentID, default: 0] += 1
        }
    }

    /// Balances `retainOpenEditor`. When the last hold on a *local* document goes, kick the
    /// sync funnel: on iPhone that is the moment popping back makes the document replayable,
    /// and waiting for the next reconnect or foreground would be an arbitrary delay.
    func releaseOpenEditor(documentID: UUID, wasWritable: Bool = true) {
        if wasWritable {
            releaseWritableOpenEditor(documentID: documentID)
        }
        guard let held = openEditors[documentID] else { return }
        if held <= 1 {
            openEditors[documentID] = nil
            // The local id — the ordinary case. Also the **server** id of a checkpointed
            // record: once checkpointed the local row is withheld and the user meets the
            // document under its real id, which is exactly the editor `finishMigration`'s
            // `serverID` guards now defer to. Without this the deferred migration would wait
            // for an unrelated foreground or reconnect.
            // A tombstoned id too: `runDeletePass` defers while an editor holds the document,
            // and popping back is the moment that deferral clears. Without this the deletion
            // would wait for an unrelated foreground or reconnect while its row sat struck
            // through — and on iPad, where the editor is a persistent detail column, closing
            // it is the designed completion path.
            // A queued photo joins the same list: its collection is deferred while an editor is
            // open, and a photo queued while the network was up has no reconnect edge coming.
            if isPendingCreate(documentID: documentID) || anyCheckpointedRecord(forServerID: documentID) != nil
                || isPendingDelete(documentID: documentID) || hasPendingAttachments(documentID: documentID)
            {
                Task { await syncPendingDrafts() }
            }
        } else {
            openEditors[documentID] = held - 1
        }
    }

    func retainWritableOpenEditor(documentID: UUID) {
        writableOpenEditors[documentID, default: 0] += 1
    }

    func releaseWritableOpenEditor(documentID: UUID) {
        guard let held = writableOpenEditors[documentID] else { return }
        if held <= 1 {
            writableOpenEditors[documentID] = nil
        } else {
            writableOpenEditors[documentID] = held - 1
        }
    }

    /// Registered by an editor while it is on screen, so a replay can rewrite its in-memory
    /// blocks in the same turn it rewrites the draft.
    ///
    /// `token` identifies this registration: passing nil removes only that one, so a screen
    /// tearing down cannot clear an observer another screen installed for the same document.
    func setPendingAttachmentRewriteObserver(
        _ observer: (@MainActor (_ placeholderURL: String, _ resolvedURL: String) -> Void)?,
        for documentID: UUID,
        token: UUID
    ) {
        if let observer {
            attachmentRewriteObservers[documentID, default: [:]][token] = observer
        } else {
            attachmentRewriteObservers[documentID]?[token] = nil
            if attachmentRewriteObservers[documentID]?.isEmpty == true {
                attachmentRewriteObservers[documentID] = nil
            }
        }
    }

    private func hasOpenEditor(documentID: UUID) -> Bool {
        (openEditors[documentID] ?? 0) > 0
    }

    private func hasWritableOpenEditor(documentID: UUID) -> Bool {
        (writableOpenEditors[documentID] ?? 0) > 0
    }

    /// How many editor screens have this document open (`retainOpenEditor`).
    func openEditorCount(documentID: UUID) -> Int {
        openEditors[documentID] ?? 0
    }

    /// Any pending record waiting to migrate onto this **server** id, regardless of session.
    /// Used by device-wide protection guards (sweep/delete/move/alias) that must hold across
    /// sign-out or transient identity gaps.
    private func anyCheckpointedRecord(forServerID documentID: UUID) -> PendingDocumentCreate? {
        pendingCreates.values.first { $0.syncedServerID == documentID }
    }

    /// A record waiting to migrate onto this **server** id on the current origin, scoped to the
    /// signed-in account when known. Fails closed when `signedInUser.userID == nil` (cookie
    /// handover or pre-`/users/me/` launch) so classic/live writes and ownership clearing cannot
    /// slip in before identity resolves.
    private func checkpointedRecord(forServerID documentID: UUID) -> PendingDocumentCreate? {
        let currentUserID = signedInUser.userID
        return pendingCreates.values.first {
            $0.syncedServerID == documentID
                && $0.serverOrigin == serverOrigin
                && (currentUserID == nil || $0.ownerUserID == currentUserID)
        }
    }

    /// Whether `documentID` is the server ID of a checkpointed local create for the signed-in
    /// account (or any account when identity is still unknown) and server origin whose migration
    /// onto that server ID has not completed yet.
    func hasCheckpointedCreate(forServerID documentID: UUID) -> Bool {
        _ = pendingCreatesVersion
        _ = pins.revision
        return checkpointedRecord(forServerID: documentID) != nil
    }

    /// A checkpointed record owned by the currently signed-in account on `client.serverOrigin`.
    /// Unlike `checkpointedRecord(forServerID:)` (which fails closed when `signedInUser.userID`
    /// is nil to block writes), display, retry and discard require a known matching owner so
    /// another account's waiting edits are never shown, copied, retried or discarded.
    private func ownedCheckpointedRecord(forServerID documentID: UUID) -> PendingDocumentCreate? {
        guard let currentUserID = signedInUser.userID else { return nil }
        return pendingCreates.values.first {
            $0.syncedServerID == documentID
                && $0.serverOrigin == client.serverOrigin
                && $0.ownerUserID == currentUserID
        }
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
        // Read through on each pass. Draft quarantine now makes this sticky
        // across unrelated healthy writes and launches, until explicit recovery
        // can decode every retained blob. Unknown bodies must never become empty
        // create payloads or let the replay remove their only create records.
        guard !draftStore.holdsUnreadableData else { return }
        // Which account is in front of us. Asked once per pass, and only when there is
        // something to send: `isReplayable` needs it, and this is the layer that *can* await
        // it — the coordinator is constructed long before `/users/me/` returns. A failure
        // (offline, or a server that omits the id) leaves every record unreplayable, which
        // is the correct answer rather than a reason to guess.
        guard let currentUserID = try? await client.currentUser().id, draftsAreScoped(to: currentUserID) else {
            return
        }

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
            //
            // **A parent whose deletion is queued holds its children the same way**, for a
            // reason the local case cannot reach: that parent *is* a real server document, so
            // `POST documents/{serverID}/children/` would succeed — filing a brand-new
            // sub-page into a document that is about to be deleted, which then either takes
            // the child down with it server-side or leaves it orphaned. Waiting costs the
            // sub-page a pass; on the deletion landing, the existing 404-probe re-root path
            // owns whatever is left, exactly as it does for a parent deleted by a co-author.
            if let parentID = record.parentID,
                isPendingCreate(documentID: parentID) || isPendingDelete(documentID: parentID)
            {
                continue
            }
            // **A checkpointed record whose server document is queued for deletion goes no
            // further** — and this is the guard that closes the resurrection path, so it is
            // worth stating exactly. Past this line `replayCreate` takes its *resume* branch:
            // it GETs `formattedContent(syncedServerID)`, and a `.notFound` there is read as
            // "the document is gone", which clears the checkpoint and lets the next pass
            // **re-POST the document from its draft**. A queued deletion makes that 404 not
            // merely possible but expected — our own DELETE may already have landed in a pass
            // that died before its cleanup ran — so without this the user's deletion would
            // reliably undo itself, and the document would come back under a new id with its
            // old body. It is the same resurrection `discardPendingWork`'s server-id branch
            // documents, reached one error over.
            if let serverID = record.syncedServerID, isPendingDelete(documentID: serverID) { continue }
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
            guard draftsAreScoped(to: currentUserID) else { return }
            await replayCreate(record)
        }
    }

    private func replayCreate(_ record: PendingDocumentCreate) async {
        var record = record
        if record.syncedServerID == nil {
            // The draft carries any rename made since the document was minted, so it wins.
            let title = draftStore.draft(for: record.localID)?.title ?? record.title
            let created: Document
            // The POST is about to file this document under `record.parentID`, and the copy
            // held here is written back below — so a local move made during the await would be
            // silently reverted *after* the server had already acted on the old parent.
            // `moveLocalDocument` refuses while this is set, which turns "unlikely" into
            // "unrepresentable" for the price of a set insert.
            createPostsInFlight.insert(record.localID)
            defer { createPostsInFlight.remove(record.localID) }
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
            // The fetch awaited: the drafts read below must still be the record owner's.
            guard draftsAreScoped(to: record.ownerUserID) else { return }
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
            // user's text — and the stranded draft is left failing under a dead id once
            // `runSyncPass` GETs it and takes the same 404. (Note the draft under `serverID` is
            // never covered by the pending-create hold in *either* ordering — that guard is keyed
            // on the local id. What the ordering decides is whether the body is still reachable at
            // all, not whether it is protected from that refusal — the checkpointed window has its
            // own server-id suppression there, and this branch is about the state after the
            // checkpoint is cleared.)
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
            // the checkpoint stays, and the checkpoint is what stops `runSyncPass` marking the
            // `serverID` draft failed. Both bodies survive. Note "retries next pass" means it
            // re-asks, not that it converges: if the document really is gone this re-takes
            // the same 404 on every trigger, indefinitely. That standoff is deliberate —
            // `runCreatePass` will not clear the checkpoint while the draft exists, and
            // `runSyncPass` will not mark the draft failed while the record is checkpointed — and
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
                !mayPredateSave(marker), inFlight[serverID] == nil, !hasWritableOpenEditor(documentID: serverID)
            {
                if let orphanReplica = orphan.replica {
                    let serverScope = orphanReplica.scope
                    let localScope = ReplicaScope(
                        serverOrigin: serverScope.serverOrigin, ownerUserID: serverScope.ownerUserID,
                        org: serverScope.org, documentID: record.localID)
                    if let copied = try? replicaStore.copyReplica(from: serverScope, to: localScope) {
                        let localAdapter = ReplicaSaveAdapter(store: replicaStore, scope: localScope)
                        let prepared = try? localAdapter.prepare()
                        let body = prepared?.markdown ?? orphan.markdown
                        let localRef =
                            prepared?.request.reference
                            ?? ReplicaDraftReference(manifest: copied, markdown: body)
                        saveDraft(
                            PendingDraft(
                                documentID: record.localID, title: orphan.title, markdown: body,
                                updatedAt: orphan.updatedAt, baseline: nil,
                                replica: localRef))
                        rekeyAttachments(from: serverID, to: record.localID, ownerUserID: record.ownerUserID)
                        removeDraft(documentID: serverID)
                        try? replicaStore.remove(for: serverScope)
                        syncBackupExclusion(for: record.localID, scope: localScope)
                        syncBackupExclusion(for: serverID)
                    }
                } else {
                    saveDraft(
                        PendingDraft(
                            documentID: record.localID, title: orphan.title, markdown: orphan.markdown,
                            updatedAt: orphan.updatedAt, baseline: nil))
                    rekeyAttachments(from: serverID, to: record.localID, ownerUserID: record.ownerUserID)
                    removeDraft(documentID: serverID)
                    syncBackupExclusion(for: record.localID)
                    syncBackupExclusion(for: serverID)
                }
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
            // Discharging unconditionally would clear the conflict hold before we know no work
            // survives under `serverID`. The guards below ensure discharge runs only once
            // nothing remains under this id to protect.
            //
            // (Those statements are ~45 lines down, past the three guards and their own
            // rationale. This block is here because it explains why the *branch* ends the way
            // it does; the next paragraph starts a separate argument.)
            //
            // **Do not start over while work survives under the server id.** The checkpoint is
            // the *only* thing keeping that draft out of `runSyncPass`'s 404/403 refusal:
            // `isPendingCreate` is keyed on the local id, so that branch skips it solely because
            // `checkpointedRecord(forServerID:)` answers non-nil. Clearing `syncedServerID`
            // disarms that — and `runSyncPass` runs next in the same pass, takes the same 404,
            // and marks the draft failed while a re-POST mints a separate document.
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
            guard !hasWritableOpenEditor(documentID: serverID) else { return }
            guard draftStore.draft(for: serverID) == nil else { return }
            // **And never while the tombstones are unknown.** This is the one branch that
            // turns a 404 into a re-POST, and with the delete store undecodable we cannot tell
            // this 404 from one caused by the app's own DELETE landing in a pass that died
            // before its cleanup ran — in which case starting over re-creates, under a new id,
            // a document the user deleted. Nothing a later launch can undo. Scoped to this
            // branch rather than the whole resume on purpose: nothing clears the quarantine,
            // so withholding the resume outright would strand every checkpointed record on the
            // install permanently, body safe but server document empty.
            guard !deleteStoreUnreadable else { return }
            // Nothing is left under that id, so the conflict record and any parked save are
            // moot by construction — there is no work left for them to protect.
            queued[serverID] = nil
            clearResolvedConflict(documentID: serverID)
            // **Edit the live record, never the captured copy.** `record` was snapshotted
            // before this branch's two network round trips, and a move landing inside that
            // window re-points the stored one — so writing the copy back would restore the
            // *pre-move* `parentID` along with clearing the checkpoint, silently undoing a move
            // the user was told had landed, and re-POSTing the document at its old location.
            // Where the old parent is since tombstoned it is worse than cosmetic: the record
            // wedges on `runCreatePass`'s parent gate. Same window `migrateCreatedDocument`
            // reads the mirror for.
            guard var live = pendingCreates[record.localID] else { return }
            live.syncedServerID = nil
            // Cleared with the checkpoint it was stamped beside, or a persisted record would
            // carry a `postedTitle` with no `syncedServerID` — which is what its own doc
            // comment says cannot happen.
            live.postedTitle = nil
            live.replayBlockedAt = nil
            live.replayBlockedBuild = nil
            updatePendingCreate(live)
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
        // sync pass would 404 and mark that draft failed. The checkpoint is already persisted, so
        // bailing out on *this* guard is free: the next pass resumes at migration.
        guard !hasOpenEditor(documentID: record.localID) else { return }
        // Same for the account: an identity that changed during the await would read the body as
        // absent and migrate an empty document. The checkpoint waits for the owner's next pass.
        guard draftsAreScoped(to: record.ownerUserID) else { return }
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
        guard !hasWritableOpenEditor(documentID: serverID) else { return }
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
    /// id that the very next sync pass GETs, 404s, and marks failed.
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
        let localOwnership = nativeOwnership(documentID: localID)
        let serverOwnership = nativeOwnership(documentID: serverID)
        if case .unreadable = localOwnership { return }
        if case .unreadable = serverOwnership { return }
        let nativeScopes = [
            draft?.replica?.scope,
            migrated?.replica?.scope,
            queued[localID]?.replicaRequest?.reference.scope,
            localOwnership.scope,
            serverOwnership.scope,
        ].compactMap { $0 }
        if !nativeScopes.isEmpty {
            guard let ownerUserID = record.ownerUserID,
                nativeScopes.allSatisfy({ $0.ownerUserID == ownerUserID })
            else { return }
        }
        if let nativeScope = nativeScopes.first,
            migrateNativeCreatedDocument(
                record, serverID: serverID, scope: nativeScope, draft: draft, migrated: migrated,
                serverTitle: serverTitle, serverUpdatedAt: serverUpdatedAt, serverMarkdown: serverMarkdown,
                document: document)
        {
            return
        }
        // First **non-nil**, not first non-empty — and that distinction is load-bearing if a
        // second draft remover is ever added. `carriedPush` below keys off
        // `draft == nil && queued[localID] == nil`, which concedes that `draft == nil` with
        // `queued` populated is representable; in that shape a present-but-*empty* `queued`
        // would win over a non-empty `migrated`, set `willAdoptServer`, and delete the migrated
        // body. `finishMigration`'s both-drafts guard does *not* cover it, since it keys on
        // draft presence rather than on `queued`.
        //
        // Unreachable today: no remover leaves `queued` populated. A new one that does is the
        // site to watch.
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
        // `.discardServerWins` and raise a false conflict.
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
        // `syncCanonicalMarkdown`, as `draftSyncBodyDecision` compares: a body spelling italic
        // `_x_` against the server's `*x*` is not a divergence. Its emptiness is
        // `canonicalMarkdown`'s (same blocks kept, every non-empty text encodes non-empty).
        let canonicalBody = syncCanonicalMarkdown(body)
        let canonicalServer = syncCanonicalMarkdown(serverMarkdown)
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
        saveDraft(
            PendingDraft(
                documentID: serverID, title: title, markdown: body, updatedAt: Date(),
                baseline: baseline, lastPushedMarkdown: carriedPush))
        removeDraft(documentID: localID)
        // Every per-document map the coordinator keys by id. `queued` matters most: it holds
        // a copy of the user's newest keystrokes. (Hygiene rather than a rescue: for a pending
        // create it always agrees with the draft, since `enqueue` write-ahead-saves from the
        // same `save` it parks and no save is ever in flight to make them diverge — the body
        // chain would find it in the draft either way.) Leaving it behind would strand it under an id
        // nothing will ever push.
        states[localID] = nil
        clearFailure(localID)
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
        if willAdoptServer { removeDraft(documentID: serverID) }
        // **The parent is read from the mirror, not from `record`.** The resume path captures
        // its copy before two network round trips, and a move landing inside that window
        // re-points the stored record — so the captured `parentID` is the *pre-move* placement.
        // Trusting it undoes what `completeDocumentMove` just did: a promoted document is
        // appended back into its old parent's cached level, and one filed under a parent is
        // written back into the persisted recents cache as a root, where a later failed fetch
        // re-seeds Home from it. Same class as the `createPostsInFlight` window, on the branch
        // that flag does not cover; `finishMigration` already re-reads the mirror one guard
        // above for the same reason.
        if let document {
            // `.map` rather than `?.parentID ??`: a **nil parent is the legitimate root
            // value**, so the optional-chained form falls through to the stale copy for
            // exactly the case this exists to fix — a document promoted to the top level
            // during the migration would be filed back under its old parent.
            let liveParentID = pendingCreates[localID].map(\.parentID) ?? record.parentID
            insertIntoListCaches(document, parentID: liveParentID)
        }

        // **Re-key the sub-pages created under this document before the record goes.** They
        // carry its *local* id in their own `parentID` — an id the server has never seen —
        // and `runCreatePass`'s dependency gate is what has kept them unsent. Pointing them
        // at the real id is what opens that gate, and because the pass re-reads every record
        // from the mirror, a parent and its sub-pages replay in the same pass.
        //
        // **Before `removePendingCreate`, and that ordering is the whole safety argument.**
        // Each `updatePendingCreate` is its own whole-store write, so a parent with N sub-pages
        // means N+1 writes and a kill can land between any two of them — the property is not
        // that the window is small, it is that **the record's presence is what gates every
        // child, whatever subset of the rewrites has landed.** So: record still present ⇒ every
        // child is still gated, rewritten or not, and the next pass redoes the migration from
        // the checkpoint; record gone ⇒ the loop ran to completion, so every child names a live
        // server id and `POST documents/{serverID}/children/` is valid, the checkpoint being
        // what proves that document exists. Neither is lossy.
        //
        // The reverse order breaks exactly that: it admits a state where the record is gone
        // while a child still names the dead local id, and nothing gates it any more — it POSTs
        // `documents/{local-uuid}/children/`, 404s, probes the parent, 404s again, and is
        // silently re-rooted. That is the one outcome the gate exists to prevent, so it must
        // not be reachable through a kill either.
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
        // Queued photos are re-keyed here for the same reason and with the same ordering: the
        // create record's presence is what makes `runAttachmentPass` skip them, so while it
        // exists every record naming this document is held whether or not it has been re-keyed
        // yet, and a kill mid-loop simply redoes an idempotent rewrite. Dropping the record first
        // would leave a photo naming a dead local id — a `documents/{local-uuid}/…` upload that
        // 404s — and worse, the collection branch reads the *localID* draft, which the migration
        // removed above, so it would read the record as unreferenced and delete the only copy of
        // the photo.
        //
        // The placeholder names the *attachment's* id, not the document's, so no markdown needs
        // rewriting here: the hold follows the content across the re-key by itself.
        //
        // A native record whose replica has no manifest is a conversion that stopped before its
        // replica existed (an ownership marker alone may remain, which the native branch clears
        // before falling through here): this page migrates classically and its classic draft
        // still names the placeholder, so the record goes back to classic. Left native, its
        // commit would find no replica, answer `.gone` and delete the photo's only copy. Judged
        // per record, not by `nativeScopes`, which was read before that clear.
        for attachment in pendingAttachments.values.filter({ $0.documentID == localID }) {
            let orphanedNative = attachment.nativeScope.map { (try? replicaStore.manifest(for: $0)) == nil } ?? false
            guard orphanedNative else {
                var rekeyed = attachment
                rekeyed.documentID = serverID
                updatePendingAttachment(rekeyed)
                continue
            }
            updatePendingAttachment(
                PendingAttachment(
                    localID: attachment.localID, documentID: serverID, createdAt: attachment.createdAt,
                    serverOrigin: attachment.serverOrigin, ownerUserID: attachment.ownerUserID,
                    uploadedURLString: attachment.uploadedURLString, failedAt: attachment.failedAt))
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
            clearFailure(serverID)
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

    private func finishAdoptedNativeMigration(
        _ record: PendingDocumentCreate, serverID: UUID, serverTitle: String?, document: Document?,
        localScope: ReplicaScope, serverScope: ReplicaScope
    ) {
        let localID = record.localID
        removeDraft(documentID: localID)
        removeDraft(documentID: serverID)
        states[localID] = nil
        clearFailure(localID)
        queued[localID] = nil
        settledSaves[localID] = nil
        lastConfirmedPushMarkdown[localID] = nil
        knownServerTitles[localID] = nil
        knownServerTitles[serverID] = serverTitle
        conflicts[localID] = nil
        contentCache.remove(documentID: localID)
        childrenCache.removeDocument(localID)
        if let document {
            let liveParentID = pendingCreates[localID].map(\.parentID) ?? record.parentID
            insertIntoListCaches(document, parentID: liveParentID)
        }
        for var child in pendingCreates.values.filter({ $0.parentID == localID }) {
            child.parentID = serverID
            updatePendingCreate(child)
        }
        for var attachment in pendingAttachments.values.filter({ $0.documentID == localID }) {
            attachment.documentID = serverID
            updatePendingAttachment(attachment)
        }
        try? replicaStore.remove(for: localScope)
        try? replicaStore.remove(for: serverScope)
        removePendingCreate(documentID: localID)
        clearResolvedConflict(documentID: serverID)
        states[serverID] = .idle
        clearFailure(serverID)
        syncBackupExclusion(for: localID)
        syncBackupExclusion(for: serverID)
        onDocumentMigrated?(document)
    }

    /// Whether a native upload record targets this document. A page whose only content is a
    /// queued photo projects to empty Markdown, so adopting the server would discard its block.
    private func hasNativeAttachment(scope: ReplicaScope) -> Bool {
        pendingAttachments.values.contains { $0.nativeScope == scope }
    }

    private func migrateNativeCreatedDocument(
        _ record: PendingDocumentCreate, serverID: UUID, scope: ReplicaScope,
        draft: PendingDraft?, migrated: PendingDraft?, serverTitle: String?, serverUpdatedAt: Date,
        serverMarkdown: String, document: Document?
    ) -> Bool {
        guard let ownerUserID = record.ownerUserID, scope.ownerUserID == ownerUserID else {
            return true
        }
        let localID = record.localID
        let localScope = ReplicaScope(
            serverOrigin: scope.serverOrigin, ownerUserID: scope.ownerUserID,
            org: scope.org, documentID: localID)
        let serverScope = ReplicaScope(
            serverOrigin: scope.serverOrigin, ownerUserID: scope.ownerUserID,
            org: scope.org, documentID: serverID)
        let localManifest: ReplicaManifest?
        let serverManifest: ReplicaManifest?
        do {
            localManifest = try replicaStore.manifest(for: localScope)
            serverManifest = try replicaStore.manifest(for: serverScope)
        } catch {
            return true
        }
        let sourceScope: ReplicaScope
        if localManifest != nil {
            sourceScope = localScope
        } else if let serverManifest, draft == nil || serverManifest.migratedFromLocalID == localID {
            sourceScope = serverScope
        } else {
            if serverManifest == nil {
                if draft == nil, migrated == nil, queued[localID] == nil {
                    guard replicaStore.clearOwnership(for: localScope),
                        replicaStore.clearOwnership(for: serverScope)
                    else { return true }
                    // Crash after `willAdoptServer` cleared drafts/replicas before removing the
                    // pending-create record: finish dropping the local record and stale markers.
                    finishAdoptedNativeMigration(
                        record, serverID: serverID, serverTitle: serverTitle, document: document,
                        localScope: localScope, serverScope: serverScope)
                    return true
                }
                if draft?.replica == nil, migrated?.replica == nil, queued[localID]?.replicaRequest == nil {
                    guard replicaStore.clearOwnership(for: localScope),
                        replicaStore.clearOwnership(for: serverScope)
                    else { return true }
                    // `createLocalDocument` failed before writing a manifest and fell back to a
                    // classic draft, or a stale manifest-less marker remained: hand off to classic.
                    try? replicaStore.remove(for: localScope)
                    try? replicaStore.remove(for: serverScope)
                    syncBackupExclusion(for: localID)
                    syncBackupExclusion(for: serverID)
                    return false
                }
            }
            return true
        }
        guard let restored = try? replicaStore.restore(for: sourceScope) else { return true }
        let sourceAdapter = ReplicaSaveAdapter(store: replicaStore, scope: sourceScope)
        let sourcePrepared = try? sourceAdapter.prepare()
        let fallbackBody = queued[localID]?.markdown ?? draft?.markdown ?? migrated?.markdown ?? ""
        let sourceMarkdown = sourcePrepared?.markdown ?? fallbackBody

        let localTitle = queued[localID]?.title ?? draft?.title ?? migrated?.title
        let knownToServer = record.postedTitle ?? record.title
        let title =
            if let localTitle, localTitle != knownToServer {
                localTitle
            } else {
                serverTitle ?? localTitle ?? record.title
            }
        let canonicalSource = syncCanonicalMarkdown(sourceMarkdown)
        let canonicalServer = syncCanonicalMarkdown(serverMarkdown)
        let willAdoptServer =
            restored.manifest.outbox.isEmpty && canonicalSource.isEmpty && !canonicalServer.isEmpty
            && !hasNativeAttachment(scope: localScope) && !hasNativeAttachment(scope: serverScope)

        if willAdoptServer {
            if sourceScope != serverScope,
                let serverManifest, serverManifest.migratedFromLocalID != localID,
                !serverManifest.outbox.isEmpty || migrated != nil
            {
                return true
            }
            finishAdoptedNativeMigration(
                record, serverID: serverID, serverTitle: serverTitle, document: document,
                localScope: localScope, serverScope: serverScope)
            return true
        }

        if sourceScope != serverScope {
            if let serverManifest, serverManifest.migratedFromLocalID != localID, migrated != nil {
                return true
            }
            guard let fullState = try? ReplicaSaveAdapter.fullState(restored),
                (try? replicaStore.migrateLocalReplica(
                    from: localScope, to: serverScope, fullState: fullState)) != nil
            else { return true }
        }
        let serverAdapter = ReplicaSaveAdapter(store: replicaStore, scope: serverScope)
        guard let prepared = try? serverAdapter.prepare() else { return true }
        let body = prepared.markdown
        let serverRef = prepared.request.reference
        let canonicalBody = syncCanonicalMarkdown(body)
        let diverged = !canonicalServer.isEmpty && canonicalServer != canonicalBody
        let baseline =
            diverged
            ? DraftBaseline(serverUpdatedAt: nil, markdown: "", title: serverTitle)
            : DraftBaseline(serverUpdatedAt: serverUpdatedAt, markdown: serverMarkdown, title: serverTitle)
        let carriedPush = (draft == nil && queued[localID] == nil) ? migrated?.lastPushedMarkdown : nil

        saveDraft(
            PendingDraft(
                documentID: serverID, title: title, markdown: body, updatedAt: Date(),
                baseline: baseline, lastPushedMarkdown: carriedPush, replica: serverRef))
        removeDraft(documentID: localID)
        states[localID] = nil
        clearFailure(localID)
        queued[localID] = nil
        settledSaves[localID] = nil
        lastConfirmedPushMarkdown[localID] = nil
        knownServerTitles[localID] = nil
        knownServerTitles[serverID] = serverTitle
        conflicts[localID] = nil
        contentCache.remove(documentID: localID)
        childrenCache.removeDocument(localID)
        if let document {
            let liveParentID = pendingCreates[localID].map(\.parentID) ?? record.parentID
            insertIntoListCaches(document, parentID: liveParentID)
        }
        for var child in pendingCreates.values.filter({ $0.parentID == localID }) {
            child.parentID = serverID
            updatePendingCreate(child)
        }
        for var attachment in pendingAttachments.values.filter({ $0.documentID == localID }) {
            attachment.documentID = serverID
            updatePendingAttachment(attachment)
        }
        try? replicaStore.remove(for: localScope)
        removePendingCreate(documentID: localID)
        syncBackupExclusion(for: localID)
        syncBackupExclusion(for: serverID, scope: serverScope)
        defer { onDocumentMigrated?(document) }

        if diverged {
            lastConfirmedPushMarkdown[serverID] = nil
            recordConflict(documentID: serverID, serverUpdatedAt: serverUpdatedAt)
        }
        if !canonicalServer.isEmpty, canonicalServer == canonicalBody {
            clearResolvedConflict(documentID: serverID)
        }
        try? enqueueReplica(adapter: serverAdapter, title: title, baseline: baseline)
        return true
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
        // A POST refused because the sign-in changed was never sent; and after a switch nothing
        // here may judge the record — every outcome below is a stamp or a re-parent.
        guard !(error is CancellationError), draftsAreScoped(to: record.ownerUserID) else { return }
        guard let docsError = error as? DocsAPIError else {
            // Not one of ours (a `CancellationError`, anything a future networking change lets
            // escape). Classify it rather than returning silently, which would be the one exit
            // from this function that leaves the record POSTing on every trigger with nothing
            // recorded. In-memory `.failed`, so a relaunch still retries once.
            markCreateRejected(record, reason: safeErrorSummary(error))
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
                // The parent is **gone** — the one answer that justifies re-parenting, which
                // this pass cannot undo (the old parent is stored nowhere; the user can now
                // re-file the document with Move, but nothing here knows where it belonged).
                // Never a bare 403: an ancestor-access recompute 403s transiently and
                // would 403 the create too, so the pair is one transient seen twice, not
                // corroboration. Same rule the resume path states for the same evidence.
                //
                // Retry as a **root** rather than stranding the content: placement is
                // recoverable by the user, a lost body is not.
                guard pendingCreates[record.localID] != nil, draftsAreScoped(to: record.ownerUserID) else { return }
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
                guard draftsAreScoped(to: record.ownerUserID) else { return }
                markCreateRejected(record, reason: "\(safeErrorSummary(docsError)), parent probe forbidden")
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
            guard draftsAreScoped(to: record.ownerUserID) else { return }
            markCreateRejected(record, reason: safeErrorSummary(docsError))
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
        markCreateRejected(record, reason: safeErrorSummary(docsError))
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
    private func markCreateRejected(_ record: PendingDocumentCreate, reason: String) {
        // Re-read: this runs after the POST await, and a delete during it has already removed
        // the record and reset the state. Writing here would leave a `.failed` entry keyed to
        // an id nothing owns.
        guard pendingCreates[record.localID] != nil else { return }
        markFailed(record.localID, reason: "Create rejected: \(reason)", offersRetry: false)
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
    ///
    /// Any account's: a save on the wire blocks detection whoever started it.
    func hasSaveInFlight(documentID: UUID) -> Bool {
        inFlight[documentID] != nil
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
    ///
    /// `session` is the sign-in the edit was made in (the editor's, captured when it loaded): the
    /// draft is filed under that account, and sent only while it is the one signed in.
    func enqueue(
        documentID: UUID, title: String, markdown: String, baseline: DraftBaseline? = nil,
        editedIn session: SignedInSession? = nil
    ) {
        enqueue(
            documentID: documentID, save: PendingSave(title: title, markdown: markdown), baseline: baseline,
            session: session)
    }

    /// Queue a **live-collaboration full-state snapshot** save. `snapshot` is the Yjs bytes
    /// to write verbatim (yhub on Docs 6, the legacy `"websocket": true` PATCH before it);
    /// `projectedMarkdown` is our replica's render of them and is the value **every**
    /// reconcile/baseline/cache rule keys off — it becomes the write-ahead draft body, the
    /// `lastConfirmedPushMarkdown` stamp on
    /// success, and the content-cache body, exactly as a classic save's markdown does. This
    /// reuses the identical write-ahead draft, enqueue-hold, single-writer, and latest-wins
    /// machinery as the classic `enqueue` (they share the private core below); the only
    /// difference reaches `start`, which sees a non-nil `liveSnapshot` and calls
    /// `saveLiveSnapshot` instead of `saveDocumentContent`.
    ///
    /// Called by `LiveEditingBridge`'s snapshot debounce (C2c wired what C2b built).
    func enqueueLiveSnapshot(
        documentID: UUID, snapshot: Data, projectedMarkdown: String, title: String, baseline: DraftBaseline? = nil,
        editedIn session: SignedInSession? = nil
    ) {
        enqueue(
            documentID: documentID,
            save: PendingSave(title: title, markdown: projectedMarkdown, liveSnapshot: snapshot),
            baseline: baseline, session: session)
    }

    /// Capture only verified durable journal bytes. Old Markdown drafts keep
    /// their classic owner; only an existing raw generation may be advanced.
    /// The shadow is never the caller's: it is the stored draft's verified one,
    /// or projected from the raw revision when there is none or it is older.
    func enqueueReplica(
        adapter: ReplicaSaveAdapter, title: String, baseline: DraftBaseline? = nil, resetRetryBackoff: Bool = true
    ) throws {
        let id = adapter.scope.documentID
        guard adapter.scope.serverOrigin == client.serverOrigin, adapter.scope.ownerUserID == signedInUser.userID
        else { throw ReplicaSaveError.otherServerOrAccount }
        guard !draftStore.holdsUnreadableData else { throw ReplicaSaveError.quarantinedDrafts }
        let previous = draftStore.draft(for: id)
        let (request, markdown): (ReplicaSaveRequest, String)
        if let previous {
            guard let reference = previous.replica, reference.scope == adapter.scope else {
                throw ReplicaSaveError.incompatibleDraft
            }
            (request, markdown) = try adapter.prepare(markdown: previous.markdown, expected: reference)
        } else {
            (request, markdown) = try adapter.prepare()
        }
        // Bounds integrated remote segments too, after the capture verified the
        // files. Compaction keeps revision, generation and every outbox segment,
        // so the captured request stays valid.
        adapter.compactIfNeeded()
        if resetRetryBackoff { resetNativeSaveRetry(documentID: id) }
        enqueue(
            documentID: id,
            save: PendingSave(title: title, markdown: markdown, replicaRequest: request),
            baseline: baseline ?? previous?.baseline)
    }

    /// The shared core of both public entry points. Classic and live saves differ only in the
    /// `PendingSave` handed here (a live save carries `liveSnapshot` bytes and a projected
    /// `markdown`); the draft write, enqueue-hold, and latest-wins logic below are identical.
    private func enqueue(
        documentID: UUID, save: PendingSave, baseline: DraftBaseline?, session: SignedInSession? = nil
    ) {
        let now = signedInSession
        let session = session ?? now
        let owner = save.replicaRequest?.reference.scope.ownerUserID ?? session.owner(now: now)
        let writtenIn = SignedInSession(userID: owner, epoch: session.epoch)
        // A compatibility writer must never replace a raw-owned draft, even
        // if its Markdown shadow is identical or the native switch is off.
        if draftStore.draft(for: documentID, in: writtenIn)?.replica != nil, save.replicaRequest == nil {
            if inFlight[documentID] == nil { states[documentID] = .pendingSync }
            return
        }
        // A successful native save removes its draft, so the draft check above
        // cannot protect a clean replica. The durable owner marker outlives the
        // draft: once it names this document, the classic and live writers must
        // never enqueue for it. Native requests are the only exception.
        if save.replicaRequest == nil, isNativeOwned(documentID: documentID) {
            if inFlight[documentID] == nil { states[documentID] = .pendingSync }
            return
        }
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
            lastConfirmedPushMarkdown[documentID, in: writtenIn]
            ?? draftStore.draft(for: documentID, in: writtenIn)?.lastPushedMarkdown
        let draft = PendingDraft(
            documentID: documentID, title: save.title, markdown: save.markdown, updatedAt: Date(),
            baseline: baseline,
            lastPushedMarkdown: lastPushed,
            // Carry the hold through: `enqueue` rebuilds the whole draft, so omitting this
            // would silently erase a persisted conflict on the next keystroke.
            conflictServerUpdatedAt: conflicts[documentID, in: writtenIn]?.serverUpdatedAt,
            replica: save.replicaRequest?.reference, ownerUserID: owner)
        saveDraft(draft, setAsideIn: owner == nil ? session.epoch : nil)
        // A local document's *displayed* title comes from its draft (`pendingLocalDocuments`
        // overlays it, so a rename shows in lists before the replay lands), and this is the
        // write that changes it. Without the bump, `HomeViewModel`'s memo — keyed on the
        // record version — would keep serving the creation title until an unrelated create or
        // delete happened to move it.
        if isPendingCreate(documentID: documentID) { pendingCreatesVersion += 1 }
        // Another session's edit (a screen left from before a re-login, or one made in a sign-in
        // never named) is kept on disk under its own account and never sent under this one: the
        // sync pass replays it when that account is signed in again. An unnamed sign-in still
        // sends its own edits, as the session in front of us.
        guard owner == nil ? session.epoch == now.epoch : owner == now.userID else {
            // The draft just written is newer than anything that session parked: drop the parked
            // copy, or it would later win over this draft (the editor restores a parked save
            // first, and a release would push it).
            queued[documentID, in: writtenIn] = nil
            if now.userID == nil || owner == nil, inFlight[documentID] == nil { states[documentID] = .pendingSync }
            return
        }
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
        //
        // And a fourth: a **queued deletion**. The screen that deleted the document pops and
        // every fresh editor for it is gated at `load()`, but neither closes this off — a
        // *second, already-loaded* editor never goes through `load()` again. Push a document
        // from Home and again from Search (each tab owns its `NavigationStack`), delete it in
        // one, switch to the other: that view model still has `hasLoadedContent`, has never
        // seen `isDocumentDiscarded`, and its next keystroke would PATCH a document the user
        // deleted. Holding here is what makes `handleDidQueueDelete`'s "nothing can enqueue
        // for a tombstoned id" true rather than merely usually-true. The draft is still
        // written, so the work is on disk either way, and the undo releases the hold.
        //
        // And a fifth: the body still names a photo that has not been uploaded, as the
        // `schrift-attachment://` placeholder its block carries. Pushing that would write a URL
        // no client can resolve into the document every collaborator reads — the web editor
        // included — and the backend's `extract_attachments()` would record it verbatim. The
        // photo's bytes are already on disk beside the draft, so this is the same bargain as
        // every other hold: the work is safe locally, and the attachment replay pass will upload,
        // rewrite the placeholder to the real media URL, and re-enqueue.
        //
        // **Keyed on the content, never on the attachment store.** A save is asked about the
        // markdown it is about to push, so a store that cannot be decoded stalls the replay
        // instead of leaking a placeholder — and every other gate that can reach `start`
        // (`releaseHeldSave`, `finish`'s queued restart) asks the same question of the save it
        // is about to start, which is what makes a document holding *two* queued photos release
        // only once the last one has landed.
        let namesPendingAttachment = markdownReferencesPendingAttachment(save.markdown)
        if isPendingCreate(documentID: documentID) || isPendingDelete(documentID: documentID)
            || conflicts[documentID] != nil || inFlight[documentID] != nil || namesPendingAttachment
            || (save.replicaRequest != nil && isLiveReplicaHeld(documentID))
        {
            queued[documentID] = save
            syncBackupExclusion(for: documentID, scope: save.replicaRequest?.reference.scope)
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
            //
            // A pending attachment likewise — but only when nothing is actually on the wire.
            // This is the first hold that can co-occur with an in-flight save (a pending create
            // never has one, and the conflict invariant forbids it), and stamping
            // unconditionally would report "Saved on this device" while a save really was
            // being sent. `finish` re-parks this slot and stamps it then, which is when the
            // claim becomes true.
            if isPendingCreate(documentID: documentID) || conflicts[documentID] != nil
                || isPendingDelete(documentID: documentID)
                || (inFlight[documentID] == nil && namesPendingAttachment)
                || (save.replicaRequest != nil && inFlight[documentID] == nil && isLiveReplicaHeld(documentID))
            {
                states[documentID] = .pendingSync
            }
            return
        }
        // Latest-wins, and defence in depth for the invariant above: a stale slot parked by a
        // hold that was released some other way must never be resurrected by this save's
        // `finish` and pushed over the newer content.
        queued[documentID] = nil
        syncBackupExclusion(for: documentID, scope: save.replicaRequest?.reference.scope)
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
    /// when the server moved on, the pass records a conflict for the user to resolve.
    ///
    /// Unlike `recoverDrafts()` this is **repeatable**: it is the funnel for the
    /// reconnect, foreground and launch triggers, so it self-guards against
    /// overlapping runs rather than running once per process. An overlapping trigger is
    /// **coalesced, never dropped**: the run in flight may already have passed (and
    /// failed on) the very drafts the new trigger cares about — a reconnect landing
    /// mid-run is exactly that — so returning early would lose it until the next
    /// background→foreground cycle.
    func syncPendingDrafts() async {
        guard !isSyncingDrafts else {
            needsAnotherSyncPass = true
            return
        }
        isSyncingDrafts = true
        defer {
            isSyncingDrafts = false
            let waiters = Array(syncPassWaiters.values)
            syncPassWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        repeat {
            needsAnotherSyncPass = false
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
            // **Deletions first.** A landed DELETE removes its create record, its draft and
            // its cache entries, so running it ahead of the other two means they simply find
            // nothing rather than having to reason about a document that is about to go: both
            // re-read their stores and the mirror at the top of every iteration, so a
            // completion inside this pass is visible to them in the same pass. The reverse
            // order would have `runCreatePass` resume a record the user deleted (the guard
            // catches it, but only by declining to make progress) and `runSyncPass` do a round
            // trip for a document that no longer exists.
            //
            // It shares the funnel for the same reason the create replay does: its own
            // triggers could overlap, and two passes sending the same DELETE would report a
            // 404 to the second, which is indistinguishable from a co-author's delete.
            //
            // Every request of the pass is bound to the sign-in generation it started in, as a
            // save's are: a login writing new cookies meanwhile sends nothing more, and
            // `draftsAreScoped` reads the same clock, so no pass acts on a body or record in the
            // window before the identity store hears of the change.
            let isCurrent = signInIsCurrent?()
            await DocsAPIClient.$saveIsCurrent.withValue(isCurrent) {
                await runDeletePass()
                await syncPendingPins()
                // Before the create pass, so a page this device has not POSTed yet is already a
                // replica when the POST lands and `migrateCreatedDocument` re-keys it natively.
                convertUnsentClassicCreates()
                await runCreatePass()
                // Between the two: a queued photo's upload is what *releases* the attachment hold,
                // so running it here lets the same pass upload, rewrite, and push. It also has to
                // run after the create pass, because a photo in a locally-created document cannot
                // be uploaded until that document has a server id.
                await runAttachmentPass()
                await runSyncPass()
            }
        } while needsAnotherSyncPass
    }

    func setForegrounded(_ foregrounded: Bool) {
        isForegrounded = foregrounded
        if !foregrounded { cancelNativeSaveRetries(resetBackoff: false) }
    }

    func cancelNativeSaveRetries(resetBackoff: Bool = true) {
        for task in nativeRetryTasks.values { task.cancel() }
        nativeRetryTasks.removeAll()
        nativeRetryTokens.removeAll()
        if resetBackoff { nativeRetryAttempts.removeAll() }
    }

    private func resetNativeSaveRetry(documentID: UUID) {
        nativeRetryTasks.removeValue(forKey: documentID)?.cancel()
        nativeRetryTokens[documentID] = nil
        nativeRetryAttempts[documentID] = nil
    }

    private func cancelNativeSaveRetryTask(documentID: UUID) {
        nativeRetryTasks.removeValue(forKey: documentID)?.cancel()
        nativeRetryTokens[documentID] = nil
    }

    private func canRetryNativeSave(documentID: UUID) -> Bool {
        guard isOnline(), isForegrounded, signInIsCurrent?()() ?? true else { return false }
        guard inFlight[documentID] == nil, queued[documentID] == nil else { return false }
        guard conflicts[documentID] == nil,
            !isPendingCreate(documentID: documentID),
            !isPendingDelete(documentID: documentID),
            !isLiveReplicaHeld(documentID)
        else { return false }
        if case .failed = state(for: documentID) { return false }
        guard let draft = draftStore.draft(for: documentID),
            let reference = draft.replica,
            reference.scope.documentID == documentID,
            reference.scope.serverOrigin == client.serverOrigin,
            reference.scope.ownerUserID == signedInUser.userID,
            !markdownReferencesPendingAttachment(draft.markdown)
        else { return false }
        return true
    }

    /// Schedules a bounded exponential backoff retry for a transiently-failed native replica save
    /// while online and foregrounded, honouring `Retry-After` on 429 and respecting all holds.
    private func scheduleNativeSaveRetry(documentID: UUID, error: DocsAPIError) {
        guard canRetryNativeSave(documentID: documentID) else { return }
        let attempt = nativeRetryAttempts[documentID] ?? 0
        let retryAfter: TimeInterval? =
            if case .rateLimited(let seconds) = error { seconds } else { nil }
        let delay = nativeSaveRetryBackoff.delay(attempt: attempt, retryAfter: retryAfter)
        nativeRetryAttempts[documentID] = attempt + 1
        nativeRetryTasks.removeValue(forKey: documentID)?.cancel()
        let sleep = self.sleep
        let isCurrent = signInIsCurrent?()
        let token = UUID()
        nativeRetryTokens[documentID] = token
        nativeRetryTasks[documentID] = Task { [weak self] in
            defer {
                if let self, self.nativeRetryTokens[documentID] == token {
                    self.nativeRetryTasks[documentID] = nil
                    self.nativeRetryTokens[documentID] = nil
                }
            }
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self, self.nativeRetryTokens[documentID] == token else { return }
            guard isCurrent?() ?? true else {
                self.resetNativeSaveRetry(documentID: documentID)
                return
            }
            await self.runNativeSaveRetry(documentID: documentID, token: token)
        }
    }

    private func runNativeSaveRetry(documentID: UUID, token: UUID) async {
        guard canRetryNativeSave(documentID: documentID),
            let draft = draftStore.draft(for: documentID), draft.replica != nil
        else {
            if draftStore.draft(for: documentID)?.replica == nil {
                nativeRetryAttempts[documentID] = nil
            }
            return
        }
        if isSyncingDrafts {
            needsAnotherSyncPass = true
            return
        }
        if let retryError = await replayDraft(draft, isNativeRetry: true) {
            guard !Task.isCancelled, nativeRetryTokens[documentID] == token else { return }
            scheduleNativeSaveRetry(documentID: documentID, error: retryError)
        }
    }

    func syncPendingPins() async {
        await pins.sync { [self] documentID in
            isPendingCreate(documentID: documentID) || isPendingDelete(documentID: documentID)
        }
    }

    func cachedPinRow(for documentID: UUID) -> Document? {
        listCache.document(for: documentID) ?? childrenCache.document(for: documentID)
    }

    // MARK: - Delete replay

    /// Send the deletions queued while the server was out of reach.
    ///
    /// Same shape as `runCreatePass`: a cheap no-work gate before any round trip, one
    /// `/users/me/` for the whole pass, and every record re-read from the mirror after each
    /// await. The account fetch is deliberately **not** shared with the create pass. Hoisting
    /// it into `syncPendingDrafts` would reorder that pass's own gates — it asks only when it
    /// has work, and several tests pin "not even `/users/me/`" — and the case both passes have
    /// work in the same iteration costs exactly one extra GET.
    private func runDeletePass() async {
        let tombstones = deleteStore.allDeletes()
        // Nothing this session could send: a foreign origin, or a tombstone nothing can
        // attribute. Without this every trigger would pay a `/users/me/` forever.
        guard tombstones.contains(where: { $0.serverOrigin == serverOrigin && $0.ownerUserID != nil }) else {
            return
        }
        // A failure leaves every tombstone unsent, which is the correct answer rather than a
        // reason to guess — see `runCreatePass`.
        guard let currentUserID = try? await client.currentUser().id, draftsAreScoped(to: currentUserID) else {
            return
        }

        for snapshot in tombstones {
            // Re-read rather than trusting the snapshot: the loop awaits, and an undo can have
            // landed since. Sending on the stale copy would delete a document the user just
            // asked to keep.
            guard let tombstone = pendingDeletes[snapshot.documentID] else { continue }
            guard draftsAreScoped(to: currentUserID) else { return }
            // **Scoped before the send, not after.** A tombstone belonging to another account
            // must not be sent under this session's cookies: it would very likely take DRF's
            // 403-as-404, which the ladder below reads as "already deleted" and completes —
            // discarding local work for a deletion this session never had the right to make.
            guard tombstone.serverOrigin == serverOrigin, tombstone.ownerUserID == currentUserID else { continue }
            // Every record remover in this file defers to an open editor, and this one removes
            // more than most. The alias is belt and braces: a checkpointed record is withheld
            // from `pendingLocalDocuments` the instant it is checkpointed, so no screen should
            // be holding the local id while a tombstone names the server one — but if one were,
            // `completePendingDelete` would reach `discardPendingWork`'s restart-as-fresh-create
            // arm, which clears the checkpoint and re-POSTs the document the user deleted.
            let localAlias = anyCheckpointedRecord(forServerID: tombstone.documentID)?.localID
            guard !hasOpenEditor(documentID: tombstone.documentID) else { continue }
            if let localAlias, hasOpenEditor(documentID: localAlias) { continue }

            do {
                try await client.deleteDocument(documentID: tombstone.documentID)
            } catch let error as DocsAPIError where error == .notFound {
                // Already gone — the same outcome as a success, and the reason completion is
                // ordered the way it is: a pass that died between the DELETE and its cleanup
                // resumes here, so this is the *expected* second half of a torn completion, not
                // only a co-author having got there first. Fall through.
            } catch let error as DocsAPIError where error == .forbidden {
                // Terminal, and the one outcome that gives the document back. The deletion is
                // not merely delayed — this session may not make it — so keeping the tombstone
                // would strike the row through forever while retrying something that cannot
                // succeed. Local data is untouched: the row returns, un-struck, and the user
                // can try again or leave it. (Silently, for now: there is no notice channel
                // here, the same gap a `.failed` create has.)
                // Not after a switch: a 403 under another account's cookies says nothing about
                // this account's right to delete, and dropping the tombstone is irreversible.
                guard draftsAreScoped(to: currentUserID) else { return }
                dropPendingDelete(documentID: tombstone.documentID)
                unwedgeHeldSave(documentID: tombstone.documentID)
                continue
            } catch {
                // Everything else keeps the tombstone for a later trigger — transport, 5xx,
                // rate limits, an expired session (the re-login sheet is already up), and
                // `.routeNotFound`, which says something about the *server* rather than about
                // this document. Deliberately an explicit ladder rather than
                // `retryableSaveFailure`: that classifier lumps `.notFound`, `.forbidden` and
                // `.routeNotFound` together as "not retryable", and here they are three
                // different outcomes.
                continue
            }
            // The completion and the revival read and remove this account's draft and cached
            // body; after a switch during the DELETE they would touch another's. The tombstone
            // (if it is still there) re-sends next pass and takes the 404 as done.
            guard draftsAreScoped(to: currentUserID) else { return }
            // The DELETE landed (or the document was already gone) — but an undo may have
            // arrived while it was in flight. That race is one request wide and cannot be
            // closed from here: the send is the only suspension point, and both the undo and
            // this re-read are synchronous on the main actor.
            //
            // **Leaving the local side untouched is not enough.** With the tombstone gone,
            // every one of its suppressions is off — and `runSyncPass`, later in this very
            // pass, then finds a draft whose document now 404s (because we just deleted it),
            // passes all of its guards, and marks it failed under a dead id that can never sync.
            // The user pressed "keep this document", not "strand my draft on a deleted page".
            //
            // So the undo is *honoured* instead: the server copy is gone, and the way to keep
            // the content is to create it again. `reviveAsLocalDocument` re-mints it as a
            // document this device owns, carrying the body over, and the create replay POSTs
            // it. That is exactly what the checkpointed path already did for free through its
            // `.notFound` start-over — this gives the plain server document the same recovery.
            guard pendingDeletes[tombstone.documentID] != nil else {
                // **Deliberately does not defer to an open editor**, unlike every other record
                // remover here — deferring is unsafe. The tombstone is already gone, so nothing
                // suppresses `runSyncPass` any more: later in this same pass it GETs a document
                // that now 404s and marks the draft failed under a dead id. Nor does deferring
                // survive a relaunch, where `openEditors` is empty and so is the tombstone, so
                // the revive is never reconsidered and the draft sits failed under a dead id.
                //
                // A screen open on the dead id is torn down by the announcement below
                // (`EditorViewModel.handleDeletionLanded`), so it does **not** keep its
                // in-memory content. What the revived document carries is the draft — or,
                // failing that, the cached body — as read a few lines down, so anything typed
                // since the last autosave flush is in neither. That window is bounded by the
                // autosave debounce and is the accepted price of not stranding the *whole* body
                // under a dead id, which is what deferring costs.
                reviveAsLocalDocument(documentID: tombstone.documentID, ownerUserID: currentUserID)
                continue
            }
            // Re-check the editor holds too, for the same reason the tombstone is re-read: the
            // send is a suspension point, and a screen acquired during it would otherwise send
            // `completePendingDelete` into `discardPendingWork`'s restart-as-fresh-create arm,
            // which keeps the record and clears the checkpoint — and the next create pass then
            // re-POSTs the document the user just deleted. The pre-send guard argues this is
            // unreachable (a checkpointed record is withheld from every listing, so nothing can
            // open its local id); this makes it structural instead of argued, for free.
            guard !hasOpenEditor(documentID: tombstone.documentID) else { continue }
            if let localAlias = anyCheckpointedRecord(forServerID: tombstone.documentID)?.localID,
                hasOpenEditor(documentID: localAlias)
            {
                continue
            }
            completePendingDelete(documentID: tombstone.documentID)
        }
    }

    /// Everything a landed deletion leaves to clean up, in the one order a crash cannot turn
    /// into a loss.
    ///
    /// **The tombstone is removed last.** Every step before it is idempotent, and the DELETE
    /// itself answers 404 the second time — which the ladder above reads as success. So a
    /// crash anywhere in here resumes on the next trigger and finishes the job. The reverse
    /// order has a window in which the deletion is forgotten while the document's draft,
    /// record and cache entries all survive: the row comes back, and a checkpointed record's
    /// resume re-POSTs the document the user deleted. Same argument, and the same direction,
    /// as `migrateCreatedDocument`'s "the record is removed last".
    private func completePendingDelete(documentID: UUID) {
        // `discardPendingWork` first, because it is the one that reasons about the record: it
        // nils `queued` before clearing the conflict (so no parked save is released against a
        // document that is now gone), drops the draft, and — for a checkpointed record met
        // under its server id — cascades the local subtree that went with it. Then the caches,
        // including the document's ghost in every other parent's cached level, or the row
        // survives in the list that was showing it until a revalidation that offline never
        // brings.
        purgeLocalTraces(documentID: documentID)
        dropPendingDelete(documentID: documentID)
        // Last, so a subscriber sees a fully settled state — same rule as `onDocumentMigrated`.
        announceDocumentDeleted(documentID)
    }

    /// A deletion that landed **immediately** — the twin of `completePendingDelete`, minus the
    /// tombstone there is none of.
    ///
    /// Exists because a delete made from a *list* row has no editor to clean up after it. The
    /// editor was the only thing that ever did: `EditorView`'s `onDeleted` called
    /// `handleDidDelete()`, which purged that one screen's caches and ended its session. Every
    /// other surface — Home, Shared, Search, the Pages drawer — learns about a deletion only
    /// through `announceDocumentDeleted`, which until now fired for *queued* deletions alone.
    ///
    /// Two failures follow from omitting it, and the second is the one that costs content: a
    /// **checkpointed** record's document is met from a list under its *server* id, so
    /// `DocumentActions.delete`'s pending-create branch never runs and nothing clears the
    /// create record or its draft — the next resume GETs that id, takes the expected 404,
    /// clears the checkpoint, and the pass after that re-POSTs the document the user deleted.
    /// `purgeLocalTraces` → `discardPendingWork` reaches the `checkpointedRecord(forServerID:)`
    /// branch that closes it.
    ///
    /// Same ordering as its twin: purge first, announce last, so a subscriber sees a fully
    /// settled state. Deliberately **not** folded into `discardPendingWork`, which is also
    /// called by paths where the document is *not* gone from the server (the queued teardown,
    /// the conflict discharge) — announcing there would un-strike a row whose deletion is
    /// still on its way.
    func completeImmediateDelete(documentID: UUID) {
        purgeLocalTraces(documentID: documentID)
        announceDocumentDeleted(documentID)
    }

    /// Everything a landed **move** owes the device — the twin of `completeImmediateDelete`,
    /// and deliberately much narrower than it.
    ///
    /// A move is not a deletion: the document still exists, its body is untouched, and its own
    /// children moved with it in the server's single atomic transaction. So the content cache
    /// and the document's *own* children level (`childrenCache.remove(parentID:)`) must both
    /// stay — purging them would throw away a cached body and a cached subtree that are still
    /// exactly right, and offline the document would go blank for no reason.
    ///
    /// What does change is where the row belongs, and the ordering below is what keeps the two
    /// halves of that from fighting: the sweep runs **before** the insert, so it can never
    /// strip the row that was just filed under the new parent.
    ///
    /// Announced **last**, like both its siblings, so a subscriber sees fully settled caches.
    /// Unlike them there is no crash-recovery sequencing to respect — every step is idempotent
    /// and the server already holds the truth, so a death part-way through is healed by the
    /// next ordinary fetch.
    func completeDocumentMove(documentID: UUID, row: Document?, newParentID: UUID?) {
        pins.documentMoved(documentID: documentID, newParentID: newParentID)
        // **A checkpointed record's `parentID` is not quite inert after all.** The POST has
        // landed, so nothing re-files the document from it — but the pending *migration* still
        // reads it twice: `insertIntoListCaches` would write this document back into the
        // recents cache as a root, undoing the removal below, and `runCreatePass`'s parent gate
        // would hold the migration whenever the *old* parent happens to be tombstoned. Both
        // are stale readings of a placement the server has since changed, so move the record
        // with the document.
        if var checkpointed = anyCheckpointedRecord(forServerID: documentID), checkpointed.parentID != newParentID {
            checkpointed.parentID = newParentID
            updatePendingCreate(checkpointed)
        }
        // The old parent is generally unknown — Home rows carry no parent id, and `Document`
        // models none — so the row is swept from *every* cached level rather than from one we
        // would have to guess. That also clears the stale ghost levels a re-parented document
        // can sit in, and it runs **before** the insert below so it can never strip the row
        // that was just filed under the new parent.
        childrenCache.removeDocument(documentID)
        if let newParentID, let row, var siblings = childrenCache.children(for: newParentID),
            // Unreachable as the two lines stand — the sweep above strips this id from *every*
            // level, this one included — and kept only so that narrowing that sweep later
            // cannot silently start duplicating rows.
            !siblings.contains(where: { $0.id == documentID })
        {
            // Only into a level that has actually been fetched — `insertIntoListCaches`' rule,
            // and for its reason: nil (never fetched) and `[]` (fetched, empty) are read as
            // different everywhere. The row's `depth`/`path` are stale from this moment;
            // neither is read anywhere, and `numchild` is still right because the subtree
            // travelled with it. The next `listChildren` replaces the level wholesale.
            siblings.append(row)
            childrenCache.save(siblings, for: newParentID)
        }
        // Home's feed is fetched without a parent filter, so whether a sub-page appears there
        // is the server's answer to give. What is certain is the direction: a document filed
        // under a parent has left the top level, and one promoted to root has joined it.
        if newParentID == nil {
            if let row { listCache.insertRecentDocument(row) }
        } else {
            listCache.removeRecentDocument(documentID)
        }
        announceDocumentMoved(
            DocumentMoveEvent(documentID: documentID, row: row, newParentID: newParentID))
    }

    /// Re-parent a document the server has never seen.
    ///
    /// Purely local, and that is the whole implementation: rewriting the record's `parentID`
    /// and bumping `pendingCreatesVersion` is enough, because every surface that lists a local
    /// document merges it in at **read** time — `HomeViewModel.recentDocuments` asks for
    /// `parentID: nil`, `EditorViewModel.mergedSubpages` and `PagesTreeViewModel.mergedChildren`
    /// ask for their own level. No fetch, no cache write, no announcement: a synthetic row
    /// exists in no fetched array and in no persisted cache anywhere (`appendChild` filters
    /// them out of the children cache, and `insertIntoListCaches` only ever sees real
    /// documents). Records naming this one as their parent follow it automatically.
    ///
    /// Returns false — changing nothing — when the move must not happen. Each guard is a real
    /// failure, not defensive noise:
    ///
    ///  - **checkpointed** (`syncedServerID != nil`): the POST has landed, so the document the
    ///    user means is the *server* one and the ladder moves that instead. The record's own
    ///    `parentID` is inert from that moment, and rewriting it would be undone by the
    ///    migration anyway;
    ///  - **create POST in flight**: `replayCreate` copies the record before its await and
    ///    writes that copy back afterwards, so a rewrite landing in between is silently lost —
    ///    and lost *after* the POST already filed the document under the old parent;
    ///  - **a local descendant, or itself**: two records naming each other deadlock
    ///    `runCreatePass`'s parent gate for good — each skips because the other is still
    ///    pending — and `pagesTreeRows` would quietly drop one of them to break the cycle. The
    ///    walk resolves a checkpointed server id back to its record, so a cycle cannot hide
    ///    behind that alias;
    ///  - **a tombstoned destination**: filing new work under a document that is on its way to
    ///    being deleted, which is `addPage`'s gate for the same reason.
    @discardableResult
    func moveLocalDocument(documentID: UUID, newParentID: UUID?) -> Bool {
        guard var record = pendingCreates[documentID], record.syncedServerID == nil else { return false }
        guard !createPostsInFlight.contains(documentID) else { return false }
        if let newParentID {
            guard newParentID != documentID, !isPendingDelete(documentID: newParentID) else { return false }
            // Walk up from the destination: if this document is anywhere above it, the move
            // would make a cycle. Iterative and `visited`-guarded like `localDescendantsToDiscard`
            // — this reads decoded data, where the shape is a tree only by construction, and a
            // blob that already holds a cycle must refuse rather than spin.
            var visited: Set<UUID> = []
            var cursor: UUID? = newParentID
            while let current = cursor {
                guard current != documentID, visited.insert(current).inserted else { return false }
                cursor = (pendingCreates[current] ?? anyCheckpointedRecord(forServerID: current))?.parentID
            }
        }
        record.parentID = newParentID
        updatePendingCreate(record)
        return true
    }

    /// Re-mint a document whose deletion the user undid **after** the DELETE had already
    /// landed, so their content survives an outcome nothing on the device could prevent.
    ///
    /// The server copy is gone and its id is dead: no draft under it can ever sync, and
    /// `runSyncPass` would mark it failed under that dead id on this very pass now that the
    /// tombstone no longer suppresses it. Creating the document again is the only reading of
    /// "keep this document" that keeps anything, and the machinery already exists — the
    /// checkpointed path reaches the same place through its `.notFound` start-over.
    ///
    /// Ordering matters for the same reason it does in `migrateCreatedDocument`: the new
    /// draft is written **before** the old one is removed, so the body is never nowhere.
    ///
    /// Two accepted losses, both unavoidable from here: the document comes back as a **root**
    /// (a draft records no parent), and it comes back under a new id, so links to the old one
    /// still point at a document that no longer exists.
    private func reviveAsLocalDocument(documentID: UUID, ownerUserID: UUID) {
        // **A checkpointed record needs none of this, and must not go through it.** Its body
        // still lives under the record's `localID` — the migration has not moved it — so a
        // revive keyed on the *server* id finds nothing, falls through to the purge, and
        // `discardPendingWork`'s checkpointed branch then cascades the local subtree and takes
        // that body with it. The record is also all the machinery this case needs: clearing
        // the checkpoint hands it straight back to `runCreatePass`, which POSTs it fresh under
        // a new server id, exactly as the `.notFound` start-over does. Everything else — the
        // record, its draft, its sub-pages — stays where it is.
        if var checkpointed = anyCheckpointedRecord(forServerID: documentID) {
            checkpointed.syncedServerID = nil
            checkpointed.postedTitle = nil
            updatePendingCreate(checkpointed)
            // The server copy really is gone, so its id-keyed caches are stale. The *local*
            // id's are untouched, which is where this record's content lives.
            contentCache.remove(documentID: documentID)
            childrenCache.remove(parentID: documentID)
            childrenCache.removeDocument(documentID)
            listCache.removeDocument(documentID)
            // And announce, exactly as the other two completions do: this branch knows the
            // server id is dead — it just purged its caches — while every list still holds the
            // row in memory, where the tombstone's removal has just **un-struck** it. Worse
            // here than elsewhere: clearing the checkpoint re-arms `pendingLocalDocuments`, so
            // without this the user sees two rows for one document, a dead server one and a
            // live local one.
            announceDocumentDeleted(documentID)
            return
        }
        // Prefer the draft — it is the user's newest text. The cached body is the fallback for
        // a document deleted without unsaved edits, which still deserves to come back.
        let draft = draftStore.draft(for: documentID)
        // A native draft's Markdown is a lossy shadow. Reviving from it would
        // silently downgrade rich state, so keep the raw replica and draft
        // instead of minting a classic document from the shadow. The raw replay
        // never discards this draft on a 404, so the work survives on disk.
        if draft?.replica != nil { return }
        let cached = contentCache.content(for: documentID)
        let markdown = draft?.markdown ?? cached?.markdown
        guard let markdown else {
            // Nothing to keep — no draft, no cached body. The document is gone and there is
            // no content to carry, so clean up rather than minting an empty document the user
            // never wrote.
            purgeLocalTraces(documentID: documentID)
            return
        }
        let known = draft?.title ?? cached?.title ?? knownServerTitles[documentID] ?? ""
        // Lists render `title ?? untitled` — a **nil** check, not a blank one — so an empty
        // string would come back as a nameless row rather than "Untitled document".
        let title = known.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled document" : known
        // The body is seeded **in the same call that mints the record**, so it is on disk under
        // the new id before the old one is touched. Writing it afterwards left a two-write
        // window in which the body existed only at the old id — whose tombstone the undo has
        // already removed, so a kill there would leave the body stranded and failing under
        // that dead id on the next launch.
        let revived = createLocalDocument(
            title: title, parentID: nil, ownerUserID: ownerUserID, seedMarkdown: markdown)
        purgeLocalTraces(documentID: documentID)
        // Announce it, exactly as a completion does: the old row is still in every list that
        // was showing it and — with the tombstone gone — has just **un-struck** back into
        // looking like a live document, which is the harm `onDocumentDeleted` exists for. The
        // id really is dead here too.
        announceDocumentDeleted(documentID)
    }

    /// Everything keyed by a server id that no longer names a document. Shared by the
    /// completion and the revive, which differ only in whether the content is carried over.
    private func purgeLocalTraces(documentID: UUID) {
        pins.remove(documentID: documentID)
        discardPendingWork(documentID: documentID)
        contentCache.remove(documentID: documentID)
        childrenCache.remove(parentID: documentID)
        childrenCache.removeDocument(documentID)
        listCache.removeDocument(documentID)
    }

    /// Clear the slot the tombstone hold parked, **without sending it**.
    ///
    /// Both paths that clear a tombstone owe this: `runSyncPass` skips any document whose
    /// `queued` slot is non-nil, so a save left parked wedges the document out of the replay
    /// for good — until an unrelated keystroke happens to drain it, which for a document the
    /// user has stopped editing never comes.
    ///
    /// **Deliberately not `releaseHeldSave`**, which goes straight to `start` — a full
    /// overwrite with no reconciliation. (It removes this path's *automatic* overwrite, not
    /// every route to one: the reading surface's "tap to retry" still reaches `saveNow`, which
    /// enqueues straight to `start`. That is the pre-existing last-writer-wins affordance, and
    /// it is at least a deliberate tap rather than a background pass.) Every other release runs behind a proof: the
    /// detection sites fire only on a decided `.push`, and "Keep my version" is an explicit
    /// choice that also advances the baseline. These two have none, and a tombstone survives
    /// launches, so the parked content can be days old: releasing it would let a stale body
    /// overwrite a co-author with no `draftSyncDecision`, no conflict and no pill.
    ///
    /// `enqueue` is write-ahead, so the content is already on disk as a draft. Clearing the
    /// slot simply hands it back to `runSyncPass`, which reconciles it like any other.
    private func unwedgeHeldSave(documentID: UUID) {
        // **Only a slot this hold parked.** With a conflict also recorded the slot belongs to
        // the conflict hold, which is still in force — clearing it there would silently drop
        // the user's pending save while the pill still asks them to choose. The conflict's own
        // resolvers drain it.
        guard conflicts[documentID] == nil else { return }
        guard inFlight[documentID] == nil, queued[documentID] != nil else { return }
        queued[documentID] = nil
        syncBackupExclusion(for: documentID)
        // The state was set to `.pendingSync` by the hold, which is still true — the work is
        // on the device and the replay is what sends it.
    }

    /// Drop a tombstone without touching anything else — the shared tail of a completed
    /// deletion and of the `.forbidden` refusal, which must *not* clean up.
    private func dropPendingDelete(documentID: UUID) {
        deleteStore.remove(documentID: documentID)
        pendingDeletes[documentID] = nil
        pendingDeletesVersion += 1
    }

    /// Upload the photos queued on this device, rewrite each placeholder to the media URL its
    /// upload resolved to, and let the ordinary save machinery push the now-clean body.
    ///
    /// Shares the funnel's coalescing rather than taking triggers of its own — two overlapping
    /// reconnects must never upload the same record twice, and the endpoint has no idempotency
    /// key to make that harmless.
    private func runAttachmentPass() async {
        let records = attachmentStore.allAttachments()
        // Cheap pre-gate before any request at all, mirroring the create pass: a device with
        // nothing sendable must not cost a `/users/me/` round trip.
        guard
            records.contains(where: { ($0.serverOrigin == serverOrigin || $0.native != nil) && $0.ownerUserID != nil })
        else { return }
        // Captured before the identity request: a sign-in switch from here on sends nothing.
        let isCurrent = signInIsCurrent?()
        // With the *drafts* unreadable every reference check answers "no document names this
        // photo", and the collection branch would delete every queued photo's bytes.
        guard !draftStore.holdsUnreadableData else { return }
        // With the *records* unreadable `allAttachments` already answered empty — but a
        // placeholder in a document still needs its record, so refuse rather than let a later
        // write rebuild the store behind it.
        guard !attachmentStore.holdsUnreadableData else { return }
        guard let currentUserID = try? await client.currentUser().id, draftsAreScoped(to: currentUserID) else {
            return
        }

        // Native records run after the classic ones: a blocked commit's retries never delay them.
        var native: [UUID] = []
        for snapshot in records {
            // Re-read after every await: the user can delete the document or discard the photo
            // while an upload is in flight, and acting on a stale copy would resurrect it.
            guard let record = pendingAttachments[snapshot.localID] else { continue }
            guard draftsAreScoped(to: currentUserID) else { return }
            // A native record (PR13b) names no Markdown, so the collection below would delete it:
            // its own run commits or drops it by the block's slot.
            if record.native != nil {
                if record.ownerUserID == currentUserID, !isPendingCreate(documentID: record.documentID) {
                    native.append(record.localID)
                }
                continue
            }
            guard isAttachmentReplayable(record, currentUserID: currentUserID) else { continue }

            // **Collection runs before the failure skip**, or a terminally-failed record whose
            // document was deleted would never be cleaned up. Deferred while an editor is open:
            // that screen may be about to flush a body that still names the photo.
            if !referencesPendingAttachment(record) {
                if !hasWritableOpenEditor(documentID: record.documentID) {
                    removePendingAttachment(localID: record.localID)
                }
                continue
            }
            // Terminal: the server rejected this upload on its merits. The hold stands and the
            // image leaf carries Retry/Remove — this one is the user's to answer.
            if record.failedAt != nil { continue }
            // A photo in a document the server has never seen: the upload would POST to
            // `documents/<local-uuid>/attachment-upload/` and 404. The create replay above sends
            // the document first; this record waits for the pass after it.
            if isPendingCreate(documentID: record.documentID) { continue }

            await replayAttachment(record)
        }
        for localID in native { await runNativeAttachment(localID, isCurrent: isCurrent) }
    }

    /// Two-phase: upload, **checkpoint the resolved URL onto the record**, then rewrite. A death
    /// between the two resumes at the rewrite rather than uploading a second copy — the same
    /// argument `syncedServerID` makes for creates, and for the same reason (no idempotency key).
    private func replayAttachment(_ record: PendingAttachment) async {
        var resolvedURL = record.uploadedURLString
        if resolvedURL == nil {
            guard let bytes = attachmentStore.data(for: record.localID) else {
                // The photo is gone, so nothing can ever resolve this placeholder. Terminal, so
                // the leaf offers Remove rather than the pass retrying forever.
                markAttachmentFailed(localID: record.localID)
                return
            }
            do {
                let mediaCheckPath = try await client.uploadAttachment(
                    documentID: record.documentID, fileName: "photo.jpg",
                    contentType: "image/jpeg", data: bytes)
                resolvedURL = await client.readyMediaURLString(
                    fromMediaCheckPath: mediaCheckPath,
                    maxAttempts: mediaCheckMaxAttempts,
                    retryInterval: mediaCheckRetryInterval)
            } catch let error as DocsAPIError {
                // Transient — including `.sessionExpired`, where the re-login sheet is already up
                // and the next pass carries it. Leave the record for that pass.
                if retryableSaveFailure(error) || error == .sessionExpired { return }
                markAttachmentFailed(localID: record.localID)
                return
            } catch {
                return
            }
            guard let resolved = resolvedURL else {
                markAttachmentFailed(localID: record.localID)
                return
            }
            // The checkpoint, before anything is rewritten. Guarded on the record still being
            // present, so a discard during the upload is not undone.
            guard var checkpointed = pendingAttachments[record.localID] else { return }
            checkpointed.uploadedURLString = resolved
            updatePendingAttachment(checkpointed)
        }
        guard let resolved = resolvedURL, pendingAttachments[record.localID] != nil else { return }
        commitResolvedAttachment(record.localID, documentID: record.documentID, resolvedURL: resolved)
    }

    /// Everything after the upload, in **one synchronous main-actor turn with no awaits**.
    ///
    /// That is the whole safety argument. An editor open on this document can flush at any
    /// suspension point, and its in-memory blocks still name the placeholder — so a rewrite split
    /// across an await could have the draft rewritten and the record removed, and then a flush
    /// re-enqueue the placeholder with no record left to resolve it: a permanent hold whose only
    /// escape is deleting the image. Within one turn that interleaving cannot happen.
    private func commitResolvedAttachment(_ localID: UUID, documentID: UUID, resolvedURL: String) {
        // The upload awaited. With the drafts scoped to anyone but the photo's owner the draft
        // reads as absent, and the record — the only way to resolve its placeholder — would be
        // removed. The uploaded URL is checkpointed, so the owner's next pass finishes this.
        guard draftsAreScoped(to: pendingAttachments[localID]?.ownerUserID) else { return }
        // A Markdown URL rewrite cannot author the corresponding rich update.
        // Keep the attachment record and raw provenance until native media
        // editing owns this operation; never flatten a raw-owned draft.
        guard draftStore.draft(for: documentID)?.replica == nil,
            queued[documentID]?.replicaRequest == nil
        else { return }
        if let draft = draftStore.draft(for: documentID) {
            let rewritten = markdownRewritingPendingAttachment(
                draft.markdown, localID: localID, resolvedURL: resolvedURL)
            if rewritten != draft.markdown {
                // Rewritten **in place**: `enqueue` must stay the only creator of a draft, and
                // every other field — the baseline, the last-pushed stamp, the conflict record,
                // the client timestamp — is reconciliation evidence this pass has no business
                // restating.
                saveDraft(
                    PendingDraft(
                        documentID: documentID, title: draft.title, markdown: rewritten,
                        updatedAt: draft.updatedAt, baseline: draft.baseline,
                        lastPushedMarkdown: draft.lastPushedMarkdown,
                        conflictServerUpdatedAt: draft.conflictServerUpdatedAt))
            }
        }
        // The parked save, if any. Rebuilt **classic**: a live snapshot's CRDT bytes still encode
        // the placeholder and `start` prefers them over the markdown, so carrying them forward
        // would push exactly what the hold exists to prevent.
        if let held = queued[documentID] {
            let rewritten = markdownRewritingPendingAttachment(
                held.markdown, localID: localID, resolvedURL: resolvedURL)
            if rewritten != held.markdown {
                queued[documentID] = PendingSave(title: held.title, markdown: rewritten)
            }
        }
        // The open editor's own copy, so its next flush cannot reintroduce what was just cleared.
        let placeholderURL = pendingAttachmentPlaceholderURL(for: localID)
        for observer in attachmentRewriteObservers[documentID]?.values ?? [:].values {
            observer(placeholderURL, resolvedURL)
        }

        removePendingAttachment(localID: localID)

        // Hand the clean body back to the ordinary machinery. Re-`enqueue` rather than
        // `releaseHeldSave`, for two reasons: `enqueue` re-derives every hold from the content it
        // is given, so a second queued photo, a conflict, or a pending create still parks it
        // correctly; and a document with no parked save at all — a draft left by a previous
        // process — gets pushed rather than waiting for a keystroke that may never come.
        guard let draft = draftStore.draft(for: documentID),
            !markdownReferencesPendingAttachment(draft.markdown)
        else { return }
        enqueue(
            documentID: documentID,
            save: PendingSave(title: queued[documentID]?.title ?? draft.title, markdown: draft.markdown),
            baseline: draft.baseline)
    }

    private func markAttachmentFailed(localID: UUID) {
        guard var record = pendingAttachments[localID], record.failedAt == nil else { return }
        record.failedAt = Date()
        updatePendingAttachment(record)
    }

    private func runSyncPass() async {
        cancelNativeSaveRetries(resetBackoff: false)
        for draft in draftStore.allDrafts() {
            if let retryError = await replayDraft(draft) {
                scheduleNativeSaveRetry(documentID: draft.documentID, error: retryError)
            }
        }
    }

    /// Replays one stored draft against the current server copy (shared by `runSyncPass` on
    /// reconnect/foreground/launch and by the online native-save backoff retry).
    /// Returns a retryable `DocsAPIError` only when a native draft's replay failed before
    /// `enqueueReplica` could start a save, so the caller can continue backoff.
    @discardableResult
    private func replayDraft(_ draft: PendingDraft, isNativeRetry: Bool = false) async -> DocsAPIError? {
        if let reference = draft.replica {
            guard reference.scope.documentID == draft.documentID,
                reference.scope.serverOrigin == client.serverOrigin,
                reference.matches(markdown: draft.markdown),
                reference.formatVersion == ReplicaManifest.currentFormat,
                !draftStore.holdsUnreadableData
            else { return nil }
            if queued[draft.documentID]?.replicaRequest != nil, !isLiveReplicaHeld(draft.documentID) {
                releaseHeldSave(documentID: draft.documentID)
            }
        }
        // A document the server has never seen cannot be reconciled against it: the GET
        // below would 404 and mark the draft failed. The create replay owns these.
        guard !isPendingCreate(documentID: draft.documentID) else { return nil }
        // A document queued for deletion is reconciled with nothing: pushing races our own
        // DELETE, and a 404/403 would mark the draft failed while the deletion is cancellable.
        guard !isPendingDelete(documentID: draft.documentID) else { return nil }
        // A draft still naming an un-uploaded photo cannot be reconciled until attachment
        // replay uploads and rewrites it; reconciling earlier would park or stamp a conflict.
        guard !markdownReferencesPendingAttachment(draft.markdown) else { return nil }
        guard inFlight[draft.documentID] == nil, queued[draft.documentID] == nil else { return nil }
        // A held writable replica sends its own step2 diff, so replaying this markdown could
        // duplicate those Yjs items. The draft waits; the replica's release triggers a new pass.
        guard !isLiveReplicaHeld(draft.documentID) else { return nil }
        // A save that FAILED this session is a retry candidate the user may still
        // be looking at (its draft is their only copy), owned by the reading
        // surface's "Couldn't save · tap to retry". Reconciling it here would
        // race or overwrite that state behind the user's back — skip it.
        if case .failed = state(for: draft.documentID) { return nil }
        // A recorded conflict waits for the user's explicit choice — never push
        // over it and never discard it here.
        if conflicts[draft.documentID] != nil { return nil }
        do {
            if let reference = draft.replica {
                guard try await client.currentUser().id == reference.scope.ownerUserID else { return nil }
                if isNativeRetry {
                    guard !Task.isCancelled, canRetryNativeSave(documentID: draft.documentID) else { return nil }
                }
                guard !isLiveReplicaHeld(draft.documentID), inFlight[draft.documentID] == nil,
                    queued[draft.documentID] == nil, draftStore.draft(for: draft.documentID) == draft,
                    !isPendingCreate(documentID: draft.documentID),
                    !isPendingDelete(documentID: draft.documentID),
                    conflicts[draft.documentID] == nil
                else { return nil }
            }
            let formatted = try await client.formattedContent(documentID: draft.documentID)
            if isNativeRetry {
                guard !Task.isCancelled, canRetryNativeSave(documentID: draft.documentID) else { return nil }
            }
            // The session may have started editing/saving this document
            // while we awaited — a stale replay would clobber the newer
            // content and its draft. Re-check before acting.
            guard inFlight[draft.documentID] == nil,
                queued[draft.documentID] == nil,
                !isLiveReplicaHeld(draft.documentID),
                !isPendingCreate(documentID: draft.documentID),
                !isPendingDelete(documentID: draft.documentID),
                conflicts[draft.documentID] == nil,
                draftStore.draft(for: draft.documentID) == draft
            else { return nil }
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
                let baseline = adoptedBaseline(draft.baseline, draftTitle: draft.title, pushingTitle: title)
                if let reference = draft.replica {
                    try enqueueReplica(
                        adapter: ReplicaSaveAdapter(store: replicaStore, scope: reference.scope),
                        title: title, baseline: baseline,
                        resetRetryBackoff: false)
                } else {
                    enqueue(
                        documentID: draft.documentID, title: title, markdown: draft.markdown, baseline: baseline)
                }
                // Marked only if the save actually started: a hold (conflict, pending delete,
                // pending attachment) parks it, and a mark left on a parked save would make a
                // later unrelated save of this document look like a replay.
                // After `.push` this is effectively always true, given `runSyncPass`'s pre-checks
                // (no in-flight or queued save, no holds); the check is kept as defence.
                if inFlight[draft.documentID] != nil { replayedPushes.insert(draft.documentID) }
            case .conflict:
                // Record it and keep the draft: the pill/sheet asks the user. Through
                // `recordConflict`, NOT a direct map write — this is the primary detection
                // path for the offline-replay case, and a direct write skipped the on-disk
                // mirror, so the hold it established silently died at the next relaunch.
                recordConflict(documentID: draft.documentID, serverUpdatedAt: formatted.updatedAt)
            case .discardServerWins:
                if draft.replica != nil {
                    recordConflict(documentID: draft.documentID, serverUpdatedAt: formatted.updatedAt)
                    return nil
                }
                // Legacy (baseline-less) classic drafts — rule 3's tolerance fallback.
                // Skip drafts that may belong to pending creates, checkpointed migrations, or
                // pending deletes (and whenever either store is unreadable) so we never
                // stamp a conflict onto them.
                guard !isPendingCreate(documentID: draft.documentID) else { return nil }
                guard !createStoreUnreadable else { return nil }
                guard anyCheckpointedRecord(forServerID: draft.documentID) == nil else { return nil }
                guard !isPendingDelete(documentID: draft.documentID) else { return nil }
                guard !deleteStoreUnreadable else { return nil }
                // Never delete waiting edits automatically: record a conflict so the user
                // chooses Keep mine / Keep server, matching native drafts.
                recordConflict(documentID: draft.documentID, serverUpdatedAt: formatted.updatedAt)
            }
        } catch let error as DocsAPIError where error == .notFound || error == .forbidden {
            if isNativeRetry, Task.isCancelled { return nil }
            // The session may have removed, replaced, or started editing/saving this draft
            // while we awaited — never stamp `.failed` onto a state that has moved on.
            guard inFlight[draft.documentID] == nil,
                queued[draft.documentID] == nil,
                !isLiveReplicaHeld(draft.documentID),
                draftStore.draft(for: draft.documentID) == draft
            else { return nil }
            if draft.replica != nil {
                markFailed(draft.documentID, reason: "Draft sync refused: \(safeErrorSummary(error))")
                return nil
            }
            // Skip drafts that may belong to pending creates, checkpointed migrations, or
            // pending deletes (and whenever either store is unreadable) so we never mark
            // them failed as missing server documents.
            guard !isPendingCreate(documentID: draft.documentID) else { return nil }
            guard !createStoreUnreadable else { return nil }
            guard anyCheckpointedRecord(forServerID: draft.documentID) == nil else { return nil }
            guard !isPendingDelete(documentID: draft.documentID) else { return nil }
            guard !deleteStoreUnreadable else { return nil }
            // Never delete waiting classic edits here: a 404/403 may be transient or revoked
            // access while the draft is the user's only copy. Mark failed so the user decides
            // via Retry or Discard.
            markFailed(draft.documentID, reason: "Draft sync refused: \(safeErrorSummary(error))")
        } catch {
            if isNativeRetry, Task.isCancelled { return nil }
            // Leave the draft for a later sync (offline, expired session, missing route, or
            // cancellation).
            if isDeferredReplayFailure(error) {
                if draft.replica != nil, draftStore.draft(for: draft.documentID) == draft {
                    states[draft.documentID] = .pendingSync
                    if let docsError = error as? DocsAPIError, retryableSaveFailure(docsError) {
                        return docsError
                    }
                }
            } else if draft.replica != nil {
                guard inFlight[draft.documentID] == nil,
                    queued[draft.documentID] == nil,
                    !isLiveReplicaHeld(draft.documentID),
                    draftStore.draft(for: draft.documentID) == draft
                else { return nil }
                markFailed(draft.documentID, reason: "Draft sync failed: \(safeErrorSummary(error))")
            } else {
                guard inFlight[draft.documentID] == nil,
                    queued[draft.documentID] == nil,
                    !isLiveReplicaHeld(draft.documentID),
                    draftStore.draft(for: draft.documentID) == draft,
                    !isPendingCreate(documentID: draft.documentID),
                    !createStoreUnreadable,
                    anyCheckpointedRecord(forServerID: draft.documentID) == nil,
                    !isPendingDelete(documentID: draft.documentID),
                    !deleteStoreUnreadable
                else { return nil }
                markFailed(draft.documentID, reason: "Draft sync failed: \(safeErrorSummary(error))")
            }
        }
        return nil
    }

    /// Errors during a background sync pass that leave the draft waiting for a later pass rather
    /// than marking it `.failed`: transient transport/5xx/rate-limit failures, `.sessionExpired`
    /// (the shared client already raised re-login), `.routeNotFound` (a fact about the route, not
    /// about this document — create and delete replay treat it as transient too), and
    /// `CancellationError`. The waiting page still offers Retry / Copy text / Discard online.
    private func isDeferredReplayFailure(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        guard let docsError = error as? DocsAPIError else { return false }
        return retryableSaveFailure(docsError) || docsError == .sessionExpired || docsError == .routeNotFound
    }

    /// Record a conflict the editor's own revalidation (`reconcileDraft`, or `apply`'s dirty
    /// branch) detected, so the pill/sheet and the enqueue-hold apply just as they do for a
    /// conflict found by `syncPendingDrafts`.
    func recordConflict(documentID: UUID, serverUpdatedAt: Date) {
        resetNativeSaveRetry(documentID: documentID)
        conflicts[documentID] = SyncConflict(serverUpdatedAt: serverUpdatedAt)
        updateBackupProtection()
        persistConflictOnDraft(documentID: documentID)
        syncBackupExclusion(for: documentID)
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
        saveDraft(
            PendingDraft(
                documentID: documentID, title: title, markdown: draft.markdown, updatedAt: draft.updatedAt,
                baseline: adoptedBaseline(draft.baseline, draftTitle: draft.title, pushingTitle: title),
                lastPushedMarkdown: draft.lastPushedMarkdown,
                conflictServerUpdatedAt: draft.conflictServerUpdatedAt, replica: draft.replica))
        syncBackupExclusion(for: documentID, scope: draft.replica?.scope)
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
        syncBackupExclusion(for: documentID)
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
        // Ordering matters: every guard here returns **before** the slot is cleared, so a held
        // save that may not start yet is kept, not silently dropped.
        guard !isPendingCreate(documentID: documentID) else { return }
        // **And the same for a queued deletion.** The editor clears conflicts from five
        // places, so a conflict resolved while a deletion is queued would otherwise reach
        // `start` here and PATCH a document on its way out — breaking the hold `enqueue` just
        // established. Same ordering rule as above: return *before* the slot is cleared, so the
        // held save is kept for the undo rather than silently dropped.
        guard !isPendingDelete(documentID: documentID) else { return }
        // **And never over an unanswered conflict.** For as long as `clearResolvedConflict` was
        // the only caller this was redundant — it nils the record immediately above the call —
        // and both other paths to `start` (`enqueue`'s hold and `finish`'s queued restart)
        // already checked it. Two later callers made it load-bearing: `cancelPendingDelete`
        // does not clear the conflict, so undoing a deletion of a document that also has one
        // recorded would full-overwrite the co-author with the pill still standing; and a
        // document can pick up a conflict while a photo sits queued offline, where releasing
        // would push the diverged body from a background pass with no screen open.
        guard conflicts[documentID] == nil else { return }
        guard inFlight[documentID] == nil, let held = queued[documentID] else { return }
        // The held body may still name *another* queued photo: a document with two pending
        // uploads is released by the second one to land, not the first. Asking the content
        // rather than tracking which record just finished is what makes that automatic.
        guard !markdownReferencesPendingAttachment(held.markdown) else { return }
        guard held.replicaRequest == nil || !isLiveReplicaHeld(documentID) else { return }
        queued[documentID] = nil

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
        // Another signed-in account must never rewrite, release or send this raw draft:
        // the conflict, baseline and queued work all stay exactly as they are. Asked of every
        // account's drafts, since that account's is not shown to this one.
        if let scope = anyAccountReplicaScope(documentID: documentID), scope.ownerUserID != signedInUser.userID {
            markFailed(documentID, reason: "Conflict resolution refused: the draft belongs to another account")
            return
        }
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
            saveDraft(
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
                        // With no baseline the body is the user's own, which block
                        // preservation must never read as the server copy.
                        // The title rides along unchanged, and the advanced timestamp is what
                        // makes this answer stick for the title too: `draftTitleOutcome` keeps
                        // the draft's title whenever the server is no newer than the baseline,
                        // so a retry after a failed push cannot re-raise the same *title*
                        // conflict the user just answered. (Only the timestamp is knowable —
                        // `SyncConflict` carries no server content, titles included.)
                        title: draft.baseline?.title,
                        markdownIsLocal: draft.baseline.map { $0.markdownIsLocal } ?? true,
                        bodyIsUnknown: draft.baseline?.bodyIsUnknown),
                    lastPushedMarkdown: draft.lastPushedMarkdown,
                    // The user answered: the hold is released, on disk as well as in memory
                    // (`clearResolvedConflict` below rewrites this to nil).
                    conflictServerUpdatedAt: nil, replica: draft.replica))
        }
        // Releases the record AND starts whatever the hold was parking.
        clearResolvedConflict(documentID: documentID)
        // No held save (the conflict was recorded before any flush)? Then push the draft.
        if queued[documentID] == nil, inFlight[documentID] == nil,
            let draft = draftStore.draft(for: documentID)
        {
            // Re-read: the draft above may have just had its baseline advanced.
            if draft.replica != nil {
                // The conflict is already cleared, so a failed capture must not read as a no-op.
                retryReplicaDraft(documentID: documentID)
            } else {
                enqueue(documentID: documentID, title: draft.title, markdown: draft.markdown, baseline: draft.baseline)
            }
        }
    }

    /// The manual retry of a raw-owned draft (the classic `enqueue` is refused for one).
    /// It re-captures the stored draft through the raw path; a capture that still fails
    /// reports `.failed`, never a silent no-op. Holds (conflict, pending create/delete,
    /// live replica) still apply through `enqueue`.
    func retryReplicaDraft(documentID: UUID) {
        guard inFlight[documentID] == nil, queued[documentID] == nil,
            let draft = draftStore.draft(for: documentID), let reference = draft.replica
        else { return }
        do {
            try enqueueReplica(
                adapter: ReplicaSaveAdapter(store: replicaStore, scope: reference.scope), title: draft.title)
        } catch {
            markFailed(documentID, reason: "Retry capture refused: \(safeErrorSummary(error))")
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
    @discardableResult
    func resolveConflictKeepingServer(documentID: UUID) -> Bool {
        let ownership = nativeOwnership(documentID: documentID)
        if case .unreadable = ownership {
            markFailed(
                documentID, reason: "Conflict resolution refused: native replica ownership is unreadable",
                offersRetry: false)
            return false
        }
        let reference = draftStore.draft(for: documentID)?.replica
        if let scope = anyAccountReplicaScope(documentID: documentID) ?? ownership.scope,
            scope.ownerUserID != signedInUser.userID
        {
            markFailed(
                documentID, reason: "Conflict resolution refused: the draft belongs to another account",
                offersRetry: false)
            return false
        }
        // The user chose the server body, so the native replica is discarded with
        // the draft. A failure removing the replica must abort and report before
        // deleting the draft, clearing the conflict, or installing server state.
        guard discardNativeReplica(documentID: documentID) else {
            markFailed(documentID, reason: "Could not discard local changes", offersRetry: false)
            return false
        }
        // Drop the held work after the replica discard succeeds: `clearResolvedConflict`
        // starts whatever the hold was parking, and this is the one resolution where
        // that work must be thrown away, not sent.
        queued[documentID] = nil
        resetNativeSaveRetry(documentID: documentID)
        removeDraft(documentID: documentID)
        // Both bodies that could have named a queued photo are now gone, so nothing would ever
        // collect its record — and the server body the user chose does not reference it either.
        discardPendingAttachments(documentID: documentID)
        clearResolvedConflict(documentID: documentID)
        // The conflict is almost always reached from a `.failed`/`.pendingSync` draft, and
        // discarding it leaves nothing to save — so the state must not keep claiming one.
        // Left alone it strands the reading surface's "Couldn't save · tap to retry" (or
        // "syncs when online") caption on a document with no unsaved work, offering a retry
        // that `saveNow` would no-op. Mirrors `finish`'s discarded branch.
        states[documentID] = .idle
        clearFailure(documentID)
        syncBackupExclusion(for: documentID, scope: reference?.scope)
        return true
    }

    // MARK: - Waiting classic edits

    /// Snapshot of unsynced classic edits waiting to push for a server document.
    struct WaitingClassicContent: Equatable, Sendable {
        let title: String
        let markdown: String
    }

    /// Resolves waiting classic edits for `documentID` (in-flight/queued classic save,
    /// classic `PendingDraft`, or checkpointed local create), tracking observable versions
    /// so SwiftUI views and `NativeEditorOpen` update as saves settle or migrate.
    func waitingClassicContent(documentID: UUID) -> WaitingClassicContent? {
        _ = draftsVersion
        _ = pendingCreatesVersion
        _ = pins.revision
        if let pending = pendingSave(documentID: documentID), pending.replicaRequest == nil {
            return WaitingClassicContent(
                title: pending.title, markdown: pending.markdown)
        }
        if let draft = draftStore.draft(for: documentID), draft.replica == nil {
            return WaitingClassicContent(
                title: draft.title, markdown: draft.markdown)
        }
        if let checkpointed = ownedCheckpointedRecord(forServerID: documentID) {
            if let pending = pendingSave(documentID: checkpointed.localID) {
                return WaitingClassicContent(
                    title: pending.title, markdown: pending.markdown)
            }
            if let draft = draftStore.draft(for: checkpointed.localID) {
                return WaitingClassicContent(
                    title: draft.title, markdown: draft.markdown)
            }
            return WaitingClassicContent(
                title: checkpointed.title, markdown: "")
        }
        return nil
    }

    /// True while `documentID` still has classic edits, a queued/in-flight classic save, or
    /// an unfinished checkpointed create waiting to sync.
    func hasWaitingClassicWork(documentID: UUID) -> Bool {
        waitingClassicContent(documentID: documentID) != nil
    }

    /// True while a classic push for `documentID` is actively on the wire or in `.saving` state.
    func isWaitingClassicInFlight(documentID: UUID) -> Bool {
        _ = draftsVersion
        _ = pendingCreatesVersion
        if inFlightContent[documentID] != nil { return true }
        if case .saving = state(for: documentID) { return true }
        return false
    }

    /// True when waiting classic edits for `documentID` (or its checkpointed create or classic
    /// queued photos) are in a terminal `.failed` state that requires explicit Retry or Discard.
    func isWaitingClassicFailed(documentID: UUID) -> Bool {
        _ = draftsVersion
        _ = pendingCreatesVersion
        _ = pendingAttachmentsVersion
        _ = pins.revision
        if case .failed = state(for: documentID) { return true }
        let checkpointed = ownedCheckpointedRecord(forServerID: documentID)
        if let checkpointed, case .failed = state(for: checkpointed.localID) { return true }
        let owner = signedInUser.userID
        return pendingAttachments.values.contains { record in
            record.native == nil && record.failedAt != nil
                && owner != nil && record.ownerUserID == owner
                && (record.documentID == documentID || record.documentID == checkpointed?.localID)
        }
    }

    /// Starts or coalesces the app-wide sync pass in a coordinator-owned task and awaits its
    /// completion. Cancelling the caller stops waiting without cancelling the shared pass or
    /// other documents' in-flight requests.
    func syncPendingDraftsAndAwaitCompletion() async {
        if isSyncingDrafts {
            needsAnotherSyncPass = true
        } else {
            // Always start one when none is running: a task still finishing has already resumed
            // its waiters, so a waiter registered now needs a pass of its own (at worst a
            // coalesced extra pass).
            Task { @MainActor [weak self] in await self?.syncPendingDrafts() }
        }
        guard !Task.isCancelled else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                syncPassWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.syncPassWaiters.removeValue(forKey: waiterID)?.resume()
            }
        }
    }

    /// Manual retry for waiting classic edits: clears terminal `.failed` state (including
    /// failed classic attachments and any failed checkpointed create), marks `.saving`
    /// immediately so the UI switches to "Syncing…", and runs the serialized sync pass so
    /// `runSyncPass` re-checks against the server rather than pushing blindly.
    func retryClassicDraft(documentID: UUID) async {
        guard inFlight[documentID] == nil else { return }
        guard hasWaitingClassicWork(documentID: documentID) else { return }
        let checkpointed = ownedCheckpointedRecord(forServerID: documentID)
        clearFailure(documentID)
        states[documentID] = .saving
        if let checkpointed, case .failed = state(for: checkpointed.localID) {
            states[checkpointed.localID] = .pendingSync
            clearFailure(checkpointed.localID)
        }
        let owner = signedInUser.userID
        for record in pendingAttachments.values where record.native == nil && record.failedAt != nil {
            guard record.documentID == documentID || record.documentID == checkpointed?.localID else { continue }
            guard owner != nil, record.ownerUserID == owner else { continue }
            var cleared = record
            cleared.failedAt = nil
            updatePendingAttachment(cleared)
        }
        await syncPendingDraftsAndAwaitCompletion()
        if inFlight[documentID] == nil, case .saving = state(for: documentID) {
            states[documentID] = hasWaitingClassicWork(documentID: documentID) ? .pendingSync : .idle
        }
    }

    /// Discards unsynced classic edits for a server document (draft, queued save, classic
    /// pending attachments, failure state, conflict, and any non-open checkpointed create)
    /// without deleting the server document itself. Refuses if native owns the document, a
    /// save is currently in flight, or an unowned checkpointed create targets this server id.
    @discardableResult
    func discardClassicDraft(documentID: UUID) -> Bool {
        guard nativeOwnership(documentID: documentID) == .none else { return false }
        guard inFlight[documentID] == nil else { return false }
        let ownedCheckpointed = ownedCheckpointedRecord(forServerID: documentID)
        let hasUnownedCheckpointed = pendingCreates.values.contains { record in
            record.syncedServerID == documentID && record.localID != ownedCheckpointed?.localID
        }
        guard !hasUnownedCheckpointed else { return false }
        guard hasWaitingClassicWork(documentID: documentID) else { return false }
        if let checkpointed = ownedCheckpointed {
            if hasOpenEditor(documentID: checkpointed.localID) {
                var restarted = checkpointed
                restarted.syncedServerID = nil
                restarted.postedTitle = nil
                updatePendingCreate(restarted)
            } else {
                let localOwnership = nativeOwnership(documentID: checkpointed.localID)
                if case .unreadable = localOwnership { return false }
                if let scope = localOwnership.scope, scope.ownerUserID != signedInUser.userID {
                    return false
                }
                guard discardNativeReplica(documentID: checkpointed.localID) else { return false }
                // Re-parent any local subpages onto `documentID` so discarding this document's
                // unsynced edits never destroys separate subpages filed under it.
                for var child in pendingCreates.values where child.parentID == checkpointed.localID {
                    child.parentID = documentID
                    updatePendingCreate(child)
                }
                removePendingCreate(documentID: checkpointed.localID)
                discardPendingAttachments(documentID: checkpointed.localID)
                removeDraft(documentID: checkpointed.localID)
                queued[checkpointed.localID] = nil
                settledSaves[checkpointed.localID] = nil
                lastConfirmedPushMarkdown[checkpointed.localID] = nil
                knownServerTitles[checkpointed.localID] = nil
                conflicts[checkpointed.localID] = nil
                states[checkpointed.localID] = .idle
                clearFailure(checkpointed.localID)
                syncBackupExclusion(for: checkpointed.localID)
            }
        }
        queued[documentID] = nil
        replayedPushes.remove(documentID)
        removeDraft(documentID: documentID)
        discardPendingAttachments(documentID: documentID)
        clearResolvedConflict(documentID: documentID)
        states[documentID] = .idle
        clearFailure(documentID)
        syncBackupExclusion(for: documentID)
        return true
    }

    /// Drops all queued/stored work for a document (delete flow). An already
    /// in-flight PATCH cannot be meaningfully cancelled — but it can still *land*
    /// before the server processes the DELETE, and `finish`'s success path would
    /// then write-through the content cache, recreating the entry the delete just
    /// purged. Nothing purges it again. Remembering the id keeps that write out.
    func discardPendingWork(documentID: UUID) {
        resetNativeSaveRetry(documentID: documentID)
        // A deleted or explicitly discarded document keeps no native replica.
        // Read the draft/marker before the branches below remove either.
        let mayRemoveDraft = discardNativeReplica(documentID: documentID)
        queued[documentID] = nil
        replayedPushes.remove(documentID)
        // The draft that named them is about to go, so nothing would ever collect these — and an
        // uncollected record keeps a photo's bytes alive for a document that no longer exists.
        discardPendingAttachments(documentID: documentID)
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
        //
        // **Only the signed-in account's record.** Another account's (a shared server document
        // whose DELETE 404s for this account and so reads as done) is that account's unsent
        // work: its record, sub-pages and draft all stay.
        let account = signedInSession.userID
        if isPendingCreate(documentID: documentID) {
            if account != nil, pendingCreates[documentID]?.ownerUserID == account {
                discardLocalSubtree(rootedAt: documentID)
                states[documentID] = .idle
                clearFailure(documentID)
            }
        } else if let checkpointed = anyCheckpointedRecord(forServerID: documentID),
            account != nil, checkpointed.ownerUserID == account
        {
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
            // no longer existed on disk, and the next launch's sweep marked failed what its
            // flush rewrote.
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
                // The page's own replica and queued photos are filed under the local id too; left
                // behind, a native photo would upload to `documents/{local-id}/` and its bytes and
                // replica would stay protected forever.
                // A replica this account may not remove (another account's, or unreadable) keeps
                // its draft and its queued photos, as everywhere else `discardNativeReplica`
                // answers false.
                let mayRemoveLocalDraft = discardNativeReplica(documentID: checkpointed.localID)
                if mayRemoveLocalDraft { discardPendingAttachments(documentID: checkpointed.localID) }
                resetNativeSaveRetry(documentID: checkpointed.localID)
                states[checkpointed.localID] = .idle
                clearFailure(checkpointed.localID)
                if mayRemoveLocalDraft { removeDraft(documentID: checkpointed.localID) }
                queued[checkpointed.localID] = nil
                settledSaves[checkpointed.localID] = nil
                lastConfirmedPushMarkdown[checkpointed.localID] = nil
                knownServerTitles[checkpointed.localID] = nil
                syncBackupExclusion(for: checkpointed.localID)
            }
        }
        if mayRemoveDraft { removeDraft(documentID: documentID) }
        syncBackupExclusion(for: documentID)
        if inFlight[documentID] != nil {
            discardedDuringSave.insert(documentID)
        }
    }

    /// The document became unavailable (404/403) and the editor purged its local
    /// copy. An in-flight save can still land afterwards and, on the success path,
    /// write the full body straight back into the content cache — on a 403 that is
    /// revoked content reappearing on disk. Unlike `discardPendingWork`, the draft
    /// stays: it is the user's only copy of unsaved work, and `recoverDrafts()`
    /// decides its fate next launch (replay if reachable, mark failed on a real 404/403).
    func suppressLocalWriteThrough(documentID: UUID) {
        queued[documentID] = nil
        resetNativeSaveRetry(documentID: documentID)
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
        syncBackupExclusion(for: documentID)
        guard inFlight[documentID] != nil else { return }
        discardedDuringSave.insert(documentID)
    }

    private func start(documentID: UUID, save: PendingSave) {
        cancelNativeSaveRetryTask(documentID: documentID)
        inFlightContent[documentID] = save
        states[documentID] = .saving
        clearFailure(documentID)
        syncBackupExclusion(for: documentID, scope: save.replicaRequest?.reference.scope)
        let diagnosticsMarker = diagnostics?.marker()
        let taskToken = backgroundTasks.begin("SchriftDocumentSave")
        // The draft's baseline is the server copy this edit descends from (the draft is
        // written before any save starts): the Docs 6 save reads it to keep the web blocks the
        // user left alone (`BlockNotePreservation`). A baseline that is the user's own body
        // (`markdownIsLocal`) is no base at all.
        let baseMarkdown = draftStore.draft(for: documentID)?.baseline?.serverMarkdown
        // Every request of this save (body and title, any route) is bound to the sign-in
        // generation it started in (review X1): a cookie handover meanwhile sends nothing more.
        let isCurrent = signInIsCurrent?()
        let session = signedInSession
        inFlight[documentID] = Task {
            await DocsAPIClient.$saveIsCurrent.withValue(isCurrent) {
                await self.runSave(
                    documentID: documentID, save: save, baseMarkdown: baseMarkdown, session: session,
                    marker: diagnosticsMarker)
            }
            backgroundTasks.end(taskToken)
        }
    }

    private func runSave(
        documentID: UUID, save: PendingSave, baseMarkdown: String?, session: SignedInSession,
        marker diagnosticsMarker: Int?
    ) async {
        do {
            // A non-nil return means the CONTENT PATCH landed and only the title failed:
            // the save still counts as failed (retryability is classified from the same
            // error) but the server holds our body, so `finish` must record the push.
            let titleFailure: DocsAPIError?
            if let request = save.replicaRequest {
                try await request.adapter.saveBody(request, client: client)
                do {
                    try await client.updateTitle(documentID: documentID, title: save.title)
                    titleFailure = nil
                } catch let error as DocsAPIError {
                    titleFailure = error
                } catch {
                    titleFailure = .network(String(describing: error))
                }
            } else if let snapshot = save.liveSnapshot {
                // Live-collaboration snapshot: write the CRDT bytes verbatim, through the same route as
                // the classic body (`saveContentViaRoute`).
                titleFailure = try await client.saveLiveSnapshot(
                    documentID: documentID, title: save.title, yjsUpdate: snapshot)
            } else {
                // Classic full-overwrite: re-derive Yjs bytes from the markdown.
                titleFailure = try await client.saveDocumentContent(
                    documentID: documentID, title: save.title, markdown: save.markdown,
                    baseMarkdown: baseMarkdown)
            }
            finish(
                documentID: documentID, save: save, session: session, error: titleFailure, contentLanded: true,
                diagnosticsMarker: diagnosticsMarker)
        } catch {
            // A throw means the content PATCH was not **confirmed** — NOT that nothing
            // reached the server: a dropped or timed-out response can hide a PATCH the
            // server applied. All we know is that we cannot *record* the push, which is
            // exactly what `draftSyncDecision`'s rule 0 backstops.
            finish(
                documentID: documentID, save: save, session: session, error: error, contentLanded: false,
                diagnosticsMarker: diagnosticsMarker)
        }
    }

    /// `session` is the one the save started in. Its draft bookkeeping is that account's even if
    /// another has signed in since, and its body reaches the content cache only while the same
    /// sign-in is in front of us.
    private func finish(
        documentID: UUID, save: PendingSave, session: SignedInSession, error: Error?, contentLanded: Bool,
        diagnosticsMarker: Int? = nil
    ) {
        // The account the save was made for: the one it started under, or the one that sign-in
        // has since been named as.
        let owner = session.owner(now: signedInSession)
        let settledIn = SignedInSession(userID: owner, epoch: session.epoch)
        inFlight[documentID] = nil
        inFlightContent[documentID, in: session] = nil
        let wasReplayedPush = replayedPushes.remove(documentID) != nil
        // Fired from every exit below (the early returns included) once the content is known to
        // be on the server; `defer` keeps it last, after state has settled.
        defer {
            if wasReplayedPush, contentLanded { onReplayedPushLanded?() }
        }
        var shouldEvictCleanReplicas = false
        defer {
            if shouldEvictCleanReplicas { evictCleanNativeReplicasIfNeeded() }
        }
        defer {
            syncBackupExclusion(for: documentID, scope: save.replicaRequest?.reference.scope)
        }
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
            lastConfirmedPushMarkdown[documentID, in: settledIn] = save.markdown
            // Stamp whatever draft is on disk: its content descends from what this save just
            // landed, whether it is a *newer* draft (the user kept typing) or the save's own
            // draft surviving a failure (a half-land keeps an **identical** draft — stamping
            // only a differing one missed exactly that case). The branches below remove it if
            // it should not survive; stamping first is harmless and keeps the rule one line.
            if let draft = draftStore.draft(for: documentID, in: settledIn) {
                saveDraft(
                    PendingDraft(
                        documentID: documentID, title: draft.title, markdown: draft.markdown,
                        updatedAt: draft.updatedAt, baseline: draft.baseline, lastPushedMarkdown: save.markdown,
                        conflictServerUpdatedAt: conflicts[documentID, in: settledIn]?.serverUpdatedAt,
                        replica: draft.replica, ownerUserID: draft.owner),
                    setAsideIn: owner == nil ? session.epoch : nil)
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
            queued[documentID, in: session] = nil
            resetNativeSaveRetry(documentID: documentID)
            states[documentID, in: session] = .idle
            clearFailure(documentID, in: session)
            if error == nil, let draft = draftStore.draft(for: documentID, in: settledIn),
                draft.title == save.title, draft.markdown == save.markdown,
                draft.replica == save.replicaRequest?.reference,
                save.replicaRequest.map({ $0.adapter.isCurrent($0) }) ?? true
            {
                removeDraft(documentID: documentID, in: settledIn)
            }
            return
        }
        var retryableNativeError: DocsAPIError?
        if error == nil {
            resetNativeSaveRetry(documentID: documentID)
            states[documentID, in: session] = .saved(Date())
            clearFailure(documentID, in: session)
            // **Both** PATCHes landed, so the server now holds this title. An editor still on
            // screen may never have seen it (a background replay can adopt a co-author's rename
            // into this save without the editor refetching), and recording it is what stops that
            // editor's next flush pushing the pre-rename title back. A save that landed *after its
            // document was discarded mid-flight* takes the `discardedDuringSave` early return
            // above and never reaches here — deliberately: for a delete, the entry was cleared and
            // a landed PATCH must not resurrect it.
            knownServerTitles[documentID, in: session] = save.title
            if let draft = draftStore.draft(for: documentID, in: settledIn), draft.title == save.title,
                draft.markdown == save.markdown, draft.replica == save.replicaRequest?.reference,
                save.replicaRequest.map({ $0.adapter.isCurrent($0) }) ?? true
            {
                removeDraft(documentID: documentID, in: settledIn)
            }
            // Keep the local copy consistent with what the server now holds.
            // The save PATCHes are void, so there is no server `updated_at` to
            // record: `serverUpdatedAt` is nil (truthfully "unknown after a void
            // save") and `syncedAt` is the client wall-clock of the confirmed save.
            // For native saves, `save.markdown` is the lossy Markdown shadow; it keeps
            // offline search and the attachments list current without extra requests,
            // and `serverUpdatedAt: nil` + native ownership ensure classic never treats
            // it as an authoritative server baseline.
            contentCache.save(
                CachedDocumentContent(
                    documentID: documentID,
                    title: save.title,
                    markdown: save.markdown,
                    syncedAt: Date(),
                    serverUpdatedAt: nil
                ), during: session)
            if let request = save.replicaRequest {
                shouldEvictCleanReplicas = true
                if !request.adapter.isCurrent(request) {
                    states[documentID, in: session] = .pendingSync
                }
            }
        } else if let docsError = error as? DocsAPIError, retryableSaveFailure(docsError) {
            // Transient/transport failure (offline, 5xx, rate limit): the edit is
            // safely on-device as a draft; mark it queued for sync rather than a
            // scary failure. `.sessionExpired` is NOT retryable — the shared client's
            // hook already raised the re-login sheet — so it lands in `.failed`.
            states[documentID, in: session] = .pendingSync
            if save.replicaRequest != nil { retryableNativeError = docsError }
        } else if error is CancellationError {
            // A sign-in switch refused the request (review X1): nothing was sent under the new
            // cookies, and the draft and journal wait for the next pass of the right account.
            resetNativeSaveRetry(documentID: documentID)
            states[documentID, in: session] = .pendingSync
        } else {
            markFailed(
                documentID, reason: "Save failed: \(error.map(safeErrorSummary) ?? "unknown error")",
                detail: diagnosticsMarker.flatMap { marker in
                    diagnostics?.failure(after: marker, newest: true) {
                        saveFailureIsRelevant($0, documentID: documentID, error: error)
                    }
                }, in: session)
        }
        // A revalidation landed while this save was on the wire, so detection was skipped. Now
        // that it has settled the invariant holds again — so decide, before anything can push.
        // Only when the content did NOT land: if it did, the server holds *our* body and the
        // observation is superseded (comparing against it would manufacture a false conflict
        // against the user's own writing).
        if let observed, !contentLanded, owner == signedInSession.userID,
            let draft = draftStore.draft(for: documentID, in: settledIn)
        {
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
        // The settling save's own account drains its parked follow-up. Settling after a switch,
        // that follow-up is the account's write-ahead draft already on disk (`enqueue` writes it
        // first), which its own replay sends; a save parked by the account now signed in
        // follows instead, under its own session.
        let settlesInCurrentSession =
            session.userID == signedInSession.userID
            && (session.userID != nil || session.epoch == signedInSession.epoch)
        if !settlesInCurrentSession { queued[documentID, in: session] = nil }
        if let next = queued.removeValue(forKey: documentID) {
            if error == nil, next == save, settlesInCurrentSession {
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
            //
            // The pending-attachment half, by contrast, is reachable the day photos can be
            // queued: a photo whose upload fails transiently *while an ordinary autosave is in
            // flight* is parked here by `enqueue`'s third disjunct — correctly left reading
            // `.saving`, since a save really is on the wire — and this is the line that would
            // start it the moment the autosave settles. Re-parking below is what finally
            // stamps it `.pendingSync`.
            guard conflicts[documentID] == nil, !isPendingCreate(documentID: documentID),
                !isPendingDelete(documentID: documentID),
                !markdownReferencesPendingAttachment(next.markdown),
                next.replicaRequest == nil || !isLiveReplicaHeld(documentID)

            else {
                queued[documentID] = next
                states[documentID] = .pendingSync
                return
            }
            start(documentID: documentID, save: next)
            return
        }
        if let retryableNativeError {
            scheduleNativeSaveRetry(documentID: documentID, error: retryableNativeError)
        }
    }
}

/// A weakly-held subscriber to landed deletions — see
/// `DocumentSaveCoordinator.observeDocumentDeleted`.
/// Per-document state an account left in memory, read and written for whoever the drafts are
/// scoped to: an in-place re-login as someone else neither shows nor sends it, and it is there
/// again when that account returns. A sign-in never named keeps its own bucket per epoch, like
/// the store's set-aside slots, so one unconfirmed session never releases another's parked save.
/// `keys` spans every bucket, for the protections.
struct AccountScoped<Value> {
    private enum Bucket: Hashable {
        case account(UUID)
        case unnamed(epoch: Int)
    }

    private let drafts: PendingDraftStore
    private var buckets: [Bucket: [UUID: Value]] = [:]

    init(_ drafts: PendingDraftStore) { self.drafts = drafts }

    private static func bucket(_ session: SignedInSession) -> Bucket {
        session.userID.map(Bucket.account) ?? .unnamed(epoch: session.epoch)
    }

    subscript(documentID: UUID) -> Value? {
        get { self[documentID, in: drafts.session] }
        set { self[documentID, in: drafts.session] = newValue }
    }

    subscript(documentID: UUID, in session: SignedInSession) -> Value? {
        get { buckets[Self.bucket(session)]?[documentID] }
        set { buckets[Self.bucket(session), default: [:]][documentID] = newValue }
    }

    var keys: Set<UUID> { Set(buckets.values.flatMap(\.keys)) }

    mutating func removeValue(forKey documentID: UUID) -> Value? {
        buckets[Self.bucket(drafts.session)]?.removeValue(forKey: documentID)
    }
}

private struct DocumentDeletedObserver {
    weak var owner: AnyObject?
    let handler: @MainActor (UUID) -> Void
}

/// A landed move, as the surfaces holding the document hear about it.
struct DocumentMoveEvent: Equatable, Sendable {
    /// The id every cache and list entry for this document is keyed by — the server's, even
    /// when the move was made from a checkpointed record's local id.
    let documentID: UUID
    /// The row to file where the document has landed, when the mover had one. Nil from a
    /// surface that holds an id rather than a row (the editor's Options sheet): the
    /// destination then picks the document up on its next fetch rather than being handed an
    /// invented row.
    let row: Document?
    /// Nil when the document was promoted to the top level.
    let newParentID: UUID?
}

/// A weakly-held subscriber to landed moves — see
/// `DocumentSaveCoordinator.observeDocumentMoved`.
private struct DocumentMovedObserver {
    weak var owner: AnyObject?
    let handler: @MainActor (DocumentMoveEvent) -> Void
}

/// Whether a failure the shared log recorded during a save is this save's reason: one of the
/// requests the save itself makes for its document — the legacy content PATCH, the
/// collaboration state GET or update PATCH, the title PATCH — so another document's save or
/// this document's other reads (the editor's `children/` list, whose failure is swallowed)
/// never show as it. Not the legacy content route's 404 a Docs 6 server answers before the
/// save falls back to the collaboration route, unless that 404 is the save's own `.notFound`
/// (a deleted document on a pre-Docs 6 server). The id is matched before `displayPath` elides it.
func saveFailureIsRelevant(_ failure: RequestFailure, documentID: UUID, error: Error?) -> Bool {
    let id = documentID.uuidString.lowercased()
    let route = failure.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
    let legacyContent = "documents/\(id)/content/"
    let isSaveRequest =
        failure.method == "PATCH" && (route == legacyContent || route == "documents/\(id)/")
        || route.hasPrefix("/collaboration/ydoc/v1/") && route.hasSuffix("/\(id)")
    guard isSaveRequest else { return false }
    let isLegacyContent404 = route == legacyContent && failure.statusCode == 404
    return !isLegacyContent404 || error as? DocsAPIError == .notFound
}
