import SwiftUI
import UIKit

// MARK: - Pure gates

/// Whether a drag has proved it is **not** a horizontal swipe, so the row's recognizer must
/// *refuse* it — as opposed to merely ignoring it — and leave the touch to the enclosing
/// scroll view.
///
/// **Refusing and ignoring are not the same thing, and mistaking one for the other is this
/// component's most expensive bug so far.** A recognizer that recognizes a drag and then
/// declines to act on it has still taken the touch; only a refused one gives it back.
///
/// The asymmetry with `.undecided` is deliberate: a drag inside the slop has proved nothing
/// yet and is left alone, because refusing that early would make a swipe that starts gently
/// impossible to perform at all.
func swipeGestureRefusesDrag(_ axis: SwipeDragAxis) -> Bool {
    axis == .vertical
}

/// The state the recognizer must move to when the axis lock refuses a drag — `nil` when there
/// is nothing to refuse.
///
/// **The two cases are not interchangeable, and this is the load-bearing half of the fix.**
/// `.failed` while the recognizer is still `.possible` hands the touch straight back to the
/// scroll view, which is the outcome that matters. Once the pan has begun on its own — it
/// commits at roughly the same distance this gate uses, so a diagonal can beat the gate to it
/// — `.failed` is not a legal transition, and `.cancelled` is what gets the recognizer out of
/// the way instead.
/// A state the recognizer has already left has nothing left to refuse, and `.cancelled` is not
/// a legal transition out of one — so those answer `nil` rather than prescribing a move UIKit
/// would reject.
func swipeGestureRefusalState(
    current: UIGestureRecognizer.State, axis: SwipeDragAxis
) -> UIGestureRecognizer.State? {
    guard swipeGestureRefusesDrag(axis) else { return nil }
    switch current {
    case .possible: return .failed
    case .began, .changed: return .cancelled
    default: return nil
    }
}

/// What one touch move means to the recognizer's axis latch.
///
/// This exists as a value function because the latch is the recognizer's only real state
/// machine, and "verified by hand" is precisely what shipped the unscrollable list.
enum SwipeGestureLatchDecision: Equatable {
    /// The drag committed horizontal on an earlier move. **The axis is decided once and then
    /// frozen** — a mid-gesture re-decision is what makes a hand-rolled swipe feel like it is
    /// fighting the list — so this move is not re-judged at all.
    case committed
    /// This move is what commits the drag to the horizontal axis.
    case commit
    /// Still inside the slop: nothing proved either way, keep watching.
    case wait
    /// Refuse the drag by moving to this state.
    case refuse(UIGestureRecognizer.State)
}

/// The whole of `touchesMoved`'s judgement, given how far the tracked touch has travelled from
/// where it started.
func swipeGestureLatchDecision(
    isHorizontal: Bool,
    current: UIGestureRecognizer.State,
    travel: CGSize,
    slop: CGFloat = SwipeRevealMetrics.slop,
    dominanceRatio: CGFloat = SwipeRevealMetrics.dominanceRatio
) -> SwipeGestureLatchDecision {
    guard !isHorizontal else { return .committed }
    let axis = swipeDragAxis(translation: travel, slop: slop, dominanceRatio: dominanceRatio)
    if let refusal = swipeGestureRefusalState(current: current, axis: axis) { return .refuse(refusal) }
    return axis == .horizontal ? .commit : .wait
}

/// What a recognizer state change means to the row.
enum SwipeGestureEvent: Equatable {
    case began
    case changed
    case ended
    case cancelled
}

/// Maps a recognizer's state onto the row's vocabulary; `nil` for the states the row has
/// nothing to do with.
///
/// **`.failed` is mapped defensively, not because the runtime reaches it.** UIKit sends action
/// messages for `.began`/`.changed`/`.ended`/`.cancelled` only, so a `.failed` transition is
/// never delivered here — and a refusal that late goes out as `.cancelled` anyway (see
/// `swipeGestureRefusalState`), from which the row does release its claim. Mapping `.failed`
/// alongside it costs nothing and states the intent: **anything that ends a drag without a
/// release must reach the row as a cancellation.** Left unmapped, `draggingRowID` would keep
/// naming a row nobody is dragging, `swipeRevealAfterScrollInteraction` would early-return
/// forever, and close-on-scroll would be dead list-wide until some other row completed a drag.
func swipeGestureEvent(for state: UIGestureRecognizer.State) -> SwipeGestureEvent? {
    switch state {
    case .began: return .began
    case .changed: return .changed
    case .ended: return .ended
    case .cancelled, .failed: return .cancelled
    default: return nil
    }
}

