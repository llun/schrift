import XCTest

@testable import Schrift

/// The live-collaboration gating chain, in the order the roadmap fixes:
/// feature toggle → offline → server support → per-session "proven unavailable".
final class LiveCollaborationAvailabilityTests: XCTestCase {
    private func availability(
        feature: Bool = true, offline: Bool = false, server: Bool = true, proven: Bool = false
    ) -> LiveCollaborationAvailability {
        liveCollaborationAvailability(
            featureEnabled: feature, isOffline: offline, serverSupports: server, provenUnavailable: proven)
    }

    func testAllGatesPassIsAvailable() {
        XCTAssertEqual(availability(), .available)
    }

    func testFeatureDisabledIsOutermostGate() {
        // Even fully online with a supporting server, the toggle wins.
        XCTAssertEqual(availability(feature: false, offline: true, server: false, proven: true), .featureDisabled)
    }

    func testOfflineOutranksServerSupport() {
        XCTAssertEqual(availability(offline: true, server: true), .offline)
    }

    func testNoServerSupportIsUnavailable() {
        XCTAssertEqual(availability(server: false), .serverUnavailable)
    }

    func testProvenUnavailableIsUnavailableEvenWhenServerSupports() {
        XCTAssertEqual(availability(server: true, proven: true), .serverUnavailable)
    }
}
