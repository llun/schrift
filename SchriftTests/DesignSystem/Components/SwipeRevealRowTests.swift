import SwiftUI
import XCTest

@testable import Schrift

/// The pure core of `SwipeRevealRow` — the shape of every mapping the gesture drives.
///
/// How the slop and dominance constants *feel* is still a device question. Whether a
/// horizontal drag coexists with the enclosing `ScrollView`'s pan is **not**: that used to be
/// left to hand verification, and the gap is what shipped a Home list that could not scroll.
/// It now has its own suite in `SwipeRevealGestureTests`.
final class SwipeRevealRowTests: XCTestCase {

    // MARK: - Axis lock

    func testADragShorterThanTheSlopIsUndecided() {
        XCTAssertEqual(swipeDragAxis(translation: CGSize(width: -6, height: 2)), .undecided)
    }

    func testAClearlySidewaysDragIsHorizontal() {
        XCTAssertEqual(swipeDragAxis(translation: CGSize(width: -30, height: 4)), .horizontal)
    }

    func testAClearlyVerticalDragIsVertical() {
        XCTAssertEqual(swipeDragAxis(translation: CGSize(width: 4, height: 30)), .vertical)
    }

    /// **The tie goes to the scroll view, not to the swipe.** A drag that is only
    /// marginally more horizontal than vertical is someone scrolling with a slightly
    /// crooked thumb; claiming it would make the list feel like it fights back.
    func testAnAmbiguousDiagonalResolvesVertical() {
        XCTAssertEqual(swipeDragAxis(translation: CGSize(width: -20, height: 18)), .vertical)
    }

    /// The slop is a distance, so the direction of travel cannot change the decision.
    func testTheAxisIgnoresTheSignOfTheTranslation() {
        XCTAssertEqual(
            swipeDragAxis(translation: CGSize(width: 30, height: -4)),
            swipeDragAxis(translation: CGSize(width: -30, height: 4)))
    }

    // MARK: - Offset mapping

    func testAClosedRowRefusesATrailingDrag() {
        // There are no leading actions, so dragging the content to the right does nothing.
        XCTAssertEqual(swipeRevealOffset(translation: 60, startingOffset: 0, stripWidth: 144), 0)
    }

    func testDraggingOpenTracksTheFingerOneToOne() {
        XCTAssertEqual(swipeRevealOffset(translation: -40, startingOffset: 0, stripWidth: 144), -40)
    }

    func testTravelPastTheStripIsRubberBandedRatherThanClamped() {
        // -200 requested against a 144 strip: the first 144 travel, the extra 56 are damped.
        let offset = swipeRevealOffset(translation: -200, startingOffset: 0, stripWidth: 144)
        XCTAssertEqual(offset, -144 - 56 * 0.25, accuracy: 0.0001)
        XCTAssertLessThan(offset, -144, "it keeps moving — a hard clamp feels broken")
        XCTAssertGreaterThan(offset, -200, "but not one-to-one")
    }

    /// A drag beginning on an already-open row continues from the strip edge instead of
    /// snapping back to zero.
    func testADragOnAnOpenRowContinuesFromWhereItSat() {
        XCTAssertEqual(swipeRevealOffset(translation: 100, startingOffset: -144, stripWidth: 144), -44)
    }

    func testAnOpenRowDraggedClosedStopsAtZero() {
        XCTAssertEqual(swipeRevealOffset(translation: 300, startingOffset: -144, stripWidth: 144), 0)
    }

    func testAnEmptyStripNeverMoves() {
        XCTAssertEqual(swipeRevealOffset(translation: -80, startingOffset: 0, stripWidth: 0), 0)
    }

    // MARK: - Settle decision

    /// A drag released with no velocity projects to where it already sits.
    func testASlowShortDragReleasedDeadCloses() {
        XCTAssertEqual(swipeRevealSettle(predictedEndOffset: -58, stripWidth: 144), .closed)
    }

