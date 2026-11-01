import XCTest

@testable import Schrift

final class EditorToolbarActionsTests: XCTestCase {
    func testEditIsNeverOfferedAlongsideDone() {
        // The two are the same slot in opposite modes; showing both would offer
        // "start editing" during an edit.
        XCTAssertFalse(editorToolbarActions(isEditing: true).contains(.edit))
        XCTAssertFalse(editorToolbarActions(isEditing: false).contains(.done))
    }

    /// There is one system toolbar in both modes, so Done takes Edit's slot and the rest stay put. A local
    /// document (one that exists only on this device) has no share URL and no accesses to list, so Share
    /// would open a sheet over a link nobody else can open; it keeps editing and Options (for Delete).
    ///
    /// Connectivity never removes Edit/Done or Options: offline editing queues through the write-ahead draft
    /// pipeline, so "offline drops Edit" — the old read-only rule — is gone. Offline drops only Share (covered
    /// in `OfflineAvailabilityTests`). Edit's safety on an unloaded document is `startEditing`'s
    /// `hasLoadedContent` guard.
    func testActionsFollowTheModeAndDropShareForALocalDocument() {
        XCTAssertEqual(editorToolbarActions(isEditing: false), [.edit, .share, .options])
        XCTAssertEqual(editorToolbarActions(isEditing: true), [.done, .share, .options])
        XCTAssertEqual(editorToolbarActions(isEditing: false, isLocal: false), [.edit, .share, .options])
        XCTAssertEqual(editorToolbarActions(isEditing: false, isLocal: true), [.edit, .options])
        XCTAssertEqual(editorToolbarActions(isEditing: true, isLocal: true), [.done, .options])
    }

    // MARK: - Presence

    /// Peer state is only ever as fresh as the last socket message, so offline it would be a claim the app
    /// can't stand behind; alone, there is nothing to show.
    func testPresenceShowsThePeerCountOnlyWhenOnlineWithPeers() {
        XCTAssertEqual(presentedPeerCount(peerCount: 1, isOffline: false), 1)
        XCTAssertEqual(presentedPeerCount(peerCount: 4, isOffline: false), 4)
        XCTAssertNil(presentedPeerCount(peerCount: 0, isOffline: false))
        XCTAssertNil(presentedPeerCount(peerCount: 3, isOffline: true))
        XCTAssertNil(presentedPeerCount(peerCount: 0, isOffline: true))
    }
}

// MARK: - Outline hand-off

final class OutlinePresentationGateTests: XCTestCase {
    func testNothingIsHeldWhileTheOutlineIsClosed() {
        let gate = OutlinePresentationGate()
        XCTAssertTrue(gate.releases(true))
        XCTAssertFalse(gate.releases(false))
        XCTAssertEqual(gate.release("link"), "link")
        XCTAssertFalse(gate.closesOutline(hasPendingRequest: true))
    }

    func testARequestMadeWhileTheOutlineIsUpIsHeldAndClosesTheOutline() {
        var gate = OutlinePresentationGate()
        gate.outlineAppeared()
        XCTAssertFalse(gate.releases(true))
        XCTAssertNil(gate.release("link"))
        XCTAssertTrue(gate.closesOutline(hasPendingRequest: true))
        XCTAssertFalse(gate.closesOutline(hasPendingRequest: false))
    }

    func testTheHeldRequestIsReleasedOnceTheOutlineHasDismissed() {
        var gate = OutlinePresentationGate()
        gate.outlineAppeared()
        gate.outlineDismissed()
        // The request itself was never reset, so it presents now with the same value.
        XCTAssertTrue(gate.releases(true))
        XCTAssertEqual(gate.release("link"), "link")
        XCTAssertFalse(gate.closesOutline(hasPendingRequest: true))
    }

    func testAnOutlineThatNeverAppearedHoldsNothingBack() {
        // Only appearance arms the gate: a presentation request for the outline that failed must
        // not leave every other sheet, picker and alert held for good.
        XCTAssertFalse(OutlinePresentationGate().isOutlineOnScreen)
    }
}

// MARK: - Navigation hand-off

final class OutlineHeldNavigationTests: XCTestCase {
    func testANavigationGoesStraightThroughWhileTheOutlineIsClosed() {
        var held = OutlineHeldNavigation<String>()
        XCTAssertEqual(held.request("child", isOutlineOnScreen: false), "child")
        XCTAssertFalse(held.isHolding)
        XCTAssertNil(held.takeAfterOutlineDismissed())
    }

    /// A page chip or a Subpages row tapped behind the outline: pushing then would leave the outline over the
    /// new document, so the push waits for the outline's dismissal and runs exactly once.
    func testANavigationMadeWhileTheOutlineIsUpWaitsForItsDismissal() {
        var held = OutlineHeldNavigation<String>()
        XCTAssertNil(held.request("child", isOutlineOnScreen: true))
        XCTAssertTrue(held.isHolding)
        XCTAssertEqual(held.takeAfterOutlineDismissed(), "child")
        XCTAssertFalse(held.isHolding)
        XCTAssertNil(held.takeAfterOutlineDismissed())
    }

    func testOnlyTheLastNavigationRequestedWhileTheOutlineIsUpIsFollowed() {
        var held = OutlineHeldNavigation<String>()
        _ = held.request("first", isOutlineOnScreen: true)
        _ = held.request("second", isOutlineOnScreen: true)
        XCTAssertEqual(held.takeAfterOutlineDismissed(), "second")
    }

    /// The gate and the hand-off agree: a navigation held while the outline is up counts as a pending request,
    /// so the outline closes for it.
    func testAHeldNavigationClosesTheOutline() {
        var gate = OutlinePresentationGate()
        gate.outlineAppeared()
        var held = OutlineHeldNavigation<String>()
        _ = held.request("child", isOutlineOnScreen: gate.isOutlineOnScreen)
        XCTAssertTrue(gate.closesOutline(hasPendingRequest: held.isHolding))
    }
}
