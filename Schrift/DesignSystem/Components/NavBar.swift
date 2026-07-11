import SwiftUI

func navBarHeight(largeTitle: Bool) -> CGFloat {
    largeTitle ? DocsSpacing.largeTitleBarHeight : DocsSpacing.navBarHeight
}

/// Whether the 44pt top row (back button / leading view) contributes any
/// height. In large-title mode with neither a back button nor a leading
/// view — the four tab screens — that row would be empty dead space above
/// the large title, so it collapses to zero height. Any back button or
/// leading view still needs its own row, in both large-title and standard
/// (non-large-title) mode, where the top row always shows.
func navBarShowsTopRow(largeTitle: Bool, hasBack: Bool, hasLeading: Bool) -> Bool {
    !(largeTitle && !hasBack && !hasLeading)
}

struct NavBarAction {
    let systemImage: String
    let label: String
    var color: IconButtonColor = .neutral
    var filled: Bool = false
    let action: () -> Void
}

struct NavBar: View {
    var title: String = ""
    var subtitle: String? = nil
    var largeTitle: Bool = false
    var titleBadge: Badge? = nil
    var backTitle: String? = nil
    var onBack: (() -> Void)? = nil
    var trailingActions: [NavBarAction] = []
    var showsBorder: Bool = true

    private var hasBack: Bool { backTitle != nil && onBack != nil }

    // No `leading` param exists yet, so this is always false; kept as an
    // explicit call site for `navBarShowsTopRow` so a future leading view
    // only has to flip this, not touch the collapse logic.
    private var hasLeading: Bool { false }

    private var showsTopRow: Bool {
        navBarShowsTopRow(largeTitle: largeTitle, hasBack: hasBack, hasLeading: hasLeading)
    }

    private var trailingActionsGroup: some View {
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

    var body: some View {
        VStack(spacing: 0) {
            if showsTopRow {
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

                    // Standard mode keeps trailing actions in this row;
                    // large-title mode renders them inline with the title
                    // below instead (see the large-title block).
                    if !largeTitle {
                        trailingActionsGroup
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
            }

            if largeTitle {
                HStack(spacing: DocsSpacing.spaceSM) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: DocsSpacing.spaceXS) {
                            Text(title)
                                .font(DocsFont.largeTitle)
                                .tracking(DocsTypographySpec.largeTitle.size * DocsTracking.tight)
                                .foregroundStyle(DocsColor.textPrimary)
                                // Handoff large title is single-line with ellipsis
                                // (nowrap/overflow-hidden/text-overflow-ellipsis) —
                                // a long doc title (editor reading mode, where the
                                // title shares the row with trailing icons) must
                                // truncate, not wrap and grow the header.
                                .lineLimit(1)
                                .truncationMode(.tail)
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

                    if !trailingActions.isEmpty {
                        trailingActionsGroup
                    }
                }
                .padding(.horizontal, DocsSpacing.gutter)
                // 10pt top when the top row is collapsed (no back/leading —
                // the compact tab header); 2pt when the top row is showing
                // (a back button already separates the title from the safe
                // area, so the block only needs a hairline of its own space).
                .padding(.top, showsTopRow ? DocsSpacing.space4xs : DocsSpacing.spaceSM - DocsSpacing.space4xs)
                .padding(.bottom, DocsSpacing.spaceSM - DocsSpacing.space4xs)
            }
        }
        .frame(minHeight: navBarHeight(largeTitle: largeTitle))
        // Solid, opaque white fill — no frosted-glass blur. `ignoresSafeArea`
        // extends the fill up through the status-bar strip (the bar itself sits
        // below the safe-area inset), so the status area reads as the same clean
        // white as the bar even on screens whose page background is sunken gray
        // (Profile, Account) — no gray/white seam above the header.
        .background(DocsColor.surfacePage.ignoresSafeArea(edges: .top))
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
        // Large title, no back, one trailing action (Home): top row
        // collapses to 0pt and the "+" sits inline beside the title.
        NavBar(
            title: "Schrift", subtitle: "docs.example.org", largeTitle: true,
            trailingActions: [
                NavBarAction(systemImage: "plus", label: "New", action: {})
            ], showsBorder: false)
        // Large title, no back, no trailing actions (Search/Shared/Profile):
        // top row collapses, no dead space above the title.
        NavBar(title: "Search", subtitle: "docs.example.org", largeTitle: true, showsBorder: false)
        // Large title WITH a back button (the editor's reading mode): the
        // top row still shows for the back button, and trailing actions
        // render inline with the title below it, not in the top row.
        NavBar(
            title: "Getting started", largeTitle: true, backTitle: "Home", onBack: {},
            trailingActions: [
                NavBarAction(systemImage: "list.bullet.indent", label: "Pages", action: {}),
                NavBarAction(systemImage: "square.and.arrow.up", label: "Share", action: {}),
                NavBarAction(systemImage: "ellipsis", label: "Options", action: {}),
            ])
        // Standard (non-large) mode, unchanged: centered title, back
        // button and trailing actions both in the 44pt top row.
        NavBar(
            title: "Docs", backTitle: "Docs", onBack: {},
            trailingActions: [
                NavBarAction(systemImage: "square.and.arrow.up", label: "Share", action: {})
            ])
        Spacer()
    }
}
