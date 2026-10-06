import SwiftUI

struct ListSection<Content: View>: View {
    @Environment(\.docsTheme) private var theme
    var header: String? = nil
    var footer: String? = nil
    let content: Content

    init(header: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.header = header
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DocsSpacing.space2xs) {
            if let header {
                Text(header)
                    .font(DocsFont.footnote.weight(.semibold))
                    .foregroundStyle(theme.colors.textTertiary)
            }

            VStack(spacing: 0) {
                content
            }
            .environment(\.docsRowGutter, 0)

            if let footer {
                Text(footer)
                    .font(DocsFont.footnote)
                    .foregroundStyle(theme.colors.textTertiary)
            }
        }
    }
}

#Preview {
    ListSection(header: "Document", footer: "These actions apply to the current document.") {
        ListRow(icon: .push_pin, title: "Pin", action: {})
        ListRow(icon: .link, title: "Copy link", action: {})
    }
    .padding()
}
