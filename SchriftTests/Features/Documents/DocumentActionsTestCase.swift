import XCTest

@testable import Schrift

/// Shared environment for the `DocumentActions…Tests` classes (delete, pin, move). Holds no tests.
@MainActor
class DocumentActionsTestCase: XCTestCase {
    let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    let documentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let ownerID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    let serverID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    var suiteNames: [String] = []
    var cacheDirectories: [URL] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        for directory in cacheDirectories { try? FileManager.default.removeItem(at: directory) }
        cacheDirectories.removeAll()
        MockURLProtocol.reset()
        super.tearDown()
    }

    struct Environment {
        let actions: DocumentActions
        let coordinator: DocumentSaveCoordinator
        let drafts: PendingDraftStore
        let creates: PendingDocumentCreateStore
        let deletes: PendingDocumentDeleteStore
        let contentCache: DocumentContentCacheStore
        let client: DocsAPIClient
        let defaults: UserDefaults
        let signedIn: SignedInUserStore
    }

    func makeEnvironment(signedInUserID: UUID? = nil) -> Environment {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let suiteName = "DocumentActionsTests.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        let drafts = PendingDraftStore(userDefaults: defaults)
        let creates = PendingDocumentCreateStore(userDefaults: defaults)
        let deletes = PendingDocumentDeleteStore(userDefaults: defaults)
        // Its own directory, never the real Application Support one — these tests write and
        // delete document bodies, and the shared store is not suite-scoped the way the
        // UserDefaults-backed ones are.
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentActionsTests/\(UUID().uuidString)", isDirectory: true)
        cacheDirectories.append(cacheDirectory)
        let contentCache = DocumentContentCacheStore(directory: cacheDirectory)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: drafts, contentCache: contentCache,
            createStore: creates, deleteStore: deletes,
            listCache: DocumentCacheStore(userDefaults: defaults),
            childrenCache: DocumentChildrenCacheStore(userDefaults: defaults),
            serverOrigin: "https://docs.example.org", backgroundTasks: .noop)
        let signedIn = SignedInUserStore(userDefaults: defaults)
        signedIn.remember(signedInUserID ?? ownerID)
        return Environment(
            actions: DocumentActions(client: client, saveCoordinator: coordinator, signedInUser: signedIn),
            coordinator: coordinator, drafts: drafts, creates: creates, deletes: deletes,
            contentCache: contentCache, client: client, defaults: defaults, signedIn: signedIn)
    }

    func stubNoContent(_ log: RequestRecorder? = nil) {
        MockURLProtocol.stubHandler = { request in
            log?.record(request)
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
    }
}
