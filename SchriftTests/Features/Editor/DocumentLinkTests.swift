import XCTest

@testable import Schrift

final class DocumentLinkTests: XCTestCase {
    private let serverHost = "docs.example.org"
    private let linked = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let current = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    private func action(_ string: String) -> DocumentLinkAction {
        guard let url = URL(string: string) else {
            XCTFail("Not a URL: \(string)")
            return .openInBrowser
        }
        return documentLinkAction(for: url, serverHost: serverHost, currentDocumentID: current)
    }

    // MARK: - In-app document links

    func testCanonicalDocumentURLOpensInApp() {
        XCTAssertEqual(
            action("https://docs.example.org/docs/11111111-1111-4111-8111-111111111111/"), .openInApp(linked))
    }

    func testDocumentURLWithoutTrailingSlashOpensInApp() {
        XCTAssertEqual(action("https://docs.example.org/docs/11111111-1111-4111-8111-111111111111"), .openInApp(linked))
    }

    /// Hostnames and schemes are case-insensitive but `String ==` is not, and iOS
    /// autocapitalizes the first letter of the server field — the same trap that once
    /// broke CSRF (`Origin: https://Docs.llun.dev`).
    func testHostAndSchemeAreMatchedCaseInsensitively() {
        XCTAssertEqual(
            action("https://DOCS.Example.ORG/docs/11111111-1111-4111-8111-111111111111/"), .openInApp(linked))
        XCTAssertEqual(
            action("HTTPS://docs.example.org/docs/11111111-1111-4111-8111-111111111111/"), .openInApp(linked))
    }

    /// `UUID(uuidString:)` accepts either case, and the two spellings name one document.
    func testUppercaseUUIDOpensInApp() {
        let hex = UUID(uuidString: "aaaaaaaa-1111-4111-8111-111111111111")!
        XCTAssertEqual(action("https://docs.example.org/docs/AAAAAAAA-1111-4111-8111-111111111111/"), .openInApp(hex))
        XCTAssertEqual(action("https://docs.example.org/docs/aaaaaaaa-1111-4111-8111-111111111111/"), .openInApp(hex))
    }

    /// A self-hosted instance may serve plain HTTP on a LAN; `normalizedServerURL`
    /// permits it, so an internal link over http is still internal.
    func testHTTPDocumentURLOpensInApp() {
        XCTAssertEqual(action("http://docs.example.org/docs/11111111-1111-4111-8111-111111111111/"), .openInApp(linked))
    }

    /// `serverHost` carries no port (RootView derives it from `URL.host`), and the id is
    /// fetched from the client's own `baseURL` regardless of what the link says.
    func testNonStandardPortStillOpensInApp() {
        XCTAssertEqual(
            action("https://docs.example.org:8443/docs/11111111-1111-4111-8111-111111111111/"), .openInApp(linked))
    }

    /// The app has no in-document anchors, so a fragment or query is ignored rather
    /// than sending the whole link to the browser.
    func testQueryAndFragmentAreIgnored() {
        XCTAssertEqual(
            action("https://docs.example.org/docs/11111111-1111-4111-8111-111111111111/?x=1#heading"),
            .openInApp(linked))
    }

    // MARK: - The document already on screen

    func testLinkToTheOpenDocumentIsSwallowed() {
        XCTAssertEqual(action("https://docs.example.org/docs/22222222-2222-4222-8222-222222222222/"), .alreadyOpen)
    }

    // MARK: - Everything else goes to the browser

    func testForeignHostOpensInBrowser() {
        XCTAssertEqual(action("https://evil.com/docs/11111111-1111-4111-8111-111111111111/"), .openInBrowser)
    }

    /// `https://docs.example.org@evil.com/…` has a *host* of `evil.com`; only the
    /// userinfo says otherwise. Matching `URL.host` — not a string prefix — rejects it.
    func testUserinfoHostSpoofOpensInBrowser() {
        XCTAssertEqual(
            action("https://docs.example.org@evil.com/docs/11111111-1111-4111-8111-111111111111/"), .openInBrowser)
    }

    func testSuffixHostSpoofOpensInBrowser() {
        XCTAssertEqual(
            action("https://docs.example.org.evil.com/docs/11111111-1111-4111-8111-111111111111/"), .openInBrowser)
    }

    /// A protocol-relative authority carries no scheme and the host is the attacker's.
    func testProtocolRelativeURLOpensInBrowser() {
        XCTAssertEqual(action("//evil.com/docs/11111111-1111-4111-8111-111111111111/"), .openInBrowser)
    }

    /// The web app only ever writes absolute links, so a host-less reference is not
    /// evidence of an internal document.
    func testRelativePathOpensInBrowser() {
        XCTAssertEqual(action("/docs/11111111-1111-4111-8111-111111111111/"), .openInBrowser)
    }

    func testDangerousSchemesOpenInBrowser() {
        XCTAssertEqual(action("javascript:alert(1)"), .openInBrowser)
        XCTAssertEqual(action("data:text/html;base64,AAAA"), .openInBrowser)
        XCTAssertEqual(action("file:///docs/11111111-1111-4111-8111-111111111111/"), .openInBrowser)
        XCTAssertEqual(action("mailto:someone@docs.example.org"), .openInBrowser)
    }

    /// `/docs/<uuid>/versions/1` is a different page, not this document.
    func testExtraPathSegmentsOpenInBrowser() {
        XCTAssertEqual(
            action("https://docs.example.org/docs/11111111-1111-4111-8111-111111111111/versions/1"), .openInBrowser)
    }

    func testDocsPathWithoutAUUIDOpensInBrowser() {
        XCTAssertEqual(action("https://docs.example.org/docs/new/"), .openInBrowser)
        XCTAssertEqual(action("https://docs.example.org/docs/"), .openInBrowser)
        XCTAssertEqual(action("https://docs.example.org/docs"), .openInBrowser)
    }

    /// URL paths are case-sensitive; `/DOCS/` is not the web app's document route.
    func testUppercasePathSegmentOpensInBrowser() {
        XCTAssertEqual(action("https://docs.example.org/DOCS/11111111-1111-4111-8111-111111111111/"), .openInBrowser)
    }

    func testUnrelatedPathOnTheServerOpensInBrowser() {
        XCTAssertEqual(action("https://docs.example.org/media/photo.jpg"), .openInBrowser)
        XCTAssertEqual(action("https://docs.example.org"), .openInBrowser)
    }

    func testExternalSiteOpensInBrowser() {
        XCTAssertEqual(action("https://example.com/a/b"), .openInBrowser)
    }

    /// `URL.host` is "" for `file:` URLs; an empty `serverHost` (RootView's fallback
    /// when the server URL somehow has no host) must not make everything match.
    func testEmptyServerHostNeverMatches() {
        let url = URL(string: "https://docs.example.org/docs/11111111-1111-4111-8111-111111111111/")!
        XCTAssertEqual(documentLinkAction(for: url, serverHost: "", currentDocumentID: current), .openInBrowser)
        let fileURL = URL(string: "file:///docs/11111111-1111-4111-8111-111111111111/")!
        XCTAssertEqual(documentLinkAction(for: fileURL, serverHost: "", currentDocumentID: current), .openInBrowser)
    }
}
