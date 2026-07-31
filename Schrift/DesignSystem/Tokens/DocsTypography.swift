import SwiftUI
import UIKit

/// A type token: the point size and weight the handoff specifies, plus the
/// Dynamic Type ramp it rides.
///
/// The handoff's iOS sizes are the HIG defaults at the Large content size, so
/// every token maps 1:1 onto a system text style (34 → `.largeTitle`, 28 →
/// `.title`, 22 → `.title2`, 17 → `.headline`/`.body`, 16 → `.callout`, 15 →
/// `.subheadline`, 13 → `.footnote`, 12 → `.caption`). That is what lets the app
/// scale with the user's text-size setting while looking byte-identical to the
/// handoff at the default size. `size` remains the reference value — it is what
/// tracking is derived from and what the UIKit editor scales from.
struct TypographySpec: Equatable {
    let size: CGFloat
    let weight: Font.Weight
    /// The system text style this token scales with.
    let textStyle: Font.TextStyle
}

enum DocsTypographySpec {
    static let largeTitle = TypographySpec(size: 34, weight: .bold, textStyle: .largeTitle)
    static let title1 = TypographySpec(size: 28, weight: .bold, textStyle: .title)
    static let title2 = TypographySpec(size: 22, weight: .bold, textStyle: .title2)
    static let headline = TypographySpec(size: 17, weight: .semibold, textStyle: .headline)
    static let body = TypographySpec(size: 17, weight: .regular, textStyle: .body)
    static let callout = TypographySpec(size: 16, weight: .regular, textStyle: .callout)
    static let subhead = TypographySpec(size: 15, weight: .regular, textStyle: .subheadline)
    static let footnote = TypographySpec(size: 13, weight: .regular, textStyle: .footnote)
    static let caption = TypographySpec(size: 12, weight: .regular, textStyle: .caption)
    static let code = TypographySpec(size: 15, weight: .regular, textStyle: .subheadline)
}

/// Letter-spacing scale (`--tracking-*`), expressed as an em fraction.
/// Apply with `.docsTracking(spec, DocsTracking.tight)` so the spacing scales
/// with the text it belongs to.
enum DocsTracking {
    static let tight: CGFloat = -0.02
    static let wide: CGFloat = 0.01
    /// Uppercase screen "eyebrow" section labels (`letter-spacing: 0.05em`).
    static let eyebrow: CGFloat = 0.05
    /// Grouped-list card headers (`letter-spacing: 0.04em`).
    static let groupedHeader: CGFloat = 0.04
}

enum DocsFont {
    static let largeTitle = font(DocsTypographySpec.largeTitle)
    static let title1 = font(DocsTypographySpec.title1)
    static let title2 = font(DocsTypographySpec.title2)
    static let headline = font(DocsTypographySpec.headline)
    static let body = font(DocsTypographySpec.body)
    static let callout = font(DocsTypographySpec.callout)
    static let subhead = font(DocsTypographySpec.subhead)
    static let footnote = font(DocsTypographySpec.footnote)
    static let caption = font(DocsTypographySpec.caption)
    static let code = font(DocsTypographySpec.code, design: .monospaced)

    private static func font(_ spec: TypographySpec, design: Font.Design? = nil) -> Font {
        .system(spec.textStyle, design: design, weight: spec.weight)
    }
}

/// The UIKit twin of `TypographySpec.textStyle`, for the block editor's
/// `UITextView`s — the one place the app builds fonts through UIKit rather than
/// SwiftUI. Pure so the mapping is testable without a view.
func uiFontTextStyle(for textStyle: Font.TextStyle) -> UIFont.TextStyle {
    switch textStyle {
    case .largeTitle: .largeTitle
    case .title: .title1
    case .title2: .title2
    case .title3: .title3
    case .headline: .headline
    case .subheadline: .subheadline
    case .body: .body
    case .callout: .callout
    case .footnote: .footnote
    case .caption: .caption1
    case .caption2: .caption2
    @unknown default: .body
    }
}

/// Scales a UIKit font built at a token's reference size to the current content
/// size category, so text in the block editor tracks Dynamic Type like every
/// SwiftUI label does.
func scaledUIFont(_ font: UIFont, for spec: TypographySpec) -> UIFont {
    UIFontMetrics(forTextStyle: uiFontTextStyle(for: spec.textStyle)).scaledFont(for: font)
}

extension View {
    /// Letter-spacing for a token, scaled with the text it decorates.
    ///
    /// `.tracking` takes points, so a fixed value drifts visibly once the text
    /// itself grows — an eyebrow label at an accessibility size would end up
    /// far too tight.
    func docsTracking(_ spec: TypographySpec, _ ratio: CGFloat) -> some View {
        modifier(ScaledTracking(base: spec.size * ratio, textStyle: spec.textStyle))
    }

    /// A font at an exact point size that still scales with Dynamic Type.
    ///
    /// Reach for this only where the handoff specifies a size that is *not* on
    /// the HIG ramp and so has no `DocsFont` token — the 14pt medium button
    /// label is the motivating case. Everywhere else use `DocsFont.*`, which
    /// rides a text style directly.
    func docsScaledFont(size: CGFloat, weight: Font.Weight, relativeTo textStyle: Font.TextStyle) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight, textStyle: textStyle))
    }
}

private struct ScaledTracking: ViewModifier {
    @ScaledMetric private var amount: CGFloat

    init(base: CGFloat, textStyle: Font.TextStyle) {
        _amount = ScaledMetric(wrappedValue: base, relativeTo: textStyle)
    }

    func body(content: Content) -> some View {
        content.tracking(amount)
    }
}

private struct ScaledSystemFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight

    init(size: CGFloat, weight: Font.Weight, textStyle: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight))
    }
}
