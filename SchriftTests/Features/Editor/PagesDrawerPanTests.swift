import UIKit
import XCTest

@testable import Schrift

/// The maths and the arbitration behind the Pages drawer following a finger.
///
/// Real touches cannot be synthesized here, so everything that decides what the drawer does is a
/// value function and is driven directly: how far a translation opens it, the rubber band past
/// open, the scrim that follows, the settle decision from position plus predicted velocity, the
/// edge strip that keeps the drawer out of the system back swipe's and the split view's sidebar
/// swipe's way, and the presentation decisions (what a release writes and announces, an outside
/// change winning over a drag, when the view unmounts, no grab mid-spring). The recognizer is read
/// through the production factory.
///
/// Not reachable from here, and not claimed: the recognizer's touch bookkeeping, reading the
/// split view's live state, and the spring itself.
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
        XCTAssertTrue(pagesDrawerEdgeZoneContains(0, edgeHasSystemSwipe: false))
        XCTAssertTrue(pagesDrawerEdgeZoneContains(PagesDrawerMetrics.edgeZoneWidth, edgeHasSystemSwipe: false))
        XCTAssertFalse(pagesDrawerEdgeZoneContains(PagesDrawerMetrics.edgeZoneWidth + 1, edgeHasSystemSwipe: false))
    }

    func testWithABackSwipeTheEdgeIsLeftToTheSystem() {
        XCTAssertFalse(pagesDrawerEdgeZoneContains(0, edgeHasSystemSwipe: true))
        XCTAssertFalse(pagesDrawerEdgeZoneContains(PagesDrawerMetrics.backSwipeInset - 1, edgeHasSystemSwipe: true))
        XCTAssertTrue(pagesDrawerEdgeZoneContains(PagesDrawerMetrics.backSwipeInset, edgeHasSystemSwipe: true))
        let end = PagesDrawerMetrics.backSwipeInset + PagesDrawerMetrics.edgeZoneWidth
        XCTAssertTrue(pagesDrawerEdgeZoneContains(end, edgeHasSystemSwipe: true))
        XCTAssertFalse(pagesDrawerEdgeZoneContains(end + 1, edgeHasSystemSwipe: true))
    }

    func testTheStripIsNarrowEnoughNotToSwallowTheScreen() {
        // A pull from the text's left margin must stay a text interaction, so the strip is a
        // sliver, not a region.
        XCTAssertLessThanOrEqual(
            PagesDrawerMetrics.backSwipeInset + PagesDrawerMetrics.edgeZoneWidth, 64)
    }

    func testTheSidebarSwipeClaimsTheEdgeOnlyWhileTheSidebarIsHidden() {
        XCTAssertTrue(
            pagesDrawerCanRevealSidebar(isCollapsed: false, presentsWithGesture: true, displayMode: .secondaryOnly))
        // The sidebar is already showing: the detail pane's edge is not the screen's.
        XCTAssertFalse(
            pagesDrawerCanRevealSidebar(isCollapsed: false, presentsWithGesture: true, displayMode: .oneBesideSecondary)
        )
        XCTAssertFalse(
            pagesDrawerCanRevealSidebar(isCollapsed: false, presentsWithGesture: true, displayMode: .oneOverSecondary))
        // No swipe offered.
        XCTAssertFalse(
            pagesDrawerCanRevealSidebar(isCollapsed: false, presentsWithGesture: false, displayMode: .secondaryOnly))
        // Collapsed into one stack: the back swipe decides instead.
        XCTAssertFalse(
            pagesDrawerCanRevealSidebar(isCollapsed: true, presentsWithGesture: true, displayMode: .secondaryOnly))
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

    func testTheNavigationControllersBackSwipesWaitOnTheOpeningRecognizerOnly() throws {
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

        // The navigation controller's real recognizers, matched by identity.
        let backSwipe = try XCTUnwrap(navigation.interactivePopGestureRecognizer)
        XCTAssertTrue(coordinator.gestureRecognizer(opening, shouldBeRequiredToFailBy: backSwipe))
        XCTAssertFalse(coordinator.gestureRecognizer(closing, shouldBeRequiredToFailBy: backSwipe))
        if let contentBackSwipe = navigation.interactiveContentPopGestureRecognizer {
            XCTAssertTrue(coordinator.gestureRecognizer(opening, shouldBeRequiredToFailBy: contentBackSwipe))
            XCTAssertFalse(coordinator.gestureRecognizer(closing, shouldBeRequiredToFailBy: contentBackSwipe))
        }

        // Any other pan — even one on the navigation controller's own view — does not wait.
        let panOnNavigationView = UIPanGestureRecognizer()
        navigation.view.addGestureRecognizer(panOnNavigationView)
        let unrelatedPan = UIPanGestureRecognizer()
        pushed.view.addGestureRecognizer(unrelatedPan)
        XCTAssertFalse(coordinator.gestureRecognizer(opening, shouldBeRequiredToFailBy: panOnNavigationView))
        XCTAssertFalse(coordinator.gestureRecognizer(opening, shouldBeRequiredToFailBy: unrelatedPan))
    }

    // MARK: - Presentation decisions

    func testAReleaseThatOpensAClosedDrawerPresentsItAndAnnounces() {
        XCTAssertEqual(
            pagesDrawerFinish(settle: .open, wasPresented: false),
            PagesDrawerFinish(presented: true, announces: true, target: 1))
    }

    func testAReleaseThatClosesAnOpenDrawerDismissesItSilently() {
        XCTAssertEqual(
            pagesDrawerFinish(settle: .closed, wasPresented: true),
            PagesDrawerFinish(presented: false, announces: false, target: 0))
    }

    func testAReleaseThatLeavesTheDrawerWhereItWasWritesNothingAndSaysNothing() {
        // An edge pull let go too early, and a close drag on the open drawer that springs back:
        // `isPresented` is not rewritten, and VoiceOver is not told the screen changed.
        XCTAssertEqual(
            pagesDrawerFinish(settle: .closed, wasPresented: false),
            PagesDrawerFinish(presented: nil, announces: false, target: 0))
        XCTAssertEqual(
            pagesDrawerFinish(settle: .open, wasPresented: true),
            PagesDrawerFinish(presented: nil, announces: false, target: 1))
    }

    func testTheButtonMountsTheDrawerClosedAndSpringsItIn() {
        XCTAssertEqual(
            pagesDrawerPresentationStep(presented: true, progress: 0, isMounted: false, reduceMotion: false),
            .mountForEntrance)
    }

    func testUnderReduceMotionTheButtonMountsTheDrawerAlreadyOpen() {
        XCTAssertEqual(
            pagesDrawerPresentationStep(presented: true, progress: 0, isMounted: false, reduceMotion: true),
            .mountOpen)
    }

    func testADragsOwnReleaseLeavesNothingForThePresentationChangeToDo() {
        // The release already sprang the panel to its target before `isPresented` changed.
        XCTAssertEqual(
            pagesDrawerPresentationStep(presented: true, progress: 1, isMounted: true, reduceMotion: false),
            .unchanged)
        XCTAssertEqual(
            pagesDrawerPresentationStep(presented: false, progress: 0, isMounted: true, reduceMotion: false),
            .unchanged)
    }

    func testAnOutsideChangeWinsOverADragInFlight() {
        // A finger holds the open drawer mostly open (0.8) when a row closes it: the panel heads
        // closed, though the finger alone would have settled it open.
        XCTAssertEqual(pagesDrawerSettle(progress: 0.8, velocity: 0, panelWidth: width), .open)
        XCTAssertEqual(
            pagesDrawerPresentationStep(presented: false, progress: 0.8, isMounted: true, reduceMotion: false),
            .animate(to: 0))
        // An edge pull barely started (0.1) when the button opens it: the panel heads open.
        XCTAssertEqual(
            pagesDrawerPresentationStep(presented: true, progress: 0.1, isMounted: true, reduceMotion: false),
            .animate(to: 1))
    }

    func testReopeningWhileTheCloseSpringRunsTurnsThePanelAround() {
        // Still mounted, its model progress already 0: no second mount, just a spring back.
        XCTAssertEqual(
            pagesDrawerPresentationStep(presented: true, progress: 0, isMounted: true, reduceMotion: false),
            .animate(to: 1))
    }

    func testOnlyTheSpringThatClosedTheDrawerUnmountsIt() {
        XCTAssertTrue(pagesDrawerShouldUnmount(target: 0, progress: 0, isPresented: false, isTracking: false))
        // An opening spring never unmounts.
        XCTAssertFalse(pagesDrawerShouldUnmount(target: 1, progress: 1, isPresented: true, isTracking: false))
        // Reopened by the button while it closed.
        XCTAssertFalse(pagesDrawerShouldUnmount(target: 0, progress: 1, isPresented: true, isTracking: false))
        XCTAssertFalse(pagesDrawerShouldUnmount(target: 0, progress: 0, isPresented: true, isTracking: false))
        // Grabbed by a new drag while it closed.
        XCTAssertFalse(pagesDrawerShouldUnmount(target: 0, progress: 0.2, isPresented: false, isTracking: true))
        XCTAssertFalse(pagesDrawerShouldUnmount(target: 0, progress: 0, isPresented: false, isTracking: true))
    }

    func testADragCannotTakeHoldWhileThePanelSprings() {
        XCTAssertTrue(pagesDrawerMayBeginDrag(isTracking: false, isSettling: false))
        XCTAssertFalse(pagesDrawerMayBeginDrag(isTracking: false, isSettling: true))
        XCTAssertFalse(pagesDrawerMayBeginDrag(isTracking: true, isSettling: false))
    }
}
