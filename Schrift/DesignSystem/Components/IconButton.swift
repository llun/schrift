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
    static func style(
        variant: IconButtonVariant, color: IconButtonColor, isDisabled: Bool = false, theme: AppTheme = .white
    )
        -> IconButtonStyleHex
    {
        let light = DocsPalette(theme: theme, isDark: false)
        let dark = DocsPalette(theme: theme, isDark: true)
        let foregroundLightHex: UInt32
        let foregroundDarkHex: UInt32
        let softLightHex: UInt32
        let softDarkHex: UInt32

        switch color {
        case .neutral:
            foregroundLightHex = light.textSecondary
            foregroundDarkHex = dark.textSecondary
            softLightHex = light.surfaceMuted
            softDarkHex = dark.surfaceMuted
        case .brand:
            // Reference IconButton brand hue is --text-brand.
            foregroundLightHex = light.textBrand
            foregroundDarkHex = dark.textBrand
            softLightHex = light.brandFillSoft
            softDarkHex = dark.brandFillSoft
        case .danger:
            foregroundLightHex = light.danger
            foregroundDarkHex = dark.danger
            softLightHex = light.dangerSoft
            softDarkHex = dark.dangerSoft
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
                backgroundLightHex: light.surfaceRaised, backgroundDarkHex: dark.surfaceRaised,
                foregroundLightHex: foregroundLightHex, foregroundDarkHex: foregroundDarkHex,
                borderLightHex: light.borderDefault, borderDarkHex: dark.borderDefault)
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
    @Environment(\.docsTheme) private var theme
    let icon: MaterialIcon
    let label: String
    var variant: IconButtonVariant = .ghost
    var color: IconButtonColor = .neutral
    var size: IconButtonSize = .medium
    var filled: Bool = false
    var isDisabled: Bool = false
    var action: () -> Void
    /// An optional secondary action on a long press, e.g. the formatting bar's list button
    /// offering every list kind. A trailing closure still binds to `action`, the first
    /// closure parameter without a default. VoiceOver reaches it as a named custom action (`longPressLabel`), since a
    /// long press is not something a VoiceOver user can discover.
    var longPressAction: (() -> Void)? = nil
    var longPressLabel: String? = nil

    var body: some View {
        let style = IconButtonStyleResolver.style(variant: variant, color: color, isDisabled: isDisabled, theme: theme)
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
        // Simultaneous, so the plain tap keeps working; the caller ignores the tap that
        // ends a successful long press (the formatting bar swaps the row out first).
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in longPressAction?() },
            isEnabled: longPressAction != nil && !isDisabled
        )
        .opacity(isDisabled ? 0.4 : 1)
        .disabled(isDisabled)
        .accessibilityLabel(label)
        .accessibilityActions {
            if let longPressAction, let longPressLabel, !isDisabled {
                Button(longPressLabel, action: longPressAction)
            }
        }
    }
}

private struct IconButtonPreview: View {
    @Environment(\.docsTheme) private var theme
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
