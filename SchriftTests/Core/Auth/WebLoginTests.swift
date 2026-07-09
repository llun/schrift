import XCTest

@testable import Schrift

final class WebLoginTests: XCTestCase {
    func testAuthenticationURLAppendsAuthenticatePath() {
        let server = URL(string: "https://docs.llun.dev")!
        XCTAssertEqual(authenticationURL(server: server).absoluteString, "https://docs.llun.dev/api/v1.0/authenticate/")
    }

    func testAuthenticationURLHandlesTrailingSlashOnServer() {
        let server = URL(string: "https://docs.llun.dev/")!
        XCTAssertEqual(authenticationURL(server: server).absoluteString, "https://docs.llun.dev/api/v1.0/authenticate/")
    }

    func testInitialAuthenticateNavigationIsNotComplete() {
        let url = URL(string: "https://docs.llun.dev/api/v1.0/authenticate/")!
        XCTAssertFalse(isLoginNavigationComplete(url: url, serverHost: "docs.llun.dev"))
    }

    func testExternalIdentityProviderNavigationIsNotComplete() {
        let url = URL(string: "https://idp.example.com/login?client_id=docs")!
        XCTAssertFalse(isLoginNavigationComplete(url: url, serverHost: "docs.llun.dev"))
    }

    func testCallbackNavigationIsNotComplete() {
        let url = URL(string: "https://docs.llun.dev/api/v1.0/callback/?code=abc&state=xyz")!
        XCTAssertFalse(isLoginNavigationComplete(url: url, serverHost: "docs.llun.dev"))
    }

    func testLandingOnSiteRootAfterLoginIsComplete() {
        let url = URL(string: "https://docs.llun.dev/")!
        XCTAssertTrue(isLoginNavigationComplete(url: url, serverHost: "docs.llun.dev"))
    }

    func testLandingOnAnySPARouteOnServerHostIsComplete() {
        let url = URL(string: "https://docs.llun.dev/some/spa/route")!
        XCTAssertTrue(isLoginNavigationComplete(url: url, serverHost: "docs.llun.dev"))
    }

    func testLandingOnBareServerRootWithoutTrailingSlashIsComplete() {
        // The docs backend's default LOGIN_REDIRECT_URL is the bare host
        // (`https://${DOCS_HOST}`) with no trailing slash, whose `path` is "".
        let url = URL(string: "https://docs.llun.dev")!
        XCTAssertTrue(isLoginNavigationComplete(url: url, serverHost: "docs.llun.dev"))
    }

    func testSyncCookiesForwardsEachCookieToStorage() {
        let sessionCookie = HTTPCookie(properties: [
            .domain: "docs.llun.dev", .path: "/", .name: "docs_sessionid", .value: "abc",
        ])!
        let csrfCookie = HTTPCookie(properties: [
            .domain: "docs.llun.dev", .path: "/", .name: "csrftoken", .value: "xyz",
        ])!
        let fake = FakeCookieStorage()

        syncCookies([sessionCookie, csrfCookie], into: fake)

        XCTAssertEqual(fake.storedCookies.count, 2)
        XCTAssertEqual(Set(fake.storedCookies.map(\.name)), Set(["docs_sessionid", "csrftoken"]))
    }

    func testSyncCookiesWithEmptyArrayDoesNothing() {
        let fake = FakeCookieStorage()
        syncCookies([], into: fake)
        XCTAssertTrue(fake.storedCookies.isEmpty)
    }

    // MARK: - Host comparison is case-insensitive

    /// WebKit reports `url.host` lowercased. A `serverHost` carrying the capital that iOS
    /// autocapitalization put there (`Notes.liiib.re`) never matched, so the login sheet
    /// stayed open on the signed-in web app forever. Hostnames are case-insensitive;
    /// `normalizedServerURL` now lowercases them, and this keeps the comparison correct
    /// even for a `serverHost` that came from somewhere else.
    func testLoginCompletesWhenServerHostDiffersOnlyByCase() {
        let url = URL(string: "https://notes.liiib.re/")!

        XCTAssertTrue(isLoginNavigationComplete(url: url, serverHost: "Notes.liiib.re"))
        XCTAssertTrue(isLoginNavigationComplete(url: url, serverHost: "NOTES.LIIIB.RE"))
    }

    /// Case-insensitivity must not become substring- or suffix-matching.
    func testLoginStillRejectsADifferentHost() {
        let url = URL(string: "https://evil.example.org/")!

        XCTAssertFalse(isLoginNavigationComplete(url: url, serverHost: "notes.liiib.re"))
        XCTAssertFalse(
            isLoginNavigationComplete(
                url: URL(string: "https://notes.liiib.re.evil.org/")!,
                serverHost: "notes.liiib.re"))
    }

    /// The API-path exclusion must survive the case change: the callback hop is not "done".
    func testAPIPathIsStillNotComplete() {
        let callback = URL(string: "https://notes.liiib.re/api/v1.0/callback/?code=abc")!

        XCTAssertFalse(isLoginNavigationComplete(url: callback, serverHost: "Notes.liiib.re"))
    }
}
