import SwiftUI

func markdownInlineText(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text)) ?? AttributedString(text)
}

func markdownHeadingFont(level: Int) -> Font {
    switch level {
    case 1: return DocsFont.title1
    case 2: return DocsFont.title2
    default: return DocsFont.headline
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(markdownInlineText(text))
                .font(markdownHeadingFont(level: level))
                .foregroundStyle(DocsColor.textPrimary)

        case .paragraph(let text):
            Text(markdownInlineText(text))
                .font(DocsFont.body)
                .foregroundStyle(DocsColor.textPrimary)

        case .bulletItem(let text):
            HStack(alignment: .top, spacing: DocsSpacing.spaceXS) {
                Text("•")
                Text(markdownInlineText(text))
            }
            .font(DocsFont.body)
            .foregroundStyle(DocsColor.textPrimary)

        case .checklistItem(let checked, let text):
            HStack(alignment: .top, spacing: DocsSpacing.spaceXS) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? DocsColor.brandFill : DocsColor.textTertiary)
                Text(markdownInlineText(text))
                    .strikethrough(checked)
            }
            .font(DocsFont.body)
            .foregroundStyle(DocsColor.textPrimary)

        case .quote(let text):
            HStack(spacing: DocsSpacing.spaceXS) {
                Rectangle()
                    .fill(DocsColor.borderDefault)
                    .frame(width: 3)
                Text(markdownInlineText(text))
                    .italic()
            }
            .font(DocsFont.body)
            .foregroundStyle(DocsColor.textSecondary)
        }
    }
}
