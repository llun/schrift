import Foundation
import WebKit

func authenticationURL(server: URL) -> URL {
    server.appendingPathComponent("api/v1.0/authenticate/")
}

/// Hostnames are case-insensitive, and WebKit always reports `url.host` lowercased. An
/// exact `==` against a `serverHost` carrying the capital iOS autocapitalization put there
/// (`Notes.liiib.re`) never matched, so login never completed and the sheet stayed open on
/// the already-signed-in web app. `normalizedServerURL` lowercases the host now; comparing
/// case-insensitively here keeps a `serverHost` from any other source correct too. This
/// remains an **exact** host match — never a suffix or substring one.
func isLoginNavigationComplete(url: URL, serverHost: String, apiPathPrefix: String = "/api/v1.0/") -> Bool {
    guard let host = url.host, host.caseInsensitiveCompare(serverHost) == .orderedSame else { return false }
    return !url.path.hasPrefix(apiPathPrefix)
}

protocol CookieStoring {
    func setCookie(_ cookie: HTTPCookie)
    func cookies(for url: URL) -> [HTTPCookie]?
    func deleteCookie(_ cookie: HTTPCookie)
}

extension HTTPCookieStorage: CookieStoring {}

func syncCookies(_ cookies: [HTTPCookie], into storage: CookieStoring) {
    for cookie in cookies {
        storage.setCookie(cookie)
    }
}

/// The login web view's own HTTP cache (`WKWebsiteDataStore.default()`) can hold pages it
/// loaded for the account that just left. Cookies stay: the IdP's single sign-on lives there.
@MainActor
func clearWebLoginCache() {
    WKWebsiteDataStore.default().removeData(
        ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache], modifiedSince: .distantPast
    ) {}
}
