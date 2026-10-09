import XCTest

@testable import Schrift

final class DocsAPIErrorTests: XCTestCase {
    /// The 401 → `sessionExpired` mapping is exercised end to end by `DocsAPIClientTests`.
    func testMapsPlainStatusCodesToTheirErrors() {
        let cases: [(Int, DocsAPIError)] = [
            (403, .forbidden),
            (404, .notFound),
            (500, .server(statusCode: 500)),
            (429, .rateLimited(retryAfter: nil)),
        ]
        for (status, expected) in cases {
            XCTAssertEqual(DocsAPIErrorMapper.map(statusCode: status, headers: [:]), expected, "\(status)")
        }
    }

    /// Django serves a plain HTML page when the *route* is absent; DRF answers a missing
    /// *object* with JSON. Conflating them made a backend without `formatted-content/`
    /// report every one of its documents as deleted.
    func testHTML404MapsToRouteNotFound() {
        XCTAssertEqual(
            DocsAPIErrorMapper.map(statusCode: 404, headers: ["Content-Type": "text/html; charset=utf-8"]),
            .routeNotFound)
        // Header names are case-insensitive and HTTPURLResponse does not normalize them.
        XCTAssertEqual(
            DocsAPIErrorMapper.map(statusCode: 404, headers: ["content-type": "TEXT/HTML"]), .routeNotFound)
    }

    /// Only positive evidence of HTML downgrades a 404. An unlabelled or JSON 404 stays
    /// `.notFound`, because the delete and cache-purge paths key off it.
    func testJSONOrUnlabelled404StaysNotFound() {
        XCTAssertEqual(
            DocsAPIErrorMapper.map(statusCode: 404, headers: ["Content-Type": "application/json"]), .notFound)
        XCTAssertEqual(DocsAPIErrorMapper.map(statusCode: 404, headers: [:]), .notFound)
    }

    func testMapsTooManyRequestsWithRetryAfter() {
        XCTAssertEqual(
            DocsAPIErrorMapper.map(statusCode: 429, headers: ["Retry-After": "30"]),
            .rateLimited(retryAfter: 30)
        )
    }
}
