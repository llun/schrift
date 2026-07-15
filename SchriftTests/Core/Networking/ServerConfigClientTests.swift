import XCTest

@testable import Schrift

final class ServerConfigClientTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> DocsAPIClient {
        DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
    }

    func testFetchesConfigVersion() async throws {
        let responseBody = #"{"RELEASE_VERSION":"5.4.1"}"#.data(using: .utf8)!
        MockURLProtocol.stubHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertTrue(request.url!.absoluteString.hasSuffix("/api/v1.0/config/"))
            return .init(statusCode: 200, headers: [:], body: responseBody, error: nil)
        }
        let client = makeClient()

        let config = try await client.serverConfig()

        XCTAssertEqual(config.version, "5.4.1")
    }

    func testMissingVersionTolerated() async throws {
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: "{}".data(using: .utf8)!, error: nil)
        }
        let client = makeClient()

        let config = try await client.serverConfig()

        XCTAssertNil(config.version)
    }

    func testDecodesCollaborationWsUrlAndAdvertisesSupport() async throws {
        let body = #"{"RELEASE_VERSION":"5.4.1","COLLABORATION_WS_URL":"wss://docs.example.org/collaboration/ws/"}"#
            .data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }

        let config = try await makeClient().serverConfig()

        XCTAssertEqual(config.collaborationWsUrl, "wss://docs.example.org/collaboration/ws/")
        XCTAssertTrue(config.supportsLiveCollaboration)
    }

    func testAbsentCollaborationWsUrlMeansNoLiveSupport() async throws {
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: "{}".data(using: .utf8)!, error: nil)
        }

        let config = try await makeClient().serverConfig()

        XCTAssertNil(config.collaborationWsUrl)
        XCTAssertFalse(config.supportsLiveCollaboration)
    }

    func testEmptyCollaborationWsUrlIsNotSupport() async throws {
        let body = #"{"COLLABORATION_WS_URL":""}"#.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }

        let config = try await makeClient().serverConfig()

        XCTAssertFalse(config.supportsLiveCollaboration)
    }
}
