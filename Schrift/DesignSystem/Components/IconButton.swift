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
    let backgroundHex: UInt32?
    let foregroundHex: UInt32
    let borderHex: UInt32?
}

enum IconButtonStyleResolver {
    static func style(variant: IconButtonVariant, color: IconButtonColor, isDisabled: Bool) -> IconButtonStyleHex {
        if isDisabled {
            return IconButtonStyleHex(backgroundHex: nil, foregroundHex: DocsColorHex.textDisabled, borderHex: nil)
        }

        let foregroundHex: UInt32
        let softHex: UInt32

        switch color {
        case .neutral:
            foregroundHex = DocsColorHex.textSecondary
            softHex = DocsColorHex.surfaceMuted
        case .brand:
            foregroundHex = DocsColorHex.textBrandSecondary
            softHex = DocsColorHex.brandFillSoft
        case .danger:
            foregroundHex = DocsColorHex.danger
            softHex = DocsColorHex.dangerSoft
        }

        switch variant {
        case .ghost:
            return IconButtonStyleHex(backgroundHex: nil, foregroundHex: foregroundHex, borderHex: nil)
        case .soft:
            return IconButtonStyleHex(backgroundHex: softHex, foregroundHex: foregroundHex, borderHex: nil)
        case .outline:
            return IconButtonStyleHex(backgroundHex: nil, foregroundHex: foregroundHex, borderHex: foregroundHex)
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
    let systemImage: String
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
            Image(systemName: systemImage)
                .font(.system(size: size.glyph))
                .symbolVariant(filled ? .fill : .none)
                .frame(width: size.box, height: size.box)
                .foregroundStyle(Color(hex: style.foregroundHex))
                .background(style.backgroundHex.map { Color(hex: $0) } ?? Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: DocsRadius.md)
                        .strokeBorder(style.borderHex.map { Color(hex: $0) } ?? Color.clear, lineWidth: style.borderHex == nil ? 0 : 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: DocsRadius.md))
        }
        .disabled(isDisabled)
        .accessibilityLabel(label)
    }
}

#Preview {
    HStack(spacing: DocsSpacing.spaceSM) {
        IconButton(systemImage: "magnifyingglass", label: "Search", variant: .ghost, color: .neutral, action: {})
        IconButton(systemImage: "plus", label: "Add", variant: .soft, color: .brand, action: {})
        IconButton(systemImage: "trash", label: "Delete", variant: .outline, color: .danger, action: {})
        IconButton(systemImage: "ellipsis", label: "More", isDisabled: true, action: {})
    }
    .padding()
}
