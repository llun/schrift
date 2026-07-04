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
