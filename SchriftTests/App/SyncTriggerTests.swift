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
}
