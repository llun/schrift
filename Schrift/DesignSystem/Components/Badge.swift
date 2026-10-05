import SwiftUI

enum BadgeTone {
    case accent
    case neutral
    case danger
    case success
    case warning
    case info
}

struct BadgeStyleHex: Equatable {
    let backgroundLightHex: UInt32
    let backgroundDarkHex: UInt32
    let foregroundLightHex: UInt32
    let foregroundDarkHex: UInt32
}

enum BadgeStyleResolver {
    // Foregrounds match the prototype's Cunningham badge tones: the deeper
    // -650 / -strong inks (not the -550 body colors) for readable pills.
    static func style(tone: BadgeTone, theme: AppTheme = .white) -> BadgeStyleHex {
        let light = DocsPalette(theme: theme, isDark: false)
        let dark = DocsPalette(theme: theme, isDark: true)
        switch tone {
        case .accent:
            return BadgeStyleHex(
                backgroundLightHex: light.brandFillSoft, backgroundDarkHex: dark.brandFillSoft,
                foregroundLightHex: light.textBrandSecondary,
                foregroundDarkHex: dark.textBrandSecondary)
        case .neutral:
            return BadgeStyleHex(
                backgroundLightHex: light.gray100, backgroundDarkHex: dark.gray100,
                foregroundLightHex: light.gray600, foregroundDarkHex: dark.gray600)
        case .danger:
            return BadgeStyleHex(
                backgroundLightHex: light.dangerSoft, backgroundDarkHex: dark.dangerSoft,
                foregroundLightHex: light.dangerStrong, foregroundDarkHex: dark.dangerStrong)
        case .success:
            return BadgeStyleHex(
                backgroundLightHex: light.successSoft, backgroundDarkHex: dark.successSoft,
                foregroundLightHex: light.success650, foregroundDarkHex: dark.success650)
        case .warning:
            return BadgeStyleHex(
                backgroundLightHex: light.warningSoft, backgroundDarkHex: dark.warningSoft,
                foregroundLightHex: light.warning650, foregroundDarkHex: dark.warning650)
        case .info:
            return BadgeStyleHex(
                backgroundLightHex: light.infoSoft, backgroundDarkHex: dark.infoSoft,
                foregroundLightHex: light.info650, foregroundDarkHex: dark.info650)
        }
    }
}

struct Badge: View {
    @Environment(\.docsTheme) private var theme
    let text: String
    var tone: BadgeTone = .neutral
    var icon: MaterialIcon? = nil
    /// Leading status dot (used by the Profile "• Connected" server badge).
    var dot: Bool = false

    var body: some View {
        let style = BadgeStyleResolver.style(tone: tone, theme: theme)
        let foreground = Color(lightHex: style.foregroundLightHex, darkHex: style.foregroundDarkHex)
        HStack(spacing: DocsSpacing.space3xs) {
            if dot {
                Circle()
                    .fill(foreground)
                    .frame(width: 6, height: 6)
            }
            if let icon {
                MaterialSymbol(icon, size: 14)
            }
            Text(text)
                .font(DocsFont.caption.weight(.semibold))
        }
        .padding(.horizontal, DocsSpacing.spaceXS)
        .padding(.vertical, 5)
        .foregroundStyle(foreground)
        .background(Color(lightHex: style.backgroundLightHex, darkHex: style.backgroundDarkHex))
        .clipShape(RoundedRectangle(cornerRadius: DocsRadius.lg))
    }
}

#Preview {
    HStack(spacing: DocsSpacing.spaceXS) {
        Badge(text: "Admin", tone: .accent)
        Badge(text: "3", tone: .neutral)
        Badge(text: "Failed", tone: .danger, icon: .cancel)
        Badge(text: "Active", tone: .success)
        Badge(text: "Pending", tone: .warning)
        Badge(text: "Info", tone: .info)
    }
    .padding()
}

#Preview("Dark") {
    HStack(spacing: DocsSpacing.spaceXS) {
        Badge(text: "Admin", tone: .accent)
        Badge(text: "3", tone: .neutral)
        Badge(text: "Failed", tone: .danger, icon: .cancel)
        Badge(text: "Active", tone: .success)
        Badge(text: "Pending", tone: .warning)
        Badge(text: "Info", tone: .info)
    }
    .padding()
    .preferredColorScheme(.dark)
}
