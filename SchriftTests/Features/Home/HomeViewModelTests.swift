import XCTest

@testable import Schrift

private final class RequestLog: @unchecked Sendable {
    var urls: [String] = []
}

@MainActor
final class HomeViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!

    private var preferences: UserDefaults!
    private var preferencesSuiteName: String!

    override func setUp() {
        super.setUp()
        preferencesSuiteName = "HomeViewModelTests.preferences.\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: preferencesSuiteName)!
    }

    override func tearDown() {
        MockURLProtocol.stubHandler = nil
        MockURLProtocol.lastRequest = nil
        preferences.removePersistentDomain(forName: preferencesSuiteName)
        super.tearDown()
    }

    private func makeCache() -> DocumentCacheStore {
        let suiteName = "HomeViewModelTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        return DocumentCacheStore(userDefaults: userDefaults)
    }

    private func makeViewModel(cache: DocumentCacheStore? = nil, userDefaults: UserDefaults? = nil) -> HomeViewModel {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        // Isolate the save coordinator's draft store so `load()`'s draft recovery
        // can't replay drafts left in UserDefaults.standard by other tests (which
        // would fire an extra formatted-content GET and pollute recorded URLs).
        let suiteName = "HomeViewModelTests.coordinator.\(UUID().uuidString)"
        let draftStore = PendingDraftStore(userDefaults: UserDefaults(suiteName: suiteName)!)
        let coordinator = DocumentSaveCoordinator(client: client, draftStore: draftStore, backgroundTasks: .noop)
        return HomeViewModel(
            client: client,
            cache: cache ?? makeCache(),
            saveCoordinator: coordinator,
            userDefaults: userDefaults ?? preferences
        )
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
        cache.saveRecentDocuments([recentDocument], filter: .all)

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
        XCTAssertEqual(cache.loadRecentDocuments(filter: .all)?.map(\.title), ["Recent Doc"])
    }

    func testLoadWithNonAllFilterSavesUnderItsOwnKey() async {
        let cache = makeCache()
        let allRecentBody = Self.paginatedFixture(
            id: "99999999-9999-4999-8999-999999999999", title: "All Doc", isFavorite: false)
        let allRecentDocument = try! JSONDecoder.docsAPI.decode(PaginatedResponse<Document>.self, from: allRecentBody)
            .results[0]
        cache.saveRecentDocuments([allRecentDocument], filter: .all)
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
        XCTAssertEqual(cache.loadRecentDocuments(filter: .shared)?.map(\.title), ["Shared Doc"])
        // The .all filter's cache is untouched by another filter's fetch.
        XCTAssertEqual(cache.loadRecentDocuments(filter: .all)?.map(\.title), ["All Doc"])
    }

    func testSelectFilterSeedsRecentDocumentsFromThatFilterCache() async {
        let cache = makeCache()
        let sharedBody = Self.paginatedFixture(
            id: "12121212-1212-4121-8121-121212121212", title: "Cached Shared Doc", isFavorite: false)
        let sharedDocument = try! JSONDecoder.docsAPI.decode(PaginatedResponse<Document>.self, from: sharedBody)
            .results[0]
        cache.saveRecentDocuments([sharedDocument], filter: .shared)
        let viewModel = makeViewModel(cache: cache)
        // Offline: the fetch fails, so what shows is the synchronous seed.
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.selectFilter(.shared)

        XCTAssertEqual(viewModel.recentDocuments.map(\.title), ["Cached Shared Doc"])
        XCTAssertNil(viewModel.errorMessage)
    }

    func testLoadFailureKeepsCachedDocumentsVisibleAndStaysSilent() async {
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
        cache.saveRecentDocuments([cachedRecentDocument], filter: .all)
        let viewModel = makeViewModel(cache: cache)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.load()

        XCTAssertEqual(viewModel.pinnedDocuments.map(\.title), ["Offline Pinned"])
        XCTAssertEqual(viewModel.recentDocuments.map(\.title), ["Offline Recent"])
        // Passive revalidation failures stay silent behind cached rows.
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.isOffline)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testRefreshFailureWithCachedDocumentsSetsErrorMessage() async {
        let cache = makeCache()
        let cachedRecentBody = Self.paginatedFixture(
            id: "13131313-1313-4131-8131-131313131313", title: "Offline Recent", isFavorite: false)
        let cachedRecentDocument = try! JSONDecoder.docsAPI.decode(
            PaginatedResponse<Document>.self, from: cachedRecentBody
        ).results[0]
        cache.saveRecentDocuments([cachedRecentDocument], filter: .all)
        let viewModel = makeViewModel(cache: cache)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.refresh()

        // Pull-to-refresh is the explicit "give me fresh data" path — failures
        // surface even though cached rows stay visible.
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.recentDocuments.map(\.title), ["Offline Recent"])
    }

    func testConcurrentLoadAndFilterSwitchApplyTheLatestFilter() async {
        let viewModel = makeViewModel()
        let sharedBody = Self.paginatedFixture(
            id: "14141414-1414-4141-8141-141414141414", title: "Shared Doc", isFavorite: false)
        let allBody = Self.paginatedFixture(
            id: "15151515-1515-4151-8151-151515151515", title: "All Doc", isFavorite: false)
        let empty = Self.emptyFixture
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("favorite_list") {
                return .init(statusCode: 200, headers: [:], body: empty, error: nil)
            }
            if url.contains("is_creator_me=false") {
                return .init(statusCode: 200, headers: [:], body: sharedBody, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: allBody, error: nil)
        }

        // Race an in-flight load with a filter switch (Task {} inherits the
        // main actor, so both interleave at suspension points like .task and
        // .refreshable do): whichever fetch lands last, the generation guard
        // makes the switched-to filter's data win.
        let first = Task { await viewModel.load() }
        let second = Task { await viewModel.selectFilter(.shared) }
        await first.value
        await second.value

        XCTAssertEqual(viewModel.selectedFilter, .shared)
        XCTAssertEqual(viewModel.recentDocuments.map(\.title), ["Shared Doc"])
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

    func testFirstRunOfUncachedFilterFailureShowsErrorDespitePinnedRows() async {
        let cache = makeCache()
        let pinnedBody = Self.paginatedFixture(
            id: "16161616-1616-4161-8161-161616161616", title: "Cached Pinned", isFavorite: true)
        let pinnedDocument = try! JSONDecoder.docsAPI.decode(PaginatedResponse<Document>.self, from: pinnedBody)
            .results[0]
        cache.savePinnedDocuments([pinnedDocument])
        let viewModel = makeViewModel(cache: cache)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        // First-ever visit to a never-cached filter: pinned rows are no
        // evidence for it, so a total failure must not be silent.
        await viewModel.selectFilter(.shared)

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.isOffline)
    }

    func testCreateDocumentOfflinePersistsIntoAllFilterCacheOnly() async {
        let cache = makeCache()
        preferences.set(true, forKey: "schrift.workOffline")
        cache.saveRecentDocuments([], filter: .pinned)
        let viewModel = makeViewModel(cache: cache)
        await viewModel.selectFilter(.pinned)
        MockURLProtocol.stubHandler = { _ in
            .init(
                statusCode: 201, headers: [:],
                body: """
                    {
                        "id": "17171717-1717-4171-8171-171717171717",
                        "title": "New Doc",
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
                        "path": "0002",
                        "updated_at": "2026-01-15T10:30:00Z",
                        "user_role": "owner",
                        "is_favorite": false
                    }
                    """.data(using: .utf8)!, error: nil)
        }

        let document = await viewModel.createDocument()

        // The new (unpinned) document lands in the .all cache — never in the
        // selected filter's cache, which the server would not return it for.
        XCTAssertEqual(document?.title, "New Doc")
        XCTAssertEqual(cache.loadRecentDocuments(filter: .all)?.map(\.title), ["New Doc"])
        XCTAssertEqual(cache.loadRecentDocuments(filter: .pinned), [])
    }

    func testWorkOfflinePreferenceServesCacheWithoutNetwork() async {
        let cache = makeCache()
        let pinnedBody = Self.paginatedFixture(
            id: "18181818-1818-4181-8181-181818181818", title: "Offline Pinned", isFavorite: true)
        let recentBody = Self.paginatedFixture(
            id: "19191919-1919-4191-8191-191919191919", title: "Offline Recent", isFavorite: false)
        cache.savePinnedDocuments([
            try! JSONDecoder.docsAPI.decode(PaginatedResponse<Document>.self, from: pinnedBody).results[0]
        ])
        cache.saveRecentDocuments(
            [try! JSONDecoder.docsAPI.decode(PaginatedResponse<Document>.self, from: recentBody).results[0]],
            filter: .all)
        preferences.set(true, forKey: "schrift.workOffline")
        let viewModel = makeViewModel(cache: cache)
        let recorder = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            recorder.record(request)
            return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }

        await viewModel.load()

        XCTAssertEqual(recorder.methods.count, 0, "work offline must never hit the network")
        XCTAssertEqual(viewModel.pinnedDocuments.map(\.title), ["Offline Pinned"])
        XCTAssertEqual(viewModel.recentDocuments.map(\.title), ["Offline Recent"])
        XCTAssertTrue(viewModel.isOffline)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testSelectFilterWithCurrentFilterIsANoOp() async {
        let viewModel = makeViewModel()
        let sentinelBody = Self.paginatedFixture(
            id: "20202020-2020-4202-8202-202020202020", title: "On Screen", isFavorite: false)
        viewModel.recentDocuments = [
            try! JSONDecoder.docsAPI.decode(PaginatedResponse<Document>.self, from: sentinelBody).results[0]
        ]
        let recorder = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            recorder.record(request)
            return .init(statusCode: 200, headers: [:], body: Self.emptyFixture, error: nil)
        }

        // Re-tapping the active filter must neither reseed from (possibly
        // stale) cache nor fire a redundant load.
        await viewModel.selectFilter(.all)

        XCTAssertEqual(recorder.methods.count, 0)
        XCTAssertEqual(viewModel.recentDocuments.map(\.title), ["On Screen"])
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

    func testFirstRunOfPinnedFilterShowsPlaceholderDespiteHiddenPinnedRows() async {
        // Pinned rows exist but their section is hidden under the .pinned
        // filter — they must not suppress the first-run spinner, or the
        // content area renders blank.
        let cache = makeCache()
        let pinnedBody = Self.paginatedFixture(
            id: "21212121-2121-4212-8212-212121212121", title: "Cached Pinned", isFavorite: true)
        cache.savePinnedDocuments(
            [try! JSONDecoder.docsAPI.decode(PaginatedResponse<Document>.self, from: pinnedBody).results[0]])
        let viewModel = makeViewModel(cache: cache)
        let gate = DispatchSemaphore(value: 0)
        MockURLProtocol.stubHandler = { _ in
            gate.wait()  // hold the fetch open so the mid-flight state is observable
            return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }

        let load = Task { await viewModel.selectFilter(.pinned) }
        await waitUntil { viewModel.isLoading }
        XCTAssertTrue(viewModel.isLoading, "hidden pinned rows are no substitute for the first-run spinner")

        gate.signal()
        gate.signal()
        await load.value
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNotNil(viewModel.errorMessage, "first-ever .pinned load failed with nothing visible")
    }
}
