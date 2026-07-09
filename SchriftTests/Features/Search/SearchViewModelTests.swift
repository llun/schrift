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
}
