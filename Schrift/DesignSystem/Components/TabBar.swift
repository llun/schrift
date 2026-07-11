import SwiftUI

struct TabBarItem {
    let value: String
    let label: String
    let icon: MaterialIcon
}

struct TabBar: View {
    let items: [TabBarItem]
    @Binding var selection: String
    var showsSafeArea: Bool = true

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.value) { item in
                let isSelected = item.value == selection
                Button(action: { selection = item.value }) {
                    VStack(spacing: DocsSpacing.space4xs) {
                        // Selected tabs use the filled Material Symbols variant
                        // (FILL axis) for emphasis — the bundled font always
                        // carries it, so there is no missing-variant fallback to
                        // worry about the way SF Symbols required.
                        MaterialSymbol(item.icon, size: 25, fill: isSelected)
                        Text(item.label)
                            .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                    }
                    .padding(.vertical, DocsSpacing.space4xs)
                    .foregroundStyle(isSelected ? DocsColor.brandFill : DocsColor.gray450)
                    .frame(maxWidth: .infinity)
                }
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.top, DocsSpacing.space2xs)
        .padding(.bottom, DocsSpacing.space2xs)
        .frame(maxWidth: .infinity)
        // The translucent bar fills the home-indicator safe area itself; the
        // content sits just above it. Padding the content by the full safe-area
        // inset (as before) double-counted it against the device inset and left
        // a large empty gap below the labels.
        .background(
            DocsColor.surfacePage.opacity(0.9)
                .background(.ultraThinMaterial)
                .ignoresSafeArea(edges: showsSafeArea ? .bottom : [])
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DocsColor.borderDefault)
                .frame(height: 0.5)
        }
    }
}

#Preview {
    @Previewable @State var selection = "docs"
    VStack {
        Spacer()
        TabBar(
            items: [
                TabBarItem(value: "docs", label: "Docs", icon: .description),
                TabBarItem(value: "search", label: "Search", icon: .search),
                TabBarItem(value: "shared", label: "Shared", icon: .group),
                TabBarItem(value: "me", label: "Profile", icon: .account_circle),
            ], selection: $selection)
    }
}
