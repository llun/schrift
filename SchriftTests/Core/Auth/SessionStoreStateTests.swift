import XCTest

@testable import Schrift

// Cookie fixtures use obviously fake values; no test prints cookie values.
@MainActor
final class SessionStoreStateTests: SessionStoreTestCase {
    func testStartsUnauthenticatedWithNoServerURLWhenStorageEmpty() {
        let store = SessionStore(userDefaults: userDefaults, keychain: FakeKeychainStore())
        XCTAssertNil(store.serverURL)
        XCTAssertFalse(store.isAuthenticated)
    }

    func testSignInPersistsServerURLAndAuthenticatedFlag() throws {
        let store = SessionStore(userDefaults: userDefaults, keychain: FakeKeychainStore())
        try store.signIn(serverURL: serverURL)
        XCTAssertEqual(store.serverURL, serverURL)
        XCTAssertTrue(store.isAuthenticated)
    }

    func testSignOutClearsAuthenticatedFlagButKeepsServerURL() throws {
        let store = SessionStore(userDefaults: userDefaults, keychain: FakeKeychainStore())
        try store.signIn(serverURL: serverURL)
        try store.signOut()
        XCTAssertFalse(store.isAuthenticated)
        XCTAssertEqual(store.serverURL, serverURL)
    }

    func testStateReloadsFromStorageOnFreshInit() throws {
        let keychain = FakeKeychainStore()
        let first = SessionStore(userDefaults: userDefaults, keychain: keychain)
        try first.signIn(serverURL: serverURL)

        let second = SessionStore(userDefaults: userDefaults, keychain: keychain)
        XCTAssertEqual(second.serverURL, serverURL)
        XCTAssertTrue(second.isAuthenticated)
    }

    func testAuthenticatedInitMigratesBothKeychainKeysAccessibility() throws {
        // On launch an already-signed-in user's items (written by a build
        // predating the ThisDeviceOnly class) must be migrated — for the auth
        // flag AND the cookie snapshot. Guards against dropping or misplacing
        // either upgrade call, or moving it outside the `isAuthenticated` gate.
        let keychain = FakeKeychainStore()
        let first = SessionStore(userDefaults: userDefaults, keychain: keychain)
        try first.signIn(serverURL: serverURL)

        _ = SessionStore(userDefaults: userDefaults, keychain: keychain)

        XCTAssertEqual(
            Set(keychain.upgradedKeys),
            Set(["dev.llun.Schrift.isAuthenticated", "dev.llun.Schrift.sessionCookies"]))
    }

    func testUnauthenticatedInitMigratesNothing() {
        // Nothing to migrate when signed out — don't touch the Keychain.
        let keychain = FakeKeychainStore()
        _ = SessionStore(userDefaults: userDefaults, keychain: keychain)
        XCTAssertTrue(keychain.upgradedKeys.isEmpty)
    }

    func testNoteSessionExpiredSetsFlagOnlyWhenAuthenticated() throws {
        let store = SessionStore(userDefaults: userDefaults, keychain: FakeKeychainStore())
        store.noteSessionExpired()
        XCTAssertFalse(store.needsReauthentication)

        try store.signIn(serverURL: serverURL)
        store.noteSessionExpired()
        XCTAssertTrue(store.needsReauthentication)
    }

    func testCancelReauthenticationClearsFlag() throws {
        let store = SessionStore(userDefaults: userDefaults, keychain: FakeKeychainStore())
        try store.signIn(serverURL: serverURL)
        store.noteSessionExpired()

        store.cancelReauthentication()

        XCTAssertFalse(store.needsReauthentication)
    }

    func testSignInClearsReauthenticationFlag() throws {
        let store = SessionStore(userDefaults: userDefaults, keychain: FakeKeychainStore())
        try store.signIn(serverURL: serverURL)
        store.noteSessionExpired()

        try store.signIn(serverURL: serverURL)

        XCTAssertFalse(store.needsReauthentication)
    }

    func testSignOutClearsReauthenticationFlag() throws {
        let store = SessionStore(userDefaults: userDefaults, keychain: FakeKeychainStore())
        try store.signIn(serverURL: serverURL)
        store.noteSessionExpired()

        try store.signOut()

        XCTAssertFalse(store.needsReauthentication)
    }

    // MARK: - Silent re-authentication

    private func makeSignedInStore(
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) throws -> SessionStore {
        let store = SessionStore(
            userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: FakeCookieStorage(), now: now)
        try store.signIn(serverURL: serverURL)
        return store
    }

    func testAnExpiryRecoversSilentlyBeforeShowingTheSheet() throws {
        let store = try makeSignedInStore()

        store.noteSessionExpired()

        XCTAssertTrue(store.isSilentlyReauthenticating)
        XCTAssertFalse(store.presentsReauthenticationSheet)
    }

    func testAFurther401DuringASilentAttemptDoesNotRaiseTheSheetOrStartAnotherAttempt() throws {
        let store = try makeSignedInStore()
        store.noteSessionExpired()
        let attempt = store.reauthenticationAttempt

        store.noteSessionExpired()

        XCTAssertTrue(store.isSilentlyReauthenticating)
        XCTAssertFalse(store.presentsReauthenticationSheet)
        XCTAssertEqual(store.reauthenticationAttempt, attempt)
    }

