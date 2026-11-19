import XCTest

@testable import Schrift

final class ServerCapabilityStoreTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private let suiteName = "dev.llun.Schrift.tests.ServerCapabilityStoreTests"
    private let origin = "https://docs.example.org"

    override func setUp() {
        super.setUp()
        userDefaults = UserDefaults(suiteName: suiteName)
        userDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testAnUnrecordedServerIsUnknown() {
        XCTAssertNil(ServerCapabilityStore(userDefaults: userDefaults).capability(forServerOrigin: origin))
    }

    func testARecordedCapabilitySurvivesANewStore() {
        ServerCapabilityStore(userDefaults: userDefaults).record(.legacy, forServerOrigin: origin)

        XCTAssertEqual(
            ServerCapabilityStore(userDefaults: userDefaults).capability(forServerOrigin: origin), .legacy)
    }

    func testCapabilitiesAreKeyedByOrigin() {
        let store = ServerCapabilityStore(userDefaults: userDefaults)
        store.record(.docs6, forServerOrigin: "https://a.example.org")
        store.record(.legacy, forServerOrigin: "https://b.example.org")

        XCTAssertEqual(store.capability(forServerOrigin: "https://a.example.org"), .docs6)
        XCTAssertEqual(store.capability(forServerOrigin: "https://b.example.org"), .legacy)
        XCTAssertNil(store.capability(forServerOrigin: "https://c.example.org"))
    }

    func testRecordingAConfigDerivesTheCapability() {
        let store = ServerCapabilityStore(userDefaults: userDefaults)

        store.record(ServerConfig(releaseVersion: "6.0.0"), forServerOrigin: origin)
        XCTAssertEqual(store.capability(forServerOrigin: origin), .docs6)

        store.record(ServerConfig(releaseVersion: "5.4.1"), forServerOrigin: origin)
        XCTAssertEqual(store.capability(forServerOrigin: origin), .legacy)
    }

    func testClearingOneOriginLeavesTheOthers() {
        let store = ServerCapabilityStore(userDefaults: userDefaults)
        store.record(.docs6, forServerOrigin: "https://a.example.org")
        store.record(.legacy, forServerOrigin: "https://b.example.org")

        store.clear(forServerOrigin: "https://b.example.org")

        XCTAssertEqual(store.capability(forServerOrigin: "https://a.example.org"), .docs6)
        XCTAssertNil(store.capability(forServerOrigin: "https://b.example.org"))
    }

    func testAnEmptyOriginIsNeverStored() {
        let store = ServerCapabilityStore(userDefaults: userDefaults)
        store.record(.docs6, forServerOrigin: origin)

        store.record(.legacy, forServerOrigin: "")

        XCTAssertEqual(store.capability(forServerOrigin: origin), .docs6)
        XCTAssertNil(store.capability(forServerOrigin: ""))
    }

    // MARK: - serverCapability(from:)

    func testADecodedConfigProvesItsSide() {
        XCTAssertEqual(serverCapability(from: .success(ServerConfig(releaseVersion: "6.0.0"))), .docs6)
        XCTAssertEqual(serverCapability(from: .success(ServerConfig(releaseVersion: "5.4.1"))), .legacy)
        // A yhub-shaped collaboration URL identifies Docs 6 even when the version is hidden.
        XCTAssertEqual(
            serverCapability(
                from: .success(
                    ServerConfig(collaborationWsUrl: "wss://docs.example.org/collaboration/ws/v1/docs"))),
            .docs6)
    }

    /// A server with no `config/` route cannot be Docs 6 — the collaboration URL that would
    /// prove it comes from config — so a 404 of either kind is an answer, not a failure.
    func testAMissingConfigRouteIsDefinitiveLegacy() {
        XCTAssertEqual(serverCapability(from: .failure(DocsAPIError.routeNotFound)), .legacy)
        XCTAssertEqual(serverCapability(from: .failure(DocsAPIError.notFound)), .legacy)
    }

    /// Everything else proves nothing: reading a failed fetch as legacy would lock a Docs 6
    /// user out of their own server whenever they launch offline.
    func testAFailedFetchProvesNothing() {
        XCTAssertNil(serverCapability(from: .failure(DocsAPIError.network("offline"))))
        XCTAssertNil(serverCapability(from: .failure(DocsAPIError.server(statusCode: 500))))
        XCTAssertNil(serverCapability(from: .failure(DocsAPIError.sessionExpired)))
        XCTAssertNil(serverCapability(from: .failure(URLError(.notConnectedToInternet))))
    }
}
