import XCTest
@testable import DocsIOS

final class SessionStoreTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private let suiteName = "dev.llun.DocsIOS.tests.SessionStoreTests"

    override func setUp() {
        super.setUp()
        userDefaults = UserDefaults(suiteName: suiteName)
        userDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testStartsUnauthenticatedWithNoServerURLWhenStorageEmpty() {
        let store = SessionStore(userDefaults: userDefaults, keychain: FakeKeychainStore())
        XCTAssertNil(store.serverURL)
        XCTAssertFalse(store.isAuthenticated)
    }

    func testSignInPersistsServerURLAndAuthenticatedFlag() throws {
        let store = SessionStore(userDefaults: userDefaults, keychain: FakeKeychainStore())
        let url = URL(string: "https://docs.llun.dev")!
        try store.signIn(serverURL: url)
        XCTAssertEqual(store.serverURL, url)
        XCTAssertTrue(store.isAuthenticated)
    }

    func testSignOutClearsAuthenticatedFlagButKeepsServerURL() throws {
        let store = SessionStore(userDefaults: userDefaults, keychain: FakeKeychainStore())
        let url = URL(string: "https://docs.llun.dev")!
        try store.signIn(serverURL: url)
        try store.signOut()
        XCTAssertFalse(store.isAuthenticated)
        XCTAssertEqual(store.serverURL, url)
    }

    func testStateReloadsFromStorageOnFreshInit() throws {
        let keychain = FakeKeychainStore()
        let url = URL(string: "https://docs.llun.dev")!
        let first = SessionStore(userDefaults: userDefaults, keychain: keychain)
        try first.signIn(serverURL: url)

        let second = SessionStore(userDefaults: userDefaults, keychain: keychain)
        XCTAssertEqual(second.serverURL, url)
        XCTAssertTrue(second.isAuthenticated)
    }
}
