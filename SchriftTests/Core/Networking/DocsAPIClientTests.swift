import XCTest

@testable import Schrift

final class DocsAPIClientTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!

    override func tearDown() {
        MockURLProtocol.stubHandler = nil
        MockURLProtocol.lastRequest = nil
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
}
