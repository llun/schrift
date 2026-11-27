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
    func removeCookies(since date: Date)
}

extension HTTPCookieStorage: CookieStoring {}

func syncCookies(_ cookies: [HTTPCookie], into storage: CookieStoring) {
    for cookie in cookies {
        storage.setCookie(cookie)
    }
}

/// What `clearWebLoginCache` removes. Never cookies: the IdP's single sign-on lives there.
let webLoginCacheDataTypes: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]

/// The login web view's own HTTP cache (`WKWebsiteDataStore.default()`) holds pages it loaded
/// for whichever account signed in last.
@MainActor
func clearWebLoginCache() {
    WKWebsiteDataStore.default().removeData(ofTypes: webLoginCacheDataTypes, modifiedSince: .distantPast) {}
}

/// Everything the login web view stores: on a sign-out, cookies too (the IdP's single sign-on
/// with them, so the next sign-in asks for a password); on an account change, all but cookies.
@MainActor
func webLoginSiteDataTypes(includingCookies: Bool) -> Set<String> {
    var types = WKWebsiteDataStore.allWebsiteDataTypes()
    if !includingCookies { types.remove(WKWebsiteDataTypeCookies) }
    return types
}

@MainActor
func clearWebLoginSiteData(includingCookies: Bool) {
    WKWebsiteDataStore.default().removeData(
        ofTypes: webLoginSiteDataTypes(includingCookies: includingCookies), modifiedSince: .distantPast
    ) {}
}
