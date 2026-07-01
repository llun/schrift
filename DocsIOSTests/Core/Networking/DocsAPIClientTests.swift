import XCTest
@testable import DocsIOS

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
}
