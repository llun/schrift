import SwiftUI

struct ComponentCatalogPreview: View {
    @State private var isSwitchOn = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DocsSpacing.spaceLG) {
                catalogSection("Buttons") {
                    VStack(spacing: DocsSpacing.spaceSM) {
                        DocsButton(title: "Primary", variant: .primary, color: .brand, action: {})
                        DocsButton(title: "Secondary", variant: .secondary, color: .brand, action: {})
                        DocsButton(title: "Tertiary", variant: .tertiary, color: .brand, action: {})
                        DocsButton(title: "Outline", variant: .outline, color: .brand, action: {})
                        DocsButton(title: "Danger", variant: .primary, color: .danger, action: {})
                        DocsButton(title: "Disabled", variant: .primary, color: .brand, isDisabled: true, action: {})
                    }
                }

                catalogSection("Icon Buttons") {
                    HStack(spacing: DocsSpacing.spaceSM) {
                        IconButton(systemImage: "magnifyingglass", label: "Search", variant: .ghost, color: .neutral, action: {})
                        IconButton(systemImage: "plus", label: "Add", variant: .soft, color: .brand, action: {})
                        IconButton(systemImage: "trash", label: "Delete", variant: .outline, color: .danger, action: {})
                    }
                }

                catalogSection("Badges") {
                    HStack(spacing: DocsSpacing.spaceXS) {
                        Badge(text: "Admin", tone: .accent)
                        Badge(text: "3", tone: .neutral)
                        Badge(text: "Failed", tone: .danger, icon: "xmark.circle")
                        Badge(text: "Active", tone: .success)
                    }
                }

                catalogSection("Switch") {
                    Switch(isOn: $isSwitchOn)
                }
            }
            .padding(DocsSpacing.spaceBase)
        }
        .background(DocsColor.surfacePage)
    }

    @ViewBuilder
    private func catalogSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DocsSpacing.spaceXS) {
            Text(title)
                .font(DocsFont.title2)
                .foregroundStyle(DocsColor.textPrimary)
            content()
        }
    }
}

#Preview {
    ComponentCatalogPreview()
}
