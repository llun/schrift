import XCTest
@testable import Schrift

final class DocumentEndpointsPathTests: XCTestCase {
    func testListPathWithNoFiltersHasNoQueryString() {
        XCTAssertEqual(documentsListPath(), "documents/")
    }

    func testListPathWithIsFavoriteTrue() {
        XCTAssertEqual(documentsListPath(isFavorite: true), "documents/?is_favorite=true")
    }

    func testListPathWithMultipleFilters() {
        let path = documentsListPath(isFavorite: false, title: "roadmap", ordering: "-updated_at", page: 2, pageSize: 20)
        XCTAssertTrue(path.hasPrefix("documents/?"))
        XCTAssertTrue(path.contains("is_favorite=false"))
        XCTAssertTrue(path.contains("title=roadmap"))
        XCTAssertTrue(path.contains("ordering=-updated_at") || path.contains("ordering=-updated_at".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!))
        XCTAssertTrue(path.contains("page=2"))
        XCTAssertTrue(path.contains("page_size=20"))
    }

    func testSearchPathEncodesQuery() {
        XCTAssertEqual(documentsSearchPath(query: "Q3 Planning"), "documents/search/?q=Q3%20Planning")
    }
}

final class DocumentEndpointsClientTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!

    override func tearDown() {
        MockURLProtocol.stubHandler = nil
        MockURLProtocol.lastRequest = nil
        super.tearDown()
    }

    private func makeClient() -> DocsAPIClient {
        DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
    }

    private static let paginatedFixture = """
    {
        "count": 1,
        "next": null,
        "previous": null,
        "results": [
            {
                "id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b",
                "title": "Q3 Planning",
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
                "is_favorite": true
            }
        ]
    }
    """.data(using: .utf8)!

    func testListDocumentsRequestsCorrectURLWithQueryString() async throws {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: Self.paginatedFixture, error: nil) }
        let client = makeClient()

        let page = try await client.listDocuments(isFavorite: true, ordering: "-updated_at")

        XCTAssertEqual(page.count, 1)
        XCTAssertEqual(page.results.first?.title, "Q3 Planning")
        let requestedURL = MockURLProtocol.lastRequest?.url?.absoluteString ?? ""
        XCTAssertTrue(requestedURL.hasPrefix("https://docs.example.org/api/v1.0/documents/?"))
        XCTAssertTrue(requestedURL.contains("is_favorite=true"))
    }

    func testFavoriteDocumentsRequestsFavoriteListPath() async throws {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: Self.paginatedFixture, error: nil) }
        let client = makeClient()

        let page = try await client.favoriteDocuments()

        XCTAssertEqual(page.results.count, 1)
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.absoluteString, "https://docs.example.org/api/v1.0/documents/favorite_list/")
    }

    func testSearchDocumentsEncodesQueryInURL() async throws {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: Self.paginatedFixture, error: nil) }
        let client = makeClient()

        _ = try await client.searchDocuments(query: "Q3 Planning")

        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.absoluteString, "https://docs.example.org/api/v1.0/documents/search/?q=Q3%20Planning")
    }

    func testSetFavoriteTrueSendsPostToFavoriteRoute() async throws {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 201, headers: [:], body: #"{"detail": "Document marked as favorite"}"#.data(using: .utf8)!, error: nil) }
        let client = makeClient()
        let id = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!

        try await client.setFavorite(documentID: id, isFavorite: true)

        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.absoluteString, "https://docs.example.org/api/v1.0/documents/8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b/favorite/")
    }

    func testSetFavoriteFalseSendsDeleteAndToleratesEmptyBody() async throws {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 204, headers: [:], body: Data(), error: nil) }
        let client = makeClient()
        let id = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!

        try await client.setFavorite(documentID: id, isFavorite: false)

        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "DELETE")
    }
}
