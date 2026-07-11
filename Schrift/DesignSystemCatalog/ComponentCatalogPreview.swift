import SwiftUI

struct ComponentCatalogPreview: View {
    @State private var isSwitchOn = true
    @State private var searchText = ""
    @State private var selectedSegment = 0
    @State private var textFieldValue = ""
    @State private var catalogTab = "docs"

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
                        IconButton(
                            systemImage: "magnifyingglass", label: "Search", variant: .ghost, color: .neutral,
                            action: {})
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

                catalogSection("Avatars") {
                    HStack(spacing: DocsSpacing.spaceSM) {
                        Avatar(name: "Camille Moreau")
                        Avatar(name: "Alfredo Levin", size: 48)
                        Avatar(name: "")
                    }
                }

                catalogSection("Avatar Group") {
                    AvatarGroup(
                        names: [
                            "Camille Moreau", "Alfredo Levin", "Desirae Dokidis", "Amandine Salambo", "Charlie Saris",
                        ], max: 3)
                }

                catalogSection("Doc Icons") {
                    HStack(spacing: DocsSpacing.spaceSM) {
                        DocIcon(emoji: "📄")
                        DocIcon(emoji: nil, tinted: true)
                        DocIcon(emoji: "📌", pinned: true)
                    }
                }

                catalogSection("Search Field") {
                    SearchField(text: $searchText)
                }

                catalogSection("Segmented Control") {
                    SegmentedControl(segments: ["All", "Shared", "Pinned"], selectedIndex: $selectedSegment)
                }

                catalogSection("Text Field") {
                    DocsTextField(
                        label: "Docs server", text: $textFieldValue, placeholder: "docs.example.org", icon: "cloud",
                        helper: "The app signs in with your existing session.")
                }

                catalogSection("Nav Bar") {
                    VStack(spacing: DocsSpacing.spaceXS) {
                        NavBar(
                            title: "Docs", subtitle: "docs.example.org", largeTitle: true,
                            trailingActions: [
                                NavBarAction(systemImage: "magnifyingglass", label: "Search", action: {})
                            ])
                        NavBar(
                            title: "Docs", backTitle: "Docs", onBack: {},
                            trailingActions: [
                                NavBarAction(systemImage: "square.and.arrow.up", label: "Share", action: {})
                            ])
                    }
                }

                catalogSection("Tab Bar") {
                    TabBar(
                        items: [
                            TabBarItem(value: "docs", label: "Docs", systemImage: "doc.text"),
                            TabBarItem(value: "search", label: "Search", systemImage: "magnifyingglass"),
                            TabBarItem(value: "shared", label: "Shared", systemImage: "person.2"),
                        ], selection: $catalogTab, showsSafeArea: false)
                }

                catalogSection("List Row / List Section") {
                    ListSection(header: "Document", footer: "These actions apply to the current document.") {
                        ListRow(systemImage: "pin", title: "Pin", value: "Pinned", action: {})
                        ListRow(systemImage: "link", title: "Copy link", showsChevron: true, action: {})
                        ListRow(title: "Delete document", isDestructive: true, action: {})
                    }
                }

                catalogSection("Link Reach Pill") {
                    HStack(spacing: DocsSpacing.spaceXS) {
                        LinkReachPill(reach: .restricted, showsHint: true)
                        LinkReachPill(reach: .authenticated)
                        LinkReachPill(reach: .public)
                    }
                }

                catalogSection("Share Member Row") {
                    VStack(spacing: 0) {
                        ShareMemberRow(
                            name: "Camille Moreau", email: "camille.moreau@beta.gouv.fr", role: "Admin",
                            isCurrentUser: true)
                        ShareMemberRow(name: "Alfredo Levin", email: "alfredo.levin@test.gouv.fr", role: "Editor")
                        ShareMemberRow(name: "Desirae Dokidis", email: "desirae.dokidis@gmail.com", role: "Reader")
                    }
                }

                catalogSection("Doc Row") {
                    VStack(spacing: 0) {
                        DocRow(emoji: "📄", title: "Q3 Planning", pinned: true, reach: .restricted, date: "3 days ago")
                        DocRow(emoji: "📊", title: "Roadmap", reach: .authenticated, date: "Yesterday")
                        DocRow(title: "Public notes", reach: .public, date: "Last week")
                    }
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
        .environment(LocalizationStore())
}
