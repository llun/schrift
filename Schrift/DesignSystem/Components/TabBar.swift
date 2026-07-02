import SwiftUI

func tabBarIconName(baseSystemImage: String, isSelected: Bool) -> String {
    isSelected ? "\(baseSystemImage).fill" : baseSystemImage
}

struct TabBarItem {
    let value: String
    let label: String
    let systemImage: String
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
                        Image(systemName: tabBarIconName(baseSystemImage: item.systemImage, isSelected: isSelected))
                            .font(.system(size: 25, weight: isSelected ? .medium : .regular))
                        Text(item.label)
                            .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                    }
                    .foregroundStyle(isSelected ? DocsColor.brandFill : DocsColor.gray450)
                    .frame(maxWidth: .infinity)
                }
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.top, DocsSpacing.space3xs)
        .padding(.bottom, showsSafeArea ? DocsSpacing.homeIndicatorHeight : DocsSpacing.space3xs)
        .frame(height: DocsSpacing.tabBarHeight + (showsSafeArea ? DocsSpacing.homeIndicatorHeight : 0))
        .background(DocsColor.surfacePage.opacity(0.9))
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
        TabBar(items: [
            TabBarItem(value: "docs", label: "Docs", systemImage: "doc.text"),
            TabBarItem(value: "search", label: "Search", systemImage: "magnifyingglass"),
            TabBarItem(value: "shared", label: "Shared", systemImage: "person.2"),
            TabBarItem(value: "me", label: "Profile", systemImage: "person.crop.circle"),
        ], selection: $selection)
    }
}
