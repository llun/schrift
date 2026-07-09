import XCTest

@testable import Schrift

final class ServerURLInputTests: XCTestCase {
    func testBareHostnameGetsHTTPSScheme() {
        XCTAssertEqual(normalizedServerURL(from: "docs.llun.dev")?.absoluteString, "https://docs.llun.dev")
    }

    func testAlreadyHasHTTPSSchemeIsPreserved() {
        XCTAssertEqual(normalizedServerURL(from: "https://docs.llun.dev")?.absoluteString, "https://docs.llun.dev")
    }

    func testTrailingSlashIsStripped() {
        XCTAssertEqual(normalizedServerURL(from: "https://docs.llun.dev/")?.absoluteString, "https://docs.llun.dev")
    }

    func testWhitespaceIsTrimmed() {
        XCTAssertEqual(normalizedServerURL(from: "  docs.llun.dev  ")?.absoluteString, "https://docs.llun.dev")
    }

    func testEmptyStringReturnsNil() {
        XCTAssertNil(normalizedServerURL(from: ""))
    }

    func testWhitespaceOnlyStringReturnsNil() {
        XCTAssertNil(normalizedServerURL(from: "   "))
    }

    func testInvalidHostReturnsNil() {
        XCTAssertNil(normalizedServerURL(from: "not a valid host???"))
    }

    func testDisallowedSchemeReturnsNil() {
        XCTAssertNil(normalizedServerURL(from: "ftp://docs.llun.dev"))
    }

    func testHTTPSchemeWithPortIsPreserved() {
        XCTAssertEqual(normalizedServerURL(from: "http://localhost:8000")?.absoluteString, "http://localhost:8000")
    }

    func testPathQueryAndFragmentAreStripped() {
        XCTAssertEqual(
            normalizedServerURL(from: "https://docs.llun.dev/some/path?x=1#frag")?.absoluteString,
            "https://docs.llun.dev")
    }

    // MARK: - Host case

    /// iOS autocapitalizes the first letter of a plain text field, so a user typing the
    /// server address gets `Docs.llun.dev`. Hostnames are case-insensitive per DNS, but
    /// nothing downstream was: `isLoginNavigationComplete` compared `url.host == serverHost`
    /// and WebKit lowercases its side, so login detection never fired and the sheet never
    /// closed; and `DocsAPIClient.siteOrigin` sent `Origin: https://Docs.llun.dev`, which
    /// Django rejects with "Origin checking failed" on **every** non-GET, while GETs — which
    /// carry no Origin — keep working. Canonicalize once, here.
    func testHostIsLowercased() {
        XCTAssertEqual(normalizedServerURL(from: "Docs.llun.dev")?.absoluteString, "https://docs.llun.dev")
        XCTAssertEqual(normalizedServerURL(from: "HTTPS://DOCS.LLUN.DEV")?.absoluteString, "https://docs.llun.dev")
        XCTAssertEqual(normalizedServerURL(from: "Notes.Liiib.RE")?.host, "notes.liiib.re")
    }

    func testPortSurvivesHostLowercasing() {
        XCTAssertEqual(
            normalizedServerURL(from: "Docs.Example.ORG:8443")?.absoluteString, "https://docs.example.org:8443")
    }
}
