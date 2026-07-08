import XCTest

@testable import Schrift

@MainActor
final class DocumentSaveCoordinatorTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!
    private let otherDocumentID = UUID(uuidString: "9C2C2C2C-2C2C-4C2C-8C2C-2C2C2C2C2C2C")!
    private var cacheDirectory: URL!

    private static let formattedBody = Data(
        """
        {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "Server content", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
        """.utf8)

    @MainActor
    private final class BackgroundTaskRecorder {
        var beginCount = 0
        var endCount = 0

        var provider: BackgroundTaskProvider {
            BackgroundTaskProvider(
                begin: { [weak self] _ in
                    self?.beginCount += 1
                    return 7
                },
                end: { [weak self] _ in
                    self?.endCount += 1
                }
            )
        }
    }

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentSaveCoordinatorTests.\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        MockURLProtocol.stubHandler = nil
        MockURLProtocol.lastRequest = nil
        try? FileManager.default.removeItem(at: cacheDirectory)
        cacheDirectory = nil
        super.tearDown()
    }

    private func makeCoordinator(
        backgroundTasks: BackgroundTaskProvider = .noop
    ) -> (DocumentSaveCoordinator, PendingDraftStore, DocumentContentCacheStore) {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let suiteName = "DocumentSaveCoordinatorTests.\(UUID().uuidString)"
        let draftStore = PendingDraftStore(userDefaults: UserDefaults(suiteName: suiteName)!)
        let contentCache = DocumentContentCacheStore(directory: cacheDirectory)
        let coordinator = DocumentSaveCoordinator(
            client: client,
            draftStore: draftStore,
            contentCache: contentCache,
            backgroundTasks: backgroundTasks
        )
        return (coordinator, draftStore, contentCache)
    }

    /// A save is now two PATCHes: content (base64 Yjs) then title. Each save is
    /// counted by its single content PATCH. `recoverDrafts` first GETs
    /// formatted-content to compare timestamps.
    private func savesInFlight(_ log: RequestRecorder) -> Int {
        log.count(ofMethod: "PATCH", urlContaining: "/content/")
    }

    private func stubSavePipeline(log: RequestRecorder, saveDelay: TimeInterval = 0, contentStatus: Int = 204) {
        let formattedBody = Self.formattedBody
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            switch request.httpMethod {
            case "GET" where url.contains("formatted-content"):
                return .init(statusCode: 200, headers: [:], body: formattedBody, error: nil)
            case "PATCH" where url.hasSuffix("/content/"):
                if saveDelay > 0 {
                    Thread.sleep(forTimeInterval: saveDelay)
                }
                return .init(statusCode: contentStatus, headers: [:], body: Data(), error: nil)
            case "PATCH":
                return .init(statusCode: 200, headers: [:], body: Data(), error: nil)  // title
            default:
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
            }
        }
    }

    private func isSaved(_ state: DocumentSaveCoordinator.DocSaveState) -> Bool {
        if case .saved = state { return true }
        return false
    }

    private func isFailed(_ state: DocumentSaveCoordinator.DocSaveState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    func testEnqueueRunsPipelineClearsDraftAndBalancesBackgroundTask() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let recorder = BackgroundTaskRecorder()
        let (coordinator, draftStore, _) = makeCoordinator(backgroundTasks: recorder.provider)

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Content")

        // Write-ahead: the draft exists before the save completes.
        XCTAssertNotNil(draftStore.draft(for: documentID))

        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        XCTAssertTrue(isSaved(coordinator.state(for: documentID)))
        // A save PATCHes content (base64 Yjs) then title.
        XCTAssertEqual(log.methods, ["PATCH", "PATCH"])
        XCTAssertEqual(savesInFlight(log), 1)
        XCTAssertNil(draftStore.draft(for: documentID))
        XCTAssertEqual(recorder.beginCount, 1)
        XCTAssertEqual(recorder.endCount, 1)
    }

    func testEnqueueWhileInFlightCoalescesToLatestContent() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log, saveDelay: 0.2)
        let (coordinator, draftStore, _) = makeCoordinator()

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "v1")
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "v2")
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "v3")

        XCTAssertEqual(coordinator.pendingSave(documentID: documentID)?.markdown, "v3")

        await waitUntil(timeout: 5) {
            self.isSaved(coordinator.state(for: self.documentID)) && self.savesInFlight(log) == 2
        }

        // v1 saved, v2 dropped by coalescing, v3 saved as the follow-up.
        XCTAssertEqual(savesInFlight(log), 2)
        XCTAssertNil(coordinator.pendingSave(documentID: documentID))
        XCTAssertNil(draftStore.draft(for: documentID))
    }

    func testReenqueueingIdenticalContentWhileInFlightSkipsFollowUp() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log, saveDelay: 0.2)
        let (coordinator, _, _) = makeCoordinator()

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "same")
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "same")

        await waitUntil(timeout: 5) { self.isSaved(coordinator.state(for: self.documentID)) }
        // Give any (incorrect) follow-up a moment to start.
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(savesInFlight(log), 1)
    }

    func testFailedSaveKeepsDraftAndReportsFailure() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log, contentStatus: 500)
        let (coordinator, draftStore, _) = makeCoordinator()

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Content")

        await waitUntil { self.isFailed(coordinator.state(for: self.documentID)) }

        XCTAssertTrue(isFailed(coordinator.state(for: documentID)))
        XCTAssertEqual(draftStore.draft(for: documentID)?.markdown, "# Content")
    }

    func testDocumentsSaveIndependently() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, _, _) = makeCoordinator()

        coordinator.enqueue(documentID: documentID, title: "A", markdown: "a")
        coordinator.enqueue(documentID: otherDocumentID, title: "B", markdown: "b")

        await waitUntil {
            self.isSaved(coordinator.state(for: self.documentID))
                && self.isSaved(coordinator.state(for: self.otherDocumentID))
        }

        XCTAssertTrue(isSaved(coordinator.state(for: documentID)))
        XCTAssertTrue(isSaved(coordinator.state(for: otherDocumentID)))
    }

    func testRecoverDraftsReplaysDraftNewerThanServer() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, draftStore, _) = makeCoordinator()
        // Server updated_at is 2026-01-15; a draft written "now" is newer.
        draftStore.save(PendingDraft(documentID: documentID, title: "Doc", markdown: "# Draft", updatedAt: Date()))

        await coordinator.recoverDrafts()
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        XCTAssertTrue(isSaved(coordinator.state(for: documentID)))
        XCTAssertGreaterThanOrEqual(savesInFlight(log), 1)
        XCTAssertNil(draftStore.draft(for: documentID))
    }

    func testRecoverDraftsDiscardsDraftOlderThanServer() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, draftStore, _) = makeCoordinator()
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Stale", updatedAt: Date(timeIntervalSince1970: 0)))

        await coordinator.recoverDrafts()

        XCTAssertNil(draftStore.draft(for: documentID))
        XCTAssertEqual(savesInFlight(log), 0)
    }

    func testRecoverDraftsDropsDraftForInaccessibleDocument() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 404, headers: [:], body: Data(), error: nil)
        }
        let (coordinator, draftStore, _) = makeCoordinator()
        draftStore.save(PendingDraft(documentID: documentID, title: "Doc", markdown: "# Gone", updatedAt: Date()))

        await coordinator.recoverDrafts()

        XCTAssertNil(draftStore.draft(for: documentID))
        XCTAssertEqual(savesInFlight(log), 0)
    }

    func testRecoverDraftsRunsOnlyOnce() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, draftStore, _) = makeCoordinator()
        draftStore.save(PendingDraft(documentID: documentID, title: "Doc", markdown: "# Draft", updatedAt: Date()))

        await coordinator.recoverDrafts()
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
        let savesAfterFirstRecovery = savesInFlight(log)

        await coordinator.recoverDrafts()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(savesInFlight(log), savesAfterFirstRecovery)
    }

    func testSaveSuccessWritesContentCacheEntry() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, _, contentCache) = makeCoordinator(backgroundTasks: .noop)

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Content")
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        let entry = contentCache.content(for: documentID)
        XCTAssertEqual(entry?.title, "Doc")
        XCTAssertEqual(entry?.markdown, "# Content")
        XCTAssertNotNil(entry?.syncedAt)
    }

    func testSaveFailureWritesNoContentCacheEntry() async {
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 500, headers: [:], body: Data(), error: nil)
        }
        let (coordinator, _, contentCache) = makeCoordinator(backgroundTasks: .noop)

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Content")
        await waitUntil {
            if case .failed = coordinator.state(for: self.documentID) { return true }
            return false
        }

        XCTAssertNil(contentCache.content(for: documentID))
    }

    func testDiscardStoredDraftRemovesOnlyIfUnchanged() {
        let (coordinator, draftStore, _) = makeCoordinator(backgroundTasks: .noop)
        let original = PendingDraft(
            documentID: documentID, title: "A", markdown: "a", updatedAt: Date(timeIntervalSince1970: 100))
        draftStore.save(original)

        // Draft changed since the caller captured it: keep the newer one.
        let newer = PendingDraft(
            documentID: documentID, title: "B", markdown: "b", updatedAt: Date(timeIntervalSince1970: 200))
        draftStore.save(newer)
        coordinator.discardStoredDraft(original)
        XCTAssertEqual(draftStore.draft(for: documentID), newer)

        // Unchanged: removed.
        coordinator.discardStoredDraft(newer)
        XCTAssertNil(draftStore.draft(for: documentID))
    }

    func testDiscardPendingWorkDropsDraft() {
        let (coordinator, draftStore, _) = makeCoordinator(backgroundTasks: .noop)
        draftStore.save(PendingDraft(documentID: documentID, title: "A", markdown: "a", updatedAt: Date()))
        coordinator.discardPendingWork(documentID: documentID)
        XCTAssertNil(draftStore.draft(for: documentID))
    }

    // MARK: - Save markers (raced-revalidation detection)

    func testSaveMarkerWithNoSaveActivityDoesNotPredate() {
        let (coordinator, _, _) = makeCoordinator(backgroundTasks: .noop)
        let marker = coordinator.saveMarker(documentID: documentID)
        XCTAssertFalse(coordinator.mayPredateSave(marker, documentID: documentID))
    }

    func testSaveMarkerTakenWhileASaveIsInFlightPredates() async {
        let log = RequestRecorder()
        let (coordinator, _, _) = makeCoordinator(backgroundTasks: .noop)
        stubSavePipeline(log: log, saveDelay: 0.2)
        coordinator.enqueue(documentID: documentID, title: "A", markdown: "a")

        let marker = coordinator.saveMarker(documentID: documentID)

        XCTAssertTrue(coordinator.mayPredateSave(marker, documentID: documentID), "in flight when the marker was taken")
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
        XCTAssertTrue(coordinator.mayPredateSave(marker, documentID: documentID), "still true once it lands")
    }

    /// The case a "was a save pending?" boolean alone would miss: no save existed
    /// when the fetch was issued, but one started *and settled* while it awaited.
    func testSaveMarkerPredatesASaveThatStartedAndSettledAfterIt() async {
        let log = RequestRecorder()
        let (coordinator, _, _) = makeCoordinator(backgroundTasks: .noop)
        stubSavePipeline(log: log)
        let marker = coordinator.saveMarker(documentID: documentID)
        XCTAssertFalse(coordinator.mayPredateSave(marker, documentID: documentID))

        coordinator.enqueue(documentID: documentID, title: "A", markdown: "a")
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        XCTAssertTrue(coordinator.mayPredateSave(marker, documentID: documentID))
    }

    func testSaveMarkerPredatesAFailedSaveToo() async {
        let log = RequestRecorder()
        let (coordinator, _, _) = makeCoordinator(backgroundTasks: .noop)
        stubSavePipeline(log: log, contentStatus: 500)
        let marker = coordinator.saveMarker(documentID: documentID)

        coordinator.enqueue(documentID: documentID, title: "A", markdown: "a")
        await waitUntil {
            if case .failed = coordinator.state(for: self.documentID) { return true }
            return false
        }

        XCTAssertTrue(
            coordinator.mayPredateSave(marker, documentID: documentID),
            "a failed content PATCH may still have been applied server-side before it errored")
    }

    func testSaveMarkerIsPerDocument() async {
        let log = RequestRecorder()
        let (coordinator, _, _) = makeCoordinator(backgroundTasks: .noop)
        let otherID = UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!
        stubSavePipeline(log: log)
        let marker = coordinator.saveMarker(documentID: otherID)

        coordinator.enqueue(documentID: documentID, title: "A", markdown: "a")
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        XCTAssertFalse(coordinator.mayPredateSave(marker, documentID: otherID), "another document's save is irrelevant")
    }
}
