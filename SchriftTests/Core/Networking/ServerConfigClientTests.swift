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

    // MARK: - Docs 6 (yhub)

    /// Docs 6 replaced Hocuspocus with yhub's plain y-websocket. The app's collaboration
    /// layer speaks Hocuspocus, so a Docs 6 server must not read as live-capable — known
    /// from the release major *or* from the yhub URL shape when the version is withheld.
    func testADocs6ServerDoesNotAdvertiseLiveCollaboration() {
        let byVersion = ServerConfig(
            releaseVersion: "6.0.0", collaborationWsUrl: "wss://docs.example.org/collaboration/ws/")
        let byShape = ServerConfig(collaborationWsUrl: "wss://docs.example.org/collaboration/ws/v1/docs")
        let hocuspocus = ServerConfig(
            releaseVersion: "5.7.0", collaborationWsUrl: "wss://docs.example.org/collaboration/ws/")

        XCTAssertTrue(byVersion.usesCollaborationYDocServer)
        XCTAssertFalse(byVersion.supportsLiveCollaboration)
        XCTAssertTrue(byShape.usesCollaborationYDocServer)
        XCTAssertFalse(byShape.supportsLiveCollaboration)
        XCTAssertFalse(hocuspocus.usesCollaborationYDocServer)
        XCTAssertTrue(hocuspocus.supportsLiveCollaboration)
    }

    /// The org is interpolated into a request path, so only plain URL-safe text is taken from
    /// config; anything else — including a dot segment that would resolve out of the route —
    /// falls back to yhub's default.
    func testTheCollaborationOrgIsTakenOnlyWhenItIsPlainPathText() {
        let cases: [(url: String?, org: String)] = [
            ("wss://docs.example.org/collaboration/ws/v1/acme-team", "acme-team"),
            ("wss://docs.example.org/collaboration/ws/v1/acme/", "acme"),
            ("wss://docs.example.org/collaboration/ws/v1/a%2Fb", "docs"),
            ("wss://docs.example.org/collaboration/ws/v1/..", "docs"),
            ("wss://docs.example.org/collaboration/ws/", "docs"),
            (nil, "docs"),
        ]
        for (url, org) in cases {
            XCTAssertEqual(
                ServerConfig(releaseVersion: "6.0.0", collaborationWsUrl: url).collaborationOrg, org, "\(url ?? "nil")")
        }
    }

    /// The content-save route is decided only by a definitive config; an unversioned,
    /// non-yhub config proves nothing and leaves the save to discover it.
    func testContentSaveRouteFollowsTheConfig() {
        XCTAssertEqual(ContentSaveRoute(config: ServerConfig(releaseVersion: "6.1.2")), .collaborationYDoc(org: "docs"))
        XCTAssertEqual(
            ContentSaveRoute(config: ServerConfig(collaborationWsUrl: "wss://docs.example.org/collaboration/ws/v1/x")),
            .collaborationYDoc(org: "x"))
        XCTAssertEqual(ContentSaveRoute(config: ServerConfig(releaseVersion: "5.10.0")), .legacyContent)
        XCTAssertNil(ContentSaveRoute(config: ServerConfig()))
        XCTAssertNil(
            ContentSaveRoute(config: ServerConfig(collaborationWsUrl: "wss://docs.example.org/collaboration/ws/")))
    }

    func testFetchingADocs6ConfigRecordsTheCollaborationSaveRoute() async throws {
        let body = #"{"RELEASE_VERSION":"6.0.0"}"#.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }
        let client = makeClient()

        _ = try await client.serverConfig()

        let route = await client.contentSaveRoute
        XCTAssertEqual(route, .collaborationYDoc(org: "docs"))
    }
}
