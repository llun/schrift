import XCTest

@testable import Schrift

final class DocsAPIErrorTests: XCTestCase {
    func testMapsUnauthorizedToSessionExpired() {
        XCTAssertEqual(DocsAPIErrorMapper.map(statusCode: 401, headers: [:]), .sessionExpired)
    }

    func testMapsForbiddenToForbidden() {
        XCTAssertEqual(DocsAPIErrorMapper.map(statusCode: 403, headers: [:]), .forbidden)
    }

    func testMapsNotFoundToNotFound() {
        XCTAssertEqual(DocsAPIErrorMapper.map(statusCode: 404, headers: [:]), .notFound)
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

    func testMapsTooManyRequestsWithoutRetryAfter() {
        XCTAssertEqual(DocsAPIErrorMapper.map(statusCode: 429, headers: [:]), .rateLimited(retryAfter: nil))
    }

    func testMapsUnhandledStatusCodeToServer() {
        XCTAssertEqual(DocsAPIErrorMapper.map(statusCode: 500, headers: [:]), .server(statusCode: 500))
    }
}
