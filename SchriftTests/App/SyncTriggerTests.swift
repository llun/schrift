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

    /// A handover's cookies are not confirmed yet, so the page is read-only: every classic socket
    /// closes rather than staying writable under the previous account. A confirmed account change
    /// closes the sessions opened for another; the same account keeps its own.
    func testCollaborationSignInActionClosesOnAHandoverAndOnAConfirmedAccountChange() {
        let account = UUID()
        XCTAssertEqual(
            collaborationSignInAction(isAwaitingConfirmation: true, account: nil), .closeAll,
            "a handover's cookies are not confirmed yet")
        XCTAssertEqual(
            collaborationSignInAction(isAwaitingConfirmation: true, account: account), .closeAll,
            "the account it names is not confirmed either")
        XCTAssertEqual(
            collaborationSignInAction(isAwaitingConfirmation: false, account: account), .closeOthers(account),
            "the same account keeps its sessions; another account's go")
        XCTAssertEqual(
            collaborationSignInAction(isAwaitingConfirmation: false, account: nil), .closeAll,
            "a confirmation that named nobody proves nothing about the open sessions")
    }
}
