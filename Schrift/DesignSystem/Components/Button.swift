import SwiftUI

enum ButtonVariant {
    case primary
    case secondary
    case tertiary
    case outline
}

enum ButtonColor {
    case brand
    case neutral
    case danger
}

struct ButtonStyleHex: Equatable {
    let backgroundLightHex: UInt32?
    let backgroundDarkHex: UInt32?
    let foregroundLightHex: UInt32
    let foregroundDarkHex: UInt32
    let borderLightHex: UInt32?
    let borderDarkHex: UInt32?
}

enum ButtonStyleResolver {
    // The disabled look is driven purely by lowering opacity at the view level
    // (matching the reference), so the resolver keeps each variant's own colors.
    static func style(variant: ButtonVariant, color: ButtonColor, isDisabled: Bool = false) -> ButtonStyleHex {
        let fillLightHex: UInt32
        let fillDarkHex: UInt32
        let softLightHex: UInt32
        let softDarkHex: UInt32
        let onFillLightHex: UInt32
        let onFillDarkHex: UInt32
        let softForegroundLightHex: UInt32
        let softForegroundDarkHex: UInt32

        switch color {
        case .brand:
            fillLightHex = DocsColorHex.brandFill
            fillDarkHex = DocsColorHexDark.brandFill
            softLightHex = DocsColorHex.brandFillSoft
            softDarkHex = DocsColorHexDark.brandFillSoft
            onFillLightHex = DocsColorHex.textOnBrand
            onFillDarkHex = DocsColorHexDark.textOnBrand
            // Reference Button hues use --text-brand as the ink for soft/ghost/outline.
            softForegroundLightHex = DocsColorHex.textBrand
            softForegroundDarkHex = DocsColorHexDark.textBrand
        case .neutral:
            fillLightHex = DocsColorHex.textPrimary
            fillDarkHex = DocsColorHexDark.textPrimary
            softLightHex = DocsColorHex.surfaceMuted
            softDarkHex = DocsColorHexDark.surfaceMuted
            onFillLightHex = DocsColorHex.textOnBrand
            onFillDarkHex = DocsColorHexDark.textOnBrand
            softForegroundLightHex = DocsColorHex.textPrimary
            softForegroundDarkHex = DocsColorHexDark.textPrimary
        case .danger:
            fillLightHex = DocsColorHex.danger
            fillDarkHex = DocsColorHexDark.danger
            softLightHex = DocsColorHex.dangerSoft
            softDarkHex = DocsColorHexDark.dangerSoft
            onFillLightHex = DocsColorHex.textOnBrand
            onFillDarkHex = DocsColorHexDark.textOnBrand
            softForegroundLightHex = DocsColorHex.danger
            softForegroundDarkHex = DocsColorHexDark.danger
        }

        switch variant {
        case .primary:
            return ButtonStyleHex(
                backgroundLightHex: fillLightHex, backgroundDarkHex: fillDarkHex,
                foregroundLightHex: onFillLightHex, foregroundDarkHex: onFillDarkHex,
                borderLightHex: nil, borderDarkHex: nil)
        case .secondary:
            return ButtonStyleHex(
                backgroundLightHex: softLightHex, backgroundDarkHex: softDarkHex,
                foregroundLightHex: softForegroundLightHex, foregroundDarkHex: softForegroundDarkHex,
                borderLightHex: nil, borderDarkHex: nil)
        case .tertiary:
            return ButtonStyleHex(
                backgroundLightHex: nil, backgroundDarkHex: nil,
                foregroundLightHex: softForegroundLightHex, foregroundDarkHex: softForegroundDarkHex,
                borderLightHex: nil, borderDarkHex: nil)
        case .outline:
            // Reference outline = raised surface fill + neutral hairline border + ink label.
            return ButtonStyleHex(
                backgroundLightHex: DocsColorHex.surfaceRaised, backgroundDarkHex: DocsColorHexDark.surfaceRaised,
                foregroundLightHex: softForegroundLightHex, foregroundDarkHex: softForegroundDarkHex,
                borderLightHex: DocsColorHex.borderDefault, borderDarkHex: DocsColorHexDark.borderDefault)
        }
    }
}

enum ButtonSize {
    case small
    case medium
    case large

    var height: CGFloat {
        switch self {
        case .small: return 32
        case .medium: return 40
        case .large: return 52
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .small: return 12
        case .medium: return 16
        case .large: return 22
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .small: return 13
        case .medium: return 14
        case .large: return 16
        }
    }

    /// Leading-glyph point size — distinct from (and larger than) the label,
    /// matching the reference `iconSize` per size at weight 500.
    var iconSize: CGFloat {
        switch self {
        case .small: return 18
        case .medium: return 20
        case .large: return 22
        }
    }

    /// Icon-to-label gap (reference `gap` per size).
    var iconGap: CGFloat {
        switch self {
        case .small: return DocsSpacing.space2xs
        case .medium, .large: return DocsSpacing.spaceXS
        }
    }
}

/// Builds an adaptive `Color` from a paired light/dark hex, or `.clear` when
/// the pair is absent (e.g. a variant with no background/border). The resolver
/// always sets both halves of a pair together, so a nil light hex implies a
/// nil dark hex.
private func optionalAdaptiveColor(lightHex: UInt32?, darkHex: UInt32?) -> Color {
    guard let lightHex, let darkHex else { return .clear }
    return Color(lightHex: lightHex, darkHex: darkHex)
}

struct DocsButton: View {
    let title: String
    var variant: ButtonVariant = .primary
    var color: ButtonColor = .brand
    var size: ButtonSize = .medium
    var icon: String? = nil
    var fullWidth: Bool = false
    var pill: Bool = false
    var isDisabled: Bool = false
    var action: () -> Void

    var body: some View {
        let style = ButtonStyleResolver.style(variant: variant, color: color, isDisabled: isDisabled)
        Button(action: action) {
            HStack(spacing: size.iconGap) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: size.iconSize, weight: .medium))
                }
                Text(title)
                    .font(.system(size: size.fontSize, weight: .semibold))
            }
            .padding(.horizontal, size.horizontalPadding)
            .frame(height: size.height)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .foregroundStyle(Color(lightHex: style.foregroundLightHex, darkHex: style.foregroundDarkHex))
            .background(optionalAdaptiveColor(lightHex: style.backgroundLightHex, darkHex: style.backgroundDarkHex))
            .overlay(
                RoundedRectangle(cornerRadius: pill ? DocsRadius.pill : DocsRadius.sm)
                    .strokeBorder(
                        optionalAdaptiveColor(lightHex: style.borderLightHex, darkHex: style.borderDarkHex),
                        lineWidth: style.borderLightHex == nil ? 0 : 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: pill ? DocsRadius.pill : DocsRadius.sm))
        }
        .opacity(isDisabled ? 0.4 : 1)
        .disabled(isDisabled)
    }
}

#Preview {
    VStack(spacing: DocsSpacing.spaceSM) {
        DocsButton(title: "Primary", variant: .primary, color: .brand, action: {})
        DocsButton(title: "Secondary", variant: .secondary, color: .brand, action: {})
        DocsButton(title: "Tertiary", variant: .tertiary, color: .brand, action: {})
        DocsButton(title: "Outline", variant: .outline, color: .brand, action: {})
        DocsButton(title: "Danger", variant: .primary, color: .danger, action: {})
        DocsButton(title: "Disabled", variant: .primary, color: .brand, isDisabled: true, action: {})
    }
    .padding()
}
