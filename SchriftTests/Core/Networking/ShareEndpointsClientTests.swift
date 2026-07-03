import XCTest

@testable import Schrift

private func bodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 4096
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    while stream.hasBytesAvailable {
        let bytesRead = stream.read(&buffer, maxLength: bufferSize)
        if bytesRead > 0 {
            data.append(buffer, count: bytesRead)
        } else {
            break
        }
    }
    return data
}

final class ShareEndpointsClientTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    override func tearDown() {
        MockURLProtocol.stubHandler = nil
        MockURLProtocol.lastRequest = nil
        super.tearDown()
    }

    private func makeClient() -> DocsAPIClient {
        DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
    }

    func testSetLinkConfigurationWithRestrictedReachSendsExplicitNullLinkRole() async throws {
        let responseBody = #"{"link_reach": "restricted", "link_role": null}"#.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: responseBody, error: nil) }
        let client = makeClient()

        let result = try await client.setLinkConfiguration(
            documentID: documentID, linkReach: .restricted, linkRole: nil)

        XCTAssertEqual(result.linkReach, .restricted)
        XCTAssertNil(result.linkRole)
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "PUT")
        let sentBody = MockURLProtocol.lastRequest.flatMap(bodyData(from:))
        let json = try XCTUnwrap(sentBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertTrue(json.keys.contains("link_role"))
        XCTAssertTrue(json["link_role"] is NSNull)
    }

    func testSetLinkConfigurationWithAuthenticatedReachSendsLinkRole() async throws {
        let responseBody = #"{"link_reach": "authenticated", "link_role": "reader"}"#.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: responseBody, error: nil) }
        let client = makeClient()

        let result = try await client.setLinkConfiguration(
            documentID: documentID, linkReach: .authenticated, linkRole: .reader)

        XCTAssertEqual(result.linkReach, .authenticated)
        XCTAssertEqual(result.linkRole, .reader)
        let sentBody = MockURLProtocol.lastRequest.flatMap(bodyData(from:))
        let json = try XCTUnwrap(sentBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] })
        XCTAssertEqual(json["link_role"], "reader")
    }

    func testCreateAccessSendsUserIdAndRole() async throws {
        let responseBody = """
            {"id": "22222222-2222-4222-8222-222222222222", "document": {"id": "11111111-1111-4111-8111-111111111111", "path": "0001", "depth": 1}, "user": {"id": "33333333-3333-4333-8333-333333333333", "email": "new@example.com", "full_name": "New Member", "short_name": "New", "language": "en-us", "is_first_connection": false}, "team": "", "role": "reader", "abilities": {}, "max_ancestors_role": null, "max_role": "reader"}
            """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 201, headers: [:], body: responseBody, error: nil) }
        let client = makeClient()
        let userID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

        let access = try await client.createAccess(documentID: documentID, userID: userID, role: .reader)

        XCTAssertEqual(access.role, .reader)
        let sentBody = MockURLProtocol.lastRequest.flatMap(bodyData(from:))
        let json = try XCTUnwrap(sentBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] })
        XCTAssertEqual(json["user_id"], "33333333-3333-4333-8333-333333333333")
        XCTAssertEqual(json["role"], "reader")
    }

    func testSearchUsersRequestsCorrectURL() async throws {
        let responseBody = "[]".data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: responseBody, error: nil) }
        let client = makeClient()

        let results = try await client.searchUsers(query: "cam", excludingDocumentID: documentID)

        XCTAssertTrue(results.isEmpty)
        let url = MockURLProtocol.lastRequest?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("q=cam"))
        XCTAssertTrue(url.contains("document_id=11111111"))
    }

    func testDeleteAccessSendsDeleteRequest() async throws {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 204, headers: [:], body: Data(), error: nil) }
        let client = makeClient()
        let accessID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

        try await client.deleteAccess(documentID: documentID, accessID: accessID)

        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "DELETE")
    }
}
