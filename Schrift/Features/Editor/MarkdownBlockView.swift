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
    styleLinks(in: &attributed)
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
    }
}

/// Paints every link run — markdown's and the autolinker's alike — the way the
/// **editing** surface paints one: `textBrand`, single-underlined
/// (`InlineTextStyleResolver.style(for:)`'s `.link` arm).
///
/// Without this, a `[label](url)` run fell through to SwiftUI's default link
/// styling, which is the environment tint and carries no underline — so a
/// document's links changed colour *and* gained an underline the instant the
/// user tapped into edit mode. Applied after `autolinkBareURLs` so a bare URL
/// is styled by the same rule rather than by a second, nearly-identical one.
///
/// Note what this does **not** buy: the editing surface has no bare-URL
/// autolinker at all (that would mean teaching `InlineMarkdown` — the scanner
/// the full-overwrite save re-parses — a construct it does not model), so a
/// bare `https://…` is still brand-coloured while reading and plain while
/// editing. It is a colour difference on one run with no reflow, and closing it
/// is not worth touching that scanner.
///
/// The ranges are collected **before** anything is written. Setting an attribute
/// splits and merges runs, so mutating inside `for run in attributed.runs` would
/// be rewriting the collection being walked — and `AttributedString.Index` is
/// only guaranteed valid against the value it was taken from. Two links in one
/// paragraph is all it takes to reach that. (Same reason `autolinkBareURLs`
/// above collects its matches from a plain `String` snapshot first.)
private func styleLinks(in attributed: inout AttributedString) {
    let linkRanges = attributed.runs.filter { $0.link != nil }.map(\.range)
    for range in linkRanges {
        attributed[range].foregroundColor = DocsColor.textBrand
        attributed[range].underlineStyle = .single
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

/// The reading surface's half of the editor.
///
/// Every metric, font, colour and piece of chrome here comes from
/// `EditorBlockStyle` — the same table `BlockEditorRow` reads — so a block draws
/// identically whether the user is reading it or editing it. Do not reach for a
/// `DocsFont`/`DocsSpacing` token directly in this view: that is exactly how the
/// two surfaces drifted apart, and how tapping a block came to re-lay-out the
/// whole document.
struct MarkdownBlockView: View {
    let block: EditorBlock
    /// Origin the embedded image gate compares against (`imageLoadPolicy`), and
    /// the one an attachment link must be on to render as a card at all.
    /// Required (no default) so a new render site can't silently skip the gate.
    let serverOrigin: String
    var numberedIndex: Int = 1
    /// Chrome only: it changes what an *uncached* attachment card says, never
    /// whether a cached one opens.
    var isOffline: Bool = false

    @Environment(LocalizationStore.self) private var loc

    var body: some View {
        switch block.kind {
        case .divider:
            // Labelled, like the editing surface's divider: a rule the eye reads
            // as structure was silent to VoiceOver on this surface alone.
            Rectangle()
                .fill(DocsColor.borderDefault)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, EditorBlockMetrics.dividerVerticalPadding)
                .accessibilityLabel(loc[.editor_divider_a11y])

        case .image(let alt, let url):
            if let imageURL = URL(string: url) {
                MarkdownImageView(alt: alt, url: imageURL, serverOrigin: serverOrigin)
            } else {
                Text("![\(alt)](\(url))")
                    .font(DocsFont.code)
                    .foregroundStyle(DocsColor.textPrimary)
            }

        case .attachment(let name, let url):
            // Classification happens in the parser now, so this arm just draws
            // what it is given. An `AttachmentDisplay` is still rebuilt through
            // `parseAttachmentLink` rather than from the block's associated
            // values, because the card needs the validated document/file ids and
            // extension — and because a block whose url no longer matches this
            // server (a document opened after switching servers) must fall back
            // to plain link text rather than render a card it cannot load.
            if let display = parseAttachmentLink("[\(name)](\(url))", serverOrigin: serverOrigin) {
                AttachmentCardView(display: display, isOffline: isOffline)
            } else {
                Text(markdownInlineText("[\(name)](\(url))"))
                    .font(DocsFont.body)
                    .foregroundStyle(DocsColor.textPrimary)
            }

        default:
            textRow
        }
    }

    /// Every kind that carries text, drawn through the shared adornment slot,
    /// appearance table and decoration — the structural twin of
    /// `BlockEditorRow`'s editable row.
    private var textRow: some View {
        HStack(
            alignment: .top,
            spacing: blockHasAdornment(block.kind) ? EditorBlockMetrics.adornmentSpacing : 0
        ) {
            // No `onToggleChecklist`: the row's own tap enters the editor, so
            // the checkbox is drawn plain here and toggled there.
            EditorBlockAdornment(kind: block.kind, numberedIndex: numberedIndex)
            blockText
                .editorBlockDecoration(blockDecoration(for: block.kind, text: block.text))
        }
    }

    private var blockText: some View {
        let appearance = blockTextAppearance(for: block.kind, text: block.text)
        // A verbatim block's text is literal — running it through the markdown
        // parser would promise formatting its own panel says is not applied.
        let content =
            blockRendersVerbatim(block.kind, text: block.text)
            ? AttributedString(block.text) : markdownInlineText(block.text)
        return Text(content)
            .font(appearance.font)
            .foregroundStyle(appearance.color)
            .strikethrough(appearance.isStruckThrough)
            .accessibilityValue(checklistStateDescription ?? "")
    }

    /// A completed to-do's state, spoken.
    ///
    /// The eye reads it from the checkbox glyph and the strikethrough, and
    /// VoiceOver gets neither: `MaterialSymbol` is `accessibilityHidden` (its
    /// glyph is a Private-Use-Area character with no spoken text) and a
    /// strikethrough is not announced — so a checklist read aloud gave no clue
    /// which items were done. A *state*, not the editing checkbox's action label
    /// ("Mark as done"): nothing here toggles it, the row's tap enters the
    /// editor.
    ///
    /// Set on the `Text` itself rather than by collapsing the row with
    /// `.accessibilityElement(children: .combine)`. Combining would be the
    /// conventional way to give a row a value, but it flattens the element tree,
    /// and this `Text` can hold inline links that VoiceOver reaches through the
    /// Links rotor. Whether combining really would drop them is not something
    /// this repo can assert — it runs no VoiceOver tests — and between two
    /// options that both add the announcement, the one that cannot take anything
    /// away is the right bet.
    private var checklistStateDescription: String? {
        guard case .checklistItem(let checked) = block.kind else { return nil }
        return checked ? loc[.editor_checklist_state_done_a11y] : loc[.editor_checklist_state_not_done_a11y]
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
                // Same-origin uploaded attachment: renders as a card, not a link.
                MarkdownBlockView(
                    block: EditorBlock(kind: .paragraph, text: "[Q3 report.pdf](\(attachmentURL))"),
                    serverOrigin: serverOrigin)
                // The same card with nothing cached and no network.
                MarkdownBlockView(
                    block: EditorBlock(kind: .paragraph, text: "[Notes.docx](\(attachmentURL))"),
                    serverOrigin: serverOrigin, isOffline: true)
                // Off-origin link of the same shape: stays ordinary prose.
                MarkdownBlockView(
                    block: EditorBlock(
                        kind: .paragraph,
                        text: "[elsewhere.pdf](https://files.example/media/\(previewDocumentID)/attachments/x.pdf)"),
                    serverOrigin: serverOrigin)
            }
            .padding()
        }
    }

    private let serverOrigin = "https://docs.llun.dev"
    private let previewDocumentID = "11111111-1111-4111-8111-111111111111"
    private var attachmentURL: String {
        "\(serverOrigin)/media/\(previewDocumentID)/attachments/22222222-2222-4222-8222-222222222222.pdf"
    }
}

