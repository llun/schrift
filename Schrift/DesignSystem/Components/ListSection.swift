import SwiftUI

struct ListSection<Content: View>: View {
    var header: String? = nil
    var footer: String? = nil
    let content: Content

    init(header: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.header = header
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DocsSpacing.spaceXS) {
            if let header {
                Text(header.uppercased())
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.textTertiary)
                    .padding(.horizontal, DocsSpacing.gutterGrouped)
            }

            VStack(spacing: 0) {
                content
            }
            .background(DocsColor.surfacePage)
            .clipShape(RoundedRectangle(cornerRadius: DocsRadius.lg))

            if let footer {
                Text(footer)
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.textTertiary)
                    .padding(.horizontal, DocsSpacing.gutterGrouped)
            }
        }
    }
}

#Preview {
    ListSection(header: "Document", footer: "These actions apply to the current document.") {
        ListRow(systemImage: "pin", title: "Pin", action: {})
        ListRow(systemImage: "link", title: "Copy link", action: {})
    }
    .padding()
}
