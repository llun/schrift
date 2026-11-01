import SwiftUI

/// The editor's micro-motion (Direction D "Tactile"): the checklist tick, the save status
/// settling, the formatting bar changing sets and a collaborator arriving.
///
/// Every decision lives here as a pure function of `reduceMotion`, so the rule is one place and
/// is unit-tested rather than re-spelled in four views. The rule is `DocsMotion`'s own:
/// Reduce Motion removes *movement* (scale, slides, springs); where something still has to
/// change visibly it becomes a plain opacity crossfade (`DocsMotion.crossfade`), and where it
/// need not it is instant. Haptics are not motion and are never gated on it.
extension DocsMotion {
    // MARK: Checklist

    /// How far the checkbox glyph swells when ticked or unticked.
    static let checklistPulseScale: CGFloat = 1.18

    /// Whether the checkbox swells at all. Scale is movement, so Reduce Motion skips it.
    static func checklistPulses(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    /// The swell's rise.
    static let checklistPulseRise: Animation = .snappy(duration: 0.12)
    /// The swell's settle back to rest — a small overshoot, so it reads as a tap landing.
    static let checklistPulseSettle: Animation = .spring(duration: 0.3, bounce: 0.4)

    /// Whether a completed row slides out (rather than only fading) when "Hide completed" is on.
    static func checklistCollapseMoves(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    /// How long a ticked row stays on screen, checked, before it leaves while "Hide completed"
    /// is on (`ChecklistSettling`) — long enough to see the tick land. Without Reduce Motion it
    /// is about the pulse, so the row starts to go as the swell settles; under Reduce Motion
    /// there is no pulse to wait for, so it is a shorter beat, just enough to read the ticked
    /// box before it fades.
    static func checklistSettleDelay(reduceMotion: Bool) -> Duration {
        reduceMotion ? .milliseconds(150) : .milliseconds(300)
    }

    /// The animation a settled tick's row leaves under while "Hide completed" is on: the row
    /// leaving and the rows below closing the gap. A plain crossfade under Reduce Motion.
    static func checklistCollapseAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? crossfade : .snappy(duration: 0.28)
    }

    /// A ticked row leaving the reading list. Arrival (unticking never brings one back while
    /// hiding, but a remote edit can) is a plain fade.
    static func checklistCollapseTransition(reduceMotion: Bool) -> AnyTransition {
        checklistCollapseMoves(reduceMotion: reduceMotion)
            ? .asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .leading)))
            : .opacity
    }

    // MARK: Save status

    /// Whether "Saving…" blurs into "Saved". Blur is not movement, but it is a flourish, so
    /// Reduce Motion gets the plain fade.
    static func saveStatusBlurs(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    /// The radius a status label blurs to while it leaves or arrives.
    static let saveStatusBlurRadius: CGFloat = 4

    /// Saving → Saved. Quiet by design: an ease, never a spring — it runs on every autosave.
    static func saveStatusAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? crossfade : .easeInOut(duration: 0.25)
    }

    static func saveStatusTransition(reduceMotion: Bool) -> AnyTransition {
        saveStatusBlurs(reduceMotion: reduceMotion)
            ? .modifier(
                active: BlurFadeModifier(radius: saveStatusBlurRadius), identity: BlurFadeModifier(radius: 0)
            ).combined(with: .opacity)
            : .opacity
    }

    /// Whether the "Saved" check draws itself in. Under Reduce Motion it is simply there.
    static func saveCheckDrawsIn(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    /// The check's stroke drawing in.
    static let saveCheckDraw: Animation = .easeOut(duration: 0.28)

    // MARK: Formatting bar

    /// The row of buttons giving way to a set of choices (and back).
    static func formattingBarSwitchAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? crossfade : .snappy(duration: 0.22)
    }

    /// Whether the incoming set grows slightly out of the button that was pressed.
    static func formattingBarSwitchScales(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    /// The scale a set starts from (or settles to) as it crossfades.
    static let formattingBarSwitchScale: CGFloat = 0.94

    static func formattingBarSwitchTransition(reduceMotion: Bool) -> AnyTransition {
        formattingBarSwitchScales(reduceMotion: reduceMotion)
            ? .opacity.combined(with: .scale(scale: formattingBarSwitchScale, anchor: .leading)) : .opacity
    }

    // MARK: Presence

    /// Whether a new collaborator's avatar springs in. A scale is movement, so Reduce Motion
    /// gets a plain fade.
    static func presenceArrivalSprings(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    /// The scale an arriving avatar springs in from.
    static let presenceArrivalScale: CGFloat = 0.4

    static func presenceArrivalAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? crossfade : .spring(duration: 0.4, bounce: 0.3)
    }

    /// An arriving avatar scales and fades in; a leaving one only fades, so it does not
    /// shrink away over its neighbours.
    static func presenceArrivalTransition(reduceMotion: Bool) -> AnyTransition {
        presenceArrivalSprings(reduceMotion: reduceMotion)
            ? .asymmetric(
                insertion: .scale(scale: presenceArrivalScale).combined(with: .opacity), removal: .opacity)
            : .opacity
    }
}

/// A blur that fades to nothing — the half of the save status transition that is not opacity.
struct BlurFadeModifier: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}
