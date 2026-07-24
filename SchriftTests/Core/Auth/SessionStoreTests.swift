import XCTest

@testable import Schrift

// Cookie fixtures use obviously fake values; no test prints cookie values.
@MainActor
final class SessionStoreTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private let suiteName = "dev.llun.Schrift.tests.SessionStoreTests"
    private let cookiesKeychainKey = "dev.llun.Schrift.sessionCookies"
    private let serverURL = URL(string: "https://docs.llun.dev")!

    override func setUp() {
        super.setUp()
        userDefaults = UserDefaults(suiteName: suiteName)
        userDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeCookie(name: String = "docs_sessionid", value: String = "fake-session-value") -> HTTPCookie {
        HTTPCookie(properties: [
            .domain: "docs.llun.dev", .path: "/", .name: name, .value: value,
        ])!
    }

    private func makeIdPCookie(name: String = "idp_session", value: String = "fake-idp-value") -> HTTPCookie {
        HTTPCookie(properties: [
            .domain: "idp.example.org", .path: "/", .name: name, .value: value,
        ])!
    }

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

    // MARK: - Session cookie persistence

    func testSignInSnapshotsServerCookiesIntoKeychain() throws {
        let keychain = FakeKeychainStore()
        let cookieStorage = FakeCookieStorage()
        cookieStorage.setCookie(makeCookie())
        cookieStorage.setCookie(makeCookie(name: "csrftoken", value: "fake-csrf-value"))
        let store = SessionStore(userDefaults: userDefaults, keychain: keychain, cookieStorage: cookieStorage)

        try store.signIn(serverURL: serverURL)

        let data = try XCTUnwrap(try keychain.load(forKey: cookiesKeychainKey))
        let stored = try JSONDecoder().decode([StoredCookie].self, from: data)
        XCTAssertEqual(Set(stored.map(\.name)), Set(["docs_sessionid", "csrftoken"]))
    }

    func testSignInSnapshotsOnlyServerCookiesNotIdPCookies() throws {
        // The snapshot must stay scoped to the chosen server: an IdP-host
        // cookie that happens to sit in the shared storage is a third-party
        // credential and must never enter the Keychain. A regression to
        // "persist all cookies" would leak it and pass every other test.
        let keychain = FakeKeychainStore()
        let cookieStorage = FakeCookieStorage()
        cookieStorage.setCookie(makeCookie())
        cookieStorage.setCookie(makeIdPCookie())
        let store = SessionStore(userDefaults: userDefaults, keychain: keychain, cookieStorage: cookieStorage)

        try store.signIn(serverURL: serverURL)

        let data = try XCTUnwrap(try keychain.load(forKey: cookiesKeychainKey))
        let stored = try JSONDecoder().decode([StoredCookie].self, from: data)
        XCTAssertEqual(stored.map(\.name), ["docs_sessionid"])
        XCTAssertFalse(stored.contains { $0.domain.contains("idp.example.org") })
    }

    func testSignOutDeletesOnlyServerCookiesNotIdPCookies() throws {
        let keychain = FakeKeychainStore()
        let cookieStorage = FakeCookieStorage()
        cookieStorage.setCookie(makeCookie())
        cookieStorage.setCookie(makeIdPCookie())
        let store = SessionStore(userDefaults: userDefaults, keychain: keychain, cookieStorage: cookieStorage)
        try store.signIn(serverURL: serverURL)

        try store.signOut()

        // Only the server's cookie is cleared; the IdP-host cookie is left for
        // WebKit's own store to manage.
        XCTAssertEqual(cookieStorage.storedCookies.map(\.name), ["idp_session"])
    }

    func testInitRestoresPersistedCookiesWhenAuthenticated() throws {
        let keychain = FakeKeychainStore()
        let firstStorage = FakeCookieStorage()
        firstStorage.setCookie(makeCookie())
        let first = SessionStore(userDefaults: userDefaults, keychain: keychain, cookieStorage: firstStorage)
        try first.signIn(serverURL: serverURL)

        // A fresh launch after process death: the cookie storage starts empty.
        let secondStorage = FakeCookieStorage()
        _ = SessionStore(userDefaults: userDefaults, keychain: keychain, cookieStorage: secondStorage)

        XCTAssertEqual(secondStorage.storedCookies.map(\.name), ["docs_sessionid"])
        XCTAssertEqual(secondStorage.storedCookies.first?.value, "fake-session-value")
    }

    /// The two cookies Django actually sets, with the attributes it actually sets them with.
    /// `restoreSessionCookies` rebuilds each through `HTTPCookie(properties:)` and
    /// `compactMap`s the result — a cookie that fails to reconstruct vanishes silently. If
    /// `csrftoken` were the one to vanish, reads would keep working (the session cookie
    /// survives) while every non-GET request 403s with no token attached, which is exactly
    /// the shape of the create-document bug.
    func testRestoreKeepsBothTheSessionCookieAndTheRealisticCSRFCookie() throws {
        let keychain = FakeKeychainStore()
        let firstStorage = FakeCookieStorage()
        // Session-only, HttpOnly, Secure, SameSite=Lax.
        firstStorage.setCookie(
            HTTPCookie(properties: [
                .domain: "docs.llun.dev", .path: "/", .name: "sessionid", .value: "fake-session-value",
                .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE",
                .sameSitePolicy: HTTPCookieStringPolicy.sameSiteLax.rawValue,
            ])!)
        // One-year expiry, Secure, readable by JS (not HttpOnly), SameSite=Lax.
        firstStorage.setCookie(
            HTTPCookie(properties: [
                .domain: "docs.llun.dev", .path: "/", .name: "csrftoken", .value: "fake-csrf-value",
                .secure: "TRUE", .expires: Date().addingTimeInterval(31_449_600),
                .sameSitePolicy: HTTPCookieStringPolicy.sameSiteLax.rawValue,
            ])!)
        let first = SessionStore(userDefaults: userDefaults, keychain: keychain, cookieStorage: firstStorage)
        try first.signIn(serverURL: serverURL)

        // A fresh launch after process death: the cookie storage starts empty.
        let secondStorage = FakeCookieStorage()
        _ = SessionStore(userDefaults: userDefaults, keychain: keychain, cookieStorage: secondStorage)

        let restored = Set(secondStorage.storedCookies.map(\.name))
        XCTAssertTrue(restored.contains("sessionid"), "session cookie lost on restore")
        XCTAssertTrue(restored.contains("csrftoken"), "CSRF cookie lost on restore — every write would 403")
    }

    /// `csrfToken(from:)` is what `performRequest` calls to build the `X-CSRFToken` header,
    /// and it reads the restored jar. Pin the whole chain, not just the cookie names.
    func testRestoredCookiesStillYieldACSRFTokenForTheRequestHeader() throws {
        let keychain = FakeKeychainStore()
        let firstStorage = FakeCookieStorage()
        firstStorage.setCookie(makeCookie())
        firstStorage.setCookie(
            HTTPCookie(properties: [
                .domain: "docs.llun.dev", .path: "/", .name: "csrftoken", .value: "fake-csrf-value",
                .secure: "TRUE", .expires: Date().addingTimeInterval(31_449_600),
                .sameSitePolicy: HTTPCookieStringPolicy.sameSiteLax.rawValue,
            ])!)
        let first = SessionStore(userDefaults: userDefaults, keychain: keychain, cookieStorage: firstStorage)
        try first.signIn(serverURL: serverURL)

        let secondStorage = FakeCookieStorage()
        _ = SessionStore(userDefaults: userDefaults, keychain: keychain, cookieStorage: secondStorage)

        let cookies = try XCTUnwrap(secondStorage.cookies(for: serverURL))
        XCTAssertEqual(csrfToken(from: cookies), "fake-csrf-value")
    }

    /// Django gives `csrftoken` a one-year expiry. If that expiry has passed — or the device
    /// clock runs ahead of it — `validStoredCookies` drops it and every write silently loses
    /// its token, while the session-only `sessionid` sails through and reads keep working.
    func testAnExpiredCSRFCookieIsDroppedWhileTheSessionCookieSurvives() {
        let sessionOnly = StoredCookie(makeCookie())
        let expiredCSRF = StoredCookie(
            HTTPCookie(properties: [
                .domain: "docs.llun.dev", .path: "/", .name: "csrftoken", .value: "fake-csrf-value",
                .expires: Date().addingTimeInterval(-60),
            ])!)

        let valid = validStoredCookies([sessionOnly, expiredCSRF])

        XCTAssertEqual(valid.map(\.name), ["docs_sessionid"])
    }

    func testInitDoesNotRestoreCookiesWhenUnauthenticated() throws {
        let keychain = FakeKeychainStore()
        let cookies = [StoredCookie(makeCookie())]
        try keychain.save(JSONEncoder().encode(cookies), forKey: cookiesKeychainKey)

        let storage = FakeCookieStorage()
        _ = SessionStore(userDefaults: userDefaults, keychain: keychain, cookieStorage: storage)

        XCTAssertTrue(storage.storedCookies.isEmpty)
    }

    func testInitToleratesCorruptedCookieDataInKeychain() throws {
        let keychain = FakeKeychainStore()
        try keychain.save(Data([1]), forKey: "dev.llun.Schrift.isAuthenticated")
        try keychain.save(Data("not json".utf8), forKey: cookiesKeychainKey)

        let storage = FakeCookieStorage()
        let store = SessionStore(userDefaults: userDefaults, keychain: keychain, cookieStorage: storage)

        XCTAssertTrue(store.isAuthenticated)
        XCTAssertTrue(storage.storedCookies.isEmpty)
    }

    func testSignOutDeletesKeychainCookiesAndServerCookies() throws {
        let keychain = FakeKeychainStore()
        let cookieStorage = FakeCookieStorage()
        cookieStorage.setCookie(makeCookie())
        let store = SessionStore(userDefaults: userDefaults, keychain: keychain, cookieStorage: cookieStorage)
        try store.signIn(serverURL: serverURL)

        try store.signOut()

        XCTAssertNil(try keychain.load(forKey: cookiesKeychainKey))
        XCTAssertTrue(cookieStorage.storedCookies.isEmpty)
    }

    // MARK: - Reauthentication flag

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
