import XCTest

@testable import Schrift

private final class RequestLog: @unchecked Sendable {
    var requests: [URLRequest] = []
}

@MainActor
final class ShareViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    override func tearDown() {
        MockURLProtocol.stubHandler = nil
        MockURLProtocol.lastRequest = nil
        super.tearDown()
    }

    private func makeViewModel(linkReach: LinkReach = .restricted, linkRole: LinkRole? = nil) -> ShareViewModel {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        return ShareViewModel(client: client, documentID: documentID, linkReach: linkReach, linkRole: linkRole)
    }

    private static let accessesFixture = """
        {"count": 1, "next": null, "previous": null, "results": [
            {"id": "22222222-2222-4222-8222-222222222222", "document": {"id": "11111111-1111-4111-8111-111111111111", "path": "0001", "depth": 1}, "user": {"id": "33333333-3333-4333-8333-333333333333", "email": "member@example.com", "full_name": "Member One", "short_name": "Member", "language": "en-us", "is_first_connection": false}, "team": "", "role": "editor", "abilities": {}, "max_ancestors_role": null, "max_role": "editor"}
        ]}
        """.data(using: .utf8)!

    private static let invitationsFixture = """
        {"count": 1, "next": null, "previous": null, "results": [
            {"id": "44444444-4444-4444-8444-444444444444", "abilities": {}, "created_at": "2026-01-15T10:30:00Z", "email": "pending@example.com", "document": "11111111-1111-4111-8111-111111111111", "role": "reader", "issuer": "33333333-3333-4333-8333-333333333333", "is_expired": false}
        ]}
        """.data(using: .utf8)!

    func testLoadMergesAccessesAndInvitations() async {
        let viewModel = makeViewModel()
        let accesses = Self.accessesFixture
        let invitations = Self.invitationsFixture
        MockURLProtocol.stubHandler = { request in
            let path = request.url?.path ?? ""
            if path.contains("invitations") {
                return .init(statusCode: 200, headers: [:], body: invitations, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: accesses, error: nil)
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.members.count, 2)
        XCTAssertFalse(viewModel.members[0].isPending)
        XCTAssertTrue(viewModel.members[1].isPending)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testSearchWithEmptyQueryClearsResults() async {
        let viewModel = makeViewModel()
        viewModel.searchQuery = "   "

        await viewModel.search()

        XCTAssertTrue(viewModel.searchResults.isEmpty)
    }

    func testInviteCallsCreateAccessThenReloads() async {
        let viewModel = makeViewModel()
        let log = RequestLog()
        let accesses = Self.accessesFixture
        let invitations = Self.invitationsFixture
        MockURLProtocol.stubHandler = { request in
            log.requests.append(request)
            if request.httpMethod == "POST" {
                let body = """
                    {"id": "55555555-5555-4555-8555-555555555555", "document": {"id": "11111111-1111-4111-8111-111111111111", "path": "0001", "depth": 1}, "user": {"id": "66666666-6666-4666-8666-666666666666", "email": "new@example.com", "full_name": "New", "short_name": "New", "language": "en-us", "is_first_connection": false}, "team": "", "role": "reader", "abilities": {}, "max_ancestors_role": null, "max_role": "reader"}
                    """.data(using: .utf8)!
                return .init(statusCode: 201, headers: [:], body: body, error: nil)
            }
            if request.url?.path.contains("invitations") == true {
                return .init(statusCode: 200, headers: [:], body: invitations, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: accesses, error: nil)
        }
        let user = UserSearchResult(
            id: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!, email: "new@example.com", fullName: "New",
            shortName: "New")

        await viewModel.invite(user: user, role: .reader)

        XCTAssertTrue(log.requests.contains { $0.httpMethod == "POST" })
        XCTAssertTrue(log.requests.contains { $0.httpMethod == "GET" })
        XCTAssertNil(viewModel.errorMessage)
    }

    func testRemoveMemberDeletesAccessThenReloads() async {
        let viewModel = makeViewModel()
        let log = RequestLog()
        let accesses = Self.accessesFixture
        let invitations = Self.invitationsFixture
        MockURLProtocol.stubHandler = { request in
            log.requests.append(request)
            if request.httpMethod == "DELETE" {
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
            }
            if request.url?.path.contains("invitations") == true {
                return .init(statusCode: 200, headers: [:], body: invitations, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: accesses, error: nil)
        }
        let access = DocumentAccess(
            id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!, user: nil, team: nil, role: .editor)

        await viewModel.removeMember(.access(access))

        XCTAssertTrue(log.requests.contains { $0.httpMethod == "DELETE" })
    }

    func testUpdateLinkConfigurationUpdatesLocalState() async {
        let viewModel = makeViewModel(linkReach: .restricted, linkRole: nil)
        let responseBody = #"{"link_reach": "authenticated", "link_role": "reader"}"#.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: responseBody, error: nil) }

        await viewModel.updateLinkConfiguration(reach: .authenticated, role: .reader)

        XCTAssertEqual(viewModel.linkReach, .authenticated)
        XCTAssertEqual(viewModel.linkRole, .reader)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testLoadFailureSetsErrorMessage() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.load()

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
    }
}
