import SwiftUI

/// The slash-command block picker, docked above the keyboard (caret-anchored
/// popovers are unreliable on iOS; this mirrors mobile Notion).
struct SlashMenuView: View {
    let query: String
    var onSelect: (SlashMenuItem) -> Void

    @Environment(LocalizationStore.self) private var loc
    /// Four rows at the default text size, scaled so the menu still shows about
    /// four once the rows themselves grow.
    @ScaledMetric(relativeTo: .body) private var maxHeight: CGFloat = 4 * DocsSpacing.rowMinHeight

    var body: some View {
        let items = filteredSlashItems(query: query)
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
    VStack {
        SlashMenuView(query: "", onSelect: { _ in })
        SlashMenuView(query: "head", onSelect: { _ in })
    }
    .padding()
    .background(DocsColor.surfaceSunken)
    .environment(LocalizationStore())
}
