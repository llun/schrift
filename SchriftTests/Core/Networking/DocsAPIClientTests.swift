import XCTest

@testable import Schrift

final class DocsAPIClientTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient(cookies: [HTTPCookie] = []) -> DocsAPIClient {
        DocsAPIClient(
            baseURL: baseURL,
            session: MockURLProtocol.makeSession(),
            cookieProvider: { cookies }
        )
    }

    func testGetDecodesSuccessfulResponse() async throws {
        struct Config: Decodable, Equatable { let theme: String }
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: #"{"theme": "indigo"}"#.data(using: .utf8)!, error: nil)
        }

        let client = makeClient()
        let config: Config = try await client.get("config/")
        XCTAssertEqual(config, Config(theme: "indigo"))
    }

    func testUnauthorizedResponseThrowsSessionExpired() async {
        struct Config: Decodable {}
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 401, headers: [:], body: Data(), error: nil)
        }

        let client = makeClient()
        do {
            let _: Config = try await client.get("users/me/")
            XCTFail("Expected error to be thrown")
        } catch let error as DocsAPIError {
            XCTAssertEqual(error, .sessionExpired)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testUnauthorizedResponseFiresOnSessionExpiredAndStillThrows() async {
        struct Config: Decodable {}
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            func set() { lock.withLock { value = true } }
            var isSet: Bool { lock.withLock { value } }
        }
        let fired = Flag()
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 401, headers: [:], body: Data(), error: nil)
        }

        let client = DocsAPIClient(
            baseURL: baseURL,
            session: MockURLProtocol.makeSession(),
            cookieProvider: { [] },
            onSessionExpired: { fired.set() }
        )
        do {
            let _: Config = try await client.get("users/me/")
            XCTFail("Expected error to be thrown")
        } catch let error as DocsAPIError {
            XCTAssertEqual(error, .sessionExpired)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertTrue(fired.isSet)
    }

    func testSuccessAndServerErrorDoNotFireOnSessionExpired() async {
        struct Config: Decodable { let theme: String }
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            func set() { lock.withLock { value = true } }
            var isSet: Bool { lock.withLock { value } }
        }
        let fired = Flag()
        let client = DocsAPIClient(
            baseURL: baseURL,
            session: MockURLProtocol.makeSession(),
            cookieProvider: { [] },
            onSessionExpired: { fired.set() }
        )

        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: #"{"theme": "indigo"}"#.data(using: .utf8)!, error: nil)
        }
        let _: Config? = try? await client.get("config/")

        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }
        let _: Config? = try? await client.get("config/")

        XCTAssertFalse(fired.isSet)
    }

    func testRateLimitedResponseCarriesRetryAfter() async {
        struct Config: Decodable {}
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 429, headers: ["Retry-After": "12"], body: Data(), error: nil)
        }

        let client = makeClient()
        do {
            let _: Config = try await client.get("documents/")
            XCTFail("Expected error to be thrown")
        } catch let error as DocsAPIError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 12))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testNetworkFailureMapsToNetworkError() async {
        struct Config: Decodable {}
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        let client = makeClient()
        do {
            let _: Config = try await client.get("config/")
            XCTFail("Expected error to be thrown")
        } catch let error as DocsAPIError {
            guard case .network = error else {
                return XCTFail("Expected .network, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testMutatingRequestAttachesCsrfTokenFromCookies() async throws {
        struct Empty: Decodable {}
        let cookie = HTTPCookie(properties: [
            .domain: "docs.example.org",
            .path: "/",
            .name: "csrftoken",
            .value: "test-csrf-value",
        ])!
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: "{}".data(using: .utf8)!, error: nil)
        }

        let client = makeClient(cookies: [cookie])
        let _: Empty = try await client.send(path: "documents/1/", method: "PATCH", body: "{}".data(using: .utf8))

        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-CSRFToken"), "test-csrf-value")
    }

    func testGetRequestDoesNotAttachCsrfToken() async throws {
        struct Empty: Decodable {}
        let cookie = HTTPCookie(properties: [
            .domain: "docs.example.org",
            .path: "/",
            .name: "csrftoken",
            .value: "test-csrf-value",
        ])!
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: "{}".data(using: .utf8)!, error: nil)
        }

        let client = makeClient(cookies: [cookie])
        let _: Empty = try await client.get("documents/")

        XCTAssertNil(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-CSRFToken"))
    }

    // Django's CsrfViewMiddleware rejects unsafe requests on HTTPS that carry a
    // valid token but no Origin/Referer ("CSRF Failed: Referer checking failed -
    // no Referer."). These regression tests pin the Origin/Referer headers that
    // every write must carry, matching the site origin — not the /api/v1.0/ path.
    func testMutatingRequestAttachesOriginAndRefererForSiteOrigin() async throws {
        struct Empty: Decodable {}
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: "{}".data(using: .utf8)!, error: nil)
        }

        let client = makeClient()
        let _: Empty = try await client.send(path: "documents/1/", method: "PATCH", body: "{}".data(using: .utf8))

        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Origin"), "https://docs.example.org")
        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Referer"), "https://docs.example.org/")
    }

    func testPostRequestAttachesOrigin() async throws {
        struct Empty: Decodable {}
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 201, headers: [:], body: "{}".data(using: .utf8)!, error: nil)
        }

        let client = makeClient()
        let _: Empty = try await client.send(path: "documents/", method: "POST", body: "{}".data(using: .utf8))

        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Origin"), "https://docs.example.org")
    }

    func testMutatingRequestUsesBracketedOriginForIPv6Host() async throws {
        struct Empty: Decodable {}
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: "{}".data(using: .utf8)!, error: nil)
        }
        let client = DocsAPIClient(
            baseURL: URL(string: "https://[fe80::1]:8443/api/v1.0/")!,
            session: MockURLProtocol.makeSession(),
            cookieProvider: { [] }
        )
        let _: Empty = try await client.send(path: "documents/", method: "POST", body: "{}".data(using: .utf8))

        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Origin"), "https://[fe80::1]:8443")
        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Referer"), "https://[fe80::1]:8443/")
    }

    func testGetRequestDoesNotAttachOriginOrReferer() async throws {
        struct Empty: Decodable {}
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: "{}".data(using: .utf8)!, error: nil)
        }

        let client = makeClient()
        let _: Empty = try await client.get("documents/")

        XCTAssertNil(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Origin"))
        XCTAssertNil(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Referer"))
    }

    // MARK: - Server-relative URL resolution

    func testAbsoluteServerURLResolvesAgainstServerRootNotAPIBase() async {
        let url = await makeClient().absoluteServerURL(for: "/media/1111/attachments/2222.jpg")
        XCTAssertEqual(url?.absoluteString, "https://docs.example.org/media/1111/attachments/2222.jpg")
    }

    func testAbsoluteServerURLPreservesPort() async {
        let client = DocsAPIClient(
            baseURL: URL(string: "https://docs.example.org:8443/api/v1.0/")!,
            session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let url = await client.absoluteServerURL(for: "/media/a.jpg")
        XCTAssertEqual(url?.absoluteString, "https://docs.example.org:8443/media/a.jpg")
    }

    /// The path is server-controlled and gets embedded in a persisted, shared
    /// document. `URL(string:relativeTo:)` will happily leave the origin, so the
    /// resolver must pin scheme + host + port.
    func testAbsoluteServerURLRejectsOffOriginPaths() async {
        let client = makeClient()
        for hostile in [
            "//evil.com/x.jpg",  // protocol-relative authority
            "https://evil.com/x.jpg",  // absolute, other host
            "http://docs.example.org/x.jpg",  // scheme downgrade
            "javascript:alert(1)",
            "data:image/svg+xml;base64,AAAA",
            "file:///etc/passwd",
            "///evil.com/x",
        ] {
            let url = await client.absoluteServerURL(for: hostile)
            XCTAssertNil(url, "absoluteServerURL must reject \(hostile), got \(String(describing: url))")
        }
    }

    func testAbsoluteServerURLRejectsAPortChange() async {
        let url = await makeClient().absoluteServerURL(for: "https://docs.example.org:8443/media/a.jpg")
        XCTAssertNil(url)
    }

    /// Dot segments normalize within the origin, so they stay allowed.
    func testAbsoluteServerURLAllowsPathTraversalThatStaysOnOrigin() async {
        let url = await makeClient().absoluteServerURL(for: "/media/../../evil")
        XCTAssertEqual(url?.host, "docs.example.org")
    }
}
