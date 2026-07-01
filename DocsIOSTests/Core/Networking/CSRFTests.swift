import XCTest
@testable import DocsIOS

final class CSRFTests: XCTestCase {
    private func makeCookie(name: String, value: String) -> HTTPCookie {
        HTTPCookie(properties: [.domain: "docs.example.org", .path: "/", .name: name, .value: value])!
    }

    func testFindsCsrfTokenAmongMultipleCookies() {
        let cookies = [makeCookie(name: "docs_sessionid", value: "session-abc"), makeCookie(name: "csrftoken", value: "csrf-xyz")]
        XCTAssertEqual(csrfToken(from: cookies), "csrf-xyz")
    }

    func testReturnsNilWhenNoCsrfCookiePresent() {
        XCTAssertNil(csrfToken(from: [makeCookie(name: "docs_sessionid", value: "session-abc")]))
    }
}
