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
