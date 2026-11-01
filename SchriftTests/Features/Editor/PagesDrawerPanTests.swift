import UIKit
import XCTest

@testable import Schrift

/// The maths and the arbitration behind the Pages drawer following a finger.
///
/// Real touches cannot be synthesized here, so everything that decides what the drawer does is a
/// value function and is driven directly: how far a translation opens it, the rubber band past
/// open, the scrim that follows, the settle decision from position plus predicted velocity, and
/// the edge strip that keeps the drawer out of the system back swipe's way. The recognizer is
/// read through the production factory.
///
/// Not reachable from here, and not claimed: the recognizer's touch bookkeeping, the responder-
/// chain walk to the hosting navigation controller, and the spring itself.
@MainActor
final class PagesDrawerPanTests: XCTestCase {
    private let width: CGFloat = 306
    private let limit = PagesDrawerMetrics.overshootLimit

    // MARK: - Progress from translation

    func testProgressTracksTheFingerOneToOne() {
        // 1:1 means the panel's edge moves exactly as far as the finger: 153pt is half of 306.
        XCTAssertEqual(
            pagesDrawerProgress(translation: 153, startProgress: 0, panelWidth: width), 0.5, accuracy: 0.0001)
        XCTAssertEqual(
            pagesDrawerProgress(translation: 100, startProgress: 0, panelWidth: width), 100 / width, accuracy: 0.0001)
    }

    func testNoTranslationLeavesTheDrawerWhereTheDragStarted() {
        XCTAssertEqual(pagesDrawerProgress(translation: 0, startProgress: 0, panelWidth: width), 0)
        XCTAssertEqual(pagesDrawerProgress(translation: 0, startProgress: 1, panelWidth: width), 1)
    }

    func testDraggingTheOpenDrawerLeftClosesItInTheSameProportion() {
        XCTAssertEqual(
            pagesDrawerProgress(translation: -153, startProgress: 1, panelWidth: width), 0.5, accuracy: 0.0001)
        XCTAssertEqual(pagesDrawerProgress(translation: -width, startProgress: 1, panelWidth: width), 0)
    }

    func testTheDrawerIsPinnedClosedRatherThanDraggedOffScreen() {
        XCTAssertEqual(pagesDrawerProgress(translation: -40, startProgress: 0, panelWidth: width), 0)
        XCTAssertEqual(pagesDrawerProgress(translation: -900, startProgress: 1, panelWidth: width), 0)
    }

    func testReachingFullyOpenIsExactlyOneWithNoStretch() {
        XCTAssertEqual(
            pagesDrawerProgress(translation: width, startProgress: 0, panelWidth: width), 1, accuracy: 0.0001)
    }

    func testPullingPastOpenStretchesButLessThanTheFinger() {
        let progress = pagesDrawerProgress(translation: width + 60, startProgress: 0, panelWidth: width)
        XCTAssertGreaterThan(progress, 1)
        // The panel moved less than the 60pt the finger went past open…
        XCTAssertLessThan((progress - 1) * width, 60)
        // …and never more than the ceiling, however far the finger goes.
        let far = pagesDrawerProgress(translation: width * 10, startProgress: 0, panelWidth: width)
        XCTAssertLessThan((far - 1) * width, limit)
    }

    func testAnUnmeasuredPanelDoesNotDivideByZero() {
        XCTAssertEqual(pagesDrawerProgress(translation: 50, startProgress: 0.4, panelWidth: 0), 0.4)
        XCTAssertEqual(pagesDrawerProgress(translation: 50, startProgress: 3, panelWidth: 0), 1)
    }

    // MARK: - Rubber band

    func testNoExcessMovesNothing() {
        XCTAssertEqual(pagesDrawerRubberBand(excess: 0), 0)
        XCTAssertEqual(pagesDrawerRubberBand(excess: -10), 0)
        XCTAssertEqual(pagesDrawerRubberBand(excess: 10, limit: 0), 0)
    }

    func testTheBandStartsNearTheCoefficientAndStiffens() {
        let small = pagesDrawerRubberBand(excess: 1)
        XCTAssertEqual(small, PagesDrawerMetrics.rubberBandCoefficient, accuracy: 0.02)
        // Each extra point moves the panel less than the last.
        let early = pagesDrawerRubberBand(excess: 20) - pagesDrawerRubberBand(excess: 10)
        let late = pagesDrawerRubberBand(excess: 110) - pagesDrawerRubberBand(excess: 100)
        XCTAssertGreaterThan(early, late)
    }

