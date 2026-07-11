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
    static func style(tone: BadgeTone) -> BadgeStyleHex {
        switch tone {
        case .accent:
            return BadgeStyleHex(
                backgroundLightHex: DocsColorHex.brandFillSoft, backgroundDarkHex: DocsColorHexDark.brandFillSoft,
                foregroundLightHex: DocsColorHex.textBrandSecondary,
                foregroundDarkHex: DocsColorHexDark.textBrandSecondary)
        case .neutral:
            return BadgeStyleHex(
                backgroundLightHex: DocsColorHex.gray100, backgroundDarkHex: DocsColorHexDark.gray100,
                foregroundLightHex: DocsColorHex.gray600, foregroundDarkHex: DocsColorHexDark.gray600)
        case .danger:
            return BadgeStyleHex(
                backgroundLightHex: DocsColorHex.dangerSoft, backgroundDarkHex: DocsColorHexDark.dangerSoft,
                foregroundLightHex: DocsColorHex.dangerStrong, foregroundDarkHex: DocsColorHexDark.dangerStrong)
        case .success:
            return BadgeStyleHex(
                backgroundLightHex: DocsColorHex.successSoft, backgroundDarkHex: DocsColorHexDark.successSoft,
                foregroundLightHex: DocsColorHex.success650, foregroundDarkHex: DocsColorHexDark.success650)
        case .warning:
            return BadgeStyleHex(
                backgroundLightHex: DocsColorHex.warningSoft, backgroundDarkHex: DocsColorHexDark.warningSoft,
                foregroundLightHex: DocsColorHex.warning650, foregroundDarkHex: DocsColorHexDark.warning650)
        case .info:
            return BadgeStyleHex(
                backgroundLightHex: DocsColorHex.infoSoft, backgroundDarkHex: DocsColorHexDark.infoSoft,
                foregroundLightHex: DocsColorHex.info650, foregroundDarkHex: DocsColorHexDark.info650)
        }
    }
}

struct Badge: View {
    let text: String
    var tone: BadgeTone = .neutral
    var icon: String? = nil
    /// Leading status dot (used by the Profile "• Connected" server badge).
    var dot: Bool = false

    var body: some View {
        let style = BadgeStyleResolver.style(tone: tone)
        let foreground = Color(lightHex: style.foregroundLightHex, darkHex: style.foregroundDarkHex)
        HStack(spacing: DocsSpacing.space3xs) {
            if dot {
                Circle()
                    .fill(foreground)
                    .frame(width: 6, height: 6)
            }
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 14))
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
        Badge(text: "Failed", tone: .danger, icon: "xmark.circle")
        Badge(text: "Active", tone: .success)
        Badge(text: "Pending", tone: .warning)
        Badge(text: "Info", tone: .info)
    }
    .padding()
}
