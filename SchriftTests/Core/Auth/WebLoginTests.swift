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

    /// The authenticate hop, the IdP, and the API callback are all mid-flow, as is a different host or a
    /// look-alike suffix (case-insensitivity must not become substring- or suffix-matching).
    func testNavigationBeforeTheLoginLandsIsNotComplete() {
        let cases: [(url: String, serverHost: String)] = [
            ("https://docs.llun.dev/api/v1.0/authenticate/", "docs.llun.dev"),
            ("https://idp.example.com/login?client_id=docs", "docs.llun.dev"),
            ("https://docs.llun.dev/api/v1.0/callback/?code=abc&state=xyz", "docs.llun.dev"),
            // The API-path exclusion must survive a case difference in the host.
            ("https://notes.liiib.re/api/v1.0/callback/?code=abc", "Notes.liiib.re"),
            ("https://evil.example.org/", "notes.liiib.re"),
            ("https://notes.liiib.re.evil.org/", "notes.liiib.re"),
        ]
        for testCase in cases {
            XCTAssertFalse(
                isLoginNavigationComplete(url: URL(string: testCase.url)!, serverHost: testCase.serverHost),
                testCase.url)
        }
    }

    /// Landing anywhere non-API on the server host completes the login, including the bare host with no
    /// trailing slash (the docs backend's default `LOGIN_REDIRECT_URL`, whose `path` is ""). WebKit reports
    /// `url.host` lowercased, so a `serverHost` carrying the capital iOS autocapitalization put there
    /// (`Notes.liiib.re`) must still match — it once left the login sheet open on the signed-in web app.
    func testLandingOnTheServerHostCompletesTheLoginRegardlessOfCase() {
        let cases: [(url: String, serverHost: String)] = [
            ("https://docs.llun.dev/", "docs.llun.dev"),
            ("https://docs.llun.dev/some/spa/route", "docs.llun.dev"),
            ("https://docs.llun.dev", "docs.llun.dev"),
            ("https://notes.liiib.re/", "Notes.liiib.re"),
            ("https://notes.liiib.re/", "NOTES.LIIIB.RE"),
        ]
        for testCase in cases {
            XCTAssertTrue(
                isLoginNavigationComplete(url: URL(string: testCase.url)!, serverHost: testCase.serverHost),
                testCase.url)
        }
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
}
