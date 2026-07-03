import XCTest

@testable import Schrift

@MainActor
final class DocTreePanelTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let parentID = UUID(uuidString: "9C1C1C1C-1C1C-4C1C-8C1C-1C1C1C1C1C1C")!

    private var store: DocumentChildrenCacheStore!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "DocTreePanelTests.\(UUID().uuidString)"
        store = DocumentChildrenCacheStore(userDefaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDown() {
        MockURLProtocol.stubHandler = nil
        MockURLProtocol.lastRequest = nil
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeModel() -> DocTreeModel {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        return DocTreeModel(client: client, store: store)
    }

    private static func childrenFixture(id: String, title: String) -> Data {
        """
        {
            "count": 1,
            "next": null,
            "previous": null,
            "results": [
                {
                    "id": "\(id)",
                    "title": "\(title)",
                    "excerpt": null,
                    "abilities": {},
                    "computed_link_reach": "restricted",
                    "computed_link_role": null,
                    "created_at": "2026-01-15T10:30:00Z",
                    "creator": null,
                    "depth": 2,
                    "link_role": "reader",
                    "link_reach": "restricted",
                    "numchild": 0,
                    "path": "00010001",
                    "updated_at": "2026-01-15T10:30:00Z",
                    "user_role": "owner",
                    "is_favorite": false
                }
            ]
        }
        """.data(using: .utf8)!
    }

    private func decodeChild(id: String, title: String) -> Document {
        try! JSONDecoder.docsAPI
            .decode(PaginatedResponse<Document>.self, from: Self.childrenFixture(id: id, title: title))
            .results[0]
    }

    func testLoadChildrenSeedsFromStoreWhenOffline() async {
        let cached = decodeChild(id: "11111111-1111-4111-8111-111111111111", title: "Cached child")
        store.save([cached], for: parentID)
        let model = makeModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await model.loadChildren(of: parentID)

        XCTAssertEqual(model.children(of: parentID).map(\.title), ["Cached child"])
        XCTAssertTrue(model.isLoaded(parentID))
    }

    func testLoadChildrenSuccessReplacesSeedAndPersists() async {
        let cached = decodeChild(id: "22222222-2222-4222-8222-222222222222", title: "Stale child")
        store.save([cached], for: parentID)
        let model = makeModel()
        let body = Self.childrenFixture(id: "33333333-3333-4333-8333-333333333333", title: "Fresh child")
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }

        await model.loadChildren(of: parentID)

        XCTAssertEqual(model.children(of: parentID).map(\.title), ["Fresh child"])
        XCTAssertEqual(store.children(for: parentID)?.map(\.title), ["Fresh child"])
    }

    func testLoadChildrenRevalidatesOnlyOncePerSession() async {
        let model = makeModel()
        let recorder = RequestRecorder()
        let body = Self.childrenFixture(id: "44444444-4444-4444-8444-444444444444", title: "Child")
        MockURLProtocol.stubHandler = { request in
            recorder.record(request)
            return .init(statusCode: 200, headers: [:], body: body, error: nil)
        }

        await model.loadChildren(of: parentID)
        await model.loadChildren(of: parentID)

        XCTAssertEqual(recorder.count(ofMethod: "GET"), 1)
    }

    func testFailedLoadWithoutCacheLeavesNodeUnloaded() async {
        let model = makeModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await model.loadChildren(of: parentID)

        // Not loaded ≠ loaded-empty: the panel must not claim "No subpages"
        // for a node it could never fetch.
        XCTAssertFalse(model.isLoaded(parentID))
        XCTAssertTrue(model.children(of: parentID).isEmpty)
    }

    func testFailedLoadAllowsRetry() async {
        let model = makeModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }
        await model.loadChildren(of: parentID)
        XCTAssertFalse(model.isLoaded(parentID))

        // Only a successful fetch counts as the once-per-session revalidation
        // — a transient failure must not block the node forever.
        let body = Self.childrenFixture(id: "66666666-6666-4666-8666-666666666666", title: "Recovered child")
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }
        await model.loadChildren(of: parentID)

        XCTAssertEqual(model.children(of: parentID).map(\.title), ["Recovered child"])
    }

    func testToggleExpandsAndSeedsSynchronously() async {
        let cached = decodeChild(id: "55555555-5555-4555-8555-555555555555", title: "Instant child")
        store.save([cached], for: parentID)
        let model = makeModel()
        let recorder = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            recorder.record(request)
            return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }

        model.toggle(parentID)

        // Before any network round-trip completes, the cached subtree shows.
        XCTAssertTrue(model.isExpanded(parentID))
        XCTAssertEqual(model.children(of: parentID).map(\.title), ["Instant child"])

        // Drain the revalidation Task toggle spawned so its request can't
        // leak past tearDown into another test's stub handler.
        await waitUntil { recorder.methods.count >= 1 }
    }
}
