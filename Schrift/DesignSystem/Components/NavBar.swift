import SwiftUI

func navBarHeight(largeTitle: Bool) -> CGFloat {
    largeTitle ? DocsSpacing.largeTitleBarHeight : DocsSpacing.navBarHeight
}

struct NavBarAction {
    let systemImage: String
    let label: String
    var color: IconButtonColor = .neutral
    var filled: Bool = false
    let action: () -> Void
}

/// The bar's fill: white for standard chrome, sunken for screens whose page
/// background is `--surface-sunken` (Profile, Account).
enum NavBarTint {
    case page
    case sunken

    var color: Color {
        switch self {
        case .page: return DocsColor.surfacePage
        case .sunken: return DocsColor.surfaceSunken
        }
    }
}

struct NavBar: View {
    var title: String = ""
    var subtitle: String? = nil
    var largeTitle: Bool = false
    var titleBadge: Badge? = nil
    var backTitle: String? = nil
    var onBack: (() -> Void)? = nil
    var trailingActions: [NavBarAction] = []
    var surfaceTint: NavBarTint = .page
    var showsBorder: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let backTitle, let onBack {
                    Button(action: onBack) {
                        HStack(spacing: DocsSpacing.space4xs) {
                            Image(systemName: "chevron.left")
                                // Reference back glyph is larger than its 17pt label
                                // (26px arrow_back_ios_new).
                                .font(.system(size: 20, weight: .semibold))
                            Text(backTitle)
                                .font(DocsFont.body)
                        }
                        .foregroundStyle(DocsColor.brandFill)
                    }
                }

                Spacer()

                HStack(spacing: DocsSpacing.space4xs) {
                    ForEach(Array(trailingActions.enumerated()), id: \.offset) { _, action in
                        IconButton(
                            systemImage: action.systemImage,
                            label: action.label,
                            color: action.color,
                            filled: action.filled,
                            action: action.action
                        )
                    }
                }
            }
            // Center the standard-mode title across the FULL bar (matching the
            // reference's absolutely-centered title) so it stays optically
            // centered regardless of the leading/trailing control widths.
            .overlay {
                if !largeTitle, !title.isEmpty {
                    VStack(spacing: 0) {
                        Text(title)
                            .font(DocsFont.headline)
                            .foregroundStyle(DocsColor.textPrimary)
                        if let subtitle {
                            Text(subtitle)
                                .font(DocsFont.caption)
                                .foregroundStyle(DocsColor.textTertiary)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, DocsSpacing.gutter)
            .frame(height: DocsSpacing.navBarHeight)

            if largeTitle {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: DocsSpacing.spaceXS) {
                        Text(title)
                            .font(DocsFont.largeTitle)
                            .tracking(DocsTypographySpec.largeTitle.size * DocsTracking.tight)
                            .foregroundStyle(DocsColor.textPrimary)
                        if let titleBadge {
                            titleBadge
                        }
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(DocsFont.subhead)
                            .foregroundStyle(DocsColor.textTertiary)
                            .padding(.top, DocsSpacing.space4xs)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.top, DocsSpacing.space4xs)
                .padding(.bottom, DocsSpacing.spaceSM - DocsSpacing.space4xs)
            }
        }
        .frame(minHeight: navBarHeight(largeTitle: largeTitle))
        // Solid, opaque fill — no frosted-glass blur. The opaque `Color`
        // background bleeds into the top safe area, so the status-bar strip
        // reads as the same clean surface color as the bar (white for `.page`)
        // instead of a translucent gray tint.
        .background(surfaceTint.color)
        .overlay(alignment: .bottom) {
            if showsBorder {
                Rectangle()
                    .fill(DocsColor.borderDefault)
                    .frame(height: 0.5)
            }
        }
    }
}

#Preview {
    VStack(spacing: 0) {
        NavBar(
            title: "Docs", subtitle: "docs.example.org", largeTitle: true,
            trailingActions: [
                NavBarAction(systemImage: "magnifyingglass", label: "Search", action: {}),
                NavBarAction(systemImage: "plus", label: "New", action: {}),
            ])
        NavBar(
            title: "Docs", backTitle: "Docs", onBack: {},
            trailingActions: [
                NavBarAction(systemImage: "square.and.arrow.up", label: "Share", action: {})
            ])
        Spacer()
    }
}
