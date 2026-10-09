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
}
