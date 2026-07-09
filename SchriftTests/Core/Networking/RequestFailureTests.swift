import XCTest

@testable import Schrift

/// Collects what the client hands the diagnostics hook, from whatever thread it fires on.
private final class FailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _failures: [RequestFailure] = []

    var failures: [RequestFailure] {
        lock.lock()
        defer { lock.unlock() }
        return _failures
    }

    func record(_ failure: RequestFailure) {
        lock.lock()
        defer { lock.unlock() }
        _failures.append(failure)
    }
}

final class RequestFailureTests: XCTestCase {
    func testBodyPrefixIsNilForAnEmptyBody() {
        XCTAssertNil(boundedBodyPrefix(Data()))
    }

    func testBodyPrefixTruncatesToTheLimit() {
        let body = Data(repeating: UInt8(ascii: "a"), count: RequestFailure.maxBodyLength * 3)

        let prefix = boundedBodyPrefix(body)

        XCTAssertEqual(prefix?.count, RequestFailure.maxBodyLength)
    }

    /// A cut landing mid-scalar must degrade to a replacement character, not to nil — the
    /// reason is worth reading even when the byte cap lands badly.
    func testBodyPrefixSurvivesATruncatedMultiByteScalar() {
        let body = "aé".data(using: .utf8)!  // 'é' is two bytes, so limit 2 splits it

        let prefix = boundedBodyPrefix(body, limit: 2)

        XCTAssertEqual(prefix?.first, "a")
        XCTAssertEqual(prefix?.count, 2)
    }

    func testServerReasonLiftsTheDRFDetailField() {
        let body = #"{"detail":"CSRF Failed: CSRF token missing."}"#

        XCTAssertEqual(serverReason(fromBody: body), "CSRF Failed: CSRF token missing.")
    }

    func testServerReasonFallsBackToRawTextForNonJSON() {
        XCTAssertEqual(serverReason(fromBody: "<html>403 Forbidden</html>"), "<html>403 Forbidden</html>")
    }

    func testServerReasonIsNilForWhitespaceOnlyBody() {
        XCTAssertNil(serverReason(fromBody: "  \n "))
    }

    func testDisplayTextCombinesStatusAndServerReason() {
        let failure = RequestFailure(
            method: "POST",
            path: "documents/",
            statusCode: 403,
            body: #"{"detail":"CSRF Failed: Origin checking failed."}"#.data(using: .utf8)!
        )

        XCTAssertEqual(failure.displayText, "HTTP 403: CSRF Failed: Origin checking failed.")
    }

    func testDisplayTextIsJustTheStatusWhenTheBodyIsEmpty() {
        let failure = RequestFailure(method: "DELETE", path: "documents/x/", statusCode: 500, body: Data())

        XCTAssertEqual(failure.displayText, "HTTP 500")
    }
}

final class DocsAPIClientDiagnosticsTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testNonSuccessResponseReportsStatusMethodPathAndBody() async {
        let recorder = FailureRecorder()
        let body = #"{"detail":"CSRF Failed: CSRF token missing."}"#.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 403, headers: ["Set-Cookie": "sessionid=supersecret"], body: body, error: nil)
        }
        let client = DocsAPIClient(
            baseURL: baseURL,
            session: MockURLProtocol.makeSession(),
            cookieProvider: { [] },
            onRequestFailure: { recorder.record($0) }
        )

        do {
            try await client.sendVoid(path: "documents/", method: "POST", body: Data())
            XCTFail("Expected a forbidden error")
        } catch let error as DocsAPIError {
            XCTAssertEqual(error, .forbidden)
        } catch {
            XCTFail("Expected DocsAPIError, got \(error)")
        }

        XCTAssertEqual(recorder.failures.count, 1)
        let failure = recorder.failures[0]
        XCTAssertEqual(failure.statusCode, 403)
        XCTAssertEqual(failure.method, "POST")
        XCTAssertEqual(failure.path, "documents/")
        XCTAssertEqual(failure.displayText, "HTTP 403: CSRF Failed: CSRF token missing.")
    }

    /// The hook is a diagnostics channel, not a wiretap. `RequestFailure` has no field for a
    /// header or a cookie; this pins that the session credential can't leak through the body
    /// prefix either.
    func testFailureNeverCarriesCookiesOrHeaders() async throws {
        let recorder = FailureRecorder()
        MockURLProtocol.stubHandler = { _ in
            .init(
                statusCode: 500,
                headers: ["Set-Cookie": "sessionid=supersecret", "X-CSRFToken": "tokenvalue"],
                body: Data("boom".utf8),
                error: nil
            )
        }
        let cookie = HTTPCookie(properties: [
            .name: "csrftoken", .value: "supersecret", .domain: "docs.example.org", .path: "/",
        ])!
        let client = DocsAPIClient(
            baseURL: baseURL,
            session: MockURLProtocol.makeSession(),
            cookieProvider: { [cookie] },
            onRequestFailure: { recorder.record($0) }
        )

        do {
            try await client.sendVoid(path: "documents/", method: "POST", body: Data())
            XCTFail("Expected a server error")
        } catch {}

        let failure = try XCTUnwrap(recorder.failures.first)
        let serialized = "\(failure)"
        XCTAssertFalse(serialized.contains("supersecret"))
        XCTAssertFalse(serialized.contains("tokenvalue"))
        XCTAssertFalse(serialized.contains("Set-Cookie"))
    }

    /// Django compares the `Origin` header against its own host and rejects a mismatch with
    /// "CSRF Failed: Origin checking failed", which 403s **every** non-GET while GETs —
    /// carrying no Origin — keep working. `normalizedServerURL` now lowercases the host, but
    /// a `serverURL` already persisted in UserDefaults from an earlier launch still carries
    /// the capital, so the client must not trust its own `baseURL` either.
    func testOriginAndRefererAreLowercasedEvenIfTheBaseURLHostIsNot() async {
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 204, headers: [:], body: Data(), error: nil) }
        let client = DocsAPIClient(
            baseURL: URL(string: "https://Docs.Example.ORG/api/v1.0/")!,
            session: MockURLProtocol.makeSession(),
            cookieProvider: { [] }
        )

        try? await client.sendVoid(path: "documents/", method: "POST", body: Data())

        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Origin"), "https://docs.example.org")
        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Referer"), "https://docs.example.org/")
    }

    func testSuccessfulResponseReportsNothing() async throws {
        let recorder = FailureRecorder()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 204, headers: [:], body: Data(), error: nil) }
        let client = DocsAPIClient(
            baseURL: baseURL,
            session: MockURLProtocol.makeSession(),
            cookieProvider: { [] },
            onRequestFailure: { recorder.record($0) }
        )

        try await client.sendVoid(path: "documents/", method: "POST", body: Data())

        XCTAssertTrue(recorder.failures.isEmpty)
    }

    /// A transport error never reaches an HTTP status, so nothing is recorded — which is what
    /// lets the marker distinguish "offline" from "the server rejected us".
    func testTransportErrorReportsNothing() async {
        let recorder = FailureRecorder()
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        let client = DocsAPIClient(
            baseURL: baseURL,
            session: MockURLProtocol.makeSession(),
            cookieProvider: { [] },
            onRequestFailure: { recorder.record($0) }
        )

        do {
            try await client.sendVoid(path: "documents/", method: "POST", body: Data())
            XCTFail("Expected a network error")
        } catch {}

        XCTAssertTrue(recorder.failures.isEmpty)
    }
}
