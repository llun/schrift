import SwiftUI
import UIKit
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
    /// `reconcileDraft` no-ops every revalidation while its draft is on screen —
    /// so it must beat the offline wording.
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

    /// Dirty means "not on disk yet" — the draft is written by the flush — so it must
    /// not fall into the offline branch, whose wording asserts durability. Same truth
    /// `saveStatusDisplay` keeps on the editing surface. Pinned as an ordering rule:
    /// in normal operation nothing renders `.dirty` on this caption (it needs reading mode,
    /// and the reading-mode photo insert flushes in the same turn it dirties) — the one
    /// exception being a discarded document, whose flush returns before clearing `isDirty`.
    /// So this stops a reading-mode mutator from claiming a save that hasn't happened.
    func testOfflineDirtyContentReadsAsEditedNotSavedOnDevice() {
        let caption = syncCaption(
            hasUnsavedLocalContent: true, hasConflict: false, isOffline: true, saveState: .dirty,
            lastSyncedAt: now, now: now, locale: locale)

        XCTAssertEqual(caption, SyncCaption(text: .key(.editor_sync_edited_just_now), offersRetry: false))
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

    // MARK: - The caption's retry target

    /// The retry caption is the only affordance that unpins a document whose
    /// save failed — every revalidation and pull-to-refresh no-ops while that
    /// draft is on screen — so it is the last control that should be hard to
    /// hit. It shipped as a bare footnote `Text` inside a plain `Button`, which
    /// hit-tests the shape its label *draws*: one ~16pt line.
    ///
    /// The row it sits in floors at `rowMinHeight`, and that is exactly the trap
    /// CLAUDE.md names — "a 44pt frame is not a 44pt tap target" — so the floor
    /// has to be on the label. Measured, because a hit shape is invisible in a
    /// screenshot and the row's own height reports 44pt either way.
    @MainActor
    func testTheRetryCaptionFloorsItsOwnLabelToTheTapTarget() {
        let retry = captionSize(offersRetry: true)
        XCTAssertGreaterThanOrEqual(retry.height, DocsSpacing.rowMinHeight)

        // Negative control: the passive caption is one line of footnote, well
        // short of the floor — so the assertion above is reading the floor and
        // not something every caption has.
        let passive = captionSize(offersRetry: false)
        XCTAssertLessThan(passive.height, DocsSpacing.rowMinHeight)
    }

    /// …and it must not claim the height it is offered: it shares the header's
    /// metadata row, and a greedy label there would push the document down.
    @MainActor
    func testTheRetryCaptionIsContentSizedAgainstAFullScreenProposal() {
        let host = UIHostingController(
            rootView: SyncCaptionLabel(
                offersRetry: true, text: "Couldn't save · tap to retry", retryAccessibilityLabel: "Retry",
                onRetry: {}))
        let tall = host.sizeThatFits(in: CGSize(width: 370, height: 874)).height
        XCTAssertLessThanOrEqual(tall, DocsSpacing.rowMinHeight + 1, "the caption answered \(tall)pt to 874pt")
    }

    @MainActor
    private func captionSize(offersRetry: Bool) -> CGSize {
        let host = UIHostingController(
            rootView: SyncCaptionLabel(
                offersRetry: offersRetry, text: "Couldn't save · tap to retry",
                retryAccessibilityLabel: "Retry", onRetry: {}))
        return host.sizeThatFits(in: CGSize(width: 370, height: 4000))
    }
}
