import XCTest

@testable import Schrift

@MainActor
final class ServerSupportGateTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private let suiteName = "dev.llun.Schrift.tests.ServerSupportGateTests"
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

    private func makeGate() -> ServerSupportGate {
        ServerSupportGate(serverOrigin: origin, store: ServerCapabilityStore(userDefaults: userDefaults))
    }

    func testACachedLegacyServerBlocksBeforeAnyFetch() {
        ServerCapabilityStore(userDefaults: userDefaults).record(.legacy, forServerOrigin: origin)

        XCTAssertTrue(makeGate().isBlocked)
    }

    func testAnUnknownServerIsNeverBlocked() {
        XCTAssertFalse(makeGate().isBlocked)
    }

    func testARefreshedDocs6ServerClearsACachedLegacyNotice() async {
        let store = ServerCapabilityStore(userDefaults: userDefaults)
        store.record(.legacy, forServerOrigin: origin)
        let gate = makeGate()

        await gate.refresh { .success(ServerConfig(releaseVersion: "6.0.0")) }

        XCTAssertFalse(gate.isBlocked)
        XCTAssertEqual(store.capability(forServerOrigin: origin), .docs6)
    }

    func testARefreshedLegacyServerRaisesTheNotice() async {
        let gate = makeGate()

        await gate.refresh { .success(ServerConfig(releaseVersion: "5.4.1")) }

        XCTAssertTrue(gate.isBlocked)
        XCTAssertEqual(
            ServerCapabilityStore(userDefaults: userDefaults).capability(forServerOrigin: origin), .legacy)
    }

    func testAnOfflineRefreshLeavesTheCachedAnswerAlone() async {
        ServerCapabilityStore(userDefaults: userDefaults).record(.legacy, forServerOrigin: origin)
        let gate = makeGate()

        await gate.refresh { .failure(URLError(.notConnectedToInternet)) }

        XCTAssertTrue(gate.isBlocked)
    }

    func testAnOfflineRefreshOfAnUnknownServerDoesNotBlock() async {
        let gate = makeGate()

        await gate.refresh { .failure(DocsAPIError.network("offline")) }

        XCTAssertFalse(gate.isBlocked)
        XCTAssertNil(ServerCapabilityStore(userDefaults: userDefaults).capability(forServerOrigin: origin))
    }
}
