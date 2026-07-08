import XCTest

@testable import Schrift

final class EditorViewTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    func testUnderAMinuteIsSyncedJustNow() {
        XCTAssertEqual(syncStatusCaption(lastSyncedAt: base, now: base), "Synced just now")
        XCTAssertEqual(syncStatusCaption(lastSyncedAt: base, now: base.addingTimeInterval(59)), "Synced just now")
    }

    func testOlderThanAMinuteUsesRelativeWording() {
        let caption = syncStatusCaption(lastSyncedAt: base, now: base.addingTimeInterval(5 * 60))
        // RelativeDateTimeFormatter output is locale-dependent; pin the shape,
        // not the exact words.
        XCTAssertTrue(caption.hasPrefix("Synced "))
        XCTAssertNotEqual(caption, "Synced just now")
    }

    // MARK: - Sync caption + retry affordance

    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// A failed save is the only affordance that unpins the document —
    /// `reconcileDraft` no-ops every revalidation while its draft is on screen, and
    /// tap-to-edit (the other route to `saveNow()`) is blocked offline, which is
    /// exactly when saves fail. So it must beat the offline wording.
    func testFailedSaveOffersRetryEvenOffline() {
        let caption = syncCaption(
            hasUnsavedLocalContent: true, isOffline: true, saveState: .failed("x"),
            lastSyncedAt: now, now: now)

        XCTAssertEqual(caption, SyncCaption(text: "Couldn't save · tap to retry", offersRetry: true))
    }

    func testOfflineWithUnsavedContentReadsAsSavedOnDevice() {
        let caption = syncCaption(
            hasUnsavedLocalContent: true, isOffline: true, saveState: .idle, lastSyncedAt: now, now: now)

        XCTAssertEqual(caption, SyncCaption(text: "Saved on this device", offersRetry: false))
    }

    func testUnsavedContentWinsOverSyncedCaption() {
        let caption = syncCaption(
            hasUnsavedLocalContent: true, isOffline: false, saveState: .dirty, lastSyncedAt: now, now: now)

        XCTAssertEqual(caption, SyncCaption(text: "Edited just now", offersRetry: false))
    }

    func testCleanDocumentShowsSyncedCaptionAndNoRetry() {
        let caption = syncCaption(
            hasUnsavedLocalContent: false, isOffline: false, saveState: .saved, lastSyncedAt: now, now: now)

        XCTAssertEqual(caption.text, "Synced just now")
        XCTAssertFalse(caption.offersRetry)
    }

    func testNeverSyncedCleanDocument() {
        let caption = syncCaption(
            hasUnsavedLocalContent: false, isOffline: false, saveState: .idle, lastSyncedAt: nil, now: now)

        XCTAssertEqual(caption, SyncCaption(text: "Not synced yet", offersRetry: false))
    }

    /// `.failed` without unsaved local content only happens once the document is
    /// gone (a delete purges the draft). Nothing pins the screen and there is
    /// nothing to retry, so the caption must not offer one.
    func testFailedSaveWithNoUnsavedContentOffersNoRetry() {
        let caption = syncCaption(
            hasUnsavedLocalContent: false, isOffline: false, saveState: .failed("x"), lastSyncedAt: now, now: now)

        XCTAssertFalse(caption.offersRetry)
        XCTAssertEqual(caption.text, "Synced just now")
    }
}
