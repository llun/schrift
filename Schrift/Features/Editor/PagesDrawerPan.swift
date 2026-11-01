import SwiftUI
import UIKit

// MARK: - Feel constants

/// The numbers behind the Pages drawer's drag. Feel constants like `SwipeRevealMetrics`: tune
/// them on a device, not in a test.
enum PagesDrawerMetrics {
    /// Share of the panel that must be showing — after the flick's momentum is added — for a
    /// release to settle open.
    static let openThreshold: CGFloat = 0.5
    /// The furthest the panel can be pulled past fully open, in points. The rubber band
    /// approaches this and never reaches it, so "light" is a ceiling rather than a ratio.
    static let overshootLimit: CGFloat = 32
    /// UIScrollView's rubber-band coefficient: the share of the drag that still moves the
    /// panel at the moment it passes fully open.
    static let rubberBandCoefficient: CGFloat = 0.55
    /// Width of the strip, along the leading edge, in which a touch may start pulling the drawer.
    static let edgeZoneWidth: CGFloat = 36
    /// How far the strip sits in from the edge when a system swipe starts there (the back swipe,
    /// or the iPad split view's swipe that shows a hidden sidebar), so the two never contend for
    /// the same touch. The system's edge recognizers claim roughly the outer 20 points; this
    /// clears them.
    static let backSwipeInset: CGFloat = 24
}

// MARK: - Pure maths

/// What a released drag settles to.
enum PagesDrawerSettle: Equatable {
    case open
    case closed
}

/// How far a pull of `excess` points past fully open actually moves the panel. Asymptotic
/// (UIScrollView's formula), so the panel resists more the further it is pulled and can never be
/// dragged off its own background.
func pagesDrawerRubberBand(
    excess: CGFloat,
    limit: CGFloat = PagesDrawerMetrics.overshootLimit,
    coefficient: CGFloat = PagesDrawerMetrics.rubberBandCoefficient
) -> CGFloat {
    guard excess > 0, limit > 0 else { return 0 }
    return (1 - 1 / (excess * coefficient / limit + 1)) * limit
}

/// How open the drawer is while a finger drags it: 0 closed, 1 fully open, a little above 1 while
/// the panel is rubber-banding past open.
///
/// `translation` is measured in the opening direction — positive opens, negative closes — and
/// `startProgress` is where the drag began (0 for the edge pull, 1 for a drag on the open drawer).
/// Below closed the panel is pinned, as a hard stop there is what a screen edge feels like; past
/// open it stretches.
func pagesDrawerProgress(
    translation: CGFloat,
    startProgress: CGFloat,
    panelWidth: CGFloat,
    overshootLimit: CGFloat = PagesDrawerMetrics.overshootLimit
) -> CGFloat {
    guard panelWidth > 0 else { return min(max(startProgress, 0), 1) }
    let raw = startProgress + translation / panelWidth
    if raw <= 0 { return 0 }
    if raw <= 1 { return raw }
    let stretch = pagesDrawerRubberBand(excess: (raw - 1) * panelWidth, limit: overshootLimit)
    return 1 + stretch / panelWidth
}

/// The scrim's opacity as a share of its full strength: proportional to how open the drawer is,
/// and never more than full while the panel stretches past open.
func pagesDrawerScrimOpacity(progress: CGFloat) -> Double {
    Double(min(max(progress, 0), 1))
}

/// Where a released drag ends up: the position it was let go at, plus where its momentum would
/// carry it. `velocity` is points per second in the opening direction. The projection is the same
/// fast-deceleration one the swipe rows use (`swipeFlickProjection`), so a flick means the same
/// thing in both places.
func pagesDrawerSettle(
    progress: CGFloat,
    velocity: CGFloat,
    panelWidth: CGFloat,
    openThreshold: CGFloat = PagesDrawerMetrics.openThreshold
) -> PagesDrawerSettle {
    guard panelWidth > 0 else { return .closed }
    let predicted = progress + swipeFlickProjection(velocity: velocity) / panelWidth
    return predicted >= openThreshold ? .open : .closed
}

