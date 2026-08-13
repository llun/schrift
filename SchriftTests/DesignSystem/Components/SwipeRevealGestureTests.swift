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
/// a given recognizer state takes, the once-and-frozen axis latch, the state→callback mapping,
/// the flick projection, and the simultaneous-recognition answer — read through a recognizer
/// the production factory built, not through a coordinator in isolation.
///
/// What is still out of reach, and is not claimed: the one line of `makeUIGestureRecognizer`
/// that hands the coordinator to that factory (a `Context` cannot be constructed outside
/// SwiftUI); the recognizer's own touch bookkeeping — that `origin` is latched from the first
/// touch and cleared only by `reset()`, and that `.began` zeroes the translation; and the
/// ordering of the gate before `super.touchesMoved`, which is a property of the override rather
/// than of any value.
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

    /// A recognizer that has already finished has nothing left to refuse, and `.cancelled` is
    /// not a legal transition out of a terminal state — so the answer is "do nothing", not a
    /// move UIKit would reject. Reachable only if UIKit ever delivers a trailing move after a
    /// refusal; cheap enough not to depend on it not doing so.
    func testATerminalRecognizerIsNotToldToRefuseAgain() {
        for state in [UIGestureRecognizer.State.failed, .cancelled, .ended] {
            XCTAssertNil(swipeGestureRefusalState(current: state, axis: .vertical))
        }
    }

    // MARK: - The axis latch

    /// **Decided once, then frozen.** Past the commitment the latch does not re-judge the
    /// drag at all — which is what stops a swipe that curves downward from cancelling itself
    /// halfway through the strip.
    func testACommittedDragIsNeverReJudged() {
        XCTAssertEqual(
            swipeGestureLatchDecision(
                isHorizontal: true, current: .changed, travel: CGSize(width: 2, height: 300)),
            .committed,
            "a drag that already committed horizontal must not be refused by a later vertical "
                + "stretch of the same swipe")
    }

    func testTheFirstClearlySidewaysMoveCommits() {
        XCTAssertEqual(
            swipeGestureLatchDecision(
                isHorizontal: false, current: .possible, travel: CGSize(width: -30, height: 4)),
            .commit)
    }

    /// Inside the slop nothing is proved, and the latch says so rather than guessing — this is
    /// what lets a swipe start gently instead of being refused on its first few points.
    func testADragInsideTheSlopNeitherCommitsNorRefuses() {
        XCTAssertEqual(
            swipeGestureLatchDecision(
                isHorizontal: false, current: .possible, travel: CGSize(width: -6, height: 2)),
            .wait)
    }

    /// The latch routes a refusal through `swipeGestureRefusalState`, so which refusal it is
    /// still depends on how far the recognizer had got.
    func testAnUncommittedVerticalDragIsRefusedAccordingToTheRecognizersState() {
        XCTAssertEqual(
            swipeGestureLatchDecision(
                isHorizontal: false, current: .possible, travel: CGSize(width: 4, height: 30)),
            .refuse(.failed))
        XCTAssertEqual(
            swipeGestureLatchDecision(
                isHorizontal: false, current: .began, travel: CGSize(width: 4, height: 30)),
            .refuse(.cancelled))
    }

    // MARK: - Recognizer state → the row's vocabulary

    /// **Anything that ends a drag without a release reaches the row as a cancellation**, or
    /// the list-wide `draggingRowID` claim is never given back:
    /// `swipeRevealAfterScrollInteraction` early-returns forever and close-on-scroll is dead
    /// for the whole list until some other row completes a full drag.
    ///
    /// `.cancelled` is the case the runtime takes — a late refusal goes out as `.cancelled`,
    /// and a system cancellation is `.cancelled` too. `.failed` is asserted **defensively**:
    /// UIKit sends action messages only for `.began`/`.changed`/`.ended`/`.cancelled`, so it is
    /// never delivered here. Do not read this test as evidence that a `.failed` path is
    /// exercised.
    func testAnythingThatEndsADragWithoutAReleaseReachesTheRowAsACancellation() {
        XCTAssertEqual(swipeGestureEvent(for: .cancelled), .cancelled)
        XCTAssertEqual(swipeGestureEvent(for: .failed), .cancelled)
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

    /// **The projection must not open a row on its own.** With UIKit's *normal* scroll rate
    /// (0.998) this projects half a second of travel, and a barely-moving release clears the
    /// 72pt threshold from a 5pt drag — every brush of the list would leave a strip open. The
    /// rate is a feel constant that still wants a device, but this pins the direction: a slow
    /// drift is not a flick. Its counterpart below is what stops the fix from being "project
    /// nothing".
    func testAReleaseStillDriftingSlowlyDoesNotOpenAClosedRow() {
        let strip: CGFloat = 144
        let predicted = swipeRevealOffset(
            translation: swipeGestureEndTranslation(translation: -5, velocity: -200),
            startingOffset: 0, stripWidth: strip)

        XCTAssertEqual(swipeRevealSettle(predictedEndOffset: predicted, stripWidth: strip), .closed)
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
    ///
    /// The coordinator is held in a **local for the duration of the test**, and has to be:
    /// `UIGestureRecognizer.delegate` is `weak`, so passing it as a temporary would leave the
    /// recognizer delegate-less by the next line and fail this on perfectly correct code. In
    /// production SwiftUI owns the coordinator it made.
    func testTheRecognizerTheFactoryBuildsAnswersThroughItsDelegate() {
        let coordinator = SwipeRevealGesture.Coordinator()
        let recognizer = SwipeRevealGesture.makeRecognizer(delegate: coordinator)
        let scrollView = UIScrollView()

        XCTAssertTrue(
            recognizer.delegate?.gestureRecognizer?(
                recognizer, shouldRecognizeSimultaneouslyWith: scrollView.panGestureRecognizer) ?? false,
            "the recognizer handed to SwiftUI must carry a delegate that permits the scroll "
                + "view's pan to run alongside it")
    }

    /// A row swipe is a one-finger gesture. Left at UIKit's default a second finger joins this
    /// same recognizer — and what that costs is **not** the axis gate, which reads the tracked
    /// touch's own location and is unaffected: it is `super`'s `translation(in:)`, the centroid
    /// of every touch the pan accepts, which is what the row's offset follows. A finger landing
    /// mid-swipe would jump the strip.
    func testTheFactoryBuildsAOneFingerRecognizer() {
        let coordinator = SwipeRevealGesture.Coordinator()
        XCTAssertEqual(
            SwipeRevealGesture.makeRecognizer(delegate: coordinator).maximumNumberOfTouches, 1)
    }

}
