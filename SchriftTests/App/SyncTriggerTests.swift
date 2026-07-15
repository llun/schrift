import SwiftUI
import XCTest

@testable import Schrift

final class SyncTriggerTests: XCTestCase {
    func testReachabilityTriggerFiresOnlyOnTheReconnectEdge() {
        XCTAssertTrue(shouldSyncOnReachabilityChange(wasReachable: false, isReachable: true))
        XCTAssertFalse(shouldSyncOnReachabilityChange(wasReachable: true, isReachable: false), "disconnect")
        XCTAssertFalse(shouldSyncOnReachabilityChange(wasReachable: true, isReachable: true), "still reachable")
        XCTAssertFalse(shouldSyncOnReachabilityChange(wasReachable: false, isReachable: false), "still offline")
    }

    func testScenePhaseTriggerFiresOnlyOnActive() {
        XCTAssertTrue(shouldSyncOnScenePhase(.active))
        XCTAssertFalse(shouldSyncOnScenePhase(.inactive))
        XCTAssertFalse(shouldSyncOnScenePhase(.background))
    }

    func testCollaborationScenePhaseActionIgnoresTransientInactive() {
        // Only a real background closes sockets; `.inactive` is a transient blip
        // and must not tear down + rebuild every live socket.
        XCTAssertEqual(collaborationScenePhaseAction(.active), .resume)
        XCTAssertEqual(collaborationScenePhaseAction(.background), .suspend)
        XCTAssertEqual(collaborationScenePhaseAction(.inactive), .ignore)
    }
}