    func testTheBandIsMonotonicAndNeverReachesItsLimit() {
        var previous: CGFloat = 0
        for excess in stride(from: CGFloat(1), through: 5000, by: 37) {
            let moved = pagesDrawerRubberBand(excess: excess)
            XCTAssertGreaterThan(moved, previous)
            XCTAssertLessThan(moved, limit)
            previous = moved
        }
    }

    // MARK: - Scrim

    func testScrimGrowsInProportionToHowOpenTheDrawerIs() {
        XCTAssertEqual(pagesDrawerScrimOpacity(progress: 0), 0)
        XCTAssertEqual(pagesDrawerScrimOpacity(progress: 0.25), 0.25, accuracy: 0.0001)
        XCTAssertEqual(pagesDrawerScrimOpacity(progress: 0.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(pagesDrawerScrimOpacity(progress: 1), 1)
    }

    func testScrimStaysAtFullStrengthWhileThePanelStretches() {
        XCTAssertEqual(pagesDrawerScrimOpacity(progress: 1.08), 1)
        XCTAssertEqual(pagesDrawerScrimOpacity(progress: -0.2), 0)
    }

    // MARK: - Panel position

    func testPanelOffsetRunsFromOffscreenToHomeAndStretchesPastIt() {
        XCTAssertEqual(pagesDrawerPanelOffset(progress: 0, panelWidth: width), -width)
        XCTAssertEqual(pagesDrawerPanelOffset(progress: 0.5, panelWidth: width), -width / 2)
        XCTAssertEqual(pagesDrawerPanelOffset(progress: 1, panelWidth: width), 0)
        XCTAssertGreaterThan(pagesDrawerPanelOffset(progress: 1.05, panelWidth: width), 0)
        XCTAssertEqual(pagesDrawerPanelOffset(progress: -1, panelWidth: width), -width)
    }

    // MARK: - Settling

    func testASlowReleaseSettlesByWhichSideOfHalfwayItStoppedOn() {
        XCTAssertEqual(pagesDrawerSettle(progress: 0.49, velocity: 0, panelWidth: width), .closed)
        XCTAssertEqual(pagesDrawerSettle(progress: 0.5, velocity: 0, panelWidth: width), .open)
        XCTAssertEqual(pagesDrawerSettle(progress: 0.9, velocity: 0, panelWidth: width), .open)
        XCTAssertEqual(pagesDrawerSettle(progress: 0.1, velocity: 0, panelWidth: width), .closed)
    }

    func testAShortFastFlickOpensADrawerThatWasBarelyPulled() {
        // 20% open and thrown right at 1000pt/s: ~99pt of momentum is another 32%.
        XCTAssertEqual(pagesDrawerSettle(progress: 0.2, velocity: 1000, panelWidth: width), .open)
        // The same position let go gently stays closed.
        XCTAssertEqual(pagesDrawerSettle(progress: 0.2, velocity: 100, panelWidth: width), .closed)
    }

    func testALeftwardFlickClosesADrawerThatWasMostlyOpen() {
        XCTAssertEqual(pagesDrawerSettle(progress: 0.7, velocity: -1000, panelWidth: width), .closed)
        XCTAssertEqual(pagesDrawerSettle(progress: 0.7, velocity: -100, panelWidth: width), .open)
    }

    func testAStretchedDrawerAlwaysSettlesOpen() {
        XCTAssertEqual(pagesDrawerSettle(progress: 1.1, velocity: -300, panelWidth: width), .open)
    }

    func testAnUnmeasuredPanelSettlesClosed() {
        XCTAssertEqual(pagesDrawerSettle(progress: 1, velocity: 0, panelWidth: 0), .closed)
    }

    func testAnEdgePullFromTranslationToSettleEndToEnd() {
        // Finger down at the edge, dragged 120pt, lifted moving at 900pt/s: 120/306 = 0.39, and
        // the momentum adds ~89pt (0.29) — open.
        let released = pagesDrawerProgress(translation: 120, startProgress: 0, panelWidth: width)
        XCTAssertEqual(pagesDrawerSettle(progress: released, velocity: 900, panelWidth: width), .open)
        // The same drag, lifted at rest, goes back.
        XCTAssertEqual(pagesDrawerSettle(progress: released, velocity: 0, panelWidth: width), .closed)
    }

    // MARK: - The edge strip and the back swipe

    func testWithoutABackSwipeTheStripStartsAtTheEdge() {
        XCTAssertTrue(pagesDrawerEdgeZoneContains(0, canInteractivePop: false))
        XCTAssertTrue(pagesDrawerEdgeZoneContains(PagesDrawerMetrics.edgeZoneWidth, canInteractivePop: false))
        XCTAssertFalse(pagesDrawerEdgeZoneContains(PagesDrawerMetrics.edgeZoneWidth + 1, canInteractivePop: false))
    }

    func testWithABackSwipeTheEdgeIsLeftToTheSystem() {
        XCTAssertFalse(pagesDrawerEdgeZoneContains(0, canInteractivePop: true))
        XCTAssertFalse(pagesDrawerEdgeZoneContains(PagesDrawerMetrics.backSwipeInset - 1, canInteractivePop: true))
        XCTAssertTrue(pagesDrawerEdgeZoneContains(PagesDrawerMetrics.backSwipeInset, canInteractivePop: true))
        let end = PagesDrawerMetrics.backSwipeInset + PagesDrawerMetrics.edgeZoneWidth
        XCTAssertTrue(pagesDrawerEdgeZoneContains(end, canInteractivePop: true))
        XCTAssertFalse(pagesDrawerEdgeZoneContains(end + 1, canInteractivePop: true))
    }

    func testTheStripIsNarrowEnoughNotToSwallowTheScreen() {
        // A pull from the text's left margin must stay a text interaction, so the strip is a
        // sliver, not a region.
        XCTAssertLessThanOrEqual(
            PagesDrawerMetrics.backSwipeInset + PagesDrawerMetrics.edgeZoneWidth, 64)
    }

    func testTheBackSwipeIsPossibleOnlyWithSomethingToPopTo() {
        XCTAssertTrue(pagesDrawerCanInteractivePop(viewControllerCount: 2, popGestureEnabled: true))
        XCTAssertFalse(pagesDrawerCanInteractivePop(viewControllerCount: 1, popGestureEnabled: true))
        XCTAssertFalse(pagesDrawerCanInteractivePop(viewControllerCount: 0, popGestureEnabled: true))
        XCTAssertFalse(pagesDrawerCanInteractivePop(viewControllerCount: 3, popGestureEnabled: false))
    }

    func testADragIsTakenOnlyInTheDirectionTheGestureAccepts() {
        XCTAssertTrue(pagesDrawerDragMatches(travelX: 12, sign: 1))
        XCTAssertFalse(pagesDrawerDragMatches(travelX: -12, sign: 1))
        XCTAssertTrue(pagesDrawerDragMatches(travelX: -12, sign: -1))
        XCTAssertFalse(pagesDrawerDragMatches(travelX: 12, sign: -1))
        XCTAssertFalse(pagesDrawerDragMatches(travelX: 0, sign: 1))
    }

    // MARK: - The recognizer, as the factory builds it

    func testTheOpeningRecognizerWantsTheEdgeStripAndARightwardDrag() {
        let coordinator = PagesDrawerPanGesture.Coordinator()
        let recognizer = PagesDrawerPanGesture.makeRecognizer(
            mode: .open, isEnabled: true, isRightToLeft: false, delegate: coordinator)
        XCTAssertTrue(recognizer.requiresEdgeZone)
        XCTAssertEqual(recognizer.acceptedSign, 1)
        XCTAssertFalse(recognizer.isRightToLeft)
        XCTAssertEqual(recognizer.maximumNumberOfTouches, 1)
        XCTAssertTrue(recognizer.delegate === coordinator)
    }

    func testTheClosingRecognizerStartsAnywhereAndWantsALeftwardDrag() {
        let coordinator = PagesDrawerPanGesture.Coordinator()
        let recognizer = PagesDrawerPanGesture.makeRecognizer(
            mode: .close, isEnabled: true, isRightToLeft: false, delegate: coordinator)
        XCTAssertFalse(recognizer.requiresEdgeZone)
        XCTAssertEqual(recognizer.acceptedSign, -1)
    }

    func testRightToLeftMirrorsBothDirections() {
        let coordinator = PagesDrawerPanGesture.Coordinator()
        let opening = PagesDrawerPanGesture.makeRecognizer(
            mode: .open, isEnabled: true, isRightToLeft: true, delegate: coordinator)
        let closing = PagesDrawerPanGesture.makeRecognizer(
            mode: .close, isEnabled: true, isRightToLeft: true, delegate: coordinator)
        XCTAssertTrue(opening.isRightToLeft)
        XCTAssertEqual(opening.acceptedSign, -1)
        XCTAssertEqual(closing.acceptedSign, 1)
    }

    func testTheUpdatePathFollowsTheViewsInputs() {
        let coordinator = PagesDrawerPanGesture.Coordinator()
        let recognizer = PagesDrawerPanGesture.makeRecognizer(
            mode: .open, isEnabled: true, isRightToLeft: false, delegate: coordinator)
        PagesDrawerPanGesture.configure(recognizer, mode: .open, isEnabled: false, isRightToLeft: true)
        XCTAssertFalse(recognizer.isEnabled)
        XCTAssertEqual(recognizer.acceptedSign, -1)
        PagesDrawerPanGesture.configure(recognizer, mode: .open, isEnabled: true, isRightToLeft: false)
        XCTAssertTrue(recognizer.isEnabled)
        XCTAssertEqual(recognizer.acceptedSign, 1)
    }

    // MARK: - Arbitration

    /// Only a scroll view's own pan may run alongside the drawer's. Text selection and the
    /// long-press that starts it stay exclusive, so whichever recognizes first owns the touch.
    func testTheDrawerRunsAlongsideAScrollViewsPanOnly() {
        let scrollView = UIScrollView()
        XCTAssertTrue(pagesDrawerRunsAlongside(scrollView.panGestureRecognizer))

        let host = UIView()
        let strayPan = UIPanGestureRecognizer()
        host.addGestureRecognizer(strayPan)
        XCTAssertFalse(pagesDrawerRunsAlongside(strayPan))

        let longPress = UILongPressGestureRecognizer()
        host.addGestureRecognizer(longPress)
        XCTAssertFalse(pagesDrawerRunsAlongside(longPress))

        let loose = UIPanGestureRecognizer()
        XCTAssertFalse(pagesDrawerRunsAlongside(loose))
    }

    func testTheCoordinatorAnswersSimultaneityThroughThatRule() {
        let coordinator = PagesDrawerPanGesture.Coordinator()
        let recognizer = PagesDrawerPanGesture.makeRecognizer(
            mode: .open, isEnabled: true, isRightToLeft: false, delegate: coordinator)
        let scrollView = UIScrollView()
        XCTAssertTrue(
            coordinator.gestureRecognizer(
                recognizer, shouldRecognizeSimultaneouslyWith: scrollView.panGestureRecognizer))
        XCTAssertFalse(
            coordinator.gestureRecognizer(recognizer, shouldRecognizeSimultaneouslyWith: UILongPressGestureRecognizer())
        )
    }

    func testNothingWaitsOnTheDrawerWhenThereIsNoNavigationController() {
        let coordinator = PagesDrawerPanGesture.Coordinator()
        let recognizer = PagesDrawerPanGesture.makeRecognizer(
            mode: .open, isEnabled: true, isRightToLeft: false, delegate: coordinator)
        let view = UIView()
        view.addGestureRecognizer(recognizer)
        XCTAssertFalse(coordinator.gestureRecognizer(recognizer, shouldBeRequiredToFailBy: UIPanGestureRecognizer()))
    }

    func testTheNavigationControllersPansWaitOnTheOpeningRecognizerOnly() {
        let coordinator = PagesDrawerPanGesture.Coordinator()
        let root = UIViewController()
        let pushed = UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        navigation.pushViewController(pushed, animated: false)
        navigation.loadViewIfNeeded()
        pushed.loadViewIfNeeded()

        let opening = PagesDrawerPanGesture.makeRecognizer(
            mode: .open, isEnabled: true, isRightToLeft: false, delegate: coordinator)
        let closing = PagesDrawerPanGesture.makeRecognizer(
            mode: .close, isEnabled: true, isRightToLeft: false, delegate: coordinator)
        pushed.view.addGestureRecognizer(opening)
        pushed.view.addGestureRecognizer(closing)

        let systemPan = UIPanGestureRecognizer()
        navigation.view.addGestureRecognizer(systemPan)
        let unrelatedPan = UIPanGestureRecognizer()
        pushed.view.addGestureRecognizer(unrelatedPan)

        XCTAssertTrue(coordinator.gestureRecognizer(opening, shouldBeRequiredToFailBy: systemPan))
        XCTAssertFalse(coordinator.gestureRecognizer(opening, shouldBeRequiredToFailBy: unrelatedPan))
        XCTAssertFalse(coordinator.gestureRecognizer(closing, shouldBeRequiredToFailBy: systemPan))
    }
}
