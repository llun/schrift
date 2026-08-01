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

    func testPendingLocalDocumentsAreScopedToTheirParent() {
        let (coordinator, _, _) = makeCoordinator()
        let parent = UUID()
        let root = coordinator.createLocalDocument(title: "Root", parentID: nil)
        let child = coordinator.createLocalDocument(title: "Child", parentID: parent)

        XCTAssertEqual(coordinator.pendingLocalDocuments(parentID: nil).map(\.id), [root.id])
        XCTAssertEqual(coordinator.pendingLocalDocuments(parentID: parent).map(\.id), [child.id])
    }

    /// Records minted against another server stay dormant: drafts and metadata caches
    /// deliberately survive sign-out, so without this a create could be replayed into a
    /// different account — POSTing the user's content somewhere they never wrote it.
    /// Dormant, never deleted: they come back if the user signs back in.
    func testARecordFromAnotherOriginIsNeitherPendingHereNorListed() {
        let (first, _, createStore) = makeCoordinator()
        let document = first.createLocalDocument(title: "Written elsewhere", parentID: nil)
        XCTAssertNotNil(createStore.create(for: document.id))

        let (elsewhere, _, _) = makeCoordinatorSharing(createStore, serverOrigin: "https://other.example.org")

        XCTAssertFalse(elsewhere.isPendingCreate(documentID: document.id))
        XCTAssertTrue(elsewhere.pendingLocalDocuments(parentID: nil).isEmpty)
        XCTAssertNotNil(createStore.create(for: document.id), "dormant, not deleted — the user may sign back in")
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
    func testASyncPassNeitherFetchesNorDeletesAPendingCreate() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 404, headers: [:], body: Data(), error: nil)
        }
        let (coordinator, draftStore, createStore) = makeCoordinator()
        let document = coordinator.createLocalDocument(title: "Untitled document", parentID: nil)
        coordinator.enqueue(documentID: document.id, title: "Notes", markdown: "# Typed offline")

        await coordinator.syncPendingDrafts()

        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "formatted-content"), 0)
        XCTAssertEqual(draftStore.draft(for: document.id)?.markdown, "# Typed offline")
        XCTAssertNotNil(createStore.create(for: document.id))
    }

    /// The same protection has to survive a *relaunch*, because that is when
    /// `recoverDrafts()` runs — the pass most likely to meet a local document first.
    func testLaunchRecoveryDoesNotDiscardAPendingCreate() async {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 404, headers: [:], body: Data(), error: nil) }
        let (coordinator, draftStore, createStore) = makeCoordinator()
        let document = coordinator.createLocalDocument(title: "Untitled document", parentID: nil)
        coordinator.enqueue(documentID: document.id, title: "Notes", markdown: "# Typed offline")

        let (relaunched, _, _) = makeCoordinatorSharing(createStore, draftStore: draftStore)
        await relaunched.recoverDrafts()

        XCTAssertEqual(draftStore.draft(for: document.id)?.markdown, "# Typed offline")
        XCTAssertNotNil(createStore.create(for: document.id))
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
