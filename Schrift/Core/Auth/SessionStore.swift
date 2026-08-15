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
    /// Cleared when a login hands over its cookies, at sign-in and at sign-out — all three
    /// through `forgetSignedInIdentity`. Deliberately *not* on a mere expiry, and deliberately
    /// not left to `signIn` alone: see `noteSessionCookiesReplaced`.
    private let signedInUser: SignedInUserStore
    /// The Profile screen's offline copy of the account, cleared at exactly the same three
    /// moments and for the same reason: it is *displayed* before any fetch, so a kept entry
    /// would name the previous account on the new one's screen.
    private let cachedUser: CurrentUserCacheStore

    private(set) var serverURL: URL?
    private(set) var isAuthenticated: Bool
    /// A request hit a real 401 while signed in — the server session is dead
    /// and the user must re-authenticate. Observable (RootView presents the
    /// re-login sheet from it) but never persisted: a fresh launch re-derives
    /// it from the first failing request.
    private(set) var needsReauthentication = false
    /// Bumped by `signIn` and by `noteSessionCookiesReplaced` — the two moments the session
    /// underneath a live screen can become a different account's — so a screen already on
    /// display can tell that the session it was
    /// showing has been replaced. Clearing the stores is only half of session-scoping the
    /// account row: `ProfileViewModel` is `@State` in `MainTabView`, which is **not** rebuilt
    /// across a re-login (the sheet is presented over it), so its in-memory user outlives the
    /// account it belongs to and needs a reason to be re-read. `ProfileScreen` keys its `.task`
    /// on this. Deliberately not bumped by an expiry or a cancel — that is a failure of a
    /// session, not a change of one, and the dismissed-sheet contract is that cached data
    /// keeps showing. Never persisted: what matters is only that it *changes* within a
    /// process, and a fresh launch rebuilds every screen anyway.
    private(set) var signInGeneration = 0

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
        self.cachedUser = CurrentUserCacheStore(userDefaults: userDefaults)
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
        forgetSignedInIdentity()
        // Tell screens that survived the sheet to re-read what they are showing.
        signInGeneration += 1
    }

    /// A web login has just handed its cookies to the shared storage — call it *before* the
    /// confirming `/users/me/`, never after.
    ///
    /// `signIn` cannot be the only place the previous account is forgotten, because it runs
    /// only if that confirmation succeeds, while `WebLoginView.captureCookies` syncs the new
    /// session into `HTTPCookieStorage.shared` unconditionally and earlier. A 5xx or a dropped
    /// connection on that single request therefore left the app running **B's session under A's
    /// identity** — and stably so, since B's cookies are valid and nothing 401s again to
    /// re-present the sheet. In that state A's unsynced documents are listed to B (the
    /// disclosure `belongsToSession` exists to prevent), everything B creates or deletes is
    /// stamped `ownerUserID = A` and is then stranded — the replay compares it against a live
    /// `/users/me/`, so it is never sent and, once the id heals, never listed either — and
    /// Profile shows A's name and email inside B's session.
    ///
    /// Binding the clear to the cookie handover instead of to the confirmation makes the
    /// failure mode fail closed: the identity is unknown until the server names it, which is
    /// what every reader already handles (see `SignedInUserStore`). The cost when the *same*
    /// account re-authenticates and the confirm blips is that their local-only documents drop
    /// out of the lists until the next successful `/users/me/`; the records themselves are
    /// protected unconditionally by `isPendingCreate`, so nothing is lost, and it heals on the
    /// next fetch. That is strictly the smaller harm.
    ///
    /// Deliberately *not* called when the sheet is merely opened or cancelled: no cookies
    /// changed hands there, so the "a dismissed sheet keeps showing what it showed" contract —
    /// the same reason this is not done at `noteSessionExpired` — still holds.
    func noteSessionCookiesReplaced() {
        forgetSignedInIdentity()
        // The identity may have changed under screens that survived the sheet, exactly as at
        // `signIn` — clearing the stores is only half of scoping the account row to the session.
        signInGeneration += 1
    }

    /// Everything that answers *whose session is this*, forgotten together. One body, so a
    /// later piece of account-scoped state has one place to be added rather than three.
    private func forgetSignedInIdentity() {
        signedInUser.clear()
        // The account's displayed profile goes with the id, and here rather than at expiry for
        // the same reason: a dismissed re-login sheet must keep showing what it already showed.
        cachedUser.clear()
    }

    func signOut() throws {
        // Belt-and-braces beside `RootView`'s own clear: a second sign-out path added later
        // should not have to remember this one.
        forgetSignedInIdentity()
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