/// The panel's x-offset from its resting place against the leading edge: fully left of the screen
/// at 0, home at 1, a little right of home while it stretches.
func pagesDrawerPanelOffset(progress: CGFloat, panelWidth: CGFloat) -> CGFloat {
    -(1 - max(progress, 0)) * panelWidth
}

/// Whether the system can pop this screen with its back swipe right now.
func pagesDrawerCanInteractivePop(viewControllerCount: Int, popGestureEnabled: Bool) -> Bool {
    viewControllerCount > 1 && popGestureEnabled
}

/// Whether the split view hosting this screen can show its hidden sidebar with a swipe from the
/// screen's leading edge: it is expanded (not collapsed into one stack, where the back swipe rules
/// instead), it offers the swipe, and the sidebar is hidden — iPad portrait, or any width at which
/// the split view tucks the primary column away.
@MainActor
func pagesDrawerCanRevealSidebar(
    isCollapsed: Bool, presentsWithGesture: Bool, displayMode: UISplitViewController.DisplayMode
) -> Bool {
    !isCollapsed && presentsWithGesture && displayMode == .secondaryOnly
}

/// The strip, measured from the leading edge, in which a touch may start pulling the drawer open.
///
/// When a system swipe already starts at the edge — the back swipe, or the split view's swipe that
/// shows a hidden sidebar — the strip sits just inside the system's own edge zone, so the very
/// edge keeps its system meaning and the drawer takes the strip beside it. With neither — the
/// editor in the iPad detail pane beside a visible sidebar, or a root screen — it starts at the
/// edge itself.
func pagesDrawerEdgeZone(edgeHasSystemSwipe: Bool) -> ClosedRange<CGFloat> {
    let start = edgeHasSystemSwipe ? PagesDrawerMetrics.backSwipeInset : 0
    return start...(start + PagesDrawerMetrics.edgeZoneWidth)
}

func pagesDrawerEdgeZoneContains(_ leadingX: CGFloat, edgeHasSystemSwipe: Bool) -> Bool {
    pagesDrawerEdgeZone(edgeHasSystemSwipe: edgeHasSystemSwipe).contains(leadingX)
}

/// Whether a drag travelling `travelX` across the screen is the direction this gesture takes:
/// `sign` is +1 for rightward, -1 for leftward.
func pagesDrawerDragMatches(travelX: CGFloat, sign: CGFloat) -> Bool {
    travelX * sign > 0
}

// MARK: - Handlers

/// What a drag on the drawer reports. `changed` and `ended` speak in the opening direction —
/// positive opens, in either layout direction — so the maths above never has to know about RTL.
struct PagesDrawerPanHandlers {
    var began: () -> Void = {}
    var changed: (_ translation: CGFloat) -> Void = { _ in }
    var ended: (_ translation: CGFloat, _ velocity: CGFloat) -> Void = { _, _ in }
    var cancelled: () -> Void = {}
}

// MARK: - The recognizer

/// The drawer's pan recognizer: a horizontal-only pan that refuses a drag the moment it proves
/// vertical (so the editor still scrolls) or wrong-way (so a stray leftward drag in the edge strip
/// does nothing), and — when it opens the drawer — refuses any touch that does not start in the
/// edge strip.
///
/// The axis latch is `swipeGestureLatchDecision`, the one the swipe rows use, for the same
/// reason: a recognizer that merely ignores a vertical drag has still taken the touch from the
/// scroll view.
final class PagesDrawerPanGestureRecognizer: UIPanGestureRecognizer {
    /// Opening: the touch must start in the edge strip. Closing: it may start anywhere.
    var requiresEdgeZone = false
    /// Which way across the screen the drag must travel: +1 rightward, -1 leftward.
    var acceptedSign: CGFloat = 1
    var isRightToLeft = false

    private weak var trackedTouch: UITouch?
    private var origin: CGPoint?
    private var isHorizontal = false

