import XCTest

@testable import Schrift

final class VersionEndpointsClientTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    // Alphabetic hex so the path assertion actually exercises `.lowercased()`:
    // an all-digit UUID would pass whether or not the endpoint lowercases it.
    private let documentID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> DocsAPIClient {
        DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
    }

    func testListsVersions() async throws {
        let responseBody = #"""
            {"versions":[{"version_id":"v1","last_modified":"2026-07-11T15:04:00Z","is_current":true},{"version_id":"v2","last_modified":"2026-07-11T14:32:00Z"}]}
            """#.data(using: .utf8)!
        MockURLProtocol.stubHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            // Lowercased UUID: the Django backend requires it. The alphabetic
            // hex here means a dropped `.lowercased()` would fail this assertion.
            XCTAssertTrue(
                request.url!.absoluteString.hasSuffix(
                    "/documents/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/versions/"))
            return .init(statusCode: 200, headers: [:], body: responseBody, error: nil)
        }
        let client = makeClient()

        let versions = try await client.documentVersions(documentID: documentID)

        XCTAssertEqual(versions.count, 2)
        XCTAssertEqual(versions[0].id, "v1")
        XCTAssertTrue(versions[0].isCurrent)
        XCTAssertEqual(versions[1].id, "v2")
        XCTAssertFalse(versions[1].isCurrent)
    }

    func testEmptyVersionsListDecodesToEmptyArray() async throws {
        let responseBody = #"{"versions":[]}"#.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: responseBody, error: nil) }
        let client = makeClient()

        let versions = try await client.documentVersions(documentID: documentID)

        XCTAssertTrue(versions.isEmpty)
    }
}
