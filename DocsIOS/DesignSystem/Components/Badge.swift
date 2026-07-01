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
    static func style(tone: BadgeTone) -> BadgeStyleHex {
        switch tone {
        case .accent:
            return BadgeStyleHex(backgroundHex: DocsColorHex.brandFillSoft, foregroundHex: DocsColorHex.textBrandSecondary)
        case .neutral:
            return BadgeStyleHex(backgroundHex: DocsColorHex.surfaceMuted, foregroundHex: DocsColorHex.textSecondary)
        case .danger:
            return BadgeStyleHex(backgroundHex: DocsColorHex.dangerSoft, foregroundHex: DocsColorHex.danger)
        case .success:
            return BadgeStyleHex(backgroundHex: DocsColorHex.successSoft, foregroundHex: DocsColorHex.success)
        case .warning:
            return BadgeStyleHex(backgroundHex: DocsColorHex.warningSoft, foregroundHex: DocsColorHex.warning)
        case .info:
            return BadgeStyleHex(backgroundHex: DocsColorHex.infoSoft, foregroundHex: DocsColorHex.info)
        }
    }
}

struct Badge: View {
    let text: String
    var tone: BadgeTone = .neutral
    var icon: String? = nil

    var body: some View {
        let style = BadgeStyleResolver.style(tone: tone)
        HStack(spacing: DocsSpacing.space4xs) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11))
            }
            Text(text)
                .font(DocsFont.caption)
        }
        .padding(.horizontal, DocsSpacing.spaceXS)
        .padding(.vertical, DocsSpacing.space4xs)
        .foregroundStyle(Color(hex: style.foregroundHex))
        .background(Color(hex: style.backgroundHex))
        .clipShape(Capsule())
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
