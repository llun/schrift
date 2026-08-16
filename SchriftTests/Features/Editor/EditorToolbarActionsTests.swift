import XCTest

@testable import Schrift

final class EditorToolbarActionsTests: XCTestCase {
    func testEditingModeSwapsEditForDone() {
        // There is one system toolbar in both modes now, so Done takes Edit's
        // slot rather than living in a bar of its own — and the rest of the
        // actions stay put.
        XCTAssertEqual(editorToolbarActions(isEditing: true), [.done, .share, .options])
    }

    func testEditIsNeverOfferedAlongsideDone() {
        // The two are the same slot in opposite modes; showing both would offer
        // "start editing" during an edit.
        XCTAssertFalse(editorToolbarActions(isEditing: true).contains(.edit))
        XCTAssertFalse(editorToolbarActions(isEditing: false).contains(.done))
    }

    /// The resolver no longer takes connectivity at all: offline editing queues
    /// through the write-ahead draft pipeline (`.pendingSync` → replay on
    /// reconnect), so "offline drops Edit" — the old read-only rule — is gone,
    /// and a dead parameter would only invite the gate's reintroduction. Edit's
    /// safety on an unloaded document is `startEditing`'s `hasLoadedContent`
    /// guard, exactly as it is online during a load or an error state.
    func testReadingExposesEditShareOptions() {
        XCTAssertEqual(editorToolbarActions(isEditing: false), [.edit, .share, .options])
    }

    // MARK: - Presence

    func testPresenceShowsThePeerCount() {
        XCTAssertEqual(presentedPeerCount(peerCount: 1, isOffline: false), 1)
        XCTAssertEqual(presentedPeerCount(peerCount: 4, isOffline: false), 4)
    }

    func testPresenceIsHiddenWhenAlone() {
        XCTAssertNil(presentedPeerCount(peerCount: 0, isOffline: false))
    }

    /// Peer state is only ever as fresh as the last socket message, so offline
    /// it would be a claim the app can't stand behind.
    func testPresenceIsHiddenOffline() {
        XCTAssertNil(presentedPeerCount(peerCount: 3, isOffline: true))
        XCTAssertNil(presentedPeerCount(peerCount: 0, isOffline: true))
    }

    /// A document that exists only on this device has no share URL and no accesses to list,
    /// so Share would open a sheet showing "Couldn't load members" over a link nobody else
    /// can open. Editing and Options (for Delete) are exactly what it does need.
    func testALocalDocumentDropsShareButKeepsEditingAndOptions() {
        XCTAssertEqual(editorToolbarActions(isEditing: false, isLocal: true), [.edit, .options])
        XCTAssertEqual(editorToolbarActions(isEditing: true, isLocal: true), [.done, .options])
    }

    /// And a synced document is unchanged, offline or not — sharing one offline fails loudly,
    /// which predates this change.
    func testASyncedDocumentKeepsShare() {
        XCTAssertEqual(editorToolbarActions(isEditing: false), [.edit, .share, .options])
        XCTAssertEqual(editorToolbarActions(isEditing: true, isLocal: false), [.done, .share, .options])
    }
}
