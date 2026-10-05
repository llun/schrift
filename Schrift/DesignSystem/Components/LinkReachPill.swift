import SwiftUI

enum LinkReach: String {
    case restricted
    case authenticated
    case `public`
}

struct LinkReachPillStyleHex: Equatable {
    let backgroundLightHex: UInt32
    let backgroundDarkHex: UInt32
    let foregroundLightHex: UInt32
    let foregroundDarkHex: UInt32
    let icon: MaterialIcon
    let labelKey: L10nKey
    let hintKey: L10nKey
}

enum LinkReachPillStyleResolver {
    static func style(reach: LinkReach, theme: AppTheme = .white) -> LinkReachPillStyleHex {
        let light = DocsPalette(theme: theme, isDark: false)
        let dark = DocsPalette(theme: theme, isDark: true)
        switch reach {
        case .restricted:
            return LinkReachPillStyleHex(
                backgroundLightHex: light.surfaceMuted, backgroundDarkHex: dark.surfaceMuted,
                foregroundLightHex: light.textSecondary, foregroundDarkHex: dark.textSecondary,
                icon: .lock, labelKey: .reach_restricted, hintKey: .linkreach_hint_restricted)
        case .authenticated:
            // Reference uses `vpn_lock` (a lock over a globe) for the org-gated state.
            return LinkReachPillStyleHex(
                backgroundLightHex: light.infoSoft, backgroundDarkHex: dark.infoSoft,
                foregroundLightHex: light.info650, foregroundDarkHex: dark.info650,
                icon: .vpn_lock, labelKey: .reach_connected,
                hintKey: .linkreach_hint_authenticated)
        case .public:
            return LinkReachPillStyleHex(
                backgroundLightHex: light.brandFillSoft, backgroundDarkHex: dark.brandFillSoft,
                foregroundLightHex: light.textBrandSecondary,
                foregroundDarkHex: dark.textBrandSecondary,
                icon: .public, labelKey: .reach_public, hintKey: .linkreach_hint_public)
        }
    }
}

struct LinkReachPill: View {
    @Environment(\.docsTheme) private var theme
    let reach: LinkReach
    var showsHint: Bool = false

    @Environment(LocalizationStore.self) private var loc

    var body: some View {
        let style = LinkReachPillStyleResolver.style(reach: reach, theme: theme)
        HStack(spacing: DocsSpacing.space2xs) {
            MaterialSymbol(style.icon, size: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(loc[style.labelKey])
                    .docsScaledFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                if showsHint {
                    Text(loc[style.hintKey])
                        .font(DocsFont.caption)
                        .opacity(0.8)
                }
            }
        }
        // Reference uses a fuller asymmetric pad with the hint (6/8-left/12-right)
        // and a compact symmetric pad without it (5/10).
        .padding(.leading, showsHint ? DocsSpacing.spaceXS : 10)
        .padding(.trailing, showsHint ? DocsSpacing.spaceSM : 10)
        .padding(.vertical, showsHint ? DocsSpacing.space2xs : 5)
        .foregroundStyle(Color(lightHex: style.foregroundLightHex, darkHex: style.foregroundDarkHex))
        .background(Color(lightHex: style.backgroundLightHex, darkHex: style.backgroundDarkHex))
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loc[style.labelKey])
        .accessibilityHint(showsHint ? loc[style.hintKey] : "")
    }
}

#Preview {
    HStack(spacing: DocsSpacing.spaceXS) {
        LinkReachPill(reach: .restricted, showsHint: true)
        LinkReachPill(reach: .authenticated)
        LinkReachPill(reach: .public)
    }
    .padding()
    .environment(LocalizationStore())
}
