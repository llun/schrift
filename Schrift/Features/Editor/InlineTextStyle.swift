import SwiftUI
import UIKit

/// How a run of inline-marked text is drawn in the block editor.
///
/// Raw values, not `UIFont`/`UIColor`: the resolver stays a pure, `Equatable`,
/// UIKit-free function, and `BlockTextView` converts to attributes at render
/// time — the same split the design-system style resolvers use.
struct InlineTextStyle: Equatable {
    var isBold = false
    var isItalic = false
    var isMonospaced = false
    var isStruckThrough = false
    var isUnderlined = false
    /// nil inherits the block's own text color. Both set together (never one
    /// without the other) so the color stays dark-mode adaptive via
    /// `Color(lightHex:darkHex:)` — the same optional-pair convention as
    /// `ButtonStyleHex`/`IconButtonStyleHex`.
    var foregroundLightHex: UInt32?
    var foregroundDarkHex: UInt32?
}

enum InlineTextStyleResolver {
    /// Marks arrive outermost-first and compose: a bold link is blue, underlined
    /// and bold. Inline code wins the font, since a monospaced italic is not a
    /// distinction anyone reads.
    static func style(for marks: [InlineMark]) -> InlineTextStyle {
        var style = InlineTextStyle()
        for mark in marks {
            switch mark {
            case .bold:
                style.isBold = true
            case .italic:
                style.isItalic = true
            case .code:
                style.isMonospaced = true
            case .strike:
                style.isStruckThrough = true
            case .link:
                style.isUnderlined = true
                style.foregroundLightHex = DocsColorHex.textBrand
                style.foregroundDarkHex = DocsColorHexDark.textBrand
            }
        }
        return style
    }
}

/// The `NSAttributedString` attributes for a marked run, over the block's own
/// font. The one place raw values become UIKit objects.
func inlineTextAttributes(for marks: [InlineMark], base: UIFont) -> [NSAttributedString.Key: Any] {
    let style = InlineTextStyleResolver.style(for: marks)
    var attributes: [NSAttributedString.Key: Any] = [.font: inlineFont(for: style, base: base)]
    if let color = Color(lightHex: style.foregroundLightHex, darkHex: style.foregroundDarkHex) {
        attributes[.foregroundColor] = UIColor(color)
    }
    if style.isUnderlined {
        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
    }
    if style.isStruckThrough {
        attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
    }
    return attributes
}

/// Inline code takes the monospaced face outright: a monospaced italic is not a
/// distinction anyone reads. Everything else composes onto the block's own font,
/// so a bold span inside a heading stays heading-sized.
private func inlineFont(for style: InlineTextStyle, base: UIFont) -> UIFont {
    if style.isMonospaced {
        return .monospacedSystemFont(ofSize: base.pointSize, weight: style.isBold ? .bold : .regular)
    }
    var traits = base.fontDescriptor.symbolicTraits
    if style.isBold { traits.insert(.traitBold) }
    if style.isItalic { traits.insert(.traitItalic) }
    guard let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
    return UIFont(descriptor: descriptor, size: base.pointSize)
}
