import SwiftUI

/// The same component composition in every palette; no shared mutable preference.
struct ThemeCatalogPreview: View {
    let theme: AppTheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DocsSpacing.spaceLG) {
                HStack {
                    ThemeSwatch(theme: theme)
                    Text(theme.rawValue.capitalized).font(DocsFont.title1)
                }
                ListSection(header: "Preferences", footer: "A personal palette; document content stays the same.") {
                    ListRow(
                        icon: .contrast, title: "Theme", value: theme.rawValue.capitalized, showsChevron: true,
                        action: {})
                    ListRow(icon: .translate, title: "Language", value: "English", showsChevron: true, action: {})
                }
                DocRow(title: "Design principles", pinned: true, date: "Today")
                HStack {
                    Badge(text: "Connected", tone: .success, dot: true)
                    Badge(text: "Read only", tone: .neutral)
                    Badge(text: "Offline", tone: .warning)
                }
                DocsButton(title: "Continue", action: {})
                MarkdownBlockView(
                    block: EditorBlock(kind: .paragraph, text: "A calm canvas with a [link](https://example.org/)."),
                    serverOrigin: "https://example.org")
            }
            .padding(DocsSpacing.gutter)
            .foregroundStyle(theme.colors.textPrimary)
        }
        .background(theme.colors.surfacePage)
        .environment(\.docsTheme, theme)
        .environment(LocalizationStore())
    }
}

#Preview("White · Light") { ThemeCatalogPreview(theme: .white).preferredColorScheme(.light) }
#Preview("White · Dark") { ThemeCatalogPreview(theme: .white).preferredColorScheme(.dark) }
#Preview("Mist · Light") { ThemeCatalogPreview(theme: .mist).preferredColorScheme(.light) }
#Preview("Mist · Dark") { ThemeCatalogPreview(theme: .mist).preferredColorScheme(.dark) }
#Preview("Paper · Light") { ThemeCatalogPreview(theme: .paper).preferredColorScheme(.light) }
#Preview("Paper · Dark") { ThemeCatalogPreview(theme: .paper).preferredColorScheme(.dark) }