    override func reset() {
        super.reset()
        trackedTouch = nil
        origin = nil
        isHorizontal = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard trackedTouch == nil, let touch = touches.first else { return }
        if requiresEdgeZone, let view {
            let x = touch.location(in: view).x
            let leadingX = isRightToLeft ? view.bounds.width - x : x
            guard pagesDrawerEdgeZoneContains(leadingX, edgeHasSystemSwipe: view.pagesDrawerEdgeHasSystemSwipe) else {
                state = .failed
                return
            }
        }
        trackedTouch = touch
        origin = touch.location(in: nil)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        // Judged before `super`, so a refusal still hands the touch back while the recognizer is
        // `.possible` — see `SwipeRevealPanGestureRecognizer`.
        if let trackedTouch, let origin, touches.contains(trackedTouch) {
            let point = trackedTouch.location(in: nil)
            let travel = CGSize(width: point.x - origin.x, height: point.y - origin.y)
            switch swipeGestureLatchDecision(isHorizontal: isHorizontal, current: state, travel: travel) {
            case .refuse(let refusal):
                state = refusal
                return
            case .commit:
                guard pagesDrawerDragMatches(travelX: travel.width, sign: acceptedSign) else {
                    state = state == .possible ? .failed : .cancelled
                    return
                }
                isHorizontal = true
            case .wait, .committed:
                break
            }
        }
        super.touchesMoved(touches, with: event)
    }
}

extension UIView {
    /// The view controller this view belongs to: the first one up the responder chain.
    @MainActor
    fileprivate var pagesDrawerViewController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }

    /// The navigation controller this view's screen is pushed in, if any.
    @MainActor
    fileprivate var pagesDrawerNavigationController: UINavigationController? {
        pagesDrawerViewController?.navigationController
    }

    /// Whether a system swipe already starts at this screen's leading edge: the navigation
    /// controller's back swipe, or the split view's swipe that shows its hidden sidebar. That
    /// second recognizer belongs to the split view, has no public handle to wait on, and would
    /// otherwise race the drawer for the same rightward drag, so the strip steps aside for it
    /// exactly as it does for the back swipe.
    @MainActor
    fileprivate var pagesDrawerEdgeHasSystemSwipe: Bool {
        let controller = pagesDrawerViewController
        let navigation = controller?.navigationController
        let canPop = pagesDrawerCanInteractivePop(
            viewControllerCount: navigation?.viewControllers.count ?? 0,
            popGestureEnabled: navigation?.interactivePopGestureRecognizer?.isEnabled ?? false)
        guard !canPop, let split = controller?.splitViewController else { return canPop }
        return pagesDrawerCanRevealSidebar(
            isCollapsed: split.isCollapsed, presentsWithGesture: split.presentsWithGesture,
            displayMode: split.displayMode)
    }
}

// MARK: - The SwiftUI bridge

/// Bridges `PagesDrawerPanGestureRecognizer` into SwiftUI.
struct PagesDrawerPanGesture: UIGestureRecognizerRepresentable {
    enum Mode: Equatable {
        /// Pulls the closed drawer in from the leading edge strip.
        case open
        /// Pushes the open drawer back out, from anywhere it is attached.
        case close
    }

    var mode: Mode
    var isEnabled = true
    var isRightToLeft = false
    var handlers: PagesDrawerPanHandlers

    /// +1 when opening is rightward on screen (left-to-right layouts), -1 in right-to-left ones.
    private var openingSign: CGFloat { isRightToLeft ? -1 : 1 }

    /// Everything about the recognizer that follows the view's inputs, so the factory and the
    /// update path cannot drift apart and a test can reach it without a SwiftUI `Context`.
    static func configure(
        _ recognizer: PagesDrawerPanGestureRecognizer, mode: Mode, isEnabled: Bool, isRightToLeft: Bool
    ) {
        let openingSign: CGFloat = isRightToLeft ? -1 : 1
        recognizer.requiresEdgeZone = mode == .open
        recognizer.acceptedSign = mode == .open ? openingSign : -openingSign
        recognizer.isRightToLeft = isRightToLeft
        // Only on a change: assigning `isEnabled` cancels a gesture in flight.
        if recognizer.isEnabled != isEnabled { recognizer.isEnabled = isEnabled }
    }

