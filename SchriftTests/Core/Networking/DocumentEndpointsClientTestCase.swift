import XCTest

@testable import Schrift

/// Shared client wiring and list fixture for the `DocumentEndpoints…` client tests. Holds no tests.
class DocumentEndpointsClientTestCase: XCTestCase {
    let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func makeClient() -> DocsAPIClient {
        DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
    }

    static let paginatedFixture = """
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
}
