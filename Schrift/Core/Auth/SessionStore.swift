import Foundation

/// Persists the signed-in state across launches: the chosen server URL
/// (UserDefaults), an authenticated flag, and — because the Django `sessionid`
/// is a session-only cookie that `HTTPCookieStorage` drops when iOS terminates
/// the process — a Keychain snapshot of the server's cookies, restored into the
/// shared cookie storage on init so the session survives an app kill.
/// How soon after a silent re-login a further 401 is taken as the fresh session being refused
/// too, and sent to the sheet rather than retried silently.
let silentReauthenticationCooldown: TimeInterval = 60

@MainActor
@Observable
final class SessionStore {
    private static let imageCacheSessionKey = "dev.llun.Schrift.imageCacheSessionID"
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
    private let clearImageCache: () -> Void
    var imageCacheScope: String? { imageCacheSessionID?.uuidString }

    private(set) var serverURL: URL?
    private(set) var isAuthenticated: Bool
    /// A request hit a real 401 while signed in — the server session is dead
    /// and the user must re-authenticate. Observable (RootView presents the
    /// re-login sheet from it) but never persisted: a fresh launch re-derives
    /// it from the first failing request.
    private(set) var needsReauthentication = false
    /// Whether the dead session is being recovered **in front of the user** (the re-login
    /// sheet) rather than silently. A 401 first tries a hidden web login
    /// (`isSilentlyReauthenticating`): the IdP usually still holds its own session in
    /// `WKWebsiteDataStore.default()`, so the OIDC round trip completes with no typing — and
    /// presenting that as a sheet is exactly what made a login popup flash up and vanish on
    /// its own at launch. Only when the silent attempt cannot finish (the IdP wants a password,
    /// a 2FA code, or never answers) does `escalateReauthentication()` turn this on.
    private(set) var isReauthenticationInteractive = false
    /// Set once a silent attempt has failed in this process, so a later 401 — after the user
    /// dismissed the sheet, say — goes straight to the sheet instead of spinning up another
    /// hidden login that is known not to complete. Cleared by `signIn`/`signOut`.
    private var silentReauthenticationExhausted = false
    /// Identifies the current re-authentication attempt; bumped by every `noteSessionExpired`
    /// that starts one. `escalateReauthentication(attempt:)` must name it, so a timer or task
    /// left over from an earlier attempt can never escalate a later one.
    private(set) var reauthenticationAttempt = 0
    /// When a silent re-login last signed the session back in. A further 401 soon after means
    /// the fresh session is being refused anyway (one endpoint rejecting a session `/users/me/`
    /// accepts, say) — retrying silently would loop, each round forgetting and re-learning the
    /// account with nobody in the loop, so that 401 goes to the sheet instead.
    private var lastSilentSignIn: Date?
    /// A web login has put cookies in the shared storage that no confirmation has accepted yet —
    /// possibly another account's. Only `signIn` may persist those, so the background refresh
    /// stays off until it (or `signOut`) runs; `needsReauthentication` alone is not enough,
    /// because cancelling the sheet clears it while those cookies are still live.
    private var cookiesAwaitingConfirmation = false
    private let now: () -> Date
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
    /// An opaque cache namespace, not an account id or credential. Persisted so
    /// image bytes survive offline relaunch; rotated whenever cookies change hands.
    private(set) var imageCacheSessionID: UUID?

