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
            hasUnsavedLocalContent: true, hasConflict: false, isOffline: true, saveState: .failed("x"),
            lastSyncedAt: now, now: now, locale: locale)

        XCTAssertEqual(caption, SyncCaption(text: .key(.editor_sync_save_failed), offersRetry: true))
    }

    func testOfflineWithUnsavedContentReadsAsSavedOnDevice() {
        let caption = syncCaption(
            hasUnsavedLocalContent: true, hasConflict: false, isOffline: true, saveState: .idle, lastSyncedAt: now,
            now: now,
            locale: locale)

        XCTAssertEqual(caption, SyncCaption(text: .key(.editor_sync_saved_on_device), offersRetry: false))
    }

    /// Online: the auto-sync triggers can't fire (device is online), so the
    /// pending-sync caption doubles as a manual retry.
    func testPendingSyncOnlineOffersRetry() {
        let caption = syncCaption(
            hasUnsavedLocalContent: true, hasConflict: false, isOffline: false, saveState: .pendingSync,
            lastSyncedAt: now, now: now,
            locale: locale)

        XCTAssertEqual(caption, SyncCaption(text: .key(.editor_sync_pending_sync), offersRetry: true))
    }

    /// Offline: passive — reconnect will sync it, so no retry affordance. The
    /// pending-sync caption still beats the generic "Saved on this device" wording.
    func testPendingSyncOfflineIsPassiveAndBeatsGenericOfflineWording() {
        let caption = syncCaption(
            hasUnsavedLocalContent: true, hasConflict: false, isOffline: true, saveState: .pendingSync,
            lastSyncedAt: now, now: now,
            locale: locale)

        XCTAssertEqual(caption, SyncCaption(text: .key(.editor_sync_pending_sync), offersRetry: false))
    }

    func testUnsavedContentWinsOverSyncedCaption() {
        let caption = syncCaption(
            hasUnsavedLocalContent: true, hasConflict: false, isOffline: false, saveState: .dirty, lastSyncedAt: now,
            now: now,
            locale: locale)

        XCTAssertEqual(caption, SyncCaption(text: .key(.editor_sync_edited_just_now), offersRetry: false))
    }

    func testCleanDocumentShowsSyncedCaptionAndNoRetry() {
        let caption = syncCaption(
            hasUnsavedLocalContent: false, hasConflict: false, isOffline: false, saveState: .saved, lastSyncedAt: now,
            now: now,
            locale: locale)

        XCTAssertEqual(caption.text, .key(.editor_sync_just_now))
        XCTAssertFalse(caption.offersRetry)
    }

    func testNeverSyncedCleanDocument() {
        let caption = syncCaption(
            hasUnsavedLocalContent: false, hasConflict: false, isOffline: false, saveState: .idle, lastSyncedAt: nil,
            now: now,
            locale: locale)

        XCTAssertEqual(caption, SyncCaption(text: .key(.editor_sync_not_synced_yet), offersRetry: false))
    }

    /// `.failed` without unsaved local content only happens once the document is
    /// gone (a delete purges the draft). Nothing pins the screen and there is
    /// nothing to retry, so the caption must not offer one.
    func testFailedSaveWithNoUnsavedContentOffersNoRetry() {
        let caption = syncCaption(
            hasUnsavedLocalContent: false, hasConflict: false, isOffline: false, saveState: .failed("x"),
            lastSyncedAt: now, now: now,
            locale: locale)

        XCTAssertFalse(caption.offersRetry)
        XCTAssertEqual(caption.text, .key(.editor_sync_just_now))
    }

    /// A recorded conflict **holds** the push: nothing syncs and no retry can run until the
    /// user answers the pill (`saveNow` re-enqueues straight back into the hold). So the
    /// caption must neither promise a sync nor offer a dead retry — it states only the true
    /// part, and the pill is the sole affordance. It outranks both `.pendingSync` (which the
    /// hold itself sets) and `.failed` (over which a conflict can also be recorded).
    func testAConflictSuppressesTheSyncPromiseAndTheDeadRetry() {
        let held = syncCaption(
            hasUnsavedLocalContent: true, hasConflict: true, isOffline: false, saveState: .pendingSync,
            lastSyncedAt: now, now: now, locale: locale)

        XCTAssertEqual(held, SyncCaption(text: .key(.editor_sync_saved_on_device), offersRetry: false))

        let overFailed = syncCaption(
            hasUnsavedLocalContent: true, hasConflict: true, isOffline: false, saveState: .failed("x"),
            lastSyncedAt: now, now: now, locale: locale)

        XCTAssertFalse(overFailed.offersRetry, "a retry that re-enqueues straight back into the hold is not an offer")
    }

    /// A standing conflict outranks even "Synced X ago". Nested inside `hasUnsavedLocalContent`,
    /// a conflict that is still recorded and still holding every push could render as "Synced
    /// 5 min ago" — telling the user they are in sync while their next save is parked behind a
    /// question they have not answered.
    func testAConflictOutranksTheSyncedCaption() {
        let caption = syncCaption(
            hasUnsavedLocalContent: false, hasConflict: true, isOffline: false, saveState: .saved,
            lastSyncedAt: now.addingTimeInterval(-300), now: now, locale: locale)

        XCTAssertEqual(caption, SyncCaption(text: .key(.editor_sync_saved_on_device), offersRetry: false))
    }

    // MARK: - Conflict sheet

    /// The conflict sheet tells the user *when* the other copy changed — the one fact they
    /// need to choose a winner — so the relative time must read as the past, not the future.
    func testConflictServerChangedDateReadsAsThePast() {
        let changed = conflictServerChangedDate(now.addingTimeInterval(-600), now: now, locale: locale)

        XCTAssertTrue(
            changed.localizedCaseInsensitiveContains("ago"),
            "a server copy changed 10 minutes back must read as elapsed time, got \(changed)")
    }
}
