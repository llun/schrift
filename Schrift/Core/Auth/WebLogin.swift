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

/// The latest wipe of the login web view's store, until it finishes: a sign-in started right
/// after a sign-out waits for it, so the old IdP session cannot answer that login.
@MainActor private(set) var pendingWebLoginDataClear: Task<Void, Never>?

@MainActor
func clearWebLoginSiteData(includingCookies: Bool) {
    let types = webLoginSiteDataTypes(includingCookies: includingCookies)
    let previous = pendingWebLoginDataClear
    let clear = Task { @MainActor in
        await previous?.value
        await WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast)
    }
    pendingWebLoginDataClear = clear
    Task { @MainActor in
        await clear.value
        if pendingWebLoginDataClear == clear { pendingWebLoginDataClear = nil }
    }
}