/// How far a flick keeps travelling after the finger lifts.
///
/// `DragGesture.Value.predictedEndTranslation` supplied this for free; a UIKit recognizer
/// reports a *velocity* instead, so the projection is spelled out here. It is Apple's own
/// (WWDC18, *Designing Fluid Interfaces*): `velocity ÷ 1000 × rate ÷ (1 − rate)`.
///
/// The rate it defaults to is `SwipeRevealMetrics.decelerationRate` — UIKit's **fast** one,
/// ~0.1s of further travel, deliberately not the normal scroll rate's ~0.5s. That choice and
/// its arithmetic live on the constant.
///
/// `velocity` is points per second — the unit `UIPanGestureRecognizer.velocity(in:)` reports.
/// A rate outside `(0, 1)` has no projection rather than a negative or infinite one.
func swipeFlickProjection(
    velocity: CGFloat,
    decelerationRate: CGFloat = SwipeRevealMetrics.decelerationRate
) -> CGFloat {
    guard decelerationRate > 0, decelerationRate < 1 else { return 0 }
    return (velocity / 1000) * decelerationRate / (1 - decelerationRate)
}

/// Where a released drag is heading: the travel so far, plus where its momentum carries it.
///
/// This is the whole of `DragGesture.Value.predictedEndTranslation`'s job, and it is a free
/// function so the settle decision can be driven end to end from a test rather than
/// re-assembled in one.
func swipeGestureEndTranslation(
    translation: CGFloat,
    velocity: CGFloat,
    decelerationRate: CGFloat = SwipeRevealMetrics.decelerationRate
) -> CGFloat {
    translation + swipeFlickProjection(velocity: velocity, decelerationRate: decelerationRate)
}

// MARK: - The recognizer

/// The row's pan recognizer — and the one place its arbitration with the enclosing scroll
/// view is actually settled.
///
/// **Why the axis gate lives in the recognizer and not in a gesture callback.** A SwiftUI
/// `DragGesture` is *recognized* for any drag past its `minimumDistance`, whichever way that
/// drag went; discarding the vertical ones inside `onChanged` reads like "the scroll view
/// still wins", but by then the recognizer has already claimed the touch. `.simultaneousGesture`
/// is meant to keep the scroll view running alongside it, and on iOS 26 it does not reliably
/// do so for the *ancestor* `ScrollView`'s pan — so on a screen where rows cover the whole
/// viewport there is nowhere left to start a scroll that a row does not answer first, and the
/// list simply does not move. That is the Home-cannot-scroll defect this type exists to fix.
///
/// Two things close it, and they are independent:
///
/// 1. This recognizer **refuses a drag the moment it proves non-horizontal** — `.failed`
///    before it began, `.cancelled` after (a pan begins on its own at roughly the same
///    distance this gate uses, so a diagonal can beat the gate to it). A refused recognizer
///    contends for nothing.
/// 2. Its delegate declares simultaneous recognition **at the UIKit level**, which is the
///    level the scroll view's pan actually arbitrates at.
///
/// The axis is decided **once** and then frozen for the session, exactly as before: a
/// mid-gesture re-decision is what makes a hand-rolled swipe feel like it is fighting the list.
final class SwipeRevealPanGestureRecognizer: UIPanGestureRecognizer {
    // `let`, not configurable knobs: nothing sets these, and a settable copy of a shared feel
    // constant is a second place for the gate and the row to disagree about the same swipe.
    // Tune `SwipeRevealMetrics` instead — on a device, as its own doc comment says.
    private let slop = SwipeRevealMetrics.slop
    private let dominanceRatio = SwipeRevealMetrics.dominanceRatio

    /// **The one touch this gesture is about.** `Set<UITouch>` is unordered, so judging each
    /// move by `touches.first` compares whichever finger UIKit happened to hand over against an
    /// origin latched from a possibly different one: rest a second finger on the list mid-swipe
    /// and the travel reads as a large vertical jump, which cancels the swipe in progress.
    /// Held weakly — the event system owns the touch for the life of the sequence.
    private weak var trackedTouch: UITouch?
    /// Where that touch started, in **window** coordinates, which is the same ruler
    /// `handleUIGestureRecognizerAction` reads translation and velocity in. Deliberately not the
    /// row's own space: the row slides out from under the finger as the strip opens, and
    /// measuring the drag in a space the drag is moving would feed the offset back into itself.
    private var origin: CGPoint?
    /// Set once the drag has proved horizontal, after which it is never re-judged.
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
        trackedTouch = touch
        origin = touch.location(in: nil)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        // Judged **before** `super`, which is what makes a refusal effective while the
        // recognizer is still `.possible`: one that has already begun cannot hand the touch
        // back, only cancel itself out of the way.
        if let trackedTouch, let origin, touches.contains(trackedTouch) {
            let point = trackedTouch.location(in: nil)
            switch swipeGestureLatchDecision(
                isHorizontal: isHorizontal, current: state,
                travel: CGSize(width: point.x - origin.x, height: point.y - origin.y),
                slop: slop, dominanceRatio: dominanceRatio)
            {
            case .refuse(let refusal):
                state = refusal
                return
            case .commit:
                isHorizontal = true
            case .wait, .committed:
                break
            }
        }
        super.touchesMoved(touches, with: event)
    }
}

