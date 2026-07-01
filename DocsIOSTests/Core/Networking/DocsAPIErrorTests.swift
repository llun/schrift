import XCTest
@testable import DocsIOS

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