    init(
        userDefaults: UserDefaults = .standard,
        keychain: KeychainStoring = KeychainStore(),
        cookieStorage: CookieStoring = HTTPCookieStorage.shared,
        signedInUser: SignedInUserStore? = nil,
        clearImageCache: @escaping () -> Void = { ImageCacheStore().removeAll() },
        now: @escaping () -> Date = Date.init
    ) {
        self.clearImageCache = clearImageCache
        self.now = now
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
            let existing = userDefaults.string(forKey: Self.imageCacheSessionKey).flatMap(UUID.init(uuidString:))
            let namespace = existing ?? UUID()
            imageCacheSessionID = namespace
            // State initializers can run again while SwiftUI constructs a view. A redundant
            // defaults write invalidates AppStorage and can keep the first scene rendering.
            if existing == nil { userDefaults.set(namespace.uuidString, forKey: Self.imageCacheSessionKey) }
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
        // Invalidate the old disk namespace before saving replacement cookies,
        // so an interruption cannot restore new credentials with old images.
        forgetSignedInIdentity()
        let cookiesPersisted = persistSessionCookies(for: serverURL)
        self.serverURL = serverURL
        self.isAuthenticated = true
        // Serves a fresh login, a completed re-login sheet and a completed silent re-login.
        lastSilentSignIn = isSilentlyReauthenticating ? now() : nil
        endReauthentication()
        silentReauthenticationExhausted = false
        cookiesAwaitingConfirmation = false
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
        // Only a namespace paired with the successfully saved cookie snapshot
        // may survive relaunch. A failed handover/Keychain write must not let
        // this account's images display with the previous restored cookies.
        if cookiesPersisted, let imageCacheSessionID {
            userDefaults.set(imageCacheSessionID.uuidString, forKey: Self.imageCacheSessionKey)
        }
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
    /// stamped `ownerUserID = A`, and Profile shows A's name and email inside B's session.
    ///
    /// **A misattributed record is deferred, not defused.** Every replay pass compares it
    /// against a live `/users/me/` rather than against this store, so nothing of B's is ever
    /// sent into *B's* account — but the record matches `belongsToSession` again the moment
    /// **A** signs in on this device, and is then sent under A: B's document POSTed into A's
    /// account, B's queued deletion of A's document actually made. That is the outcome
    /// `belongsToSession` already warns about — "the edit lands in *their* document when they
    /// sign back in".
    ///
    /// Binding the clear to the cookie handover instead of to the confirmation makes the
    /// failure mode fail closed: the identity is unknown until the server names it, which is
    /// what every reader already handles (see `SignedInUserStore`). The cost when the *same*
    /// account re-authenticates and the confirm blips is that their local-only documents drop
    /// out of the lists, and `+` refuses to mint another, until the identity is re-learned —
    /// the records themselves are protected unconditionally by `isPendingCreate`, so nothing
    /// is lost, and `HomeViewModel.refreshSignedInUserIfUnknown` re-asks on the next
    /// pull-to-refresh, reconnect or foreground rather than leaving it to a relaunch. That is
    /// strictly the smaller harm.
    ///
    /// Deliberately *not* called when the sheet is opened, nor when it is cancelled before the
    /// web view completes: no cookies changed hands in either case, so the "a dismissed sheet
    /// keeps showing what it showed" contract — the same reason this is not done at
    /// `noteSessionExpired` — still holds there. It deliberately does **not** hold for a sheet
    /// that *completed* a login and then failed its confirmation: cookies did change hands, so
    /// the cached profile goes with them, and that is the point rather than a side effect.
    func noteSessionCookiesReplaced() {
        cookiesAwaitingConfirmation = true
        forgetSignedInIdentity()
        // The identity may have changed under screens that survived the sheet, exactly as at
        // `signIn` — clearing the stores is only half of scoping the account row to the session.
        signInGeneration += 1
    }

    /// Everything that answers *whose session is this*, forgotten together. One body, so a
    /// later piece of account-scoped state has one place to be added rather than three.
    private func forgetSignedInIdentity() {
        let namespace = UUID()
        imageCacheSessionID = namespace
        // Cookie handover precedes /users/me confirmation. Keep its new
        // namespace memory-only until signIn saves the matching cookies.
        userDefaults.removeObject(forKey: Self.imageCacheSessionKey)
        clearImageCache()
        signedInUser.clear()
        // The account's displayed profile goes with the id — it is *displayed* before any
        // fetch, so a kept entry would name the previous account on the new one's screen.
        // (Why none of this happens at a mere expiry is `signIn`'s comment above: a dismissed
        // re-login sheet must keep showing what it already showed.)
        cachedUser.clear()
    }

    func signOut() throws {
        // Belt-and-braces beside `RootView`'s own clear: a second sign-out path added later
        // should not have to remember this one.
        forgetSignedInIdentity()
        try keychain.delete(forKey: Self.authenticatedKeychainKey)
        try? keychain.delete(forKey: Self.sessionCookiesKeychainKey)
        deleteServerCookies()
        endReauthentication()
        silentReauthenticationExhausted = false
        lastSilentSignIn = nil
        cookiesAwaitingConfirmation = false
        isAuthenticated = false
        imageCacheSessionID = nil
        userDefaults.removeObject(forKey: Self.imageCacheSessionKey)
    }

    /// Called (via the API client's `onSessionExpired` hook) whenever any
    /// request 401s. Idempotent, so concurrent 401s from several view models
    /// present the re-login sheet exactly once.
    ///
    /// An expiry recovers **silently** (see `isReauthenticationInteractive`) unless a silent
    /// attempt has already failed in this process, or one signed in less than
    /// `silentReauthenticationCooldown` ago — then it goes straight to the sheet. A 401 that
    /// lands while a recovery is already under way changes nothing — in particular it never
    /// turns a silent attempt into a sheet.
    func noteSessionExpired() {
        guard isAuthenticated, !needsReauthentication else { return }
        let silentJustSucceeded = lastSilentSignIn.map { now().timeIntervalSince($0) < silentReauthenticationCooldown }
        reauthenticationAttempt += 1
        needsReauthentication = true
        isReauthenticationInteractive = silentReauthenticationExhausted || silentJustSucceeded == true
    }

    /// A hidden web login is recovering the session; RootView mounts it invisibly.
    var isSilentlyReauthenticating: Bool { needsReauthentication && !isReauthenticationInteractive }

    /// The re-login sheet is up. RootView's sheet binding reads this, not `needsReauthentication`.
    var presentsReauthenticationSheet: Bool { needsReauthentication && isReauthenticationInteractive }

    /// The silent attempt could not finish on its own — it stopped on the IdP's login page, its
    /// confirmation failed, or it ran out of time — so ask the user. A no-op unless a silent
    /// attempt is actually running, so a late timeout can neither re-open a sheet the user just
    /// answered nor raise one after a successful silent sign-in.
    func escalateReauthentication(attempt: Int) {
        guard isSilentlyReauthenticating, attempt == reauthenticationAttempt else { return }
        silentReauthenticationExhausted = true
        isReauthenticationInteractive = true
    }

    /// User dismissed the re-login sheet without signing in. Cached data keeps
    /// showing; the next failing request re-raises the flag.
    func cancelReauthentication() {
        endReauthentication()
    }

    private func endReauthentication() {
        needsReauthentication = false
        isReauthenticationInteractive = false
    }

    /// Re-snapshots the server's cookies into the Keychain when they differ from the stored
    /// copy. Called when the app goes to the background — the last moment before iOS may
    /// terminate the process and `HTTPCookieStorage` drops the session-only `sessionid`.
    ///
    /// Without it the snapshot only ever held what the server set at sign-in. Every
    /// `Set-Cookie` the server sent afterwards — a rotated session key, or Django pushing a
    /// session cookie's `Expires` forward as the session is used — lived only in memory, so a
    /// relaunch restored the **sign-in-time** cookie: an expiry long past (`validStoredCookies`
    /// drops it) or a value the server had replaced. The first request then 401'd on a session
    /// that was perfectly alive, and the app had to log in again at every cold launch.
    ///
    /// Skipped while a re-authentication is pending (the cookies on hand are the ones the server
    /// just refused) and while a web login's cookies await confirmation — they may be another
    /// account's, which only `signIn` may persist (it also pairs them with a fresh image-cache
    /// namespace); that state outlives a cancelled sheet. An empty cookie set never overwrites a
    /// stored one.
    func refreshPersistedSessionCookies() {
        guard isAuthenticated, !needsReauthentication, !cookiesAwaitingConfirmation, let serverURL else { return }
        let cookies = (cookieStorage.cookies(for: serverURL) ?? []).map(StoredCookie.init)
        guard !cookies.isEmpty else { return }
        let stored = (try? keychain.load(forKey: Self.sessionCookiesKeychainKey))
            .flatMap { try? JSONDecoder().decode([StoredCookie].self, from: $0) }
        guard stored.map(Set.init) != Set(cookies) else { return }
        _ = persistSessionCookies(for: serverURL)
    }

    // MARK: - Session cookie persistence

    /// Snapshots the cookies currently applicable to `serverURL` (the fresh
    /// `sessionid` + `csrftoken` the login web view just synced into the shared
    /// storage; IdP-host cookies stay in WebKit's own store) into the Keychain.
    /// Encoded with a bare JSONEncoder — this is Keychain data, not an API
    /// payload, so the `.docsAPI` decoder's conventions don't apply.
    private func persistSessionCookies(for serverURL: URL) -> Bool {
        let cookies = (cookieStorage.cookies(for: serverURL) ?? []).map(StoredCookie.init)
        guard let data = try? JSONEncoder().encode(cookies) else { return false }
        do {
            try keychain.save(data, forKey: Self.sessionCookiesKeychainKey)
            return true
        } catch { return false }
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