    func testEscalatingASilentAttemptPresentsTheSheet() throws {
        let store = try makeSignedInStore()
        store.noteSessionExpired()

        store.escalateReauthentication(attempt: store.reauthenticationAttempt)

        XCTAssertTrue(store.presentsReauthenticationSheet)
        XCTAssertFalse(store.isSilentlyReauthenticating)
        XCTAssertTrue(store.needsReauthentication)
    }

    /// A late timeout must not re-open a sheet the user already answered or dismissed.
    func testEscalatingWithNoSilentAttemptRunningDoesNothing() throws {
        let store = try makeSignedInStore()

        store.escalateReauthentication(attempt: store.reauthenticationAttempt)
        XCTAssertFalse(store.needsReauthentication)

        store.noteSessionExpired()
        let attempt = store.reauthenticationAttempt
        try store.signIn(serverURL: serverURL)
        store.escalateReauthentication(attempt: attempt)
        XCTAssertFalse(store.needsReauthentication)
        XCTAssertFalse(store.presentsReauthenticationSheet)
    }

    /// A timer left over from an earlier attempt must not escalate the one now running.
    func testAnEarlierAttemptCannotEscalateALaterOne() throws {
        var clock = ContinuousClock.now
        let store = try makeSignedInStore(now: { clock })
        store.noteSessionExpired()
        let first = store.reauthenticationAttempt
        try store.signIn(serverURL: serverURL)
        clock = clock.advanced(by: silentReauthenticationCooldown + .seconds(1))
        store.noteSessionExpired()

        store.escalateReauthentication(attempt: first)

        XCTAssertTrue(store.isSilentlyReauthenticating)
        XCTAssertFalse(store.presentsReauthenticationSheet)
    }

    /// Once a silent attempt has failed, a later expiry (after the user dismissed the sheet)
    /// asks the user directly rather than spinning up a hidden login known not to complete.
    func testAnExpiryAfterAFailedSilentAttemptGoesStraightToTheSheet() throws {
        let store = try makeSignedInStore()
        store.noteSessionExpired()
        store.escalateReauthentication(attempt: store.reauthenticationAttempt)
        store.cancelReauthentication()

        store.noteSessionExpired()

        XCTAssertTrue(store.presentsReauthenticationSheet)
        XCTAssertFalse(store.isSilentlyReauthenticating)
    }

    func testSigningInThroughTheSheetRestoresTheSilentAttempt() throws {
        let store = try makeSignedInStore()
        store.noteSessionExpired()
        store.escalateReauthentication(attempt: store.reauthenticationAttempt)
        try store.signIn(serverURL: serverURL)

        store.noteSessionExpired()

        XCTAssertTrue(store.isSilentlyReauthenticating)
        XCTAssertFalse(store.presentsReauthenticationSheet)
    }

    /// A session refused again right after a silent sign-in would otherwise loop: every 401
    /// starting another hidden login, each one forgetting and re-learning the account.
    func testA401SoonAfterASilentSignInGoesToTheSheet() throws {
        var clock = ContinuousClock.now
        let store = try makeSignedInStore(now: { clock })
        store.noteSessionExpired()
        try store.signIn(serverURL: serverURL)
        clock = clock.advanced(by: silentReauthenticationCooldown - .seconds(1))

        store.noteSessionExpired()

        XCTAssertTrue(store.presentsReauthenticationSheet)
    }

    func testA401LongAfterASilentSignInRecoversSilentlyAgain() throws {
        var clock = ContinuousClock.now
        let store = try makeSignedInStore(now: { clock })
        store.noteSessionExpired()
        try store.signIn(serverURL: serverURL)
        clock = clock.advanced(by: silentReauthenticationCooldown + .seconds(1))

        store.noteSessionExpired()

        XCTAssertTrue(store.isSilentlyReauthenticating)
    }

    /// A request issued before a silent sign-in and refused on the cookies it replaced says
    /// nothing about the new session; it must not raise the sheet the silent attempt avoided.
    func testA401ForARequestIssuedBeforeTheLastSignInIsIgnored() throws {
        var clock = ContinuousClock.now
        let store = try makeSignedInStore(now: { clock })
        let issuedEarlier = clock
        clock = clock.advanced(by: .seconds(1))
        store.noteSessionExpired()
        try store.signIn(serverURL: serverURL)

        store.noteSessionExpired(requestStartedAt: issuedEarlier)

        XCTAssertFalse(store.needsReauthentication)
    }

    func testA401ForARequestIssuedAfterTheLastSignInCounts() throws {
        var clock = ContinuousClock.now
        let store = try makeSignedInStore(now: { clock })
        clock = clock.advanced(by: silentReauthenticationCooldown + .seconds(1))

        store.noteSessionExpired(requestStartedAt: clock)

        XCTAssertTrue(store.isSilentlyReauthenticating)
    }
}
