import XCTest

@testable import Schrift

// Cookie fixtures use obviously fake values; no test prints cookie values.
@MainActor
final class SessionStoreIdentitySideEffectsTests: SessionStoreTestCase {
    func testImageCacheNamespaceSurvivesRelaunchButRotatesAtCookieHandoverAndSignIn() throws {
        let keychain = FakeKeychainStore()
        let cookies = FakeCookieStorage()
        let first = SessionStore(userDefaults: userDefaults, keychain: keychain, cookieStorage: cookies)
        XCTAssertNil(first.imageCacheSessionID)
        try first.signIn(serverURL: serverURL)
        let initial = try XCTUnwrap(first.imageCacheSessionID)
        let cold = SessionStore(userDefaults: userDefaults, keychain: keychain, cookieStorage: cookies)
        XCTAssertEqual(cold.imageCacheSessionID, initial)
        first.noteSessionExpired()
        first.cancelReauthentication()
        XCTAssertEqual(first.imageCacheSessionID, initial)
        first.noteSessionCookiesReplaced()
        XCTAssertNotEqual(first.imageCacheSessionID, initial)
        let handedOver = first.imageCacheSessionID
        try first.signIn(serverURL: serverURL)
        XCTAssertNotEqual(first.imageCacheSessionID, handedOver)
        try first.signOut()
        XCTAssertNil(first.imageCacheSessionID)
    }

    /// Sign-in is the moment a possibly-different account takes over, and the cached profile
    /// is shown *before* any fetch — so a kept entry would put the previous user's name and
    /// email on the new user's Profile screen, indefinitely if they are offline.
    func testSignInForgetsThePreviousAccountsCachedProfile() throws {
        let cache = CurrentUserCacheStore(userDefaults: userDefaults)
        cache.remember(
            CurrentUser(id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, email: "ada@example.org"))
        let store = SessionStore(
            userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: FakeCookieStorage())

        try store.signIn(serverURL: serverURL)

        XCTAssertNil(cache.user)
    }

    /// Unlike pending-create records — which survive because they may be the only copy of a
    /// document — this is re-fetchable server data about the session that just ended.
    func testSignOutForgetsTheCachedProfile() throws {
        let cache = CurrentUserCacheStore(userDefaults: userDefaults)
        let store = SessionStore(
            userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: FakeCookieStorage())
        try store.signIn(serverURL: serverURL)
        cache.remember(
            CurrentUser(id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, email: "ada@example.org"))

        try store.signOut()

        XCTAssertNil(cache.user)
    }

    /// The twin of `testExpiringASessionKeepsTheAccountId`, and the same contract: a dismissed
    /// re-login sheet keeps showing what it already showed, so a transient 401 must not empty
    /// the account row.
    func testExpiringASessionKeepsTheCachedProfile() throws {
        let cache = CurrentUserCacheStore(userDefaults: userDefaults)
        let store = SessionStore(
            userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: FakeCookieStorage())
        try store.signIn(serverURL: serverURL)
        cache.remember(
            CurrentUser(id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, email: "ada@example.org"))

        store.noteSessionExpired()

        XCTAssertEqual(cache.user?.email, "ada@example.org")
    }

    /// Clearing the store is only half of session-scoping the account row: `ProfileViewModel`
    /// is `@State` in `MainTabView`, which survives a re-login, so its in-memory copy needs a
    /// reason to be re-read. This counter is that reason — `ProfileScreen` keys its `.task` on
    /// it, so answering the sheet as a different account re-runs `load()` instead of leaving
    /// the previous account's email on screen until the user happens to switch tabs.
    func testSignInAdvancesTheSignInGenerationSoOpenScreensReload() throws {
        let store = SessionStore(
            userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: FakeCookieStorage())
        let before = store.signInGeneration

        try store.signIn(serverURL: serverURL)

        XCTAssertEqual(store.signInGeneration, before + 1)
    }

