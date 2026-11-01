import SwiftUI

/// How motion yields to **Reduce Motion** — the one place the mapping lives, so a screen
/// does not re-spell `reduceMotion ? nil : …` and drift.
///
/// Reduce Motion asks for less *movement* (slides, zooms, repeating sweeps); it does not ask
/// for the UI to stop changing. So the fallback is either no animation (the change lands
/// instantly) or, where an element appears and disappears, a short crossfade.
enum DocsMotion {
    /// The fade that replaces a slide when an element must still arrive visibly.
    static let crossfade: Animation = .easeInOut(duration: 0.15)

    /// `animation`, or `nil` — an instant change — when Reduce Motion is on.
    static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// Whether the toast slides up from the bottom edge. Under Reduce Motion it only fades.
    static func toastSlides(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    static func toastTransition(reduceMotion: Bool) -> AnyTransition {
        toastSlides(reduceMotion: reduceMotion)
            ? .move(edge: .bottom).combined(with: .opacity) : .opacity
    }

    /// The toast's presentation animation: the usual snappy slide, or a plain crossfade.
    static func toastAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? crossfade : .snappy
    }
}
