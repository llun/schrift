import XCTest

@testable import Schrift

/// The haptic half of `SwipeRevealRow`: when a live drag counts as having crossed the open
/// threshold. The tick itself (`.sensoryFeedback`) is not observable from here; the decision
/// that drives it is.
final class SwipeRevealThresholdTests: XCTestCase {
    private let strip: CGFloat = 144  // threshold = 72 at the default 0.5 ratio

    func testADragShortOfTheThresholdHasNotCrossed() {
        let update = swipeRevealThresholdUpdate(wasPast: false, offset: -40, stripWidth: strip)
        XCTAssertEqual(update, SwipeRevealThresholdUpdate(isPast: false, crossed: false))
    }

    func testReachingTheThresholdCrossesExactlyOnce() {
        let first = swipeRevealThresholdUpdate(wasPast: false, offset: -72, stripWidth: strip)
        XCTAssertEqual(first, SwipeRevealThresholdUpdate(isPast: true, crossed: true))
        // Further travel in the same direction is not another crossing.
        let second = swipeRevealThresholdUpdate(wasPast: first.isPast, offset: -100, stripWidth: strip)
        XCTAssertEqual(second, SwipeRevealThresholdUpdate(isPast: true, crossed: false))
    }

    func testTheThresholdMatchesTheSettleDecision() {
        // The tick and the release agree about where the line is.
        XCTAssertEqual(swipeRevealSettle(predictedEndOffset: -72, stripWidth: strip), .open)
        XCTAssertTrue(swipeRevealThresholdUpdate(wasPast: false, offset: -72, stripWidth: strip).isPast)
        XCTAssertEqual(swipeRevealSettle(predictedEndOffset: -71, stripWidth: strip), .closed)
        XCTAssertFalse(swipeRevealThresholdUpdate(wasPast: false, offset: -71, stripWidth: strip).isPast)
    }

    func testCrossingBackIsAnotherCrossing() {
        let back = swipeRevealThresholdUpdate(wasPast: true, offset: -40, stripWidth: strip)
        XCTAssertEqual(back, SwipeRevealThresholdUpdate(isPast: false, crossed: true))
        let again = swipeRevealThresholdUpdate(wasPast: back.isPast, offset: -80, stripWidth: strip)
        XCTAssertEqual(again, SwipeRevealThresholdUpdate(isPast: true, crossed: true))
    }

    /// A finger resting on the line must not stutter: stepping back a point or two stays past.
    func testHoveringJustBelowTheThresholdDoesNotRetrigger() {
        let hover = swipeRevealThresholdUpdate(wasPast: true, offset: -70, stripWidth: strip)
        XCTAssertEqual(hover, SwipeRevealThresholdUpdate(isPast: true, crossed: false))
        let clear = swipeRevealThresholdUpdate(wasPast: true, offset: -65, stripWidth: strip)
        XCTAssertEqual(clear, SwipeRevealThresholdUpdate(isPast: false, crossed: true))
    }

    func testRubberBandedTravelPastTheStripStaysPast() {
        let update = swipeRevealThresholdUpdate(wasPast: true, offset: -160, stripWidth: strip)
        XCTAssertEqual(update, SwipeRevealThresholdUpdate(isPast: true, crossed: false))
    }

    func testNoStripMeansNothingToCross() {
        let update = swipeRevealThresholdUpdate(wasPast: false, offset: -50, stripWidth: 0)
        XCTAssertEqual(update, SwipeRevealThresholdUpdate(isPast: false, crossed: false))
    }

    func testAnAlreadyOpenRowStartsPastTheThreshold() {
        // `onBegan` seeds the flag from the resting offset, so grabbing an open row is silent.
        let seeded = swipeRevealThresholdUpdate(wasPast: false, offset: -144, stripWidth: strip)
        XCTAssertTrue(seeded.isPast)
        let held = swipeRevealThresholdUpdate(wasPast: seeded.isPast, offset: -144, stripWidth: strip)
        XCTAssertFalse(held.crossed)
    }
}
