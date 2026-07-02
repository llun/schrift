import SwiftUI

enum LinkReach: String {
    case restricted
    case authenticated
    case `public`
}

struct LinkReachPillStyleHex: Equatable {
    let backgroundHex: UInt32
    let foregroundHex: UInt32
    let systemImage: String
    let label: String
    let hint: String
}

enum LinkReachPillStyleResolver {
    static func style(reach: LinkReach) -> LinkReachPillStyleHex {
        switch reach {
        case .restricted:
            return LinkReachPillStyleHex(backgroundHex: DocsColorHex.surfaceMuted, foregroundHex: DocsColorHex.textSecondary, systemImage: "lock.fill", label: "Restricted", hint: "Only invited people")
        case .authenticated:
            // Reference uses `vpn_lock` (a lock over a globe) for the org-gated state.
            return LinkReachPillStyleHex(backgroundHex: DocsColorHex.infoSoft, foregroundHex: DocsColorHex.info650, systemImage: "network.badge.shield.half.filled", label: "Connected", hint: "Anyone in the org")
        case .public:
            return LinkReachPillStyleHex(backgroundHex: DocsColorHex.brandFillSoft, foregroundHex: DocsColorHex.textBrandSecondary, systemImage: "globe", label: "Public", hint: "Anyone with the link")
        }
    }
}

struct LinkReachPill: View {
    let reach: LinkReach
    var showsHint: Bool = false

    var body: some View {
        let style = LinkReachPillStyleResolver.style(reach: reach)
        HStack(spacing: DocsSpacing.space2xs) {
            Image(systemName: style.systemImage)
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 0) {
                Text(style.label)
                    .font(.system(size: 14, weight: .semibold))
                if showsHint {
                    Text(style.hint)
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
        .foregroundStyle(Color(hex: style.foregroundHex))
        .background(Color(hex: style.backgroundHex))
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style.label)
        .accessibilityHint(showsHint ? style.hint : "")
    }
}

#Preview {
    HStack(spacing: DocsSpacing.spaceXS) {
        LinkReachPill(reach: .restricted, showsHint: true)
        LinkReachPill(reach: .authenticated)
        LinkReachPill(reach: .public)
    }
    .padding()
}
