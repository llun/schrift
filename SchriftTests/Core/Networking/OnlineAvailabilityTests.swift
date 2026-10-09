import XCTest

@testable import Schrift

/// The token is what lets a view model discard a response that crossed an offline/reconnect
/// (or a Work Offline flip), even if availability has returned by the time it lands.
@MainActor
final class OnlineAvailabilityTests: XCTestCase {
    private final class FakePath: @unchecked Sendable {
        var update: (@Sendable (Bool) -> Void)?
    }

    private var suite: String!
    private var defaults: UserDefaults!
    private var path: FakePath!
    private var connectivity: ConnectivityMonitor!
    private var availability: OnlineAvailability!

    override func setUp() {
        super.setUp()
        suite = "OnlineAvailabilityTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        let fake = FakePath()
        path = fake
        connectivity = ConnectivityMonitor(
            monitoring: NetworkPathMonitoring { update in
                fake.update = update
                return {}
            })
        availability = OnlineAvailability(connectivity: connectivity, userDefaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        availability = nil
        connectivity = nil
        super.tearDown()
    }

    private func setWorkOffline(_ value: Bool) {
        defaults.set(value, forKey: "schrift.workOffline")
        availability.preferencesChanged()
    }

    func testAResponseIsPermittedWhenNothingChanged() {
        let token = availability.token

        XCTAssertFalse(availability.isOffline)
        XCTAssertTrue(availability.permitsResponse(for: token))
    }

    func testAResponseIsRefusedWhileThePathIsDown() async {
        let token = availability.token

        path.update?(false)
        await waitUntil { self.availability.isOffline }

        XCTAssertFalse(availability.permitsResponse(for: token))
        XCTAssertFalse(availability.permitsResponse(for: availability.token), "offline refuses even a fresh token")
    }

    func testAResponseThatCrossedADisconnectAndReconnectIsStillRefused() async {
        let stale = availability.token

        path.update?(false)
        await waitUntil { self.availability.isOffline }
        path.update?(true)
        await waitUntil { !self.availability.isOffline }

        XCTAssertFalse(availability.isOffline)
        XCTAssertFalse(availability.permitsResponse(for: stale))
        XCTAssertTrue(availability.permitsResponse(for: availability.token), "issued after reconnecting")
    }

    func testWorkOfflineRefusesResponsesEvenOnALivePath() {
        let token = availability.token

        setWorkOffline(true)

        XCTAssertTrue(availability.isOffline)
        XCTAssertFalse(availability.permitsResponse(for: token))
    }

    func testTurningWorkOfflineOffAgainStillInvalidatesTheOlderToken() {
        let stale = availability.token

        setWorkOffline(true)
        setWorkOffline(false)

        XCTAssertFalse(availability.isOffline)
        XCTAssertFalse(availability.permitsResponse(for: stale))
        XCTAssertTrue(availability.permitsResponse(for: availability.token))
    }

    func testPreferencesChangedWithoutAChangeDoesNotInvalidateTokens() {
        let token = availability.token

        availability.preferencesChanged()
        availability.preferencesChanged()

        XCTAssertEqual(availability.token, token)
        XCTAssertTrue(availability.permitsResponse(for: token))
    }

    func testWorkOfflineIsReadAtTheRequestBoundaryBeforeAnyChangeNotification() {
        // An AppStorage onChange may not have run yet; the stored value must still win.
        let token = availability.token

        defaults.set(true, forKey: "schrift.workOffline")

        XCTAssertTrue(availability.isOffline)
        XCTAssertFalse(availability.permitsResponse(for: token))
    }

    func testWithoutAConnectivityMonitorOnlyThePreferenceMatters() {
        let standalone = OnlineAvailability(connectivity: nil, userDefaults: defaults)
        let onlineToken = standalone.token

        XCTAssertFalse(standalone.isOffline)
        XCTAssertTrue(standalone.permitsResponse(for: onlineToken))

        defaults.set(true, forKey: "schrift.workOffline")

        XCTAssertTrue(standalone.isOffline)
        XCTAssertFalse(standalone.permitsResponse(for: onlineToken))
        XCTAssertFalse(standalone.permitsResponse(for: standalone.token), "offline refuses even a fresh token")

        defaults.set(false, forKey: "schrift.workOffline")

        XCTAssertFalse(standalone.isOffline)
    }
}
