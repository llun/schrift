import XCTest

@testable import Schrift

final class EditorToolbarActionsTests: XCTestCase {
    func testEditingModeExposesNoNavBarActions() {
        // Editing hides the top nav bar entirely (no back button, no double
        // border); Done lives in the editing header instead, so the nav bar's
        // trailing-action list is empty in both offline and online editing.
        XCTAssertEqual(editorToolbarActions(isEditing: true, isOffline: false), [])
        XCTAssertEqual(editorToolbarActions(isEditing: true, isOffline: true), [])
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
