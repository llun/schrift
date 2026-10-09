import XCTest

@testable import Schrift

/// Shared fixtures for the `DocumentSaveCoordinator*Tests` suites that exercise the coordinator
/// through a stubbed save pipeline (save, conflict, marker, rename and live-snapshot suites). Holds
/// no tests of its own.
@MainActor
class DocumentSaveCoordinatorTestCase: XCTestCase {
    let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    let documentID = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!
    let otherDocumentID = UUID(uuidString: "9C2C2C2C-2C2C-4C2C-8C2C-2C2C2C2C2C2C")!
    var cacheDirectory: URL!

    /// Every suite `makeCoordinator` creates, so tearDown can remove each persistent
    /// domain instead of leaking a plist per test.
    var draftSuiteNames: [String] = []

    static let formattedBody = Data(
        """
        {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "Server content", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
        """.utf8)

    @MainActor
    final class BackgroundTaskRecorder {
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
        draftSuiteNames = []
    }

    override func tearDown() {
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: cacheDirectory)
        cacheDirectory = nil
        for suiteName in draftSuiteNames {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    func makeCoordinator(
        backgroundTasks: BackgroundTaskProvider = .noop
    ) -> (DocumentSaveCoordinator, PendingDraftStore, DocumentContentCacheStore) {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let suiteName = "DocumentSaveCoordinatorTests.\(UUID().uuidString)"
        draftSuiteNames.append(suiteName)
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
    func savesInFlight(_ log: RequestRecorder) -> Int {
        log.count(ofMethod: "PATCH", urlContaining: "/content/")
    }

    func stubSavePipeline(log: RequestRecorder, saveDelay: TimeInterval = 0, contentStatus: Int = 204) {
        let formattedBody = Self.formattedBody
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            switch request.httpMethod {
            case "GET" where url.contains("formatted-content"):
                return .init(statusCode: 200, headers: [:], body: formattedBody, error: nil)
            case "PATCH" where url.hasSuffix("/content/"):
                return .init(statusCode: contentStatus, headers: [:], body: Data(), error: nil, delay: saveDelay)
            case "PATCH":
                return .init(statusCode: 200, headers: [:], body: Data(), error: nil)  // title
            default:
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
            }
        }
    }

    func isSaved(_ state: DocumentSaveCoordinator.DocSaveState) -> Bool {
        if case .saved = state { return true }
        return false
    }

    func isFailed(_ state: DocumentSaveCoordinator.DocSaveState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    func isPendingSync(_ state: DocumentSaveCoordinator.DocSaveState) -> Bool {
        if case .pendingSync = state { return true }
        return false
    }
}
