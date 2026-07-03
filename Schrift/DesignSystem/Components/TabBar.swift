import SwiftUI
import UIKit

/// The symbol name a tab-bar item should render for the given selection state.
///
/// Selected tabs use the filled variant of the symbol for emphasis. A few SF
/// Symbols — notably `magnifyingglass` (the Search tab) — have **no** `.fill`
/// variant, and asking `Image(systemName:)` for a symbol that doesn't exist
/// renders an *empty* image. That made the Search tab's magnifying glass vanish
/// the moment it was selected. Fall back to the base symbol whenever the filled
/// variant isn't a real SF Symbol so selecting a tab never blanks its icon;
/// selection stays legible via the brand tint and heavier weight.
func tabBarIconName(baseSystemImage: String, isSelected: Bool) -> String {
    guard isSelected else { return baseSystemImage }
    let filled = "\(baseSystemImage).fill"
    return UIImage(systemName: filled) != nil ? filled : baseSystemImage
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
                TabBarItem(value: "docs", label: "Docs", systemImage: "doc.text"),
                TabBarItem(value: "search", label: "Search", systemImage: "magnifyingglass"),
                TabBarItem(value: "shared", label: "Shared", systemImage: "person.2"),
                TabBarItem(value: "me", label: "Profile", systemImage: "person.crop.circle"),
            ], selection: $selection)
    }
}
