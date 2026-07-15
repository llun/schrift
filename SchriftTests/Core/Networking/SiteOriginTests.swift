import XCTest

@testable import Schrift

/// The shared origin derivation used by both REST CSRF headers and the
/// collaboration socket. The `DocsAPIClient` Origin-header regression tests
/// exercise it end to end; these pin the pure function directly.
final class SiteOriginTests: XCTestCase {
    func testHTTPSHostOnly() {
        XCTAssertEqual(siteOrigin(for: URL(string: "https://docs.example.org/api/v1.0/")!), "https://docs.example.org")
    }

    func testHTTPWithPort() {
        XCTAssertEqual(siteOrigin(for: URL(string: "http://localhost:8000/api/v1.0/")!), "http://localhost:8000")
    }

    func testLowercasesSchemeAndHost() {
        XCTAssertEqual(siteOrigin(for: URL(string: "HTTPS://Docs.Example.ORG/x")!), "https://docs.example.org")
    }

    func testBracketsIPv6Host() {
        XCTAssertEqual(siteOrigin(for: URL(string: "https://[fe80::1]:8443/api/")!), "https://[fe80::1]:8443")
    }

    func testDefaultPortIsOmitted() {
        // URL only surfaces an explicit port; :443 here is implicit, so no port.
        XCTAssertEqual(siteOrigin(for: URL(string: "https://docs.example.org/")!), "https://docs.example.org")
    }

    func testReturnsNilWithoutHost() {
        XCTAssertNil(siteOrigin(for: URL(string: "mailto:a@b.com")!))
        XCTAssertNil(siteOrigin(for: URL(string: "data:text/plain,hi")!))
    }

    func testUsesTrueHostNotEmbeddedUserinfo() {
        // A URL with embedded credentials must pin the REAL host: `URL.host`
        // returns "evil.com" here, and this function's whole job is scoping
        // cookies/CSRF/the socket to the user's own server. A future string-parse
        // "simplification" that split on "://" would derive the wrong origin —
        // this locks the true-host contract (CLAUDE.md flags exactly this shape).
        XCTAssertEqual(siteOrigin(for: URL(string: "https://docs.example.org@evil.com/api/")!), "https://evil.com")
    }
}