    /// A fast flick opens even though the finger never travelled half the strip — the
    /// projection is what distinguishes a flick from an abandoned drag.
    func testAFastShortFlickOpens() {
        XCTAssertEqual(swipeRevealSettle(predictedEndOffset: -140, stripWidth: 144), .open)
    }

    /// …and the mirror: a long drag whose momentum carries it back closes.
    func testALongDragFlickedBackCloses() {
        XCTAssertEqual(swipeRevealSettle(predictedEndOffset: -4, stripWidth: 144), .closed)
    }

    func testExactlyAtTheThresholdOpens() {
        XCTAssertEqual(swipeRevealSettle(predictedEndOffset: -72, stripWidth: 144), .open)
    }

    func testAStriplessRowAlwaysSettlesClosed() {
        XCTAssertEqual(swipeRevealSettle(predictedEndOffset: -50, stripWidth: 0), .closed)
    }

    // MARK: - Widths

    func testNoActionsMeansNoStrip() {
        XCTAssertEqual(swipeActionStripWidth(actionCount: 0, buttonWidth: 72), 0)
        XCTAssertEqual(
            swipeActionButtonWidth(actionCount: 0, scaledBase: 72, rowWidth: 370), 0)
    }

    func testTheScaledBaseIsUsedWhenItFits() {
        XCTAssertEqual(
            swipeActionButtonWidth(actionCount: 2, scaledBase: 72, rowWidth: 370), 72)
    }

    /// At accessibility sizes the scaled base would swallow the row, so the strip is
    /// capped at a fraction of it and the title stays readable.
    func testAnAccessibilityScaledBaseIsCappedToAFractionOfTheRow() {
        // 0.6 * 370 = 222 across two buttons → 111 each.
        XCTAssertEqual(
            swipeActionButtonWidth(actionCount: 2, scaledBase: 224, rowWidth: 370), 111,
            accuracy: 0.0001)
    }

    /// **The 44pt floor beats the cap.** A narrow row with several actions would otherwise
    /// compute sub-44pt buttons, and a tap target below 44pt is not a trade this app makes.
    func testTheTapTargetFloorWinsOverTheCap() {
        // 0.6 * 200 = 120 across four buttons → 30 each, which the floor lifts to 44.
        XCTAssertEqual(
            swipeActionButtonWidth(actionCount: 4, scaledBase: 72, rowWidth: 200),
            DocsSpacing.rowMinHeight)
    }

    /// **The three-action strip, at the narrowest width a device actually offers.** Home rows
    /// gained Move between Pin and Delete, and CLAUDE.md's rule for a row of fixed-minimum
    /// controls is to measure it against the narrowest device before adding to it — so that
    /// the *next* addition fails a test rather than a screen.
    ///
    /// 343pt is an iPhone SE's 375pt less the 16pt gutter each side. The cap (0.6 × 343 ÷ 3 =
    /// 68.6pt) is what binds: under the 72pt base, comfortably over the 44pt floor, and the
    /// strip lands exactly on the 60% budget.
    func testADocumentRowsStripFitsTheNarrowestRowWithoutHittingTheTapTargetFloor() {
        // **Derived from the real resolver, not a literal.** A hard-coded 3 would keep passing
        // when a fourth action is added, which is the whole thing this is here to catch.
        let actionCount = documentRowSwipeActions(
            isPendingDelete: false, isLocalDocument: false, isFavorite: false, offersPin: true,
            keepLabel: "Keep", pinLabel: "Pin", unpinLabel: "Unpin", moveLabel: "Move",
            deleteLabel: "Delete", onKeep: {}, onTogglePin: {}, onMove: {}, onDelete: {}
        ).count
        let width = swipeActionButtonWidth(actionCount: actionCount, scaledBase: 72, rowWidth: 343)

        XCTAssertGreaterThan(
            width, DocsSpacing.rowMinHeight,
            "the floor must not be engaged, or the strip would exceed its share of the row")
        XCTAssertLessThanOrEqual(
            swipeActionStripWidth(actionCount: actionCount, buttonWidth: width), 343 * 0.6,
            "every action a document row offers must still fit the 60% budget")
    }