// MARK: - The SwiftUI bridge

/// Bridges `SwipeRevealPanGestureRecognizer` into SwiftUI.
///
/// Reported in the row's own terms — an x-axis translation, and a flick-projected one on
/// release — so `SwipeRevealRow` keeps driving the same pure mappings
/// (`swipeRevealOffset`/`swipeRevealSettle`) it always has.
struct SwipeRevealGesture: UIGestureRecognizerRepresentable {
    /// The pan has begun. Usually that means the drag committed horizontal — but **not
    /// always**: a pan commits on its own at roughly the distance the axis gate uses, so a
    /// near-diagonal can reach `.began` before the gate has judged it and then be refused a
    /// move later. So a row claiming itself here may find the claim taken back through
    /// `onCancelled`, which is exactly what that callback is for. The cost is that such a drag
    /// briefly closes whichever sibling was open — the same thing a scroll does — and may nudge
    /// the row a point or two before settling back.
    var onBegan: () -> Void
    /// Live x-axis translation, in points.
    var onChanged: (CGFloat) -> Void
    /// The **flick-projected** x-axis translation on release — where the drag is heading, not
    /// where the finger stopped.
    var onEnded: (CGFloat) -> Void
    /// The system took the drag away (or the axis gate refused it late). The row settles from
    /// where it currently sits, as a release with no velocity would.
    var onCancelled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    /// Split out of `makeUIGestureRecognizer` so the delegate wiring is reachable from a test:
    /// dropping the assignment is exactly the edit that brings the unscrollable list back, and
    /// it is otherwise invisible to the suite (a `Context` cannot be constructed outside
    /// SwiftUI). What stays untested is the one line below that passes `context.coordinator` in.
    /// **The delegate is a `weak` property on `UIGestureRecognizer`.** SwiftUI owns the
    /// coordinator it hands in here, so production is fine — but a caller passing a temporary
    /// gets a recognizer whose delegate is already nil, and with it the either/or arbitration
    /// that made Home unscrollable.
    static func makeRecognizer(delegate: UIGestureRecognizerDelegate) -> SwipeRevealPanGestureRecognizer {
        let recognizer = SwipeRevealPanGestureRecognizer()
        recognizer.delegate = delegate
        // A row swipe is a one-finger gesture. The tracked-touch bookkeeping already keeps the
        // *axis gate* honest with a second finger down — it reads that one touch's location —
        // but `super`'s `translation(in:)` is the centroid of every touch the pan accepts, and
        // that is what the row's offset follows. So a finger landing mid-swipe drags the strip
        // off the finger that is actually swiping — by a jump if UIKit does not re-base the
        // translation across the touch-count change (undocumented), and by half speed if it
        // does. Either way this keeps the extra touch away from it.
        recognizer.maximumNumberOfTouches = 1
        return recognizer
    }

    func makeUIGestureRecognizer(context: Context) -> SwipeRevealPanGestureRecognizer {
        Self.makeRecognizer(delegate: context.coordinator)
    }

    func updateUIGestureRecognizer(_ recognizer: SwipeRevealPanGestureRecognizer, context: Context) {}

    func handleUIGestureRecognizerAction(_ recognizer: SwipeRevealPanGestureRecognizer, context: Context) {
        // Measured in the **window** (`in: nil`), never in `recognizer.view`. The row this
        // recognizer sits on is `.offset` during the drag, and reading the translation in a
        // space the drag is itself moving would feed the row's own displacement back into the
        // next reading. It is also the ruler the axis gate uses, so the two cannot disagree.
        switch swipeGestureEvent(for: recognizer.state) {
        case .began:
            // Zeroed at the moment of commitment, so the row tracks the finger from *here*
            // rather than jumping the slop the recognizer spent deciding. It also keeps
            // `onBegan` and `onChanged` from having to run in one turn, which would make the
            // row's own claim a read-after-write on the binding it just assigned.
            recognizer.setTranslation(.zero, in: nil)
            onBegan()
        case .changed:
            onChanged(recognizer.translation(in: nil).x)
        case .ended:
            onEnded(
                swipeGestureEndTranslation(
                    translation: recognizer.translation(in: nil).x,
                    velocity: recognizer.velocity(in: nil).x))
        case .cancelled:
            onCancelled()
        case nil:
            break
        }
    }

    /// **The half of the fix SwiftUI cannot express.** The enclosing `ScrollView`'s pan is an
    /// *ancestor* recognizer, and UIKit's default for two recognizers that both want a touch
    /// is that only one gets it. Saying so here — rather than through
    /// `.simultaneousGesture`, whose reach stops at the view's own gestures — is what keeps
    /// the list scrolling while a row is swipeable.
    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
