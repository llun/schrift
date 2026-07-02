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
    static func style(variant: ButtonVariant, color: ButtonColor, isDisabled: Bool) -> ButtonStyleHex {
        if isDisabled {
            return ButtonStyleHex(backgroundHex: DocsColorHex.surfaceMuted, foregroundHex: DocsColorHex.textDisabled, borderHex: nil)
        }

        let fillHex: UInt32
        let softHex: UInt32
        let onFillHex: UInt32
        let softForegroundHex: UInt32

        switch color {
        case .brand:
            fillHex = DocsColorHex.brandFill
            softHex = DocsColorHex.brandFillSoft
            onFillHex = DocsColorHex.textOnBrand
            softForegroundHex = DocsColorHex.textBrandSecondary
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
            return ButtonStyleHex(backgroundHex: nil, foregroundHex: softForegroundHex, borderHex: softForegroundHex)
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
            HStack(spacing: DocsSpacing.spaceXS) {
                if let icon {
                    Image(systemName: icon)
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
