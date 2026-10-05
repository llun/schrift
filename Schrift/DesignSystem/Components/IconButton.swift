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

    /// All sizes share a circular 44pt control; the size axis changes the glyph only.
    var box: CGFloat { DocsSpacing.rowMinHeight }

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
    var action: () -> Void

    var body: some View {
        let style = IconButtonStyleResolver.style(variant: variant, color: color, isDisabled: isDisabled)
        Button(action: action) {
            // A fixed glyph stays centered inside the circular control at every
            // text size. VoiceOver reads the control's explicit label.
            MaterialSymbol(icon, size: size.glyph, fill: filled, scales: false)
                .frame(width: size.box, height: size.box)
                .foregroundStyle(Color(lightHex: style.foregroundLightHex, darkHex: style.foregroundDarkHex))
                .background(Color(lightHex: style.backgroundLightHex, darkHex: style.backgroundDarkHex) ?? .clear)
                .overlay(
                    Circle()
                        .strokeBorder(
                            Color(lightHex: style.borderLightHex, darkHex: style.borderDarkHex) ?? .clear,
                            lineWidth: style.borderLightHex == nil ? 0 : 1)
                )
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isDisabled ? 0.4 : 1)
        .disabled(isDisabled)
        .accessibilityLabel(label)
    }
}

private struct IconButtonPreview: View {
    var body: some View {
        VStack(spacing: DocsSpacing.spaceSM) {
            ForEach([IconButtonSize.small, .medium, .large], id: \.self) { size in
                HStack(spacing: DocsSpacing.spaceSM) {
                    IconButton(icon: .search, label: "Search", size: size, action: {})
                    IconButton(icon: .add, label: "Add", variant: .soft, color: .brand, size: size, action: {})
                    IconButton(
                        icon: .delete, label: "Delete", variant: .outline, color: .danger, size: size, action: {})
                    IconButton(icon: .more_horiz, label: "More", size: size, isDisabled: true, action: {})
                }
            }
        }
        .padding()
    }
}

#Preview("Light") { IconButtonPreview().preferredColorScheme(.light) }
#Preview("Dark") { IconButtonPreview().preferredColorScheme(.dark) }