/// The card reads `AttachmentLoader` from the environment, so every preview that
/// can render one must inject it — transitively, for any parent that embeds this
/// view (see the environment-store rule in CLAUDE.md).
///
/// The **cache** is pre-seeded rather than the loader's state table, because
/// `loadIfNeeded` re-checks the disk even for an already-`.cached` entry (it has
/// to: eviction can delete a file out from under a live card). Seeding a state
/// alone would fall straight through to a real network request from the canvas.
/// A seeded file shows the state worth reviewing — a ready attachment — and asks
/// for nothing. The downloading/failed/offline states are pinned by
/// `attachmentCardState`'s tests.
@MainActor private func previewAttachmentLoader() -> AttachmentLoader {
    let origin = "https://docs.llun.dev"
    let ready =
        "\(origin)/media/11111111-1111-4111-8111-111111111111/attachments/"
        + "22222222-2222-4222-8222-222222222222.pdf"
    let cache = AttachmentCacheStore(
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("SchriftPreviewAttachments", isDirectory: true))
    if let display = parseAttachmentLink("[preview](\(ready))", serverOrigin: origin) {
        _ = cache.store(Data("%PDF-1.4\n%preview\n".utf8), for: display)
    }
    return AttachmentLoader(
        client: DocsAPIClient(baseURL: URL(string: "\(origin)/api/v1.0/")!),
        serverOrigin: origin,
        cache: cache)
}

#Preview("Light") {
    MarkdownBlockCatalog()
        .environment(LocalizationStore())
        .environment(previewAttachmentLoader())
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    MarkdownBlockCatalog()
        .environment(LocalizationStore())
        .environment(previewAttachmentLoader())
        .preferredColorScheme(.dark)
}
