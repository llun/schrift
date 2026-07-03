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
        final class FakeCookieStoring: CookieStoring {
            private(set) var savedCookies: [HTTPCookie] = []
            func setCookie(_ cookie: HTTPCookie) { savedCookies.append(cookie) }
        }
        let sessionCookie = HTTPCookie(properties: [
            .domain: "docs.llun.dev", .path: "/", .name: "docs_sessionid", .value: "abc",
        ])!
        let csrfCookie = HTTPCookie(properties: [
            .domain: "docs.llun.dev", .path: "/", .name: "csrftoken", .value: "xyz",
        ])!
        let fake = FakeCookieStoring()

        syncCookies([sessionCookie, csrfCookie], into: fake)

        XCTAssertEqual(fake.savedCookies.count, 2)
        XCTAssertEqual(Set(fake.savedCookies.map(\.name)), Set(["docs_sessionid", "csrftoken"]))
    }

    func testSyncCookiesWithEmptyArrayDoesNothing() {
        final class FakeCookieStoring: CookieStoring {
            private(set) var savedCookies: [HTTPCookie] = []
            func setCookie(_ cookie: HTTPCookie) { savedCookies.append(cookie) }
        }
        let fake = FakeCookieStoring()
        syncCookies([], into: fake)
        XCTAssertTrue(fake.savedCookies.isEmpty)
    }
}