    static func makeRecognizer(
        mode: Mode, isEnabled: Bool, isRightToLeft: Bool, delegate: UIGestureRecognizerDelegate
    ) -> PagesDrawerPanGestureRecognizer {
        let recognizer = PagesDrawerPanGestureRecognizer()
        recognizer.delegate = delegate
        // One finger: a second would shift the translation's centroid out from under the panel.
        recognizer.maximumNumberOfTouches = 1
        configure(recognizer, mode: mode, isEnabled: isEnabled, isRightToLeft: isRightToLeft)
        return recognizer
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> PagesDrawerPanGestureRecognizer {
        Self.makeRecognizer(
            mode: mode, isEnabled: isEnabled, isRightToLeft: isRightToLeft, delegate: context.coordinator)
    }

    func updateUIGestureRecognizer(_ recognizer: PagesDrawerPanGestureRecognizer, context: Context) {
        Self.configure(recognizer, mode: mode, isEnabled: isEnabled, isRightToLeft: isRightToLeft)
    }

    func handleUIGestureRecognizerAction(_ recognizer: PagesDrawerPanGestureRecognizer, context: Context) {
        // Window coordinates, as the swipe rows read them: the panel moves under the finger.
        switch swipeGestureEvent(for: recognizer.state) {
        case .began:
            // Zeroed at commitment, so the panel tracks the finger from here rather than jumping
            // the slop the recognizer spent deciding.
            recognizer.setTranslation(.zero, in: nil)
            handlers.began()
        case .changed:
            handlers.changed(recognizer.translation(in: nil).x * openingSign)
        case .ended:
            handlers.ended(
                recognizer.translation(in: nil).x * openingSign, recognizer.velocity(in: nil).x * openingSign)
        case .cancelled:
            handlers.cancelled()
        case nil:
            break
        }
    }

    /// Arbitration with the rest of the screen.
    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            pagesDrawerRunsAlongside(otherGestureRecognizer)
        }

        /// While a touch in the edge strip is still undecided, the navigation controller's back
        /// swipes (the edge one and iOS 26's content one) wait for this one. A touch outside the
        /// strip fails this recognizer on the spot, which releases them at once, so the real edge
        /// keeps going back. They are matched by identity — the navigation controller's own
        /// properties — not by guessing their class or the view they sit on.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard (gestureRecognizer as? PagesDrawerPanGestureRecognizer)?.requiresEdgeZone == true,
                let navigation = gestureRecognizer.view?.pagesDrawerNavigationController
            else { return false }
            return otherGestureRecognizer === navigation.interactivePopGestureRecognizer
                || otherGestureRecognizer === navigation.interactiveContentPopGestureRecognizer
        }
    }
}

/// Whether the drawer's recognizer may run at the same time as `other`: only a scroll view's own
/// pan, which the axis latch already keeps off vertical drags. Anything else — text selection
/// above all — is exclusive, so whichever recognizes first owns the touch.
@MainActor
func pagesDrawerRunsAlongside(_ other: UIGestureRecognizer) -> Bool {
    guard let scrollView = other.view as? UIScrollView else { return false }
    return other === scrollView.panGestureRecognizer
}

// MARK: - Presentation decisions

/// What a released — or system-cancelled — drag does to the presentation.
struct PagesDrawerFinish: Equatable {
    /// The value to write to `isPresented`, or nil when it already says so.
    var presented: Bool?
    /// Whether to tell VoiceOver the screen changed: only when the drag opened a closed drawer.
    /// A drag that leaves the drawer where it was, or closes it, says nothing.
    var announces: Bool
    /// Where the panel springs to.
    var target: CGFloat
}

func pagesDrawerFinish(settle: PagesDrawerSettle, wasPresented: Bool) -> PagesDrawerFinish {
    let opens = settle == .open
    return PagesDrawerFinish(
        presented: opens == wasPresented ? nil : opens, announces: opens && !wasPresented, target: opens ? 1 : 0)
}

