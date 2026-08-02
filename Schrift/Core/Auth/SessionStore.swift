import Foundation

/// Persists the signed-in state across launches: the chosen server URL
/// (UserDefaults), an authenticated flag, and — because the Django `sessionid`
/// is a session-only cookie that `HTTPCookieStorage` drops when iOS terminates
/// the process — a Keychain snapshot of the server's cookies, restored into the
/// shared cookie storage on init so the session survives an app kill.
@MainActor
@Observable
final class SessionStore {
    private static let serverURLKey = "dev.llun.Schrift.serverURL"
    private static let authenticatedKeychainKey = "dev.llun.Schrift.isAuthenticated"
    private static let sessionCookiesKeychainKey = "dev.llun.Schrift.sessionCookies"

    private let userDefaults: UserDefaults
    private let keychain: KeychainStoring
    private let cookieStorage: CookieStoring
    /// Cleared the moment a session is known to be over — see `noteSessionExpired`.
    private let signedInUser: SignedInUserStore

    private(set) var serverURL: URL?
    private(set) var isAuthenticated: Bool
    /// A request hit a real 401 while signed in — the server session is dead
    /// and the user must re-authenticate. Observable (RootView presents the
    /// re-login sheet from it) but never persisted: a fresh launch re-derives
    /// it from the first failing request.
    private(set) var needsReauthentication = false

    init(
        userDefaults: UserDefaults = .standard,
        keychain: KeychainStoring = KeychainStore(),
        cookieStorage: CookieStoring = HTTPCookieStorage.shared,
        signedInUser: SignedInUserStore? = nil
    ) {
        self.userDefaults = userDefaults
        self.keychain = keychain
        self.cookieStorage = cookieStorage
        // Defaults to the same `userDefaults` this store was given, so a test that isolates
        // one isolates both.
        self.signedInUser = signedInUser ?? SignedInUserStore(userDefaults: userDefaults)
        self.serverURL = userDefaults.url(forKey: Self.serverURLKey)
        self.isAuthenticated = (try? keychain.load(forKey: Self.authenticatedKeychainKey)) != nil
        // Synchronous, so the cookies are back in the shared storage before
        // RootView builds the API client and the first request fires.
        if isAuthenticated {
            // A session stored by a build that predates the ThisDeviceOnly
            // accessibility class would otherwise keep the weaker one for as long
            // as it stays valid — which is indefinitely, since nothing re-saves
            // until sign-out or a 401. Best-effort and idempotent.
            keychain.upgradeAccessibility(forKey: Self.authenticatedKeychainKey)
            keychain.upgradeAccessibility(forKey: Self.sessionCookiesKeychainKey)
            restoreSessionCookies()
        }
    }

    func signIn(serverURL: URL) throws {
        userDefaults.set(serverURL, forKey: Self.serverURLKey)
        try keychain.save(Data([1]), forKey: Self.authenticatedKeychainKey)
        persistSessionCookies(for: serverURL)
        self.serverURL = serverURL
        self.isAuthenticated = true
        // Serves both a fresh login and a completed re-login sheet.
        self.needsReauthentication = false
        // **Forget who was signed in, here rather than at expiry.** This is the moment a
        // possibly-different account takes over the session, which is exactly when a kept id
        // becomes a disclosure: it would list the previous user's unsynced documents to the
        // new one, who could open and type into them — and the record still carries the first
        // user's `ownerUserID`, so those edits would eventually be POSTed into *their*
        // account. Refreshing after re-auth is not enough on its own, because that fetch can
        // fail; nil fails closed, and nothing local is listed until the server says whose
        // session this is.
        //
        // Clearing at `noteSessionExpired` instead would close the same window and also empty
        // the local section for a user who merely hit a transient 401 — or who dismissed the
        // sheet, whose documented contract is that cached data keeps showing — with no
        // message and nothing to re-fetch it until a Profile visit. Same safety, strictly more
        // collateral, so it is done here.
        signedInUser.clear()
    }

    func signOut() throws {
        // Belt-and-braces beside `RootView`'s own clear: a second sign-out path added later
        // should not have to remember this one.
        signedInUser.clear()
        try keychain.delete(forKey: Self.authenticatedKeychainKey)
        try? keychain.delete(forKey: Self.sessionCookiesKeychainKey)
        deleteServerCookies()
        needsReauthentication = false
        isAuthenticated = false
    }

    /// Called (via the API client's `onSessionExpired` hook) whenever any
    /// request 401s. Idempotent, so concurrent 401s from several view models
    /// present the re-login sheet exactly once.
    func noteSessionExpired() {
        guard isAuthenticated else { return }
        needsReauthentication = true
    }

    /// User dismissed the re-login sheet without signing in. Cached data keeps
    /// showing; the next failing request re-raises the flag.
    func cancelReauthentication() {
        needsReauthentication = false
    }

    // MARK: - Session cookie persistence

    /// Snapshots the cookies currently applicable to `serverURL` (the fresh
    /// `sessionid` + `csrftoken` the login web view just synced into the shared
    /// storage; IdP-host cookies stay in WebKit's own store) into the Keychain.
    /// Encoded with a bare JSONEncoder — this is Keychain data, not an API
    /// payload, so the `.docsAPI` decoder's conventions don't apply.
    private func persistSessionCookies(for serverURL: URL) {
        let cookies = (cookieStorage.cookies(for: serverURL) ?? []).map(StoredCookie.init)
        guard let data = try? JSONEncoder().encode(cookies) else { return }
        try? keychain.save(data, forKey: Self.sessionCookiesKeychainKey)
    }

    /// Restores the Keychain cookie snapshot into the cookie storage. Any
    /// failure (missing entry, undecodable data) restores nothing — the first
    /// request then 401s and the normal re-login path takes over.
    private func restoreSessionCookies() {
        guard let data = try? keychain.load(forKey: Self.sessionCookiesKeychainKey),
            let stored = try? JSONDecoder().decode([StoredCookie].self, from: data)
        else { return }
        syncCookies(validStoredCookies(stored).compactMap(\.httpCookie), into: cookieStorage)
    }

    private func deleteServerCookies() {
        guard let serverURL else { return }
        for cookie in cookieStorage.cookies(for: serverURL) ?? [] {
            cookieStorage.deleteCookie(cookie)
        }
    }
}
