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

    // MARK: - Native live gate (PR09a)

    func testNativeLiveNeedsAllFourInputs() {
        XCTAssertTrue(
            nativeLiveCollaborationEligible(
                nativeEnabled: true, liveEnabled: true, serverSupports: true, canUpdate: true))
        for missing in 0..<4 {
            var inputs = [true, true, true, true]
            inputs[missing] = false
            XCTAssertFalse(
                nativeLiveCollaborationEligible(
                    nativeEnabled: inputs[0], liveEnabled: inputs[1], serverSupports: inputs[2], canUpdate: inputs[3]),
                "input \(missing) is required")
        }
    }

    func testNativeServerCapabilityIsADocs6SocketOnly() {
        XCTAssertTrue(
            ServerConfig(releaseVersion: "6.0.0", collaborationWsUrl: "wss://a.example/collaboration/ws/")
                .supportsNativeLiveCollaboration)
        XCTAssertFalse(ServerConfig(releaseVersion: "6.0.0").supportsNativeLiveCollaboration)
        XCTAssertFalse(
            ServerConfig(releaseVersion: "4.8.0", collaborationWsUrl: "wss://a.example/collaboration/ws/")
                .supportsNativeLiveCollaboration, "native typing is Docs 6 only")
    }
}
