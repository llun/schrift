import XCTest
@testable import Schrift

@MainActor
final class DocumentSaveCoordinatorTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!
    private let otherDocumentID = UUID(uuidString: "9C2C2C2C-2C2C-4C2C-8C2C-2C2C2C2C2C2C")!

    private static let tempDocBody = Data("""
    {"id": "22222222-2222-4222-8222-222222222222", "title": "Doc.md", "excerpt": null, "abilities": {}, "computed_link_reach": "restricted", "computed_link_role": null, "created_at": "2026-01-15T10:30:00Z", "creator": null, "depth": 1, "link_role": "reader", "link_reach": "restricted", "numchild": 0, "path": "0002", "updated_at": "2026-01-15T10:30:00Z", "user_role": "owner", "is_favorite": false}
    """.utf8)

    private static let formattedBody = Data("""
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

    override func tearDown() {
        MockURLProtocol.stubHandler = nil
        MockURLProtocol.lastRequest = nil
        super.tearDown()
    }

    private func makeCoordinator(
        backgroundTasks: BackgroundTaskProvider = .noop
    ) -> (DocumentSaveCoordinator, PendingDraftStore) {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let suiteName = "DocumentSaveCoordinatorTests.\(UUID().uuidString)"
        let draftStore = PendingDraftStore(userDefaults: UserDefaults(suiteName: suiteName)!)
        let coordinator = DocumentSaveCoordinator(client: client, draftStore: draftStore, backgroundTasks: backgroundTasks)
        return (coordinator, draftStore)
    }

    private func stubSavePipeline(log: RequestRecorder, postDelay: TimeInterval = 0, patchStatus: Int = 204) {
        let tempDocBody = Self.tempDocBody
        let formattedBody = Self.formattedBody
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            switch request.httpMethod {
            case "POST":
                if postDelay > 0 {
                    Thread.sleep(forTimeInterval: postDelay)
                }
                return .init(statusCode: 201, headers: [:], body: tempDocBody, error: nil)
            case "GET" where request.url?.absoluteString.contains("formatted-content") == true:
                return .init(statusCode: 200, headers: [:], body: formattedBody, error: nil)
            case "GET":
                return .init(statusCode: 200, headers: [:], body: Data([0xAA]), error: nil)
            case "PATCH":
                return .init(statusCode: patchStatus, headers: [:], body: Data(), error: nil)
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
        let (coordinator, draftStore) = makeCoordinator(backgroundTasks: recorder.provider)

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Content")

        // Write-ahead: the draft exists before the save completes.
        XCTAssertNotNil(draftStore.draft(for: documentID))

        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        XCTAssertTrue(isSaved(coordinator.state(for: documentID)))
        XCTAssertEqual(log.methods, ["POST", "GET", "PATCH", "DELETE"])
        XCTAssertNil(draftStore.draft(for: documentID))
        XCTAssertEqual(recorder.beginCount, 1)
        XCTAssertEqual(recorder.endCount, 1)
    }

    func testEnqueueWhileInFlightCoalescesToLatestContent() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log, postDelay: 0.2)
        let (coordinator, draftStore) = makeCoordinator()

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "v1")
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "v2")
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "v3")

        XCTAssertEqual(coordinator.pendingSave(documentID: documentID)?.markdown, "v3")

        await waitUntil(timeout: 5) {
            self.isSaved(coordinator.state(for: self.documentID)) && log.count(ofMethod: "POST") == 2
        }

        // v1 saved, v2 dropped by coalescing, v3 saved as the follow-up.
        XCTAssertEqual(log.count(ofMethod: "POST"), 2)
        XCTAssertNil(coordinator.pendingSave(documentID: documentID))
        XCTAssertNil(draftStore.draft(for: documentID))
    }

    func testReenqueueingIdenticalContentWhileInFlightSkipsFollowUp() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log, postDelay: 0.2)
        let (coordinator, _) = makeCoordinator()

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "same")
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "same")

        await waitUntil(timeout: 5) { self.isSaved(coordinator.state(for: self.documentID)) }
        // Give any (incorrect) follow-up a moment to start.
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(log.count(ofMethod: "POST"), 1)
    }

    func testFailedSaveKeepsDraftAndReportsFailure() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log, patchStatus: 500)
        let (coordinator, draftStore) = makeCoordinator()

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Content")

        await waitUntil { self.isFailed(coordinator.state(for: self.documentID)) }

        XCTAssertTrue(isFailed(coordinator.state(for: documentID)))
        XCTAssertEqual(draftStore.draft(for: documentID)?.markdown, "# Content")
    }

    func testDocumentsSaveIndependently() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, _) = makeCoordinator()

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
        let (coordinator, draftStore) = makeCoordinator()
        // Server updated_at is 2026-01-15; a draft written "now" is newer.
        draftStore.save(PendingDraft(documentID: documentID, title: "Doc", markdown: "# Draft", updatedAt: Date()))

        await coordinator.recoverDrafts()
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        XCTAssertTrue(isSaved(coordinator.state(for: documentID)))
        XCTAssertGreaterThanOrEqual(log.count(ofMethod: "POST"), 1)
        XCTAssertNil(draftStore.draft(for: documentID))
    }

    func testRecoverDraftsDiscardsDraftOlderThanServer() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, draftStore) = makeCoordinator()
        draftStore.save(PendingDraft(documentID: documentID, title: "Doc", markdown: "# Stale", updatedAt: Date(timeIntervalSince1970: 0)))

        await coordinator.recoverDrafts()

        XCTAssertNil(draftStore.draft(for: documentID))
        XCTAssertEqual(log.count(ofMethod: "POST"), 0)
    }

    func testRecoverDraftsDropsDraftForInaccessibleDocument() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 404, headers: [:], body: Data(), error: nil)
        }
        let (coordinator, draftStore) = makeCoordinator()
        draftStore.save(PendingDraft(documentID: documentID, title: "Doc", markdown: "# Gone", updatedAt: Date()))

        await coordinator.recoverDrafts()

        XCTAssertNil(draftStore.draft(for: documentID))
        XCTAssertEqual(log.count(ofMethod: "POST"), 0)
    }

    func testRecoverDraftsRunsOnlyOnce() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, draftStore) = makeCoordinator()
        draftStore.save(PendingDraft(documentID: documentID, title: "Doc", markdown: "# Draft", updatedAt: Date()))

        await coordinator.recoverDrafts()
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
        let postsAfterFirstRecovery = log.count(ofMethod: "POST")

        await coordinator.recoverDrafts()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(log.count(ofMethod: "POST"), postsAfterFirstRecovery)
    }
}
