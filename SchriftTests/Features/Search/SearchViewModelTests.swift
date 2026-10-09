import XCTest

@testable import Schrift

@MainActor
final class SearchViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeStore() -> RecentSearchesStore {
        let suiteName = "SearchViewModelTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        return RecentSearchesStore(userDefaults: userDefaults)
    }

    private func makeViewModel(store: RecentSearchesStore? = nil) -> SearchViewModel {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        return SearchViewModel(client: client, store: store ?? makeStore())
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

    func testLoadQuickAccessPopulatesFavorites() async {
        let viewModel = makeViewModel()
        let body = Self.paginatedFixture(
            id: "11111111-1111-4111-8111-111111111111", title: "Pinned Doc", isFavorite: true)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }

        await viewModel.loadQuickAccess()

        XCTAssertEqual(viewModel.quickAccess.map(\.title), ["Pinned Doc"])
    }

    func testSearchWithEmptyQueryClearsResults() async {
        let viewModel = makeViewModel()
        viewModel.results = []
        viewModel.query = "   "

        await viewModel.search()

        XCTAssertTrue(viewModel.results.isEmpty)
    }

    func testRecordSearchAddsRecentTerm() {
        let viewModel = makeViewModel()
        viewModel.query = "Roadmap"

        viewModel.recordSearch()

        XCTAssertEqual(viewModel.recentSearches.first, "Roadmap")
    }

    func testReturningToSearchRetainsQueryResultsAndRecentTerms() async {
        let viewModel = makeViewModel()
        let body = Self.paginatedFixture(
            id: "11111111-1111-4111-8111-111111111111", title: "Roadmap", isFavorite: true)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }
        viewModel.query = "Roadmap"
        viewModel.recordSearch()
        await viewModel.search()

        // The shell retains this same model when Search is popped or its tab is switched.
        await viewModel.loadQuickAccess()

        XCTAssertEqual(viewModel.query, "Roadmap")
        XCTAssertEqual(viewModel.results.map(\.title), ["Roadmap"])
        XCTAssertEqual(viewModel.recentSearches, ["Roadmap"])
        XCTAssertEqual(viewModel.quickAccess.map(\.title), ["Roadmap"])
    }

    func testNetworkLossWhileReturningKeepsResultsAndReportsSearchFailure() async {
        let viewModel = makeViewModel()
        viewModel.query = "Roadmap"
        let body = Self.paginatedFixture(
            id: "11111111-1111-4111-8111-111111111111", title: "Roadmap", isFavorite: true)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }
        await viewModel.search()
        viewModel.recordSearch()
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        await viewModel.search()

        XCTAssertEqual(viewModel.errorKey, .search_error_search)
        XCTAssertFalse(viewModel.isSearching)
        XCTAssertEqual(viewModel.results.map(\.title), ["Roadmap"])
        XCTAssertEqual(viewModel.query, "Roadmap")
        XCTAssertEqual(viewModel.recentSearches, ["Roadmap"])
    }

    // MARK: - Rows for documents whose deletion is queued

    /// Search annotates too, so a document deleted from its own screen stops looking alive in
    /// results — and taps into the undo instead of opening.
    func testAResultIsAnnotatedOnceItsDeletionIsQueued() {
        let suiteName = "SearchViewModelTests.coordinator.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let user = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: PendingDraftStore(userDefaults: defaults),
            createStore: PendingDocumentCreateStore(userDefaults: defaults),
            deleteStore: PendingDocumentDeleteStore(userDefaults: defaults),
            listCache: DocumentCacheStore(userDefaults: defaults),
            childrenCache: DocumentChildrenCacheStore(userDefaults: defaults),
            serverOrigin: "https://docs.example.org", backgroundTasks: .noop)
        let signedIn = SignedInUserStore(userDefaults: defaults)
        signedIn.remember(user)
        let viewModel = SearchViewModel(
            client: client, store: makeStore(), saveCoordinator: coordinator, signedInUser: signedIn)
        let document = searchDocument()
        XCTAssertFalse(viewModel.isDeletePending(document))

        coordinator.recordPendingDelete(documentID: document.id, ownerUserID: user)
        XCTAssertTrue(viewModel.isDeletePending(document))

        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: Data(), error: nil) }
        viewModel.undoPendingDelete(document)
        XCTAssertFalse(viewModel.isDeletePending(document), "and the undo takes it off again")
        XCTAssertFalse(coordinator.isPendingDelete(documentID: document.id))
    }

    /// Without a coordinator — every `#Preview` — a row is never struck through, and the
    /// undo is a no-op that must not trap or issue a request.
    func testWithoutACoordinatorNoRowIsPendingDeleteAndUndoSendsNothing() {
        let viewModel = makeViewModel()
        let document = searchDocument()
        MockURLProtocol.stubHandler = { _ in
            XCTFail("undo without a coordinator must not hit the network")
            return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }

        XCTAssertFalse(viewModel.isDeletePending(document))
        viewModel.undoPendingDelete(document)

        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    // MARK: - search()

    func testSearchSendsTheTrimmedQueryAndInstallsResults() async {
        let viewModel = makeViewModel()
        let body = Self.paginatedFixture(
            id: "11111111-1111-4111-8111-111111111111", title: "Roadmap", isFavorite: false)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }
        viewModel.query = "  Road map \n"

        await viewModel.search()

        let url = MockURLProtocol.lastRequest?.url?.absoluteString ?? ""
        XCTAssertTrue(url.hasSuffix("documents/search/?q=Road%20map"), url)
        XCTAssertEqual(viewModel.results.map(\.title), ["Roadmap"])
        XCTAssertNil(viewModel.errorKey)
        XCTAssertFalse(viewModel.isSearching)
    }

    func testIsSearchingIsTrueWhileTheRequestIsInFlightAndFalseAfter() async {
        let viewModel = makeViewModel()
        let body = Self.paginatedFixture(
            id: "11111111-1111-4111-8111-111111111111", title: "Roadmap", isFavorite: false)
        let gate = MockURLProtocol.ResponseGate()
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: body, error: nil, releasedBy: gate)
        }
        viewModel.query = "Roadmap"

        let task = Task { await viewModel.search() }
        await waitUntil { viewModel.isSearching }
        XCTAssertTrue(viewModel.results.isEmpty)

        gate.open()
        await task.value

        XCTAssertFalse(viewModel.isSearching)
        XCTAssertEqual(viewModel.results.map(\.title), ["Roadmap"])
    }

    func testAFailedSearchSetsTheSearchErrorAndClearsItOnTheNextSuccess() async {
        let viewModel = makeViewModel()
        viewModel.query = "Roadmap"
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.search()
        XCTAssertEqual(viewModel.errorKey, .search_error_search)
        XCTAssertFalse(viewModel.isSearching)
        XCTAssertTrue(viewModel.results.isEmpty)

        let body = Self.paginatedFixture(
            id: "11111111-1111-4111-8111-111111111111", title: "Roadmap", isFavorite: false)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }
        await viewModel.search()
        XCTAssertNil(viewModel.errorKey)
        XCTAssertEqual(viewModel.results.map(\.title), ["Roadmap"])
    }

    func testBlankQueryDoesNotHitTheNetworkAndEmptiesExistingResults() async {
        let viewModel = makeViewModel()
        let body = Self.paginatedFixture(
            id: "11111111-1111-4111-8111-111111111111", title: "Roadmap", isFavorite: false)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }
        viewModel.query = "Roadmap"
        await viewModel.search()
        XCTAssertFalse(viewModel.results.isEmpty)
        MockURLProtocol.lastRequest = nil
        MockURLProtocol.stubHandler = { _ in
            XCTFail("a blank query must not search")
            return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }

        viewModel.query = "  "
        await viewModel.search()

        XCTAssertTrue(viewModel.results.isEmpty)
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testAResultForADocumentDeletedSinceTheLoadIsFiltered() async {
        let suiteName = "SearchViewModelTests.filter.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: PendingDraftStore(userDefaults: defaults),
            createStore: PendingDocumentCreateStore(userDefaults: defaults),
            deleteStore: PendingDocumentDeleteStore(userDefaults: defaults),
            listCache: DocumentCacheStore(userDefaults: defaults),
            childrenCache: DocumentChildrenCacheStore(userDefaults: defaults),
            serverOrigin: "https://docs.example.org", backgroundTasks: .noop)
        let viewModel = SearchViewModel(
            client: client, store: makeStore(), saveCoordinator: coordinator,
            signedInUser: SignedInUserStore(userDefaults: defaults))
        let deletedID = "11111111-1111-4111-8111-111111111111"
        let body = Self.paginatedFixture(id: deletedID, title: "Gone", isFavorite: true)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }
        viewModel.query = "Gone"

        // A deletion announced before the search runs: the since-load filter must drop the row the
        // server still returns, from both the results and quick access.
        coordinator.announceDocumentDeletedForTesting(UUID(uuidString: deletedID)!)
        await viewModel.search()
        await viewModel.loadQuickAccess()

        XCTAssertTrue(viewModel.results.isEmpty)
        XCTAssertTrue(viewModel.quickAccess.isEmpty)
    }

    // MARK: - loadQuickAccess / recents

    func testLoadQuickAccessFailureSetsTheQuickAccessError() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.loadQuickAccess()

        XCTAssertEqual(viewModel.errorKey, .search_error_quick)
        XCTAssertTrue(viewModel.quickAccess.isEmpty)
    }

    func testClearRecentEmptiesTheModelAndTheStore() {
        let store = makeStore()
        let viewModel = makeViewModel(store: store)
        viewModel.query = "Roadmap"
        viewModel.recordSearch()
        XCTAssertEqual(viewModel.recentSearches, ["Roadmap"])

        viewModel.clearRecent()

        XCTAssertTrue(viewModel.recentSearches.isEmpty)
        XCTAssertTrue(store.searches.isEmpty)
    }

    func testSelectRecentSetsTheQuery() {
        let viewModel = makeViewModel()
        viewModel.selectRecent("Roadmap")
        XCTAssertEqual(viewModel.query, "Roadmap")
    }

    private func searchDocument() -> Document {
        Document(
            id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!, title: "Doomed",
            excerpt: nil, abilities: DocumentAbilities(), linkReach: .restricted, linkRole: .reader,
            isFavorite: false, depth: 1, numchild: 0, path: "0001",
            createdAt: Date(), updatedAt: Date(), userRole: nil, creator: nil)
    }
}