/// What a change to `isPresented` does to the panel.
enum PagesDrawerPresentationStep: Equatable {
    /// The panel already sits at the target: a drag's release put it there.
    case unchanged
    /// Mount the drawer already open, with no entrance (Reduce Motion).
    case mountOpen
    /// Mount the drawer closed and spring it open once it has been drawn there.
    case mountForEntrance
    /// Spring the mounted panel to `target`.
    case animate(to: CGFloat)
}

/// The step for a change to `isPresented`, from wherever it came: the button, a scrim tap, a row,
/// the outline taking over, or a drag's own release.
///
/// A change from outside the drag wins over one in flight: the modifier stops tracking before it
/// asks, and the answer heads for the new value wherever the finger had the panel — the settle
/// threshold is not consulted.
func pagesDrawerPresentationStep(
    presented: Bool, progress: CGFloat, isMounted: Bool, reduceMotion: Bool
) -> PagesDrawerPresentationStep {
    let target: CGFloat = presented ? 1 : 0
    guard progress != target else { return .unchanged }
    if presented, !isMounted { return reduceMotion ? .mountOpen : .mountForEntrance }
    return .animate(to: target)
}

/// Whether a finished spring may take the drawer view down. Only the one that closed it: a reopen,
/// or a new drag, since then has taken over and needs the view.
func pagesDrawerShouldUnmount(target: CGFloat, progress: CGFloat, isPresented: Bool, isTracking: Bool) -> Bool {
    target == 0 && progress == 0 && !isPresented && !isTracking
}

/// Whether a drag may take hold of the panel. Not while one already has it, and not while the panel
/// is springing: `progress` then holds where the spring is heading, not where the panel is on
/// screen, so a drag started from it would make the panel jump before following the finger.
func pagesDrawerMayBeginDrag(isTracking: Bool, isSettling: Bool) -> Bool {
    !isTracking && !isSettling
}

// MARK: - Presentation

/// Presents the Pages drawer as a panel that follows a finger, and owns the drag's state so the
/// editor's already long modifier chain gains a single line.
///
/// `isPresented` stays the source of truth for "the drawer is open": a button, a scrim tap, a row
/// and a drag all end up setting it, and a change made from outside the drag wins over one in
/// flight. `progress` is the same fact as a fraction, so a drag can sit anywhere between.
///
/// Opening needs no gesture to be reachable: the toolbar button sets `isPresented`, and the drawer
/// springs in. The pan is a shortcut to the same place.
@MainActor
struct PagesDrawerPresentation<Drawer: View>: ViewModifier {
    @Binding var isPresented: Bool
    /// False while anything else is presented or asking to be, so the edge pull cannot open the
    /// drawer underneath it.
    let isGestureEnabled: Bool
    /// Runs when a drag — rather than the button — opened the drawer, so the editor can tell
    /// VoiceOver the screen changed.
    let onPresentedByDrag: () -> Void
    let drawer: (_ progress: CGFloat, _ pan: PagesDrawerPanHandlers) -> Drawer

    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 0 closed … 1 open. Set without animation while a finger is down.
    @State private var progress: CGFloat = 0
    /// Whether the drawer view exists. It outlives `isPresented` by the closing animation.
    @State private var isMounted = false
    @State private var isTracking = false
    /// A spring is moving the panel. Cleared by the completion of the latest one only, which
    /// `settleGeneration` tells apart from an earlier one it took over from.
    @State private var isSettling = false
    @State private var settleGeneration = 0
    @State private var dragStartProgress: CGFloat = 0
    /// The drawer has just been mounted closed and should spring open once it has drawn once.
    @State private var pendingEntrance = false
    @State private var panelWidth = PagesTreeLayout.panelWidth

    init(
        isPresented: Binding<Bool>, isGestureEnabled: Bool, onPresentedByDrag: @escaping () -> Void,
        @ViewBuilder drawer: @escaping (_ progress: CGFloat, _ pan: PagesDrawerPanHandlers) -> Drawer
    ) {
        _isPresented = isPresented
        self.isGestureEnabled = isGestureEnabled
        self.onPresentedByDrag = onPresentedByDrag
        self.drawer = drawer
    }

