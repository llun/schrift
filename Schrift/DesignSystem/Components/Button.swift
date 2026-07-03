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
    let backgroundHex: UInt32?
    let foregroundHex: UInt32
    let borderHex: UInt32?
}

enum ButtonStyleResolver {
    // The disabled look is driven purely by lowering opacity at the view level
    // (matching the reference), so the resolver keeps each variant's own colors.
    static func style(variant: ButtonVariant, color: ButtonColor, isDisabled: Bool = false) -> ButtonStyleHex {
        let fillHex: UInt32
        let softHex: UInt32
        let onFillHex: UInt32
        let softForegroundHex: UInt32

        switch color {
        case .brand:
            fillHex = DocsColorHex.brandFill
            softHex = DocsColorHex.brandFillSoft
            onFillHex = DocsColorHex.textOnBrand
            // Reference Button hues use --text-brand as the ink for soft/ghost/outline.
            softForegroundHex = DocsColorHex.textBrand
        case .neutral:
            fillHex = DocsColorHex.textPrimary
            softHex = DocsColorHex.surfaceMuted
            onFillHex = DocsColorHex.textOnBrand
            softForegroundHex = DocsColorHex.textPrimary
        case .danger:
            fillHex = DocsColorHex.danger
            softHex = DocsColorHex.dangerSoft
            onFillHex = DocsColorHex.textOnBrand
            softForegroundHex = DocsColorHex.danger
        }

        switch variant {
        case .primary:
            return ButtonStyleHex(backgroundHex: fillHex, foregroundHex: onFillHex, borderHex: nil)
        case .secondary:
            return ButtonStyleHex(backgroundHex: softHex, foregroundHex: softForegroundHex, borderHex: nil)
        case .tertiary:
            return ButtonStyleHex(backgroundHex: nil, foregroundHex: softForegroundHex, borderHex: nil)
        case .outline:
            // Reference outline = raised surface fill + neutral hairline border + ink label.
            return ButtonStyleHex(backgroundHex: DocsColorHex.surfaceRaised, foregroundHex: softForegroundHex, borderHex: DocsColorHex.borderDefault)
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
            .foregroundStyle(Color(hex: style.foregroundHex))
            .background(style.backgroundHex.map { Color(hex: $0) } ?? Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: pill ? DocsRadius.pill : DocsRadius.sm)
                    .strokeBorder(style.borderHex.map { Color(hex: $0) } ?? Color.clear, lineWidth: style.borderHex == nil ? 0 : 1)
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
