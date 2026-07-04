import Foundation

@testable import Schrift

/// Shared in-memory `CookieStoring` fake: `cookies(for:)` matches by domain
/// suffix the way `HTTPCookieStorage` does (exact host or leading-dot domain),
/// which is enough for the session-cookie persistence tests.
final class FakeCookieStorage: CookieStoring {
    private(set) var storedCookies: [HTTPCookie] = []

    func setCookie(_ cookie: HTTPCookie) {
        storedCookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
        storedCookies.append(cookie)
    }

    func cookies(for url: URL) -> [HTTPCookie]? {
        guard let host = url.host else { return nil }
        let matching = storedCookies.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return host == domain || host.hasSuffix("." + domain)
        }
        return matching.isEmpty ? nil : matching
    }

    func deleteCookie(_ cookie: HTTPCookie) {
        storedCookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
    }
}
