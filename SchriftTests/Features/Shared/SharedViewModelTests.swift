import XCTest

@testable import Schrift

@MainActor
final class SharedViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!

    private var cache: DocumentCacheStore!
    private var cacheSuiteName: String!
    private var preferences: UserDefaults!
    private var preferencesSuiteName: String!

    override func setUp() {
        super.setUp()
        cacheSuiteName = "SharedViewModelTests.\(UUID().uuidString)"
        cache = DocumentCacheStore(userDefaults: UserDefaults(suiteName: cacheSuiteName)!)
        preferencesSuiteName = "SharedViewModelTests.preferences.\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: preferencesSuiteName)!
    }

    override func tearDown() {
        MockURLProtocol.reset()
        UserDefaults(suiteName: cacheSuiteName)?.removePersistentDomain(forName: cacheSuiteName)
        preferences.removePersistentDomain(forName: preferencesSuiteName)
        super.tearDown()
    }

    private func makeViewModel() -> SharedViewModel {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        return SharedViewModel(client: client, cache: cache, userDefaults: preferences)
    }

    nonisolated private static func paginatedFixture(id: String, title: String) -> Data {
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
                    "depth": 1,
                    "link_role": "reader",
                    "link_reach": "restricted",
                    "numchild": 0,
                    "path": "0001",
                    "updated_at": "2026-01-15T10:30:00Z",
                    "user_role": "owner",
                    "is_favorite": false
                }
            ]
        }
        """.data(using: .utf8)!
    }

    private func decodeDocument(id: String, title: String) -> Document {
        try! JSONDecoder.docsAPI
            .decode(PaginatedResponse<Document>.self, from: Self.paginatedFixture(id: id, title: title))
            .results[0]
    }

    // The accesses `list` action is not paginated — the backend returns a bare
    // JSON array, not a `{count, results}` envelope.
    nonisolated private static func accessesFixture(userID: String, fullName: String) -> Data {
        """
        [
            { "id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
              "user": { "id": "\(userID)", "email": "u@x.io", "full_name": "\(fullName)", "short_name": "U" },
              "team": null, "role": "owner" }
        ]
        """.data(using: .utf8)!
    }

    func testLoadPopulatesTheSingleList() async {
        let viewModel = makeViewModel()
        let list = Self.paginatedFixture(id: "11111111-1111-4111-8111-111111111111", title: "With Me Doc")
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/accesses/") {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Self.accessesFixture(
                        userID: "55555555-5555-4555-8555-555555555555", fullName: "Amandine Salambo"),
                    error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: list, error: nil)
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.documents.map(\.title), ["With Me Doc"])
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.errorKey)
        XCTAssertFalse(viewModel.isOffline)
    }

    func testLoadRequestsSharedWithMeNotCreatorMe() async {
        let viewModel = makeViewModel()
        let recorder = RequestRecorder()
        let list = Self.paginatedFixture(id: "11111111-1111-4111-8111-111111111111", title: "With Me Doc")
        MockURLProtocol.stubHandler = { request in
            recorder.record(request)
            let url = request.url?.absoluteString ?? ""
            if url.contains("/accesses/") {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Self.accessesFixture(
                        userID: "55555555-5555-4555-8555-555555555555", fullName: "Amandine Salambo"),
                    error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: list, error: nil)
        }

        await viewModel.load()

        // The list request asks explicitly for documents NOT created by me.
        XCTAssertEqual(recorder.count(ofMethod: "GET", urlContaining: "is_creator_me=false"), 1)
        XCTAssertEqual(recorder.count(ofMethod: "GET", urlContaining: "is_creator_me=true"), 0)
    }

    func testEnrichmentPopulatesMembersAndCreatorName() async {
        let viewModel = makeViewModel()
        let docID = "11111111-1111-4111-8111-111111111111"
        let creatorID = "11111111-1111-4111-8111-111111111111"
        // A list whose `creator` matches the access user, so "Shared by" resolves.
        let list = """
            {"count":1,"next":null,"previous":null,"results":[
              {"id":"\(docID)","title":"Q2 roadmap","excerpt":null,"abilities":{},
               "computed_link_reach":"restricted","computed_link_role":null,
               "created_at":"2026-01-15T10:30:00Z","creator":"\(creatorID)","depth":1,
               "link_role":"reader","link_reach":"restricted","numchild":0,"path":"0001",
               "updated_at":"2026-01-15T10:30:00Z","user_role":"owner","is_favorite":false}]}
            """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/accesses/") {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Self.accessesFixture(userID: creatorID, fullName: "Amandine Salambo"), error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: list, error: nil)
        }

        await viewModel.load()

        let id = UUID(uuidString: docID)!
        await waitUntil { viewModel.enrichment[id] != nil }
        XCTAssertEqual(viewModel.enrichment[id]?.sharedByName, "Amandine Salambo")
        XCTAssertEqual(viewModel.enrichment[id]?.memberNames, ["Amandine Salambo"])
    }

    func testEnrichmentFailureLeavesRowUnenrichedWithoutError() async {
        let viewModel = makeViewModel()
        let list = Self.paginatedFixture(id: "11111111-1111-4111-8111-111111111111", title: "With Me Doc")
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/accesses/") {
                return .init(statusCode: 403, headers: [:], body: Data(#"{"detail":"No"}"#.utf8), error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: list, error: nil)
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.documents.map(\.title), ["With Me Doc"])
        XCTAssertNil(viewModel.errorKey)
        XCTAssertFalse(viewModel.isOffline)
        XCTAssertNil(viewModel.enrichment[UUID(uuidString: "11111111-1111-4111-8111-111111111111")!])
    }

    func testSeedsFromCacheSynchronouslyOnInit() {
        cache.saveSharedWithMeDocuments([
            decodeDocument(id: "11111111-1111-4111-8111-111111111111", title: "Cached Doc")
        ])
        let viewModel = makeViewModel()
        XCTAssertEqual(viewModel.documents.map(\.title), ["Cached Doc"])
        XCTAssertTrue(viewModel.showsDocumentList)
        XCTAssertFalse(viewModel.showsLoadingPlaceholder)
    }

    func testListFailureWithNoCacheIsLoudAndOffline() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }
        await viewModel.load()
        XCTAssertEqual(viewModel.errorKey, .shared_error_load)
        XCTAssertTrue(viewModel.isOffline)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testListFailureWithCacheIsSilent() async {
        cache.saveSharedWithMeDocuments([
            decodeDocument(id: "11111111-1111-4111-8111-111111111111", title: "Cached Doc")
        ])
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }
        await viewModel.load()
        XCTAssertNil(viewModel.errorKey)
        XCTAssertTrue(viewModel.isOffline)
        XCTAssertEqual(viewModel.documents.map(\.title), ["Cached Doc"])
    }

    func testRefreshFailureWithCacheIsLoud() async {
        // Explicit pull-to-refresh surfaces failures even behind cached rows.
        cache.saveSharedWithMeDocuments([
            decodeDocument(id: "11111111-1111-4111-8111-111111111111", title: "Cached Doc")
        ])
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }
        await viewModel.refresh()
        XCTAssertEqual(viewModel.errorKey, .shared_error_load)
        XCTAssertTrue(viewModel.isOffline)
    }

    func testWorkOfflineServesCacheWithoutNetwork() async {
        cache.saveSharedWithMeDocuments([
            decodeDocument(id: "11111111-1111-4111-8111-111111111111", title: "Offline Doc")
        ])
        preferences.set(true, forKey: "schrift.workOffline")
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }
        await viewModel.load()
        XCTAssertEqual(viewModel.documents.map(\.title), ["Offline Doc"])
        XCTAssertTrue(viewModel.isOffline)
    }

    func testSessionExpiredKeepsCacheSilently() async {
        cache.saveSharedWithMeDocuments([
            decodeDocument(id: "11111111-1111-4111-8111-111111111111", title: "Cached Doc")
        ])
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 401, headers: [:], body: Data(), error: nil) }
        await viewModel.load()
        XCTAssertNil(viewModel.errorKey)
        XCTAssertFalse(viewModel.isOffline)
        XCTAssertEqual(viewModel.documents.map(\.title), ["Cached Doc"])
    }

    func testSessionExpiredRefreshShowsNoError() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 401, headers: [:], body: Data(), error: nil) }
        await viewModel.refresh()
        XCTAssertFalse(viewModel.isOffline)
        XCTAssertNil(viewModel.errorKey)
    }

    nonisolated private static func listFixture(id: String, title: String, creator: String) -> Data {
        """
        {"count":1,"next":null,"previous":null,"results":[
          {"id":"\(id)","title":"\(title)","excerpt":null,"abilities":{},
           "computed_link_reach":"restricted","computed_link_role":null,
           "created_at":"2026-01-15T10:30:00Z","creator":"\(creator)","depth":1,
           "link_role":"reader","link_reach":"restricted","numchild":0,"path":"0001",
           "updated_at":"2026-01-15T10:30:00Z","user_role":"owner","is_favorite":false}]}
        """.data(using: .utf8)!
    }

    func testReloadPrunesEnrichmentForRemovedDocuments() async {
        let viewModel = makeViewModel()
        let docA = "11111111-1111-4111-8111-111111111111"
        let docB = "22222222-2222-4222-8222-222222222222"

        // First load: list = [A], A is its own creator, so A gets enriched.
        MockURLProtocol.stubHandler = { request in
            if request.url?.absoluteString.contains("/accesses/") == true {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Self.accessesFixture(userID: docA, fullName: "Amandine Salambo"), error: nil)
            }
            return .init(
                statusCode: 200, headers: [:], body: Self.listFixture(id: docA, title: "Doc A", creator: docA),
                error: nil)
        }
        await viewModel.load()
        XCTAssertNotNil(viewModel.enrichment[UUID(uuidString: docA)!])

        // Second load: list = [B] only. A dropped out ⇒ its enrichment is pruned.
        MockURLProtocol.stubHandler = { request in
            if request.url?.absoluteString.contains("/accesses/") == true {
                return .init(statusCode: 403, headers: [:], body: Data(), error: nil)
            }
            return .init(
                statusCode: 200, headers: [:], body: Self.paginatedFixture(id: docB, title: "Doc B"), error: nil)
        }
        await viewModel.load()

        XCTAssertEqual(viewModel.documents.map(\.id), [UUID(uuidString: docB)!])
        XCTAssertNil(viewModel.enrichment[UUID(uuidString: docA)!])
    }

    func testReloadOverwritesEnrichmentWithFreshData() async {
        let viewModel = makeViewModel()
        let docA = "11111111-1111-4111-8111-111111111111"

        MockURLProtocol.stubHandler = { request in
            if request.url?.absoluteString.contains("/accesses/") == true {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Self.accessesFixture(userID: docA, fullName: "Old Name"), error: nil)
            }
            return .init(
                statusCode: 200, headers: [:], body: Self.listFixture(id: docA, title: "Doc A", creator: docA),
                error: nil)
        }
        await viewModel.load()
        XCTAssertEqual(viewModel.enrichment[UUID(uuidString: docA)!]?.memberNames, ["Old Name"])

        MockURLProtocol.stubHandler = { request in
            if request.url?.absoluteString.contains("/accesses/") == true {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Self.accessesFixture(userID: docA, fullName: "New Name"), error: nil)
            }
            return .init(
                statusCode: 200, headers: [:], body: Self.listFixture(id: docA, title: "Doc A", creator: docA),
                error: nil)
        }
        await viewModel.refresh()

        XCTAssertEqual(viewModel.enrichment[UUID(uuidString: docA)!]?.memberNames, ["New Name"])
        XCTAssertEqual(viewModel.enrichment[UUID(uuidString: docA)!]?.sharedByName, "New Name")
    }

    func testEmptyListIsKnownAndShowsList() async {
        let viewModel = makeViewModel()
        let empty = Data(#"{"count":0,"next":null,"previous":null,"results":[]}"#.utf8)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: empty, error: nil) }

        await viewModel.load()

        XCTAssertTrue(viewModel.documents.isEmpty)
        XCTAssertTrue(viewModel.showsDocumentList)
        XCTAssertFalse(viewModel.showsLoadingPlaceholder)
        XCTAssertNil(viewModel.errorKey)
        XCTAssertFalse(viewModel.isOffline)
    }

    func testLoadSuccessWritesListThrough() async {
        let viewModel = makeViewModel()
        let list = Self.paginatedFixture(id: "77777777-7777-4777-8777-777777777777", title: "With Me Doc")
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/accesses/") {
                return .init(statusCode: 403, headers: [:], body: Data(), error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: list, error: nil)
        }

        await viewModel.load()

        XCTAssertEqual(cache.loadSharedWithMeDocuments()?.map(\.title), ["With Me Doc"])
    }
}
