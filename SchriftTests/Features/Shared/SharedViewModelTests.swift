import XCTest

@testable import Schrift

@MainActor
final class SharedViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!

    override func tearDown() {
        MockURLProtocol.stubHandler = nil
        MockURLProtocol.lastRequest = nil
        super.tearDown()
    }

    private func makeViewModel() -> SharedViewModel {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        return SharedViewModel(client: client)
    }

    private static func paginatedFixture(id: String, title: String) -> Data {
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

    func testLoadPopulatesBothScopes() async {
        let viewModel = makeViewModel()
        let withMeBody = Self.paginatedFixture(id: "11111111-1111-4111-8111-111111111111", title: "With Me Doc")
        let byMeBody = Self.paginatedFixture(id: "22222222-2222-4222-8222-222222222222", title: "By Me Doc")
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("is_creator_me=true") {
                return .init(statusCode: 200, headers: [:], body: byMeBody, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: withMeBody, error: nil)
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.sharedWithMe.map(\.title), ["With Me Doc"])
        XCTAssertEqual(viewModel.sharedByMe.map(\.title), ["By Me Doc"])
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testDocumentsFollowsScope() async {
        let viewModel = makeViewModel()
        let withMeBody = Self.paginatedFixture(id: "33333333-3333-4333-8333-333333333333", title: "With Me Doc")
        let byMeBody = Self.paginatedFixture(id: "44444444-4444-4444-8444-444444444444", title: "By Me Doc")
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("is_creator_me=true") {
                return .init(statusCode: 200, headers: [:], body: byMeBody, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: withMeBody, error: nil)
        }

        await viewModel.load()

        viewModel.scope = .withMe
        XCTAssertEqual(viewModel.documents.map(\.title), ["With Me Doc"])
        viewModel.scope = .byMe
        XCTAssertEqual(viewModel.documents.map(\.title), ["By Me Doc"])
    }

    func testLoadFailureSetsErrorMessage() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.load()

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
    }
}
