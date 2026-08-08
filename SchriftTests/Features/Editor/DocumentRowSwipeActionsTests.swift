import XCTest

@testable import Schrift

/// The two rules the three swipe surfaces must not drift on. A free function rather than
/// logic inlined in three `ForEach` bodies is exactly so these can be stated once.
final class DocumentRowSwipeActionsTests: XCTestCase {

    private func actions(
        isPendingDelete: Bool = false,
        isLocalDocument: Bool = false,
        isFavorite: Bool = false,
        offersPin: Bool = true
    ) -> [SwipeRevealAction] {
        documentRowSwipeActions(
            isPendingDelete: isPendingDelete,
            isLocalDocument: isLocalDocument,
            isFavorite: isFavorite,
            offersPin: offersPin,
            keepLabel: "Keep this document",
            pinLabel: "Pin",
            unpinLabel: "Unpin",
            deleteLabel: "Delete",
            onKeep: {}, onTogglePin: {}, onDelete: {})
    }

    func testAnOrdinaryHomeRowOffersPinThenDelete() {
        XCTAssertEqual(actions().map(\.id), ["pin", "delete"])
    }

    func testTheDeleteActionIsDestructive() {
        XCTAssertEqual(actions().last?.role, .destructive)
    }

    func testPinBecomesUnpinForAFavorite() {
        XCTAssertEqual(actions(isFavorite: false).first?.label, "Pin")
        XCTAssertEqual(actions(isFavorite: true).first?.label, "Unpin")
    }

    /// **A row already waiting to be deleted offers only the undo.** Delete would be a no-op
    /// on it, and the row's own tap already means "keep this document" — offering both would
    /// put a destructive action next to its own reversal.
    func testAPendingDeleteRowOffersOnlyKeep() {
        let pending = actions(isPendingDelete: true)
        XCTAssertEqual(pending.map(\.id), ["keep"])
        XCTAssertEqual(pending.first?.label, "Keep this document")
        XCTAssertNotEqual(pending.first?.role, .destructive, "keeping a document destroys nothing")
    }

    func testAPendingDeleteRowOffersOnlyKeepEvenWhereThereWouldBeNoPin() {
        XCTAssertEqual(actions(isPendingDelete: true, offersPin: false).map(\.id), ["keep"])
    }

    /// **A locally-created row offers no Pin.** There is no
    /// `documents/{local-uuid}/favorite/` route, so the request 404s and
    /// `retryableSaveFailure` rightly refuses to retry it — the same gate the Options sheet
    /// applies. Delete stays: dropping the local record *is* the deletion, and it is the only
    /// way to throw such a document away.
    func testALocalRowOffersDeleteButNoPin() {
        XCTAssertEqual(actions(isLocalDocument: true).map(\.id), ["delete"])
    }

    /// The Subpages list and the Pages drawer render no pinned state, so offering the action
    /// there would succeed with nothing on the row to show for it.
    func testASurfaceThatDoesNotShowPinnedStateOffersOnlyDelete() {
        XCTAssertEqual(actions(offersPin: false).map(\.id), ["delete"])
    }

    func testEveryActionCarriesANonEmptyLabelForVoiceOver() {
        for configuration in [actions(), actions(isPendingDelete: true), actions(isLocalDocument: true)] {
            for action in configuration {
                XCTAssertFalse(
                    action.label.isEmpty,
                    "\(action.id) has no label — the drawn glyph is accessibilityHidden, so the "
                        + "accessibility action name is the only thing VoiceOver can announce")
            }
        }
    }

    // MARK: - Handler wiring

    /// **The labels and ids above prove nothing about which closure each action runs.** A
    /// mutation swapping the pending-delete action's handler from `onKeep` to `onDelete` left
    /// every other test in this file green — and that inversion is not academic: it would make
    /// "Keep this document", the last chance to recover a queued deletion, open the *delete*
    /// confirmation instead.
    private func firedAction(
        id wanted: String, isPendingDelete: Bool = false, isLocalDocument: Bool = false
    ) -> String? {
        var fired: String?
        let resolved = documentRowSwipeActions(
            isPendingDelete: isPendingDelete,
            isLocalDocument: isLocalDocument,
            isFavorite: false,
            offersPin: true,
            keepLabel: "Keep this document",
            pinLabel: "Pin",
            unpinLabel: "Unpin",
            deleteLabel: "Delete",
            onKeep: { fired = "keep" },
            onTogglePin: { fired = "pin" },
            onDelete: { fired = "delete" })
        resolved.first { $0.id == wanted }?.handler()
        return fired
    }

    func testTheKeepActionRunsTheUndoHandlerAndNotTheDelete() {
        XCTAssertEqual(firedAction(id: "keep", isPendingDelete: true), "keep")
    }

    func testThePinActionRunsTheToggleHandler() {
        XCTAssertEqual(firedAction(id: "pin"), "pin")
    }

    func testTheDeleteActionRunsTheDeleteHandler() {
        XCTAssertEqual(firedAction(id: "delete"), "delete")
    }

    func testALocalRowsDeleteStillRunsTheDeleteHandler() {
        XCTAssertEqual(firedAction(id: "delete", isLocalDocument: true), "delete")
    }
}