    /// Before the first geometry callback the row's width is still zero. Falling through to
    /// a zero-width strip there would render the actions invisible on the very first swipe.
    func testAnUnmeasuredRowFallsBackToTheScaledBase() {
        XCTAssertEqual(
            swipeActionButtonWidth(actionCount: 2, scaledBase: 72, rowWidth: 0), 72)
    }

    func testTheStripIsTheButtonWidthTimesTheCount() {
        XCTAssertEqual(swipeActionStripWidth(actionCount: 3, buttonWidth: 60), 180)
    }

    // MARK: - Layout direction

    /// `.offset(x:)` is **not** mirrored by SwiftUI, so without this the strip would open
    /// off the wrong edge under an RTL locale.
    func testTheDirectionSignFlipsForRightToLeft() {
        XCTAssertEqual(swipeRevealDirectionSign(.leftToRight), 1)
        XCTAssertEqual(swipeRevealDirectionSign(.rightToLeft), -1)
    }

    // MARK: - Caption visibility

    func testCaptionsShowAtEverydaySizesAndDropAtAccessibilitySizes() {
        for size in DynamicTypeSize.allCases {
            XCTAssertEqual(
                swipeActionShowsCaption(size), !size.isAccessibilitySize,
                "\(size) disagreed — a caption in a scaled box wraps to truncated lines")
        }
    }

    // MARK: - Cross-row state

    func testBeginningADragClaimsTheRowAndClosesEverySibling() {
        let a = UUID()
        let b = UUID()
        let state = swipeRevealBeginningDrag(
            SwipeRevealState(openRowID: a, draggingRowID: nil), rowID: b)
        XCTAssertEqual(state.openRowID, b, "claiming the row is what closes the other one")
        XCTAssertEqual(state.draggingRowID, b)
    }

    func testSettlingOpenKeepsTheRowAndEndsTheDrag() {
        let row = UUID()
        let state = swipeRevealSettling(
            SwipeRevealState(openRowID: row, draggingRowID: row), rowID: row, settle: .open)
        XCTAssertEqual(state.openRowID, row)
        XCTAssertNil(state.draggingRowID)
    }

    func testSettlingClosedReleasesTheRow() {
        let row = UUID()
        let state = swipeRevealSettling(
            SwipeRevealState(openRowID: row, draggingRowID: row), rowID: row, settle: .closed)
        XCTAssertNil(state.openRowID)
        XCTAssertNil(state.draggingRowID)
    }

    /// Settling a row that is not the open one must not close whatever is.
    func testSettlingClosedOnAStaleRowLeavesTheOpenRowAlone() {
        let open = UUID()
        let stale = UUID()
        let state = swipeRevealSettling(
            SwipeRevealState(openRowID: open, draggingRowID: nil), rowID: stale, settle: .closed)
        XCTAssertEqual(state.openRowID, open)
    }

    func testScrollingClosesAnOpenRow() {
        let state = swipeRevealAfterScrollInteraction(
            SwipeRevealState(openRowID: UUID(), draggingRowID: nil))
        XCTAssertNil(state.openRowID)
    }

    /// **The one that would silently regress into "the strip closes the instant you
    /// swipe".** Both recognizers run simultaneously, so a swipe routinely nudges the
    /// scroll view — which reports an interaction while the finger is still down.
    func testScrollingDoesNotCloseTheRowBeingDragged() {
        let row = UUID()
        let state = swipeRevealAfterScrollInteraction(
            SwipeRevealState(openRowID: row, draggingRowID: row))
        XCTAssertEqual(state.openRowID, row)
        XCTAssertEqual(state.draggingRowID, row)
    }
}