    /// It marks a *change of session*, not a failure of one — a dismissed sheet must not
    /// re-run every screen's load.
    func testExpiringASessionDoesNotAdvanceTheSignInGeneration() throws {
        let store = SessionStore(
            userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: FakeCookieStorage())
        try store.signIn(serverURL: serverURL)
        let afterSignIn = store.signInGeneration

        store.noteSessionExpired()
        store.cancelReauthentication()

        XCTAssertEqual(store.signInGeneration, afterSignIn)
    }

    /// The stale-account disclosure. Signing in — which a completed re-login sheet also does
    /// — is the moment a possibly-different account takes over, so a kept id would list the
    /// previous user's unsynced documents to the new one, who could type into them, with the
    /// edits eventually POSTed into the first user's account.
    func testSigningInForgetsWhoWasSignedInBefore() throws {
        let signedIn = SignedInUserStore(userDefaults: userDefaults)
        signedIn.remember(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
        let store = SessionStore(
            userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: FakeCookieStorage())

        try store.signIn(serverURL: URL(string: "https://docs.example.org")!)

        XCTAssertNil(signedIn.userID, "fails closed until the server says whose session this is")
    }

    /// And a mere expiry does **not** clear it: the user may simply have hit a transient 401,
    /// or dismissed the sheet — whose contract is that cached data keeps showing. Emptying
    /// their local section there would be silent collateral with no safety gain, since the
    /// account has not changed until someone signs in.
    func testExpiringASessionKeepsTheAccountId() throws {
        let signedIn = SignedInUserStore(userDefaults: userDefaults)
        let store = SessionStore(
            userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: FakeCookieStorage())
        try store.signIn(serverURL: URL(string: "https://docs.example.org")!)
        signedIn.remember(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)

        store.noteSessionExpired()

        XCTAssertNotNil(signedIn.userID)
    }

    func testSigningOutForgetsTheAccountId() throws {
        let signedIn = SignedInUserStore(userDefaults: userDefaults)
        let store = SessionStore(
            userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: FakeCookieStorage())
        try store.signIn(serverURL: URL(string: "https://docs.example.org")!)
        signedIn.remember(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)

        try store.signOut()

        XCTAssertNil(signedIn.userID)
    }

    /// The window `signIn` alone cannot close. `WebLoginView` syncs the freshly authenticated
    /// cookies into the shared storage *before* anything confirms them, so by the time a login
    /// sheet reports back the session may already belong to somebody else — while `signIn`, the
    /// only thing that forgets the previous account, runs solely if the confirming `/users/me/`
    /// succeeds. A blip on that one request therefore left B's cookies live under A's identity.
    func testCookiesHandedOverByALoginForgetTheAccountTheyReplaced() throws {
        let signedIn = SignedInUserStore(userDefaults: userDefaults)
        let cache = CurrentUserCacheStore(userDefaults: userDefaults)
        let store = SessionStore(
            userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: FakeCookieStorage())
        try store.signIn(serverURL: serverURL)
        signedIn.remember(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
        cache.remember(
            CurrentUser(id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, email: "ada@example.org"))

        store.noteSessionCookiesReplaced()

        XCTAssertNil(signedIn.userID, "fails closed until the server says whose session this is")
        XCTAssertNil(cache.user, "the previous account's name and email must not outlive its cookies")
    }

    /// Forgetting the value is half of it — `ProfileViewModel` is `@State` in `MainTabView`,
    /// which the sheet is presented *over*, so its in-memory copy needs a reason to re-read.
    /// Without the bump the row keeps showing the previous account from memory even though the
    /// store behind it is empty.
    func testCookiesHandedOverByALoginAdvanceTheSignInGenerationSoOpenScreensReload() throws {
        let store = SessionStore(
            userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: FakeCookieStorage())
        try store.signIn(serverURL: serverURL)
        let afterSignIn = store.signInGeneration

        store.noteSessionCookiesReplaced()

        XCTAssertEqual(store.signInGeneration, afterSignIn + 1)
    }
}
