import XCTest

@testable import Schrift

final class EditorToolbarActionsTests: XCTestCase {
    func testEditingModeShowsOnlyDone() {
        XCTAssertEqual(editorToolbarActions(isEditing: true, isOffline: false), [.done])
        // Editing is never reachable offline, but the intent list is unconditional there.
        XCTAssertEqual(editorToolbarActions(isEditing: true, isOffline: true), [.done])
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
}
