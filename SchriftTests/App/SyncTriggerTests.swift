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

    /// A silent re-login of the same account happens routinely at launch; closing its live
    /// sessions there would drop a mounted socket. Only a confirmed account change closes.
    func testCollaborationSignInActionClosesOnlyOnAConfirmedAccountChange() {
        let account = UUID()
        XCTAssertEqual(
            collaborationSignInAction(isAwaitingConfirmation: true, account: nil), .none,
            "a handover's cookies are not confirmed yet")
        XCTAssertEqual(
            collaborationSignInAction(isAwaitingConfirmation: true, account: account), .none,
            "the account it names decides, not the handover")
        XCTAssertEqual(
            collaborationSignInAction(isAwaitingConfirmation: false, account: account), .closeOthers(account),
            "the same account keeps its sessions; another account's go")
        XCTAssertEqual(
            collaborationSignInAction(isAwaitingConfirmation: false, account: nil), .closeAll,
            "a confirmation that named nobody proves nothing about the open sessions")
    }
}
