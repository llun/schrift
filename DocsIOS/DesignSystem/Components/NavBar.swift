import SwiftUI

func navBarHeight(largeTitle: Bool) -> CGFloat {
    largeTitle ? DocsSpacing.largeTitleBarHeight : DocsSpacing.navBarHeight
}

struct NavBarAction {
    let systemImage: String
    let label: String
    let action: () -> Void
}

struct NavBar: View {
    let title: String
    var subtitle: String? = nil
    var largeTitle: Bool = false
    var titleBadge: Badge? = nil
    var backTitle: String? = nil
    var onBack: (() -> Void)? = nil
    var trailingActions: [NavBarAction] = []
    var translucent: Bool = true
    var showsBorder: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let backTitle, let onBack {
                    Button(action: onBack) {
                        HStack(spacing: DocsSpacing.space4xs) {
                            Image(systemName: "chevron.left")
                            Text(backTitle)
                        }
                        .font(DocsFont.body)
                        .foregroundStyle(DocsColor.textBrand)
                    }
                }

                Spacer()

                if !largeTitle {
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
                }

                Spacer()

                HStack(spacing: DocsSpacing.spaceXS) {
                    ForEach(Array(trailingActions.enumerated()), id: \.offset) { _, action in
                        IconButton(systemImage: action.systemImage, label: action.label, action: action.action)
                    }
                }
            }
            .padding(.horizontal, DocsSpacing.gutter)
            .frame(height: DocsSpacing.navBarHeight)

            if largeTitle {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: DocsSpacing.spaceXS) {
                        Text(title)
                            .font(DocsFont.largeTitle)
                            .foregroundStyle(DocsColor.textPrimary)
                        if let titleBadge {
                            titleBadge
                        }
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(DocsFont.footnote)
                            .foregroundStyle(DocsColor.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.bottom, DocsSpacing.spaceXS)
            }
        }
        .frame(minHeight: navBarHeight(largeTitle: largeTitle))
        .background(translucent ? DocsColor.surfacePage.opacity(0.82) : DocsColor.surfacePage)
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
        NavBar(title: "Docs", subtitle: "docs.example.org", largeTitle: true, trailingActions: [
            NavBarAction(systemImage: "magnifyingglass", label: "Search", action: {}),
            NavBarAction(systemImage: "plus", label: "New", action: {}),
        ])
        NavBar(title: "Docs", backTitle: "Docs", onBack: {}, trailingActions: [
            NavBarAction(systemImage: "square.and.arrow.up", label: "Share", action: {}),
        ])
        Spacer()
    }
}
