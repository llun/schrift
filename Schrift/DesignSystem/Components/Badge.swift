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
    let backgroundHex: UInt32
    let foregroundHex: UInt32
}

enum BadgeStyleResolver {
    // Foregrounds match the prototype's Cunningham badge tones: the deeper
    // -650 / -strong inks (not the -550 body colors) for readable pills.
    static func style(tone: BadgeTone) -> BadgeStyleHex {
        switch tone {
        case .accent:
            return BadgeStyleHex(backgroundHex: DocsColorHex.brandFillSoft, foregroundHex: DocsColorHex.textBrandSecondary)
        case .neutral:
            return BadgeStyleHex(backgroundHex: DocsColorHex.gray100, foregroundHex: DocsColorHex.gray600)
        case .danger:
            return BadgeStyleHex(backgroundHex: DocsColorHex.dangerSoft, foregroundHex: DocsColorHex.dangerStrong)
        case .success:
            return BadgeStyleHex(backgroundHex: DocsColorHex.successSoft, foregroundHex: DocsColorHex.success650)
        case .warning:
            return BadgeStyleHex(backgroundHex: DocsColorHex.warningSoft, foregroundHex: DocsColorHex.warning650)
        case .info:
            return BadgeStyleHex(backgroundHex: DocsColorHex.infoSoft, foregroundHex: DocsColorHex.info650)
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
        let foreground = Color(hex: style.foregroundHex)
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
        .background(Color(hex: style.backgroundHex))
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
