import SwiftUI
import UIKit
import XCTest

@testable import Schrift

/// The gesture half of `SwipeRevealRow` — the half that decides whether the enclosing
/// `ScrollView` keeps the touch.
///
/// `SwipeRevealRowTests`' own doc comment used to say this was "not reachable from here and
/// verified by hand". That gap is exactly what shipped the Home-cannot-scroll defect: the axis
/// lock was correct and unit-tested, but it ran *downstream* of a recognizer that had already
/// claimed the drag, so on a screen made entirely of swipeable rows there was nowhere left to
/// start a scroll. Real touches still cannot be synthesized here, but the two things that
/// actually settle the arbitration — the refusal gate and the simultaneous-recognition
/// declaration — can be, and are.
final class SwipeRevealGestureTests: XCTestCase {

    // MARK: - The refusal gate

    /// **The regression, stated directly.** Every drag the row is not interested in must be
    /// *refused*, not merely ignored — a recognized-then-ignored drag is one the scroll view
    /// no longer has. The sweep is over translations rather than over the three axis cases so
    /// that it fails the same way the screen did: by naming a drag nobody could scroll with.
    func testEveryVerticalDragIsRefused() {
        for dx in stride(from: -40.0, through: 40.0, by: 5) {
            for dy in stride(from: -40.0, through: 40.0, by: 5) {
                let translation = CGSize(width: dx, height: dy)
                let axis = swipeDragAxis(translation: translation)
                guard axis == .vertical else { continue }
                XCTAssertTrue(
                    swipeGestureRefusesDrag(axis),
                    "a vertical drag at \(translation) was not refused, so the scroll view "
                        + "would lose the touch to a row that does nothing with it")
            }
        }
    }

    /// The negative control for the sweep above: a gate that refused *everything* would pass
    /// it and break the swipe entirely.
    func testAClearlySidewaysDragIsNotRefused() {
        XCTAssertFalse(swipeGestureRefusesDrag(swipeDragAxis(translation: CGSize(width: -30, height: 4))))
    }

    /// **The asymmetry that makes a slow swipe possible.** A drag inside the slop has proved
    /// nothing yet, so it is left alone rather than refused — refusing there would mean a
    /// swipe that starts gently never gets to start at all.
    func testADragInsideTheSlopIsLeftAlone() {
        let axis = swipeDragAxis(translation: CGSize(width: -6, height: 2))
        XCTAssertEqual(axis, .undecided)
        XCTAssertFalse(swipeGestureRefusesDrag(axis))
    }

    /// The ambiguous diagonal resolves vertical (the tie goes to the scroll view), so it must
    /// also be refused — not merely dropped downstream.
    func testAnAmbiguousDiagonalIsRefused() {
        XCTAssertTrue(swipeGestureRefusesDrag(swipeDragAxis(translation: CGSize(width: -20, height: 18))))
    }

    /// The gate is exactly the axis lock's `.vertical`, never a second opinion about
    /// direction — the two disagreeing is how a row and its list start fighting.
    func testTheGateIsExactlyTheAxisLocksVerticalAnswer() {
        XCTAssertTrue(swipeGestureRefusesDrag(.vertical))
        XCTAssertFalse(swipeGestureRefusesDrag(.horizontal))
        XCTAssertFalse(swipeGestureRefusesDrag(.undecided))
    }

    // MARK: - Flick projection

    /// A release with no velocity projects to where the finger already is, which is what makes
    /// a slow, short drag settle closed.
    func testNoVelocityProjectsNoFurther() {
        XCTAssertEqual(swipeFlickProjection(velocity: 0), 0)
    }

    /// The projection carries the drag's own sign — a leftward flick must not project right.
    func testTheProjectionKeepsTheSignOfTheVelocity() {
        XCTAssertLessThan(swipeFlickProjection(velocity: -1200), 0)
        XCTAssertGreaterThan(swipeFlickProjection(velocity: 1200), 0)
    }

    /// UIKit's own deceleration projection, spelled out: `v ÷ 1000 × r ÷ (1 − r)`.
    func testTheProjectionIsUIKitsDecelerationFormula() {
        let rate = SwipeRevealMetrics.decelerationRate
        XCTAssertEqual(
            swipeFlickProjection(velocity: -1000),
            -1 * rate / (1 - rate),
            accuracy: 0.0001)
    }

    func testADegenerateDecelerationRateProjectsNothing() {
        XCTAssertEqual(swipeFlickProjection(velocity: -2000, decelerationRate: 1), 0)
        XCTAssertEqual(swipeFlickProjection(velocity: -2000, decelerationRate: 0), 0)
        XCTAssertEqual(swipeFlickProjection(velocity: -2000, decelerationRate: -0.5), 0)
    }

    /// **What the projection is for**, checked through the decision it feeds rather than in
    /// isolation: a short *fast* flick opens the row, and the same distance travelled slowly
    /// does not. `DragGesture.Value.predictedEndTranslation` used to supply this; a UIKit
    /// recognizer reports velocity instead, so the two halves have to agree.
    func testAShortFastFlickOpensWhereTheSameDistanceDraggedSlowlyDoesNot() {
        let strip: CGFloat = 144
        let travelled: CGFloat = -30

        let slow = swipeRevealOffset(
            translation: travelled + swipeFlickProjection(velocity: 0),
            startingOffset: 0, stripWidth: strip)
        let fast = swipeRevealOffset(
            translation: travelled + swipeFlickProjection(velocity: -1500),
            startingOffset: 0, stripWidth: strip)

        XCTAssertEqual(swipeRevealSettle(predictedEndOffset: slow, stripWidth: strip), .closed)
        XCTAssertEqual(swipeRevealSettle(predictedEndOffset: fast, stripWidth: strip), .open)
    }

    // MARK: - Simultaneous recognition

    /// **The half of the fix SwiftUI could not express.** The scroll view's pan is an
    /// *ancestor* recognizer, and UIKit's default is that only one of two contending
    /// recognizers gets the touch. `.simultaneousGesture` reaches the view's own gestures, not
    /// that one; this delegate answer is what actually lets the list scroll under a swipeable
    /// row.
    @MainActor
    func testTheCoordinatorAllowsAScrollViewsPanToRunAlongside() {
        let coordinator = SwipeRevealGesture.Coordinator()
        let scrollView = UIScrollView()
        let swipe = SwipeRevealPanGestureRecognizer()

        XCTAssertTrue(
            coordinator.gestureRecognizer(
                swipe, shouldRecognizeSimultaneouslyWith: scrollView.panGestureRecognizer),
            "refusing here restores the either/or arbitration that made Home unscrollable")
    }

    /// The recognizer takes its thresholds from the same constants the pure axis lock does, so
    /// tuning the feel in one place cannot leave the gate judging by another.
    @MainActor
    func testTheRecognizerUsesTheComponentsOwnMetrics() {
        let recognizer = SwipeRevealPanGestureRecognizer()
        XCTAssertEqual(recognizer.slop, SwipeRevealMetrics.slop)
        XCTAssertEqual(recognizer.dominanceRatio, SwipeRevealMetrics.dominanceRatio)
    }
}
