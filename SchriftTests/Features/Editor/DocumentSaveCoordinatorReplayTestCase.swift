import XCTest

@testable import Schrift

/// Shared fixtures for the create-replay suites (`DocumentSaveCoordinatorReplay*Tests`): the
/// coordinator environment and the request stubs. Holds no tests of its own.
@MainActor
class DocumentSaveCoordinatorReplayTestCase: XCTestCase {
    let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    let origin = "https://docs.example.org"
    let user = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let serverID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    /// The chained-create fixtures. A parent and its sub-pages must be given **different**
    /// server ids, or a test asserting "the sub-page went to its parent's children route"
    /// would pass on an implementation that filed everything under one document.
    let rootServerID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    let childServerID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    let grandchildServerID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    let restartedServerID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
    var cacheDirectory: URL!
    var suiteNames: [String] = []

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplayTests-\(UUID().uuidString)", isDirectory: true)
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

    struct Environment {
        let coordinator: DocumentSaveCoordinator
        let drafts: PendingDraftStore
        let creates: PendingDocumentCreateStore
        let lists: DocumentCacheStore
        let children: DocumentChildrenCacheStore
        let defaults: UserDefaults
    }

    func makeEnvironment(sharing defaults: UserDefaults? = nil, appBuild: String = "1") -> Environment {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let defaults =
            defaults
            ?? {
                let name = "ReplayTests.\(UUID().uuidString)"
                suiteNames.append(name)
                return UserDefaults(suiteName: name)!
            }()
        let drafts = PendingDraftStore(userDefaults: defaults)
        let creates = PendingDocumentCreateStore(userDefaults: defaults)
        let lists = DocumentCacheStore(userDefaults: defaults)
        let children = DocumentChildrenCacheStore(userDefaults: defaults)
        return Environment(
            coordinator: DocumentSaveCoordinator(
                client: client, draftStore: drafts,
                contentCache: DocumentContentCacheStore(directory: cacheDirectory),
                createStore: creates, listCache: lists, childrenCache: children,
                serverOrigin: origin, appBuild: appBuild, backgroundTasks: .noop),
            drafts: drafts, creates: creates, lists: lists, children: children, defaults: defaults)
    }

