import XCTest

@testable import Schrift

final class EditorViewTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000_000)
    private let locale = AppLanguage.english.locale

    func testUnderAMinuteIsSyncedJustNow() {
        XCTAssertEqual(syncStatusCaption(lastSyncedAt: base, now: base, locale: locale), .key(.editor_sync_just_now))
        XCTAssertEqual(
            syncStatusCaption(lastSyncedAt: base, now: base.addingTimeInterval(59), locale: locale),
            .key(.editor_sync_just_now))
    }

    func testOlderThanAMinuteUsesRelativeWording() {
        let caption = syncStatusCaption(lastSyncedAt: base, now: base.addingTimeInterval(5 * 60), locale: locale)
        // RelativeDateTimeFormatter output is locale-dependent; pin the shape
        // (the dynamic case with a non-empty relative string), not the exact words.
        guard case .syncedAgo(let ago) = caption else {
            XCTFail("expected .syncedAgo, got \(caption)")
            return
        }
        XCTAssertFalse(ago.isEmpty)
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
            lastSyncedAt: now, now: now, locale: locale)

        XCTAssertEqual(caption, SyncCaption(text: .key(.editor_sync_save_failed), offersRetry: true))
    }

    func testOfflineWithUnsavedContentReadsAsSavedOnDevice() {
        let caption = syncCaption(
            hasUnsavedLocalContent: true, isOffline: true, saveState: .idle, lastSyncedAt: now, now: now,
            locale: locale)

        XCTAssertEqual(caption, SyncCaption(text: .key(.editor_sync_saved_on_device), offersRetry: false))
    }

    /// Online: the auto-sync triggers can't fire (device is online), so the
    /// pending-sync caption doubles as a manual retry.
    func testPendingSyncOnlineOffersRetry() {
        let caption = syncCaption(
            hasUnsavedLocalContent: true, isOffline: false, saveState: .pendingSync, lastSyncedAt: now, now: now,
            locale: locale)

        XCTAssertEqual(caption, SyncCaption(text: .key(.editor_sync_pending_sync), offersRetry: true))
    }

    /// Offline: passive — reconnect will sync it, so no retry affordance. The
    /// pending-sync caption still beats the generic "Saved on this device" wording.
    func testPendingSyncOfflineIsPassiveAndBeatsGenericOfflineWording() {
        let caption = syncCaption(
            hasUnsavedLocalContent: true, isOffline: true, saveState: .pendingSync, lastSyncedAt: now, now: now,
            locale: locale)

        XCTAssertEqual(caption, SyncCaption(text: .key(.editor_sync_pending_sync), offersRetry: false))
    }

    func testUnsavedContentWinsOverSyncedCaption() {
        let caption = syncCaption(
            hasUnsavedLocalContent: true, isOffline: false, saveState: .dirty, lastSyncedAt: now, now: now,
            locale: locale)

        XCTAssertEqual(caption, SyncCaption(text: .key(.editor_sync_edited_just_now), offersRetry: false))
    }

    func testCleanDocumentShowsSyncedCaptionAndNoRetry() {
        let caption = syncCaption(
            hasUnsavedLocalContent: false, isOffline: false, saveState: .saved, lastSyncedAt: now, now: now,
            locale: locale)

        XCTAssertEqual(caption.text, .key(.editor_sync_just_now))
        XCTAssertFalse(caption.offersRetry)
    }

    func testNeverSyncedCleanDocument() {
        let caption = syncCaption(
            hasUnsavedLocalContent: false, isOffline: false, saveState: .idle, lastSyncedAt: nil, now: now,
            locale: locale)

        XCTAssertEqual(caption, SyncCaption(text: .key(.editor_sync_not_synced_yet), offersRetry: false))
    }

    /// `.failed` without unsaved local content only happens once the document is
    /// gone (a delete purges the draft). Nothing pins the screen and there is
    /// nothing to retry, so the caption must not offer one.
    func testFailedSaveWithNoUnsavedContentOffersNoRetry() {
        let caption = syncCaption(
            hasUnsavedLocalContent: false, isOffline: false, saveState: .failed("x"), lastSyncedAt: now, now: now,
            locale: locale)

        XCTAssertFalse(caption.offersRetry)
        XCTAssertEqual(caption.text, .key(.editor_sync_just_now))
    }
}
