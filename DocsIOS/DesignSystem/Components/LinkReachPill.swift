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
            return LinkReachPillStyleHex(backgroundHex: DocsColorHex.infoSoft, foregroundHex: DocsColorHex.info, systemImage: "network", label: "Connected", hint: "Anyone in the org")
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
        HStack(spacing: DocsSpacing.space4xs) {
            Image(systemName: style.systemImage)
                .font(.system(size: 11))
            VStack(alignment: .leading, spacing: 0) {
                Text(style.label)
                    .font(DocsFont.caption)
                if showsHint {
                    Text(style.hint)
                        .font(.system(size: 10))
                        .opacity(0.8)
                }
            }
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
        LinkReachPill(reach: .restricted, showsHint: true)
        LinkReachPill(reach: .authenticated)
        LinkReachPill(reach: .public)
    }
    .padding()
}
