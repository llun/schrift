import XCTest

@testable import Schrift

final class ImageLoadPolicyTests: XCTestCase {
    private let serverOrigin = "https://docs.example.org"

    private func policy(_ string: String, serverOrigin origin: String? = nil) -> ImageLoadPolicy {
        guard let url = URL(string: string) else {
            XCTFail("Not a URL on this runtime: \(string)")
            // Fail-closed; also the expected verdict for every adversarial input,
            // so a runtime that rejects one of the confirm-case strings still passes.
            return .confirm
        }
        return imageLoadPolicy(for: url, serverOrigin: origin ?? serverOrigin)
    }

    // MARK: - The user's own server auto-loads

    func testUploadedAttachmentAllows() {
        // The regression that matters most: every app/web upload is this shape.
        XCTAssertEqual(policy("https://docs.example.org/media/2f/photo.jpg"), .allow)
    }

    func testAnyPathOrQueryOnTheServerAllows() {
        XCTAssertEqual(policy("https://docs.example.org/x.png?v=2#top"), .allow)
    }

    func testHostAndSchemeMatchedCaseInsensitively() {
        // parseImageLine preserves the author's casing; the server field autocapitalizes.
        XCTAssertEqual(policy("https://DOCS.Example.ORG/a.png"), .allow)
        XCTAssertEqual(policy("HTTPS://docs.example.org/a.png"), .allow)
    }

    func testHTTPSelfHostedSameOriginAllows() {
        // Proves origin (with scheme+port), not `serverHost`, is threaded.
        XCTAssertEqual(policy("http://192.168.1.5:8000/a.png", serverOrigin: "http://192.168.1.5:8000"), .allow)
    }

    func testMatchingNonDefaultPortAllows() {
        XCTAssertEqual(
            policy("https://docs.example.org:8443/a.png", serverOrigin: "https://docs.example.org:8443"), .allow)
    }

    func testIPv6SameOriginAllows() {
        XCTAssertEqual(policy("https://[fe80::1]:8443/a.png", serverOrigin: "https://[fe80::1]:8443"), .allow)
    }

    func testOriginBuiltViaSiteOriginComposes() {
        // The real RootView derivation path: serverOrigin = siteOrigin(for: serverURL).
        let origin = siteOrigin(for: URL(string: "https://Docs.Example.ORG")!)
        XCTAssertEqual(policy("https://docs.example.org/a.png", serverOrigin: origin), .allow)
    }

    // MARK: - Everything else confirms first

    func testForeignHostConfirms() {
        XCTAssertEqual(policy("https://tracker.example.com/beacon.png"), .confirm)
    }

    func testUserinfoHostSpoofConfirms() {
        // Hosted at evil.com — URL.host reads it correctly, a string prefix would not.
        XCTAssertEqual(policy("https://docs.example.org@evil.com/p.png"), .confirm)
    }

    func testSuffixHostSpoofConfirms() {
        XCTAssertEqual(policy("https://docs.example.org.evil.com/p.png"), .confirm)
    }

    func testSubdomainOfServerConfirms() {
        // A subdomain may be a different party.
        XCTAssertEqual(policy("https://cdn.docs.example.org/p.png"), .confirm)
    }

    func testSchemeDowngradeConfirms() {
        XCTAssertEqual(policy("http://docs.example.org/a.png"), .confirm)
    }

    func testDifferentPortConfirms() {
        // Stricter than documentLinkAction, deliberately — a request is at stake.
        XCTAssertEqual(policy("https://docs.example.org:8443/a.png"), .confirm)
    }

    func testExplicitDefaultPortConfirms() {
        // Documented fail-closed papercut: :443 is a different string from portless.
        XCTAssertEqual(policy("https://docs.example.org:443/a.png"), .confirm)
    }

    func testTrailingDotHostConfirms() {
        XCTAssertEqual(policy("https://docs.example.org./a.png"), .confirm)
    }

    func testProtocolRelativeConfirms() {
        // No scheme → siteOrigin nil.
        XCTAssertEqual(policy("//evil.com/a.png"), .confirm)
    }

    func testRelativePathConfirms() {
        // Defense in depth: the parser never mints an .image for this, but the gate
        // must not depend on that.
        XCTAssertEqual(policy("/media/a.png"), .confirm)
    }

    func testHostlessSchemesConfirm() {
        for string in ["data:image/png;base64,AAAA", "mailto:a@b.com", "javascript:alert(1)", "file:///a.png"] {
            XCTAssertEqual(policy(string), .confirm, "\(string) must confirm")
        }
    }

    func testEmptyServerOriginNeverAllows() {
        // An unknown server must fail closed — nil == nil must never read as a match.
        XCTAssertEqual(policy("https://docs.example.org/media/a.png", serverOrigin: ""), .confirm)
        XCTAssertEqual(policy("file:///a.png", serverOrigin: ""), .confirm)
    }
}
