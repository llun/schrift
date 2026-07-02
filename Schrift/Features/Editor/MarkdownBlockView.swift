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
    let block: EditorBlock
    var numberedIndex: Int = 1

    var body: some View {
        switch block.kind {
        case .heading(let level):
            Text(markdownInlineText(block.text))
                .font(markdownHeadingFont(level: level))
                .foregroundStyle(DocsColor.textPrimary)

        case .paragraph:
            Text(markdownInlineText(block.text))
                .font(DocsFont.body)
                .foregroundStyle(DocsColor.textPrimary)

        case .bulletItem:
            HStack(alignment: .top, spacing: DocsSpacing.spaceXS) {
                Text("•")
                Text(markdownInlineText(block.text))
            }
            .font(DocsFont.body)
            .foregroundStyle(DocsColor.textPrimary)

        case .numberedItem:
            HStack(alignment: .top, spacing: DocsSpacing.spaceXS) {
                Text("\(numberedIndex).")
                    .monospacedDigit()
                Text(markdownInlineText(block.text))
            }
            .font(DocsFont.body)
            .foregroundStyle(DocsColor.textPrimary)

        case .checklistItem(let checked):
            HStack(alignment: .top, spacing: DocsSpacing.spaceXS) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? DocsColor.brandFill : DocsColor.textTertiary)
                Text(markdownInlineText(block.text))
                    .strikethrough(checked)
            }
            .font(DocsFont.body)
            .foregroundStyle(DocsColor.textPrimary)

        case .quote:
            HStack(spacing: DocsSpacing.spaceXS) {
                Rectangle()
                    .fill(DocsColor.borderDefault)
                    .frame(width: 3)
                Text(markdownInlineText(block.text))
                    .italic()
            }
            .font(DocsFont.body)
            .foregroundStyle(DocsColor.textSecondary)

        case .codeBlock:
            Text(block.text)
                .font(DocsFont.code)
                .foregroundStyle(DocsColor.textPrimary)
                .padding(DocsSpacing.spaceSM)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DocsColor.surfaceSunken)
                .clipShape(RoundedRectangle(cornerRadius: DocsRadius.md))

        case .divider:
            Rectangle()
                .fill(DocsColor.borderDefault)
                .frame(height: 1)
                .padding(.vertical, DocsSpacing.spaceXS)

        case .unknown:
            Text(block.text)
                .font(DocsFont.code)
                .foregroundStyle(DocsColor.textPrimary)
        }
    }
}
