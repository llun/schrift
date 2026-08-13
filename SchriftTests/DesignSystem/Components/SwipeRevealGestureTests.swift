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
/// start a scroll. Real touches still cannot be synthesized here, but everything that decides
/// the arbitration can be reached as a value function and is: the refusal gate, *which* refusal
/// a given recognizer state takes, the state→callback mapping, the flick projection, and the
/// simultaneous-recognition answer read through a recognizer the production factory built.
///
/// What is still out of reach — a `Context` cannot be constructed outside SwiftUI — is the one
/// line of `makeUIGestureRecognizer` that hands the coordinator to that factory.
@MainActor
final class SwipeRevealGestureTests: XCTestCase {

    // MARK: - The refusal gate

    /// The gate is exactly the axis lock's `.vertical` — never a second opinion about
    /// direction, the two disagreeing being how a row and its list start fighting. The
    /// `.undecided` answer is the asymmetry that makes a slow swipe possible at all: a drag
    /// inside the slop has proved nothing yet, and refusing there would mean a swipe that
    /// starts gently never gets to start.
    ///
    /// (There is deliberately no sweep over translations here. One was written, and it was
    /// vacuous: `swipeGestureRefusesDrag` *is* `axis == .vertical`, so guarding a loop on that
    /// and then asserting it cannot fail. `swipeDragAxis`'s own mapping is covered by
    /// `SwipeRevealRowTests`.)
    func testTheGateIsExactlyTheAxisLocksVerticalAnswer() {
        XCTAssertTrue(swipeGestureRefusesDrag(.vertical))
        XCTAssertFalse(swipeGestureRefusesDrag(.horizontal))
        XCTAssertFalse(swipeGestureRefusesDrag(.undecided))
    }

    // MARK: - Refusing, and the two ways of doing it

    /// **The regression, stated directly.** A drag that is still `.possible` is refused with
    /// `.failed`, which is what hands the touch straight back to the scroll view. This is the
    /// path a plain vertical scroll takes, and getting it wrong is the whole defect.
    func testAVerticalDragIsFailedWhileTheRecognizerHasNotBegun() {
        XCTAssertEqual(swipeGestureRefusalState(current: .possible, axis: .vertical), .failed)
    }

    /// **The other half, and not interchangeable with it.** A pan commits on its own at about
    /// the distance this gate uses, so a diagonal can beat the gate to `.began`. `.failed` is
    /// not a legal transition from there; `.cancelled` is what gets the recognizer out of the
    /// way. Asserting the two states map to *different* answers is what makes inverting the
    /// branch a red test rather than a shipped one.
    func testADragThatAlreadyBeganIsCancelledRatherThanFailed() {
        XCTAssertEqual(swipeGestureRefusalState(current: .began, axis: .vertical), .cancelled)
        XCTAssertEqual(swipeGestureRefusalState(current: .changed, axis: .vertical), .cancelled)
        XCTAssertNotEqual(
            swipeGestureRefusalState(current: .began, axis: .vertical),
            swipeGestureRefusalState(current: .possible, axis: .vertical))
    }

    /// The negative control: a gate that refused *everything* would satisfy the two above and
    /// break the swipe entirely.
    func testADragTheAxisLockAcceptsIsNotRefusedFromAnyState() {
        for state in [UIGestureRecognizer.State.possible, .began, .changed] {
            XCTAssertNil(swipeGestureRefusalState(current: state, axis: .horizontal))
            XCTAssertNil(swipeGestureRefusalState(current: state, axis: .undecided))
        }
    }

    // MARK: - Recognizer state → the row's vocabulary

    /// **`.failed` must reach the row as a cancellation.** A late refusal has to release the
    /// list-wide `draggingRowID` claim exactly as a system cancellation does — left unmapped,
    /// `swipeRevealAfterScrollInteraction` early-returns forever and close-on-scroll is dead
    /// for the whole list until some other row completes a full drag.
    func testALateRefusalReachesTheRowAsACancellation() {
        XCTAssertEqual(swipeGestureEvent(for: .failed), .cancelled)
        XCTAssertEqual(swipeGestureEvent(for: .cancelled), .cancelled)
    }

