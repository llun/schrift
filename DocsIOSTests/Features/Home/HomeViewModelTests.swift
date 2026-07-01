import XCTest
@testable import DocsIOS

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

    private func makeViewModel() -> HomeViewModel {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        return HomeViewModel(client: client)
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

    private static let emptyFixture: Data = #"{"count": 0, "next": null, "previous": null, "results": []}"#.data(using: .utf8)!

    func testLoadPopulatesPinnedAndRecentDocuments() async {
        let viewModel = makeViewModel()
        let pinnedBody = Self.paginatedFixture(id: "11111111-1111-4111-8111-111111111111", title: "Pinned Doc", isFavorite: true)
        let recentBody = Self.paginatedFixture(id: "22222222-2222-4222-8222-222222222222", title: "Recent Doc", isFavorite: false)
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
        let body = Self.paginatedFixture(id: "33333333-3333-4333-8333-333333333333", title: "Q3 Planning", isFavorite: false)
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

        let documentBody = Self.paginatedFixture(id: "44444444-4444-4444-8444-444444444444", title: "Doc", isFavorite: false)
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
}
