import Foundation

func authenticationURL(server: URL) -> URL {
    server.appendingPathComponent("api/v1.0/authenticate/")
}

func isLoginNavigationComplete(url: URL, serverHost: String, apiPathPrefix: String = "/api/v1.0/") -> Bool {
    url.host == serverHost && !url.path.hasPrefix(apiPathPrefix)
}

protocol CookieStoring {
    func setCookie(_ cookie: HTTPCookie)
}

extension HTTPCookieStorage: CookieStoring {}

func syncCookies(_ cookies: [HTTPCookie], into storage: CookieStoring) {
    for cookie in cookies {
        storage.setCookie(cookie)
    }
}
