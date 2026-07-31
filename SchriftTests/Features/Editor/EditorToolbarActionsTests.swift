import XCTest

@testable import Schrift

final class EditorToolbarActionsTests: XCTestCase {
    func testEditingModeSwapsEditForDone() {
        // There is one system toolbar in both modes now, so Done takes Edit's
        // slot rather than living in a bar of its own — and the rest of the
        // actions stay put, including offline (where Edit would be withheld but
        // Done is the way *out* of a session already in progress).
        XCTAssertEqual(editorToolbarActions(isEditing: true, isOffline: false), [.done, .share, .options])
        XCTAssertEqual(editorToolbarActions(isEditing: true, isOffline: true), [.done, .share, .options])
    }

    func testEditIsNeverOfferedAlongsideDone() {
        // The two are the same slot in opposite modes; showing both would offer
        // "start editing" during an edit.
        for isOffline in [false, true] {
            let editing = editorToolbarActions(isEditing: true, isOffline: isOffline)
            XCTAssertFalse(editing.contains(.edit), "offline=\(isOffline)")
            let reading = editorToolbarActions(isEditing: false, isOffline: isOffline)
            XCTAssertFalse(reading.contains(.done), "offline=\(isOffline)")
        }
    }

    func testReadingOnlineExposesEditShareOptions() {
        XCTAssertEqual(editorToolbarActions(isEditing: false, isOffline: false), [.edit, .share, .options])
    }

    func testReadingOfflineDropsEditSoTheDocumentStaysReadOnly() {
        // Offline is read-only: the Edit entry point is withheld, matching the
        // reading surface's other editing gates (block tap / Start writing /
        // Add a subpage). Share and Options remain available offline.
        XCTAssertEqual(editorToolbarActions(isEditing: false, isOffline: true), [.share, .options])
    }

    // MARK: - Presence badge

    func testPresenceBadgeShowsThePeerCount() {
        XCTAssertEqual(presenceBadgeCount(peerCount: 1, isOffline: false), 1)
        XCTAssertEqual(presenceBadgeCount(peerCount: 4, isOffline: false), 4)
    }

    func testPresenceBadgeIsHiddenWhenAlone() {
        XCTAssertNil(presenceBadgeCount(peerCount: 0, isOffline: false))
    }

    /// Peer state is only ever as fresh as the last socket message, so offline
    /// it would be a claim the app can't stand behind.
    func testPresenceBadgeIsHiddenOffline() {
        XCTAssertNil(presenceBadgeCount(peerCount: 3, isOffline: true))
        XCTAssertNil(presenceBadgeCount(peerCount: 0, isOffline: true))
    }
}
