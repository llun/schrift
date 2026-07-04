import Foundation

/// Keychain-persistable snapshot of an `HTTPCookie` (`HTTPCookie` itself is not
/// Codable). `expiresDate == nil` means a session-only cookie (e.g. Django's
/// `sessionid` under `SESSION_EXPIRE_AT_BROWSER_CLOSE`) — exactly the kind
/// `HTTPCookieStorage.shared` drops when iOS terminates the process, and the
/// reason this type exists: the app snapshots the server's cookies into the
/// Keychain at sign-in and restores them on launch so the session survives.
///
/// Instances carry the live session credential in `value`. NEVER log, print,
/// or serialize them anywhere other than the Keychain.
struct StoredCookie: Codable, Equatable, Sendable {
    let name: String
    let value: String
    let domain: String
    let path: String
    /// nil = session-only cookie (no server-set expiry).
    let expiresDate: Date?
    let isSecure: Bool
    let isHTTPOnly: Bool
    /// `HTTPCookieStringPolicy.rawValue`, when the server set SameSite.
    let sameSitePolicy: String?

    init(_ cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain
        path = cookie.path
        expiresDate = cookie.expiresDate
        isSecure = cookie.isSecure
        isHTTPOnly = cookie.isHTTPOnly
        sameSitePolicy = cookie.sameSitePolicy?.rawValue
    }

    /// Reconstructs the cookie via `HTTPCookie(properties:)`. Omitting
    /// `.expires` yields a session-only cookie again; `.secure` and the raw
    /// "HttpOnly" key (there is no public `HTTPCookiePropertyKey.httpOnly`)
    /// take the "TRUE" string form the initializer expects. Returns nil only
    /// for malformed data.
    var httpCookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
        ]
        if let expiresDate {
            properties[.expires] = expiresDate
        }
        if isSecure {
            properties[.secure] = "TRUE"
        }
        if isHTTPOnly {
            properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
        }
        if let sameSitePolicy {
            properties[.sameSitePolicy] = sameSitePolicy
        }
        return HTTPCookie(properties: properties)
    }
}

/// Drops cookies already expired at `now`. Session-only cookies (nil
/// `expiresDate`) are kept — their lifetime is the server session's, not the
/// device clock's. Restoring an expired cookie would be a no-op the cookie
/// storage performs anyway, but filtering keeps the restored set honest.
func validStoredCookies(_ cookies: [StoredCookie], now: Date = Date()) -> [StoredCookie] {
    cookies.filter { cookie in
        guard let expiresDate = cookie.expiresDate else { return true }
        return expiresDate > now
    }
}
