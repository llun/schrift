import SwiftUI

/// Parse inline markdown for display, preserving whitespace (so multi-line
/// prose keeps its line breaks) and autolinking bare URLs.
///
/// `AttributedString(markdown:)` renders explicit `[text](url)` links but — per
/// CommonMark — leaves *bare* URLs (`https://…`) as plain text. We run a link
/// data detector over the rendered characters afterwards and attach a link
/// only where one isn't already present, so bare URLs become tappable without
/// double-linking the target of an existing markdown link.
func markdownInlineText(_ text: String) -> AttributedString {
    var attributed =
        (try? AttributedString(markdown: text, options: inlineMarkdownOptions)) ?? AttributedString(text)
    autolinkBareURLs(in: &attributed)
    return attributed
}

private let inlineMarkdownOptions = AttributedString.MarkdownParsingOptions(
    interpretedSyntax: .inlineOnlyPreservingWhitespace)

private func autolinkBareURLs(in attributed: inout AttributedString) {
    let plain = String(attributed.characters)
    guard !plain.isEmpty,
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    else { return }

    let fullRange = NSRange(plain.startIndex..<plain.endIndex, in: plain)
    for match in detector.matches(in: plain, options: [], range: fullRange) {
        guard let url = match.url, let stringRange = Range(match.range, in: plain) else { continue }
        let lower = plain.distance(from: plain.startIndex, to: stringRange.lowerBound)
        let upper = plain.distance(from: plain.startIndex, to: stringRange.upperBound)
        let attributedRange =
            attributed.index(
                attributed.startIndex, offsetByCharacters: lower)..<attributed.index(
                attributed.startIndex, offsetByCharacters: upper)
        // Skip spans that markdown already turned into a link.
        guard !attributed[attributedRange].runs.contains(where: { $0.link != nil }) else { continue }
        attributed[attributedRange].link = url
        attributed[attributedRange].foregroundColor = DocsColor.textBrand
    }
}

/// True when an `.unknown` block is plain prose that spilled across lines (e.g.
/// a paragraph with a hard line break) and should render as rich inline text
/// rather than verbatim monospace. Tables (`|`), HTML (`<`), standalone images
/// (`![`), and indented continuation content stay verbatim so structure and
/// content are never reinterpreted.
func unknownRendersAsProse(_ text: String) -> Bool {
    let lines = text.components(separatedBy: "\n")
    guard lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return false }
    return lines.allSatisfy { line in
        if line.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        guard let first = line.first, first != " ", first != "\t" else { return false }
        return !line.hasPrefix("|") && !line.hasPrefix("![") && !line.hasPrefix("<")
    }
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
            HStack(alignment: .top, spacing: 0) {
                RoundedRectangle(cornerRadius: DocsRadius.xs)
                    .fill(DocsColor.brandFill)
                    .frame(width: 4)
                Text(markdownInlineText(block.text))
                    .italic()
                    .font(DocsFont.body)
                    .foregroundStyle(DocsColor.textSecondary)
                    .padding(.vertical, DocsSpacing.spaceXS)
                    .padding(.horizontal, DocsSpacing.spaceSM)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DocsColor.surfaceSunken)
            .clipShape(RoundedRectangle(cornerRadius: DocsRadius.md))

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

        case .image(let alt, let url):
            if let imageURL = URL(string: url) {
                MarkdownImageView(alt: alt, url: imageURL)
            } else {
                Text("![\(alt)](\(url))")
                    .font(DocsFont.code)
                    .foregroundStyle(DocsColor.textPrimary)
            }

        case .unknown:
            if unknownRendersAsProse(block.text) {
                Text(markdownInlineText(block.text))
                    .font(DocsFont.body)
                    .foregroundStyle(DocsColor.textPrimary)
            } else {
                Text(block.text)
                    .font(DocsFont.code)
                    .foregroundStyle(DocsColor.textPrimary)
            }
        }
    }
}

/// Renders a document image inline. `AsyncImage` fetches through
/// `URLSession.shared`, which carries the `docs.llun.dev` session cookie from
/// `HTTPCookieStorage.shared`, so authenticated media loads without extra
/// plumbing. A failed load degrades to a tappable link so the URL is never lost.
struct MarkdownImageView: View {
    let alt: String
    let url: URL

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: DocsRadius.md))
                    .accessibilityLabel(alt.isEmpty ? "Image" : alt)
            case .failure:
                fallbackLink
            case .empty:
                placeholder
            @unknown default:
                placeholder
            }
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: DocsRadius.md)
            .fill(DocsColor.surfaceSunken)
            .frame(maxWidth: .infinity)
            .frame(height: 160)
            .overlay { ProgressView() }
            .accessibilityLabel(alt.isEmpty ? "Loading image" : "Loading image: \(alt)")
    }

    private var fallbackLink: some View {
        Link(destination: url) {
            HStack(spacing: DocsSpacing.spaceXS) {
                Image(systemName: "photo")
                Text(alt.isEmpty ? url.absoluteString : alt)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(DocsFont.footnote)
            .foregroundStyle(DocsColor.textBrand)
            .padding(DocsSpacing.spaceSM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DocsColor.surfaceSunken)
            .clipShape(RoundedRectangle(cornerRadius: DocsRadius.md))
        }
    }
}

#Preview {
    ScrollView {
        VStack(alignment: .leading, spacing: DocsSpacing.spaceSM) {
            MarkdownBlockView(block: EditorBlock(kind: .paragraph, text: "Visit https://docs.llun.dev for details."))
            MarkdownBlockView(
                block: EditorBlock(kind: .paragraph, text: "A [markdown link](https://example.com) inline."))
            MarkdownBlockView(block: EditorBlock(kind: .quote, text: "A quote should read as its own aside."))
            MarkdownBlockView(
                block: EditorBlock(kind: .unknown, text: "Line one with https://a.example\nLine two continues."))
            MarkdownBlockView(
                block: EditorBlock(kind: .image(alt: "diagram", url: "https://docs.llun.dev/media/sample.png")))
        }
        .padding()
    }
}
