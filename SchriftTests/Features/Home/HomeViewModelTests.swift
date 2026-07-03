import XCTest

@testable import Schrift

private final class RequestLog: @unchecked Sendable {
    var urls: [String] = []
}

@MainActor
final class HomeViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!

    override func tearDown() {
        MockURLProtocol.stubHandler = nil
        MockURLProtocol.lastRequest = nil
        super.tearDown()
    }

    private func makeCache() -> DocumentCacheStore {
        let suiteName = "HomeViewModelTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        return DocumentCacheStore(userDefaults: userDefaults)
    }

    private func makeViewModel(cache: DocumentCacheStore? = nil) -> HomeViewModel {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        // Isolate the save coordinator's draft store so `load()`'s draft recovery
        // can't replay drafts left in UserDefaults.standard by other tests (which
        // would fire an extra formatted-content GET and pollute recorded URLs).
        let suiteName = "HomeViewModelTests.coordinator.\(UUID().uuidString)"
        let draftStore = PendingDraftStore(userDefaults: UserDefaults(suiteName: suiteName)!)
        let coordinator = DocumentSaveCoordinator(client: client, draftStore: draftStore, backgroundTasks: .noop)
        return HomeViewModel(client: client, cache: cache ?? makeCache(), saveCoordinator: coordinator)
    }

    private static func paginatedFixture(id: String, title: String, isFavorite: Bool) -> Data {
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
                    "is_favorite": \(isFavorite)
                }
            ]
        }
        """.data(using: .utf8)!
    }

    private static let emptyFixture: Data = #"{"count": 0, "next": null, "previous": null, "results": []}"#.data(
        using: .utf8)!

    func testLoadPopulatesPinnedAndRecentDocuments() async {
        let viewModel = makeViewModel()
        let pinnedBody = Self.paginatedFixture(
            id: "11111111-1111-4111-8111-111111111111", title: "Pinned Doc", isFavorite: true)
        let recentBody = Self.paginatedFixture(
            id: "22222222-2222-4222-8222-222222222222", title: "Recent Doc", isFavorite: false)
        MockURLProtocol.stubHandler = { request in
            let path = request.url?.path ?? ""
            if path.contains("favorite_list") {
                return .init(statusCode: 200, headers: [:], body: pinnedBody, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: recentBody, error: nil)
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.pinnedDocuments.map(\.title), ["Pinned Doc"])
        XCTAssertEqual(viewModel.recentDocuments.map(\.title), ["Recent Doc"])
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testSelectFilterUpdatesQueryParametersForRecentList() async {
        let viewModel = makeViewModel()
        let log = RequestLog()
        let empty = Self.emptyFixture
        MockURLProtocol.stubHandler = { request in
            let path = request.url?.path ?? ""
            if !path.contains("favorite_list") {
                log.urls.append(request.url?.absoluteString ?? "")
            }
            return .init(statusCode: 200, headers: [:], body: empty, error: nil)
        }

        await viewModel.selectFilter(.shared)

        XCTAssertEqual(viewModel.selectedFilter, .shared)
        XCTAssertTrue(log.urls.last?.contains("is_creator_me=false") ?? false)
    }

    func testSearchWithEmptyQueryClearsResults() async {
        let viewModel = makeViewModel()
        viewModel.searchResults = []
        viewModel.searchQuery = "   "

        await viewModel.search()

        XCTAssertTrue(viewModel.searchResults.isEmpty)
    }

    func testSearchWithQueryPopulatesResults() async {
        let viewModel = makeViewModel()
        viewModel.searchQuery = "Q3"
        let body = Self.paginatedFixture(
            id: "33333333-3333-4333-8333-333333333333", title: "Q3 Planning", isFavorite: false)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }

        await viewModel.search()

        XCTAssertEqual(viewModel.searchResults.map(\.title), ["Q3 Planning"])
    }

    func testToggleFavoriteCallsSetFavoriteThenReloads() async {
        let viewModel = makeViewModel()
        let log = RequestLog()
        let empty = Self.emptyFixture
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            log.urls.append(url)
            if url.contains("/favorite/") && !url.contains("favorite_list") {
                return .init(statusCode: 201, headers: [:], body: Data(), error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: empty, error: nil)
        }

        let documentBody = Self.paginatedFixture(
            id: "44444444-4444-4444-8444-444444444444", title: "Doc", isFavorite: false)
        let document = try! JSONDecoder.docsAPI.decode(PaginatedResponse<Document>.self, from: documentBody).results[0]

        await viewModel.toggleFavorite(document)

        XCTAssertTrue(log.urls.contains { $0.contains("/favorite/") && !$0.contains("favorite_list") })
        XCTAssertTrue(log.urls.contains { $0.contains("favorite_list") })
    }

    func testLoadFailureSetsErrorMessage() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.load()

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testInitSeedsPinnedAndRecentDocumentsFromCache() {
        let cache = makeCache()
        let pinnedBody = Self.paginatedFixture(
            id: "55555555-5555-4555-8555-555555555555", title: "Cached Pinned", isFavorite: true)
        let recentBody = Self.paginatedFixture(
            id: "66666666-6666-4666-8666-666666666666", title: "Cached Recent", isFavorite: false)
        let pinnedDocument = try! JSONDecoder.docsAPI.decode(PaginatedResponse<Document>.self, from: pinnedBody)
            .results[0]
        let recentDocument = try! JSONDecoder.docsAPI.decode(PaginatedResponse<Document>.self, from: recentBody)
            .results[0]
        cache.savePinnedDocuments([pinnedDocument])
        cache.saveRecentDocuments([recentDocument])

        let viewModel = makeViewModel(cache: cache)

        XCTAssertEqual(viewModel.pinnedDocuments.map(\.title), ["Cached Pinned"])
        XCTAssertEqual(viewModel.recentDocuments.map(\.title), ["Cached Recent"])
    }

    func testLoadWithAllFilterSavesResultsToCache() async {
        let cache = makeCache()
        let viewModel = makeViewModel(cache: cache)
        let pinnedBody = Self.paginatedFixture(
            id: "77777777-7777-4777-8777-777777777777", title: "Pinned Doc", isFavorite: true)
        let recentBody = Self.paginatedFixture(
            id: "88888888-8888-4888-8888-888888888888", title: "Recent Doc", isFavorite: false)
        MockURLProtocol.stubHandler = { request in
            let path = request.url?.path ?? ""
            if path.contains("favorite_list") {
                return .init(statusCode: 200, headers: [:], body: pinnedBody, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: recentBody, error: nil)
        }

        await viewModel.load()

        XCTAssertEqual(cache.loadPinnedDocuments().map(\.title), ["Pinned Doc"])
        XCTAssertEqual(cache.loadRecentDocuments().map(\.title), ["Recent Doc"])
    }

    func testLoadWithNonAllFilterDoesNotOverwriteRecentCache() async {
        let cache = makeCache()
        let staleRecentBody = Self.paginatedFixture(
            id: "99999999-9999-4999-8999-999999999999", title: "Stale All Doc", isFavorite: false)
        let staleRecentDocument = try! JSONDecoder.docsAPI.decode(
            PaginatedResponse<Document>.self, from: staleRecentBody
        ).results[0]
        cache.saveRecentDocuments([staleRecentDocument])
        let viewModel = makeViewModel(cache: cache)
        let sharedBody = Self.paginatedFixture(
            id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", title: "Shared Doc", isFavorite: false)
        let empty = Self.emptyFixture
        MockURLProtocol.stubHandler = { request in
            let path = request.url?.path ?? ""
            if path.contains("favorite_list") {
                return .init(statusCode: 200, headers: [:], body: empty, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: sharedBody, error: nil)
        }

        await viewModel.selectFilter(.shared)

        XCTAssertEqual(viewModel.recentDocuments.map(\.title), ["Shared Doc"])
        XCTAssertEqual(cache.loadRecentDocuments().map(\.title), ["Stale All Doc"])
    }

    func testLoadFailureKeepsCachedDocumentsVisible() async {
        let cache = makeCache()
        let cachedPinnedBody = Self.paginatedFixture(
            id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", title: "Offline Pinned", isFavorite: true)
        let cachedRecentBody = Self.paginatedFixture(
            id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc", title: "Offline Recent", isFavorite: false)
        let cachedPinnedDocument = try! JSONDecoder.docsAPI.decode(
            PaginatedResponse<Document>.self, from: cachedPinnedBody
        ).results[0]
        let cachedRecentDocument = try! JSONDecoder.docsAPI.decode(
            PaginatedResponse<Document>.self, from: cachedRecentBody
        ).results[0]
        cache.savePinnedDocuments([cachedPinnedDocument])
        cache.saveRecentDocuments([cachedRecentDocument])
        let viewModel = makeViewModel(cache: cache)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.load()

        XCTAssertEqual(viewModel.pinnedDocuments.map(\.title), ["Offline Pinned"])
        XCTAssertEqual(viewModel.recentDocuments.map(\.title), ["Offline Recent"])
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testLoadFailureSetsIsOffline() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.load()

        XCTAssertTrue(viewModel.isOffline)
    }

    func testLoadSuccessKeepsIsOfflineFalse() async {
        let viewModel = makeViewModel()
        let pinnedBody = Self.paginatedFixture(
            id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd", title: "Pinned Doc", isFavorite: true)
        let recentBody = Self.paginatedFixture(
            id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", title: "Recent Doc", isFavorite: false)
        MockURLProtocol.stubHandler = { request in
            let path = request.url?.path ?? ""
            if path.contains("favorite_list") {
                return .init(statusCode: 200, headers: [:], body: pinnedBody, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: recentBody, error: nil)
        }

        await viewModel.load()

        XCTAssertFalse(viewModel.isOffline)
    }

    func testLoadSuccessAfterFailureClearsIsOffline() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }
        await viewModel.load()
        XCTAssertTrue(viewModel.isOffline)

        let empty = Self.emptyFixture
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: empty, error: nil) }
        await viewModel.load()

        XCTAssertFalse(viewModel.isOffline)
    }

    func testToggleFavoriteFailureDoesNotSetIsOffline() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }
        let documentBody = Self.paginatedFixture(
            id: "ffffffff-ffff-4fff-8fff-ffffffffffff", title: "Doc", isFavorite: false)
        let document = try! JSONDecoder.docsAPI.decode(PaginatedResponse<Document>.self, from: documentBody).results[0]

        await viewModel.toggleFavorite(document)

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isOffline)
    }
}
