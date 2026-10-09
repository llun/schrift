import XCTest

@testable import Schrift

// Cookie fixtures use obviously fake values; no test prints cookie values.
/// Shared storage, fixtures and cookie builders for the `SessionStore…Tests` classes. Holds no tests.
@MainActor
class SessionStoreTestCase: XCTestCase {
    var userDefaults: UserDefaults!
    let suiteName = "dev.llun.Schrift.tests.SessionStoreTests.\(UUID().uuidString)"
    let cookiesKeychainKey = "dev.llun.Schrift.sessionCookies"
    let serverURL = URL(string: "https://docs.llun.dev")!

    override func setUp() {
        super.setUp()
        userDefaults = UserDefaults(suiteName: suiteName)
        userDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func makeCookie(name: String = "docs_sessionid", value: String = "fake-session-value") -> HTTPCookie {
        HTTPCookie(properties: [
            .domain: "docs.llun.dev", .path: "/", .name: name, .value: value,
        ])!
    }

    func makeIdPCookie(name: String = "idp_session", value: String = "fake-idp-value") -> HTTPCookie {
        HTTPCookie(properties: [
            .domain: "idp.example.org", .path: "/", .name: name, .value: value,
        ])!
    }
}
