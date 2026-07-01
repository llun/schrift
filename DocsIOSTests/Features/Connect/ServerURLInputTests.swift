import XCTest
@testable import DocsIOS

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
        XCTAssertEqual(normalizedServerURL(from: "https://docs.llun.dev/some/path?x=1#frag")?.absoluteString, "https://docs.llun.dev")
    }
}
