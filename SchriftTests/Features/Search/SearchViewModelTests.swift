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

    /// Without a coordinator — every `#Preview`, and any screen that has none — both members
    /// answer harmlessly rather than trapping.
    func testTheDeletionMembersAreInertWithoutACoordinator() {
        let viewModel = makeViewModel()
        let document = searchDocument()

        XCTAssertFalse(viewModel.isDeletePending(document))
        viewModel.undoPendingDelete(document)
    }

    private func searchDocument() -> Document {
        Document(
            id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!, title: "Doomed",
            excerpt: nil, abilities: DocumentAbilities(), linkReach: .restricted, linkRole: .reader,
            isFavorite: false, depth: 1, numchild: 0, path: "0001",
            createdAt: Date(), updatedAt: Date(), userRole: nil, creator: nil)
    }
}