    func body(content: Content) -> some View {
        content
            .gesture(
                PagesDrawerPanGesture(
                    mode: .open, isEnabled: isGestureEnabled, isRightToLeft: layoutDirection == .rightToLeft,
                    handlers: handlers)
            )
            .onGeometryChange(for: CGFloat.self) {
                PagesTreeLayout.width(availableWidth: $0.size.width)
            } action: {
                panelWidth = $0
            }
            .overlay {
                if isMounted {
                    drawer(progress, handlers)
                        .onAppear(perform: runPendingEntrance)
                }
            }
            .onChange(of: isPresented) { _, presented in presentationChanged(presented) }
            .onAppear {
                if isPresented, !isMounted {
                    progress = 1
                    isMounted = true
                }
            }
    }

    // MARK: Drag

    private var handlers: PagesDrawerPanHandlers {
        PagesDrawerPanHandlers(
            began: {
                guard pagesDrawerMayBeginDrag(isTracking: isTracking, isSettling: isSettling) else { return }
                isTracking = true
                dragStartProgress = progress
                pendingEntrance = false
                isMounted = true
            },
            changed: { translation in
                guard isTracking else { return }
                progress = pagesDrawerProgress(
                    translation: translation, startProgress: dragStartProgress, panelWidth: panelWidth)
            },
            ended: { translation, velocity in
                guard isTracking else { return }
                let released = pagesDrawerProgress(
                    translation: translation, startProgress: dragStartProgress, panelWidth: panelWidth)
                progress = released
                finish(pagesDrawerSettle(progress: released, velocity: velocity, panelWidth: panelWidth))
            },
            cancelled: {
                // The system took the drag: settle from where the panel sits, as a release with no
                // velocity would.
                guard isTracking else { return }
                finish(pagesDrawerSettle(progress: progress, velocity: 0, panelWidth: panelWidth))
            })
    }

    private func finish(_ settle: PagesDrawerSettle) {
        isTracking = false
        let outcome = pagesDrawerFinish(settle: settle, wasPresented: isPresented)
        if let presented = outcome.presented { isPresented = presented }
        if outcome.announces { onPresentedByDrag() }
        animate(to: outcome.target)
    }

    // MARK: Button and other presenters

    private func presentationChanged(_ presented: Bool) {
        // A change from outside the drag (the button, a row, the outline taking over) wins over a
        // drag in flight, whose remaining callbacks are then ignored.
        isTracking = false
        let step = pagesDrawerPresentationStep(
            presented: presented, progress: progress, isMounted: isMounted, reduceMotion: reduceMotion)
        switch step {
        case .unchanged:
            break
        case .mountOpen:
            isMounted = true
            progress = 1
        case .mountForEntrance:
            isMounted = true
            pendingEntrance = true
        case .animate(let target):
            animate(to: target)
        }
    }

    /// The drawer was just mounted at 0; spring it open now that it has been drawn there once.
    private func runPendingEntrance() {
        guard pendingEntrance else { return }
        pendingEntrance = false
        animate(to: isPresented ? 1 : 0)
    }

    private func animate(to target: CGFloat) {
        settleGeneration += 1
        guard let animation = DocsMotion.animation(PagesDrawerMotion.settle, reduceMotion: reduceMotion) else {
            isSettling = false
            progress = target
            if target == 0 { isMounted = false }
            return
        }
        let generation = settleGeneration
        isSettling = true
        withAnimation(animation) {
            progress = target
        } completion: {
            if generation == settleGeneration { isSettling = false }
            if pagesDrawerShouldUnmount(
                target: target, progress: progress, isPresented: isPresented, isTracking: isTracking)
            {
                isMounted = false
            }
        }
    }
}

enum PagesDrawerMotion {
    /// A touch of overshoot on release. Reduce Motion replaces it with no animation at all
    /// (`DocsMotion.animation`), while the panel still follows the finger.
    static let settle: Animation = .spring(duration: 0.4, bounce: 0.15)
}
