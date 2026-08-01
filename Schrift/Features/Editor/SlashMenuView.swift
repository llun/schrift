import SwiftUI

/// The slash-command block picker, docked above the keyboard (caret-anchored
/// popovers are unreliable on iOS; this mirrors mobile Notion).
struct SlashMenuView: View {
    let query: String
    /// Drops the Photo item — it POSTs an attachment, which has no offline queue.
    var isOffline: Bool = false
    var onSelect: (SlashMenuItem) -> Void

    @Environment(LocalizationStore.self) private var loc
    /// Four rows at the default text size, scaled so the menu still shows about
    /// four once the rows themselves grow.
    @ScaledMetric(relativeTo: .body) private var maxHeight: CGFloat = 4 * DocsSpacing.rowMinHeight

    var body: some View {
        let items = filteredSlashItems(query: query, isOffline: isOffline)
        if !items.isEmpty {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            HStack(spacing: DocsSpacing.spaceSM) {
                                MaterialSymbol(item.icon, size: 20)
                                    .foregroundStyle(DocsColor.textSecondary)
                                    .frame(width: 24)
                                Text(loc[item.titleKey])
                                    .font(DocsFont.body)
                                    .foregroundStyle(DocsColor.textPrimary)
                                Spacer()
                            }
                            .padding(.horizontal, DocsSpacing.spaceBase)
                            .frame(minHeight: DocsSpacing.rowMinHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
            // Glass like the formatting bar it sits directly above — the two
            // share a `GlassEffectContainer` in the editor, so they read as one
            // floating surface instead of a card stacked on a capsule.
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: DocsRadius.lg))
            .accessibilityLabel(loc[.editor_slash_menu_a11y])
        }
    }
}

#Preview {
    slashMenuPreview
}

/// The menu is glass, so it is only really legible *over something*. Both
/// previews put it over document-like text rather than a flat swatch, which is
/// the case that decides whether the translucency works.
#Preview("Dark") {
    slashMenuPreview
        .preferredColorScheme(.dark)
}

@MainActor @ViewBuilder
private var slashMenuPreview: some View {
    ZStack(alignment: .bottom) {
        VStack(alignment: .leading, spacing: DocsSpacing.spaceXS) {
            ForEach(0..<12, id: \.self) { _ in
                Text("Body text the menu floats over, to check legibility.")
                    .font(DocsFont.body)
                    .foregroundStyle(DocsColor.textPrimary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()

        VStack {
            SlashMenuView(query: "", onSelect: { _ in })
            SlashMenuView(query: "head", onSelect: { _ in })
            // Offline: same list minus Photo, the one item that POSTs.
            SlashMenuView(query: "", isOffline: true, onSelect: { _ in })
        }
        .padding()
    }
    .background(DocsColor.surfacePage)
    .environment(LocalizationStore())
}