    func testTheRecognizedStatesMapThrough() {
        XCTAssertEqual(swipeGestureEvent(for: .began), .began)
        XCTAssertEqual(swipeGestureEvent(for: .changed), .changed)
        XCTAssertEqual(swipeGestureEvent(for: .ended), .ended)
    }

    /// The negative control for the mapping: a touch that has not moved is not an event, so a
    /// mapping that answered *something* for every state would be caught here.
    func testAnUnstartedRecognizerIsNotAnEvent() {
        XCTAssertNil(swipeGestureEvent(for: .possible))
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

    /// A release with no velocity ends where the finger is — nothing is added on the way out.
    func testAReleaseWithNoVelocityEndsWhereTheFingerStopped() {
        XCTAssertEqual(swipeGestureEndTranslation(translation: -30, velocity: 0), -30)
    }

    /// **What the projection is for**, driven through the same function the recognizer calls
    /// rather than re-assembled here: a short *fast* flick opens the row, and the same distance
    /// travelled slowly does not. `DragGesture.Value.predictedEndTranslation` used to supply
    /// this; a UIKit recognizer reports velocity instead, so the two halves have to agree.
    func testAShortFastFlickOpensWhereTheSameDistanceDraggedSlowlyDoesNot() {
        let strip: CGFloat = 144
        let travelled: CGFloat = -30

        let slow = swipeRevealOffset(
            translation: swipeGestureEndTranslation(translation: travelled, velocity: 0),
            startingOffset: 0, stripWidth: strip)
        let fast = swipeRevealOffset(
            translation: swipeGestureEndTranslation(translation: travelled, velocity: -1500),
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
    func testTheCoordinatorAllowsAScrollViewsPanToRunAlongside() {
        let coordinator = SwipeRevealGesture.Coordinator()
        let scrollView = UIScrollView()
        let swipe = SwipeRevealPanGestureRecognizer()

        XCTAssertTrue(
            coordinator.gestureRecognizer(
                swipe, shouldRecognizeSimultaneouslyWith: scrollView.panGestureRecognizer),
            "refusing here restores the either/or arbitration that made Home unscrollable")
    }

    /// **Asked of a recognizer the production factory built, not of a coordinator in
    /// isolation.** Deleting the delegate assignment is the one-line edit that brings the
    /// unscrollable list straight back, and with the answer read *through* `recognizer.delegate`
    /// that edit turns this red — an unset delegate leaves nothing to ask. (`shouldRecognize‐
    /// SimultaneouslyWith` is an optional ObjC requirement, so an unimplemented one lands on the
    /// `?? false` too.) A `Context` cannot be constructed outside SwiftUI, so what remains
    /// unreachable from here is only `makeUIGestureRecognizer`'s one line passing the
    /// coordinator in.
    func testTheRecognizerTheFactoryBuildsAnswersThroughItsDelegate() {
        let recognizer = SwipeRevealGesture.makeRecognizer(delegate: SwipeRevealGesture.Coordinator())
        let scrollView = UIScrollView()

        XCTAssertTrue(
            recognizer.delegate?.gestureRecognizer?(
                recognizer, shouldRecognizeSimultaneouslyWith: scrollView.panGestureRecognizer) ?? false,
            "the recognizer handed to SwiftUI must carry a delegate that permits the scroll "
                + "view's pan to run alongside it")
    }

    /// The recognizer takes its thresholds from the same constants the pure axis lock does, so
    /// tuning the feel in one place cannot leave the gate judging by another.
    func testTheRecognizerUsesTheComponentsOwnMetrics() {
        let recognizer = SwipeRevealPanGestureRecognizer()
        XCTAssertEqual(recognizer.slop, SwipeRevealMetrics.slop)
        XCTAssertEqual(recognizer.dominanceRatio, SwipeRevealMetrics.dominanceRatio)
    }
}
