import XCTest

@testable import Schrift

/// The coordinator's half of offline creation: minting a local document, and the two
/// **holds** that keep a document the server has never seen from being addressed as if
/// it had. Both holds are the safety net for the replay that PR 3 adds — they land first,
/// and dormant, because without them the existing pipeline actively destroys a local
/// document the moment it runs.
@MainActor
final class DocumentSaveCoordinatorCreateTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let origin = "https://docs.example.org"
    private var cacheDirectory: URL!
    private var suiteNames: [String] = []

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoordinatorCreateTests-\(UUID().uuidString)", isDirectory: true)
        suiteNames = []
    }

    override func tearDown() {
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: cacheDirectory)
        for name in suiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        super.tearDown()
    }

    private func makeCoordinator(serverOrigin: String? = nil) -> (
        DocumentSaveCoordinator, PendingDraftStore, PendingDocumentCreateStore
    ) {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let suiteName = "CoordinatorCreateTests.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        let draftStore = PendingDraftStore(userDefaults: defaults)
        let createStore = PendingDocumentCreateStore(userDefaults: defaults)
        let coordinator = DocumentSaveCoordinator(
            client: client,
            draftStore: draftStore,
            contentCache: DocumentContentCacheStore(directory: cacheDirectory),
            createStore: createStore,
            serverOrigin: serverOrigin ?? origin,
            backgroundTasks: .noop
        )
        return (coordinator, draftStore, createStore)
    }

    private func savesInFlight(_ log: RequestRecorder) -> Int {
        log.count(ofMethod: "PATCH", urlContaining: "/content/")
    }

    // MARK: - Minting a local document

    func testCreatingALocalDocumentRecordsItAndReportsItAsPending() {
        let (coordinator, _, createStore) = makeCoordinator()

        let document = coordinator.createLocalDocument(title: "Untitled document", parentID: nil)

        XCTAssertTrue(coordinator.isPendingCreate(documentID: document.id))
        XCTAssertEqual(createStore.create(for: document.id)?.title, "Untitled document")
        XCTAssertEqual(createStore.create(for: document.id)?.serverOrigin, origin)
    }

    /// A document created but never typed into still has to reach the server, so the
    /// record carries it. The seed draft exists so the editor's `restoreLocalContent`
    /// can render it with no changes at all — its precedence already covers drafts.
    func testANewLocalDocumentGetsASeedDraftSoTheEditorCanRenderIt() {
        let (coordinator, draftStore, _) = makeCoordinator()

        let document = coordinator.createLocalDocument(title: "Untitled document", parentID: nil)

        let draft = draftStore.draft(for: document.id)
        XCTAssertEqual(draft?.title, "Untitled document")
        XCTAssertEqual(draft?.markdown, "", "a brand-new document has no content yet")
    }

    /// Nothing is on the server, so nothing is syncing — but the work *is* on the device.
    /// `.pendingSync` is the truthful state and gives the caption its "syncs when online"
    /// wording for free.
    func testANewLocalDocumentReportsPendingSyncNotIdle() {
        let (coordinator, _, _) = makeCoordinator()

        let document = coordinator.createLocalDocument(title: "Untitled document", parentID: nil)

        XCTAssertEqual(coordinator.state(for: document.id), .pendingSync)
    }

    /// Once the replay has POSTed it, the server owns the document — the fetched list is
    /// where it belongs. Surfacing it here as well would show the row twice, under an id
    /// the fetched list cannot match (local vs server), which no de-duplication can fix.
    func testACheckpointedRecordIsNoLongerListedAsLocal() {
        let (coordinator, _, createStore) = makeCoordinator()
        let document = coordinator.createLocalDocument(title: "Untitled document", parentID: nil)
        var record = createStore.create(for: document.id)!

        record.syncedServerID = UUID()
        createStore.save(record)
        let (resumed, _, _) = makeCoordinatorSharing(createStore)

        XCTAssertTrue(resumed.pendingLocalDocuments(parentID: nil).isEmpty)
        XCTAssertTrue(resumed.isPendingCreate(documentID: document.id), "still protected until migration finishes")
    }

    func testPendingLocalDocumentsAreScopedToTheirParent() {
        let (coordinator, _, _) = makeCoordinator()
        let parent = UUID()
        let root = coordinator.createLocalDocument(title: "Root", parentID: nil)
        let child = coordinator.createLocalDocument(title: "Child", parentID: parent)

        XCTAssertEqual(coordinator.pendingLocalDocuments(parentID: nil).map(\.id), [root.id])
        XCTAssertEqual(coordinator.pendingLocalDocuments(parentID: parent).map(\.id), [child.id])
    }

    /// A record minted against another server is not *listed* here — you should not see
    /// documents belonging to a server you are not signed in to.
    func testARecordFromAnotherOriginIsNotListed() {
        let (first, _, createStore) = makeCoordinator()
        let document = first.createLocalDocument(title: "Written elsewhere", parentID: nil)

        let (elsewhere, _, _) = makeCoordinatorSharing(createStore, serverOrigin: "https://other.example.org")

        XCTAssertTrue(elsewhere.pendingLocalDocuments(parentID: nil).isEmpty)
    }

    /// …but it **is** still protected. This is the difference between "may we send it"
    /// and "may anything address it", and conflating them cost the content: the holds
    /// were origin-scoped while `runSyncPass` walks *every* draft, so signing in to
    /// another server left a foreign record's draft with no hold at all — the pass GET
    /// 404ed and deleted it. The record survived pointing at nothing, and a later replay
    /// would have POSTed an empty document under the original title. Dormant has to mean
    /// no requests *and* no deletion.
    func testARecordFromAnotherOriginIsStillProtectedFromTheSyncPass() async {
        let log = RequestRecorder()
        let (first, draftStore, createStore) = makeCoordinator()
        let document = first.createLocalDocument(title: "Written elsewhere", parentID: nil)
        first.enqueue(documentID: document.id, title: "Written elsewhere", markdown: "# Body typed on server A")

        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 404, headers: [:], body: Data(), error: nil)
        }
        let (elsewhere, _, _) = makeCoordinatorSharing(
            createStore, draftStore: draftStore, serverOrigin: "https://other.example.org")
        await elsewhere.recoverDrafts()

        XCTAssertTrue(elsewhere.isPendingCreate(documentID: document.id), "protection is not origin-scoped")
        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "formatted-content"), 0)
        XCTAssertEqual(
            draftStore.draft(for: document.id)?.markdown, "# Body typed on server A",
            "the content survives signing in elsewhere")
        XCTAssertNotNil(createStore.create(for: document.id), "dormant, not deleted — the user may sign back in")
    }

    /// Origin identifies the *server*, not the *account*, and records survive sign-out —
    /// so a second user on the same server must not inherit the first user's unsynced
    /// documents and POST them into their own account. The replay is what checks this
    /// (it can await `/users/me/`; the coordinator is built before that returns).
    func testARecordIsOnlyReplayableByTheUserWhoCreatedIt() {
        let (coordinator, _, createStore) = makeCoordinator()
        let author = UUID()
        let someoneElse = UUID()
        coordinator.createLocalDocument(title: "Mine", parentID: nil, ownerUserID: author)
        let record = createStore.allCreates()[0]

        XCTAssertTrue(coordinator.isReplayable(record, currentUserID: author))
        XCTAssertFalse(coordinator.isReplayable(record, currentUserID: someoneElse))
        XCTAssertFalse(coordinator.isReplayable(record, currentUserID: nil))
    }

    func testARecordIsNeverReplayableAgainstAnotherServer() {
        let (coordinator, _, createStore) = makeCoordinator()
        let author = UUID()
        coordinator.createLocalDocument(title: "Mine", parentID: nil, ownerUserID: author)
        let record = createStore.allCreates()[0]

        let (elsewhere, _, _) = makeCoordinatorSharing(createStore, serverOrigin: "https://other.example.org")

        XCTAssertFalse(elsewhere.isReplayable(record, currentUserID: author))
    }

    /// A record predating the owner field is origin-checked only — it must not become
    /// permanently unreplayable just because it was written before the field existed.
    func testALegacyRecordWithNoOwnerIsStillReplayable() {
        let (coordinator, _, createStore) = makeCoordinator()
        createStore.save(
            PendingDocumentCreate(
                localID: UUID(), title: "Legacy", createdAt: Date(timeIntervalSince1970: 1_000),
                serverOrigin: origin))
        let record = createStore.allCreates()[0]

        XCTAssertTrue(coordinator.isReplayable(record, currentUserID: UUID()))
    }

    /// The title shown in a list is the one the user last typed, not the one the document
    /// was minted with — otherwise every list says "Untitled document" until the replay.
    func testAListedLocalDocumentShowsTheRenamedTitle() {
        let (coordinator, _, _) = makeCoordinator()
        let document = coordinator.createLocalDocument(title: "Untitled document", parentID: nil)

        coordinator.enqueue(documentID: document.id, title: "Notes", markdown: "# Typed offline")

        XCTAssertEqual(coordinator.pendingLocalDocuments(parentID: nil).first?.title, "Notes")
    }

    /// The record outlives the process that minted it, so a relaunch still knows the
    /// document is local — which is what keeps the holds below in force from the first
    /// `enqueue` of the new process, before any replay has run.
    func testAPendingCreateSurvivesARelaunch() {
        let (coordinator, draftStore, createStore) = makeCoordinator()
        let document = coordinator.createLocalDocument(title: "Untitled document", parentID: nil)

        let (relaunched, _, _) = makeCoordinatorSharing(createStore, draftStore: draftStore)

        XCTAssertTrue(relaunched.isPendingCreate(documentID: document.id))
    }

    // MARK: - Hold 1: no PATCH may name an id the server has never seen

    /// The document has no server id, so `saveDocumentContent` would PATCH
    /// `documents/<local-uuid>/content/` and 404. That is not retryable, so the state
    /// would land on `.failed` — and `runSyncPass` skips `.failed` drafts, wedging the
    /// document out of the replay that is supposed to rescue it.
    func testEditingAPendingCreateWritesTheDraftAndIssuesNoRequest() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        let (coordinator, draftStore, _) = makeCoordinator()
        let document = coordinator.createLocalDocument(title: "Untitled document", parentID: nil)

        coordinator.enqueue(documentID: document.id, title: "Notes", markdown: "# Typed offline")

        await waitAndConfirmNever { self.savesInFlight(log) > 0 }
        XCTAssertEqual(draftStore.draft(for: document.id)?.markdown, "# Typed offline", "write-ahead still applies")
        XCTAssertEqual(coordinator.state(for: document.id), .pendingSync)
    }

    /// The held save must stay visible to the editor: `pendingSave` is what
    /// `restoreLocalContent` and `hasUnsavedLocalContent` read, and a held save that
    /// vanished from it would let the screen claim there is nothing unsaved.
    func testAHeldCreateSaveIsStillVisibleAsPendingWork() {
        let (coordinator, _, _) = makeCoordinator()
        let document = coordinator.createLocalDocument(title: "Untitled document", parentID: nil)

        coordinator.enqueue(documentID: document.id, title: "Notes", markdown: "# Typed offline")

        XCTAssertEqual(coordinator.pendingSave(documentID: document.id)?.markdown, "# Typed offline")
    }

    /// Latest-wins still holds while parked: the next keystroke replaces the queued slot
    /// rather than stacking, so the replay pushes the newest content once.
    func testASecondEditReplacesTheHeldOne() {
        let (coordinator, draftStore, _) = makeCoordinator()
        let document = coordinator.createLocalDocument(title: "Untitled document", parentID: nil)

        coordinator.enqueue(documentID: document.id, title: "Notes", markdown: "# First")
        coordinator.enqueue(documentID: document.id, title: "Notes", markdown: "# Second")

        XCTAssertEqual(coordinator.pendingSave(documentID: document.id)?.markdown, "# Second")
        XCTAssertEqual(draftStore.draft(for: document.id)?.markdown, "# Second")
    }

    /// `clearResolvedConflict` releases whatever the hold was parking by calling `start`
    /// **directly** — the one path that reaches the network without passing through
    /// `enqueue`'s hold, and the editor clears conflicts from five places. For a document
    /// the server has never seen that would PATCH a nonexistent id, take a 404, and land on
    /// `.failed`, which `runSyncPass` skips: wedged out of the replay meant to create it.
    /// The held save must stay parked *and* stay held — dropping it would lose the content.
    func testReleasingAHoldNeverStartsASaveForAPendingCreate() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        let (coordinator, _, _) = makeCoordinator()
        let document = coordinator.createLocalDocument(title: "Untitled document", parentID: nil)
        coordinator.enqueue(documentID: document.id, title: "Notes", markdown: "# Typed offline")

        coordinator.clearResolvedConflict(documentID: document.id)

        await waitAndConfirmNever { self.savesInFlight(log) > 0 }
        XCTAssertEqual(
            coordinator.pendingSave(documentID: document.id)?.markdown, "# Typed offline",
            "the held save is kept, not dropped on the floor")
    }

    // MARK: - Hold 2: the sync pass must not destroy a local document

    /// The pass GETs every draft's document before deciding. A local id 404s, and the
    /// existing catch removes the draft — which for a document that exists nowhere else
    /// is the user's only copy. Without this guard the first launch, foreground, or
    /// reconnect after creating a document offline silently deletes it.
    /// Deliberately does **not** enqueue first: a queued save would make the pre-existing
    /// `queued[…] == nil` guard `continue` on the next line, so the test would stay green
    /// with hold 2 deleted and would be pinning machinery that predates this change.
    /// A freshly-minted document with only its seed draft reaches the new guard directly.
    func testASyncPassNeverFetchesAPendingCreate() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 404, headers: [:], body: Data(), error: nil)
        }
        let (coordinator, draftStore, createStore) = makeCoordinator()
        let document = coordinator.createLocalDocument(title: "Untitled document", parentID: nil)

        await coordinator.syncPendingDrafts()

        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "formatted-content"), 0, "hold 2: no GET at all")
        XCTAssertNotNil(draftStore.draft(for: document.id))
        XCTAssertNotNil(createStore.create(for: document.id))
    }

    /// The same protection has to survive a *relaunch*, because that is when
    /// `recoverDrafts()` runs — the pass most likely to meet a local document first. The
    /// relaunched coordinator has an empty `queued`, so this reaches the guard even with
    /// content typed.
    func testLaunchRecoveryNeitherFetchesNorDiscardsAPendingCreate() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 404, headers: [:], body: Data(), error: nil)
        }
        let (coordinator, draftStore, createStore) = makeCoordinator()
        let document = coordinator.createLocalDocument(title: "Untitled document", parentID: nil)
        coordinator.enqueue(documentID: document.id, title: "Notes", markdown: "# Typed offline")

        let (relaunched, _, _) = makeCoordinatorSharing(createStore, draftStore: draftStore)
        await relaunched.recoverDrafts()

        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "formatted-content"), 0)
        XCTAssertEqual(draftStore.draft(for: document.id)?.markdown, "# Typed offline")
        XCTAssertNotNil(createStore.create(for: document.id))
    }

    /// The state has to survive a relaunch too: `states` is in-memory while the record is
    /// on disk, so without seeding it the reading surface would show "Edited just now"
    /// for a document that exists nowhere but this device.
    func testAPendingCreateStillReportsPendingSyncAfterARelaunch() {
        let (coordinator, draftStore, createStore) = makeCoordinator()
        let document = coordinator.createLocalDocument(title: "Untitled document", parentID: nil)

        let (relaunched, _, _) = makeCoordinatorSharing(createStore, draftStore: draftStore)

        XCTAssertEqual(relaunched.state(for: document.id), .pendingSync)
    }

    /// A real server document is unaffected: its 404 still means "deleted elsewhere",
    /// and its draft is still dropped. The guard must be narrow.
    func testAServerDocumentsDraftIsStillDroppedOnA404() async {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 404, headers: [:], body: Data(), error: nil) }
        let (coordinator, draftStore, _) = makeCoordinator()
        let serverID = UUID()
        draftStore.save(
            PendingDraft(documentID: serverID, title: "Doc", markdown: "# Stale", updatedAt: Date()))

        await coordinator.syncPendingDrafts()

        XCTAssertNil(draftStore.draft(for: serverID))
    }

    // MARK: - Deleting a local document

    /// Deleting a local document is purely local — there is no server object to DELETE —
    /// so the record has to go with the draft, or the replay would resurrect a document
    /// the user threw away.
    func testDiscardingPendingWorkRemovesTheCreateRecordToo() {
        let (coordinator, draftStore, createStore) = makeCoordinator()
        let document = coordinator.createLocalDocument(title: "Untitled document", parentID: nil)
        coordinator.enqueue(documentID: document.id, title: "Notes", markdown: "# Typed offline")

        coordinator.discardPendingWork(documentID: document.id)

        XCTAssertNil(createStore.create(for: document.id))
        XCTAssertNil(draftStore.draft(for: document.id))
        XCTAssertFalse(coordinator.isPendingCreate(documentID: document.id))
    }

    /// A 404/403 on a *server* document keeps its draft (the user's unsaved work) — and
    /// a local document can never legitimately reach that path, so nothing there may
    /// touch the create record either.
    func testSuppressingLocalWriteThroughLeavesACreateRecordAlone() {
        let (coordinator, _, createStore) = makeCoordinator()
        let document = coordinator.createLocalDocument(title: "Untitled document", parentID: nil)

        coordinator.suppressLocalWriteThrough(documentID: document.id)

        XCTAssertNotNil(createStore.create(for: document.id))
    }

    // MARK: - Helpers

    /// A second coordinator over the same stores — a relaunch, or the same device signed
    /// in to a different server.
    private func makeCoordinatorSharing(
        _ createStore: PendingDocumentCreateStore,
        draftStore: PendingDraftStore? = nil,
        serverOrigin: String? = nil
    ) -> (DocumentSaveCoordinator, PendingDraftStore, PendingDocumentCreateStore) {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let suiteName = "CoordinatorCreateTests.spare.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let drafts = draftStore ?? PendingDraftStore(userDefaults: UserDefaults(suiteName: suiteName)!)
        let coordinator = DocumentSaveCoordinator(
            client: client,
            draftStore: drafts,
            contentCache: DocumentContentCacheStore(directory: cacheDirectory),
            createStore: createStore,
            serverOrigin: serverOrigin ?? origin,
            backgroundTasks: .noop
        )
        return (coordinator, drafts, createStore)
    }
}