    /// `/users/me/`, the create `POST`, the `formatted-content` GET the draft replay makes,
    /// and the two save PATCHes. `createdAt`/`updatedAt` on the create response is the
    /// baseline the migration stamps, and the GET echoes it so rule 2 sees a server that has
    /// not moved past it.
    func stubReplayPipeline(
        log: RequestRecorder,
        serverUpdatedAt: String = "2026-03-01T12:00:00Z",
        createStatus: Int = 201,
        title: String = "Untitled document",
        postDelay: TimeInterval = 0
    ) {
        let userBody = Data(
            """
            {"id": "11111111-1111-4111-8111-111111111111", "email": "a@example.org"}
            """.utf8)
        let createdBody = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "\(title)",
             "abilities": {"destroy": true, "partial_update": true},
             "content": "", "created_at": "\(serverUpdatedAt)", "updated_at": "\(serverUpdatedAt)",
             "depth": 1, "numchild": 0, "path": "00000A", "link_reach": "restricted",
             "link_role": "reader", "user_role": "owner"}
            """.utf8)
        let formattedBody = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "\(title)", "content": "",
             "created_at": "\(serverUpdatedAt)", "updated_at": "\(serverUpdatedAt)"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            switch request.httpMethod {
            case "GET" where url.hasSuffix("users/me/"):
                return .init(statusCode: 200, headers: [:], body: userBody, error: nil)
            case "GET" where url.contains("formatted-content"):
                return .init(statusCode: 200, headers: [:], body: formattedBody, error: nil)
            case "GET":
                return .init(statusCode: 200, headers: [:], body: createdBody, error: nil)
            case "POST":
                return .init(
                    statusCode: createStatus, headers: [:], body: createdBody, error: nil, delay: postDelay)
            default:
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
            }
        }
    }

    /// A pipeline that hands out a **different** server id per create, so a parent and its
    /// sub-pages can be told apart in the request log. `childIDs` maps the parent server id a
    /// `children/` POST addresses onto the id the server assigns; a POST under any *other*
    /// parent answers DRF's JSON 404 — which is exactly what a client-minted id would really
    /// get, so a regression that sends a sub-page too early fails here rather than passing
    /// against an over-obliging stub.
    func stubChainedReplayPipeline(
        log: RequestRecorder, rootID: UUID, childIDs: [UUID: UUID],
        updatedAt: String = "2026-03-01T12:00:00Z"
    ) {
        let ids = Set([rootID] + Array(childIDs.values))
        let documents = Dictionary(
            uniqueKeysWithValues: ids.map { id in
                (
                    id,
                    Data(
                        """
                        {"id": "\(id.uuidString.lowercased())", "title": "Untitled document",
                         "abilities": {"destroy": true, "partial_update": true, "children_create": true},
                         "content": "", "created_at": "\(updatedAt)", "updated_at": "\(updatedAt)",
                         "depth": 1, "numchild": 0, "path": "00000A", "link_reach": "restricted",
                         "link_role": "reader", "user_role": "owner"}
                        """.utf8)
                )
            })
        let contents = Dictionary(
            uniqueKeysWithValues: ids.map { id in
                (
                    id,
                    Data(
                        """
                        {"id": "\(id.uuidString.lowercased())", "title": "Untitled document", "content": "",
                         "created_at": "\(updatedAt)", "updated_at": "\(updatedAt)"}
                        """.utf8)
                )
            })
        let rootBody = documents[rootID] ?? Data()
        let missing = Data("{\"detail\": \"Not found.\"}".utf8)
        stubUsersMeThen(log: log) { request in
            let url = request.url?.absoluteString ?? ""
            let addressed = addressedDocumentID(in: url)
            switch request.httpMethod {
            case "POST" where url.contains("/children/"):
                guard let parent = addressed, let assigned = childIDs[parent], let body = documents[assigned]
                else { return .init(statusCode: 404, headers: [:], body: missing, error: nil) }
                return .init(statusCode: 201, headers: [:], body: body, error: nil)
            case "POST":
                return .init(statusCode: 201, headers: [:], body: rootBody, error: nil)
            case "GET":
                guard let id = addressed,
                    let body = url.contains("formatted-content") ? contents[id] : documents[id]
                else { return .init(statusCode: 404, headers: [:], body: missing, error: nil) }
                return .init(statusCode: 200, headers: [:], body: body, error: nil)
            default:
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
            }
        }
    }

    func creates(_ log: RequestRecorder) -> Int {
        log.count(ofMethod: "POST", urlContaining: "documents/")
    }

    func savesInFlight(_ log: RequestRecorder) -> Int {
        log.count(ofMethod: "PATCH", urlContaining: "/content/")
    }

    /// `/users/me/` answers this user; everything else is the caller's to decide.
    func stubUsersMeThen(
        log: RequestRecorder, _ handler: @escaping @Sendable (URLRequest) -> MockURLProtocol.Stub
    ) {
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            if request.url?.absoluteString.hasSuffix("users/me/") == true {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data("{\"id\": \"11111111-1111-4111-8111-111111111111\"}".utf8), error: nil)
            }
            return handler(request)
        }
    }
}

/// The document id a request addresses — `documents/<uuid>/children/`,
/// `documents/<uuid>/formatted-content/`, or `documents/<uuid>/`.
///
/// Free rather than a method on the suite: stub handlers are `@Sendable` and run off the
/// main actor, so they cannot call into a `@MainActor` test class.
func addressedDocumentID(in url: String) -> UUID? {
    guard let marker = url.range(of: "documents/") else { return nil }
    return UUID(uuidString: String(url[marker.upperBound...].prefix(36)))
}
