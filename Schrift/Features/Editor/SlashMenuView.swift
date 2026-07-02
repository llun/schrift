import SwiftUI

/// The slash-command block picker, docked above the keyboard (caret-anchored
/// popovers are unreliable on iOS; this mirrors mobile Notion).
struct SlashMenuView: View {
    let query: String
    var onSelect: (SlashMenuItem) -> Void

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
                                Image(systemName: item.systemImage)
                                    .font(DocsFont.subhead)
                                    .foregroundStyle(DocsColor.textSecondary)
                                    .frame(width: 24)
                                Text(item.title)
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
            .frame(maxHeight: 4 * DocsSpacing.rowMinHeight)
            .fixedSize(horizontal: false, vertical: true)
            .background(DocsColor.surfacePage)
            .clipShape(RoundedRectangle(cornerRadius: DocsRadius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: DocsRadius.lg)
                    .strokeBorder(DocsColor.borderDefault, lineWidth: 1)
            )
            .shadow(color: DocsColor.textPrimary.opacity(0.12), radius: 12, x: 0, y: 4)
            .accessibilityLabel("Block type menu")
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
}
