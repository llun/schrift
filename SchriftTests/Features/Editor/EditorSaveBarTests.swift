import XCTest

@testable import Schrift

/// The editing header's status slot. Its one non-obvious rule is precedence: a recorded
/// conflict **holds** the push, so the header must not claim a sync or offer a retry that
/// only re-parks the save — the same rule `syncCaption` applies on the reading surface.
final class EditorSaveBarTests: XCTestCase {

    // MARK: - Without a conflict: the raw save state

    func testMapsEachSaveStateWhenNoConflictIsRecorded() {
        XCTAssertEqual(display(.idle), .none)
        XCTAssertEqual(display(.dirty), .save)
        XCTAssertEqual(display(.saving), .saving)
        XCTAssertEqual(display(.saved), .saved)
        XCTAssertEqual(display(.pendingSync), .savedOnDevice)
        XCTAssertEqual(display(.failed("nope")), .retry)
    }

    // MARK: - Under a held conflict

    /// The bug this rule exists for: the enqueue-hold parks the flush *without sending it*
    /// and leaves the state reading as a completed save. The header then told the user their
    /// work was synced while it sat behind a conflict they had not answered.
    func testAHeldSaveNeverReadsAsSaved() {
        XCTAssertEqual(
            display(.saved, hasConflict: true),
            .savedOnDevice,
            "a held save is on the device, not on the server")
        XCTAssertEqual(display(.saving, hasConflict: true), .savedOnDevice)
        XCTAssertEqual(display(.pendingSync, hasConflict: true), .savedOnDevice)
    }

    /// `saveNow` re-enqueues straight back into the hold, so a retry affordance here would
    /// promise a sync it cannot perform. The conflict pill — shown during editing too — is
    /// the only way out, so the header offers nothing.
    func testAFailedSaveUnderAConflictOffersNoDeadRetry() {
        XCTAssertEqual(display(.failed("nope"), hasConflict: true), .savedOnDevice)
    }

    /// …but `.dirty` keeps its funnel. The newest keystrokes are **not** on disk yet — the
    /// draft is written by the flush — so "Saved on this device" would be a lie, and tapping
    /// Save is exactly what puts them there (held, but persisted).
    func testDirtyKeepsItsSaveFunnelUnderAConflict() {
        XCTAssertEqual(display(.dirty, hasConflict: true), .save)
    }

    /// Rule 0 is gated on there being unsaved local content, exactly as `syncCaption` is: a
    /// conflict recorded against a document with nothing unsaved must not understate a save
    /// that genuinely reached the server.
    func testAConflictWithNothingUnsavedDoesNotDowngradeASyncedSave() {
        XCTAssertEqual(
            saveStatusDisplay(saveState: .saved, hasConflict: true, hasUnsavedLocalContent: false),
            .saved)
    }

    // MARK: - Helper

    private func display(
        _ state: EditorViewModel.SaveState,
        hasConflict: Bool = false
    ) -> SaveStatusDisplay {
        saveStatusDisplay(saveState: state, hasConflict: hasConflict, hasUnsavedLocalContent: true)
    }
}
