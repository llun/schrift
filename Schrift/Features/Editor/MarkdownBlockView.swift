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
    /// Origin the embedded image gate compares against (`imageLoadPolicy`).
    /// Required (no default) so a new render site can't silently skip the gate.
    let serverOrigin: String
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
                MaterialSymbol(checked ? .check_box : .check_box_outline_blank, size: 20)
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
                MarkdownImageView(alt: alt, url: imageURL, serverOrigin: serverOrigin)
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

/// Renders a document image inline. When the image is same-origin as the user's
/// Docs server (`imageLoadPolicy`) it fetches through `URLSession.shared`, which
/// carries the session cookie from `HTTPCookieStorage.shared`, so authenticated
/// media loads without extra plumbing. An image from any other origin renders a
/// tap-to-load placeholder and issues no request until the reader taps it — an
/// off-origin `AsyncImage` would leak the reader's IP/User-Agent/timing to a host
/// the document's author chose. A failed load degrades to a tappable link so the
/// URL is never lost.
///
/// Known residual: `AsyncImage` follows HTTP redirects, so a same-origin URL that
/// the user's own server 302s off-origin still leaks. Out of v1 scope (see the
/// architecture doc); the fix would be a custom loader with a redirect-blocking
/// `URLSession` delegate.
struct MarkdownImageView: View {
    let alt: String
    let url: URL
    /// `siteOrigin(for:)` of the signed-in server. "" blocks everything — the
    /// safe direction.
    let serverOrigin: String

    @Environment(LocalizationStore.self) private var loc

    /// The cross-origin URL the reader approved, if any. Held as the *URL*, not a
    /// `Bool`: `applyLiveRemoteChange` reuses a surviving block's `EditorBlock.id`,
    /// so this view's identity — and this `@State` — outlives a content change, and
    /// consent for one host must never carry to a URL an edit later swapped in.
    /// View-local and never persisted: approval is one URL, one session.
    @State private var approvedURL: URL?

    private var shouldLoad: Bool {
        imageLoadPolicy(for: url, serverOrigin: serverOrigin) == .allow || approvedURL == url
    }

    var body: some View {
        if shouldLoad { remoteImage } else { tapToLoad }
    }

    private var remoteImage: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: DocsRadius.md))
                    .accessibilityLabel(alt.isEmpty ? loc[.editor_image_a11y] : alt)
            case .failure:
                fallbackLink
            case .empty:
                placeholder
            @unknown default:
                placeholder
            }
        }
    }

    /// Off-origin: a card (the same family as `fallbackLink` — "we are not showing
    /// the image", not the spinner that promises one is coming) that fetches only
    /// when tapped. `Button` rather than `.onTapGesture` so it takes the tap from
    /// the reading row's own tap-to-edit gesture, carries the button trait, and
    /// flattens its two labels into one accessibility element.
    private var tapToLoad: some View {
        Button {
            approvedURL = url
        } label: {
            HStack(alignment: .top, spacing: DocsSpacing.spaceXS) {
                MaterialSymbol(.image, size: 16)
                    .foregroundStyle(DocsColor.textTertiary)
                VStack(alignment: .leading, spacing: DocsSpacing.space4xs) {
                    Text(loc[.editor_image_external])
                        .foregroundStyle(DocsColor.textBrand)
                    if let host = url.host {
                        // host is document content — never localized.
                        Text(host)
                            .foregroundStyle(DocsColor.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .font(DocsFont.footnote)
            .padding(DocsSpacing.spaceSM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DocsColor.surfaceSunken)
            .clipShape(RoundedRectangle(cornerRadius: DocsRadius.md))
            .contentShape(RoundedRectangle(cornerRadius: DocsRadius.md))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(loc.format(.editor_image_external_a11y, url.host ?? url.absoluteString))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: DocsRadius.md)
            .fill(DocsColor.surfaceSunken)
            .frame(maxWidth: .infinity)
            .frame(height: 160)
            .overlay { ProgressView() }
            .accessibilityLabel(
                alt.isEmpty ? loc[.editor_image_loading_a11y] : loc.format(.editor_image_loading_named_a11y, alt))
    }

    private var fallbackLink: some View {
        Link(destination: url) {
            HStack(spacing: DocsSpacing.spaceXS) {
                MaterialSymbol(.image, size: 16)
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

private struct MarkdownBlockCatalog: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DocsSpacing.spaceSM) {
                MarkdownBlockView(
                    block: EditorBlock(kind: .paragraph, text: "Visit https://docs.llun.dev for details."),
                    serverOrigin: serverOrigin)
                MarkdownBlockView(
                    block: EditorBlock(kind: .paragraph, text: "A [markdown link](https://example.com) inline."),
                    serverOrigin: serverOrigin)
                MarkdownBlockView(
                    block: EditorBlock(kind: .quote, text: "A quote should read as its own aside."),
                    serverOrigin: serverOrigin)
                MarkdownBlockView(
                    block: EditorBlock(kind: .unknown, text: "Line one with https://a.example\nLine two continues."),
                    serverOrigin: serverOrigin)
                // Same-origin attachment: auto-loads.
                MarkdownBlockView(
                    block: EditorBlock(kind: .image(alt: "diagram", url: "https://docs.llun.dev/media/sample.png")),
                    serverOrigin: serverOrigin)
                // Off-origin image: tap-to-load placeholder.
                MarkdownBlockView(
                    block: EditorBlock(kind: .image(alt: "tracker", url: "https://tracker.example/beacon.png")),
                    serverOrigin: serverOrigin)
            }
            .padding()
        }
    }

    private let serverOrigin = "https://docs.llun.dev"
}

#Preview("Light") {
    MarkdownBlockCatalog()
        .environment(LocalizationStore())
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    MarkdownBlockCatalog()
        .environment(LocalizationStore())
        .preferredColorScheme(.dark)
}
