import SwiftUI

enum IconButtonVariant {
    case ghost
    case soft
    case outline
}

enum IconButtonColor {
    case neutral
    case brand
    case danger
}

struct IconButtonStyleHex: Equatable {
    let backgroundLightHex: UInt32?
    let backgroundDarkHex: UInt32?
    let foregroundLightHex: UInt32
    let foregroundDarkHex: UInt32
    let borderLightHex: UInt32?
    let borderDarkHex: UInt32?
}

enum IconButtonStyleResolver {
    // Disabled is driven by view-level opacity (matching the reference), so the
    // resolver keeps each variant's own colors.
    static func style(variant: IconButtonVariant, color: IconButtonColor, isDisabled: Bool = false)
        -> IconButtonStyleHex
    {
        let foregroundLightHex: UInt32
        let foregroundDarkHex: UInt32
        let softLightHex: UInt32
        let softDarkHex: UInt32

        switch color {
        case .neutral:
            foregroundLightHex = DocsColorHex.textSecondary
            foregroundDarkHex = DocsColorHexDark.textSecondary
            softLightHex = DocsColorHex.surfaceMuted
            softDarkHex = DocsColorHexDark.surfaceMuted
        case .brand:
            // Reference IconButton brand hue is --text-brand.
            foregroundLightHex = DocsColorHex.textBrand
            foregroundDarkHex = DocsColorHexDark.textBrand
            softLightHex = DocsColorHex.brandFillSoft
            softDarkHex = DocsColorHexDark.brandFillSoft
        case .danger:
            foregroundLightHex = DocsColorHex.danger
            foregroundDarkHex = DocsColorHexDark.danger
            softLightHex = DocsColorHex.dangerSoft
            softDarkHex = DocsColorHexDark.dangerSoft
        }

        switch variant {
        case .ghost:
            return IconButtonStyleHex(
                backgroundLightHex: nil, backgroundDarkHex: nil,
                foregroundLightHex: foregroundLightHex, foregroundDarkHex: foregroundDarkHex,
                borderLightHex: nil, borderDarkHex: nil)
        case .soft:
            return IconButtonStyleHex(
                backgroundLightHex: softLightHex, backgroundDarkHex: softDarkHex,
                foregroundLightHex: foregroundLightHex, foregroundDarkHex: foregroundDarkHex,
                borderLightHex: nil, borderDarkHex: nil)
        case .outline:
            // Reference outline = raised surface fill + neutral hairline border + ink glyph.
            return IconButtonStyleHex(
                backgroundLightHex: DocsColorHex.surfaceRaised, backgroundDarkHex: DocsColorHexDark.surfaceRaised,
                foregroundLightHex: foregroundLightHex, foregroundDarkHex: foregroundDarkHex,
                borderLightHex: DocsColorHex.borderDefault, borderDarkHex: DocsColorHexDark.borderDefault)
        }
    }
}

enum IconButtonSize {
    case small
    case medium
    case large

    /// Tap-target box size (pt).
    var box: CGFloat {
        switch self {
        case .small: return 32
        case .medium: return 40
        case .large: return 44
        }
    }

    /// Glyph point size.
    var glyph: CGFloat {
        switch self {
        case .small: return 20
        case .medium: return 24
        case .large: return 26
        }
    }
}

struct IconButton: View {
    let icon: MaterialIcon
    let label: String
    var variant: IconButtonVariant = .ghost
    var color: IconButtonColor = .neutral
    var size: IconButtonSize = .medium
    var filled: Bool = false
    var isDisabled: Bool = false
    /// The floor on the tap target's **width**. 44pt by default, per iOS. A row
    /// of buttons sharing a fixed width — the editor's formatting bar — passes 0
    /// and lets them divide the space instead: nine 44pt minimums add up to more
    /// than an iPhone is wide, and a hard minimum does not compress, so the bar
    /// would silently push its whole screen wider than the display.
    /// The 44pt *height* is never negotiable.
    var minimumTapWidth: CGFloat = DocsSpacing.rowMinHeight
    var action: () -> Void

    var body: some View {
        let style = IconButtonStyleResolver.style(variant: variant, color: color, isDisabled: isDisabled)
        Button(action: action) {
            MaterialSymbol(icon, size: size.glyph, fill: filled)
                .frame(width: size.box, height: size.box)
                .foregroundStyle(Color(lightHex: style.foregroundLightHex, darkHex: style.foregroundDarkHex))
                .background(Color(lightHex: style.backgroundLightHex, darkHex: style.backgroundDarkHex) ?? .clear)
                .overlay(
                    RoundedRectangle(cornerRadius: DocsRadius.md)
                        .strokeBorder(
                            Color(lightHex: style.borderLightHex, darkHex: style.borderDarkHex) ?? .clear,
                            lineWidth: style.borderLightHex == nil ? 0 : 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: DocsRadius.md))
        }
        // Keep the reference's smaller visual box, but never let the tap target
        // fall below the 44pt iOS minimum (the reference documents this too).
        .frame(minWidth: minimumTapWidth, minHeight: DocsSpacing.rowMinHeight)
        .contentShape(Rectangle())
        .opacity(isDisabled ? 0.4 : 1)
        .disabled(isDisabled)
        .accessibilityLabel(label)
    }
}

#Preview {
    HStack(spacing: DocsSpacing.spaceSM) {
        IconButton(icon: .search, label: "Search", variant: .ghost, color: .neutral, action: {})
        IconButton(icon: .add, label: "Add", variant: .soft, color: .brand, action: {})
        IconButton(icon: .delete, label: "Delete", variant: .outline, color: .danger, action: {})
        IconButton(icon: .more_horiz, label: "More", isDisabled: true, action: {})
    }
    .padding()
}
