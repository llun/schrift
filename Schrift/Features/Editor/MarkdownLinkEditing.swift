import Foundation

/// Creating, retargeting and removing `[label](url)` in a block's markdown
/// source. Pure string surgery in UTF-16 coordinates — the same coordinates the
/// caret uses — so the editor never needs to know that a link is anything other
/// than characters.

/// A rewritten source plus the selection to request afterwards.
struct MarkdownLinkEdit: Equatable {
    let text: String
    let selection: NSRange
}

/// The link whose `[label](url)` extent contains `offset`, if any. Drives both
/// the tap-to-edit menu and the sheet's prefill.
func linkSpan(in text: String, containing offset: Int) -> InlineLinkSpan? {
    InlineMarkdown.layout(of: text).links.first { NSLocationInRange(offset, $0.range) }
}

/// Wraps `range` (or inserts at a collapsed caret) as a markdown link. The
/// caret lands *after* the link, so typing on does not extend it.
func insertMarkdownLink(in text: String, range: NSRange, label: String, url: String) -> MarkdownLinkEdit {
    let markdown = markdownLink(label: label, url: url)
    return replacing(range, in: text, with: markdown)
}

/// Retargets an existing link in place.
func replaceMarkdownLink(in text: String, span: InlineLinkSpan, label: String, url: String) -> MarkdownLinkEdit {
    replacing(span.range, in: text, with: markdownLink(label: label, url: url))
}

/// Unwraps a link, keeping its text.
///
/// The **raw** label substring is kept, escapes and all — not `span.label`. A
/// label authored as `\*text\*` displays as `*text*`, and re-inserting that
/// unescaped would turn the leftover text into italics. Preserving the source
/// bytes is the only rewrite that changes nothing but the link.
func removeMarkdownLink(in text: String, span: InlineLinkSpan) -> MarkdownLinkEdit {
    let rawLabel = (text as NSString).substring(with: span.labelRange)
    return replacing(span.range, in: text, with: rawLabel)
}

private func replacing(_ range: NSRange, in text: String, with markdown: String) -> MarkdownLinkEdit {
    let source = text as NSString
    var range = range
    range.location = min(max(0, range.location), source.length)
    range.length = min(max(0, range.length), source.length - range.location)
    return MarkdownLinkEdit(
        text: source.replacingCharacters(in: range, with: markdown),
        selection: NSRange(location: range.location + (markdown as NSString).length, length: 0)
    )
}

private func markdownLink(label: String, url: String) -> String {
    "[" + escapedLinkLabel(label) + "](" + url + ")"
}

/// Escapes what would otherwise terminate the label early or re-enter the
/// markdown grammar. `InlineMarkdown` honours backslash escapes when it looks
/// for the closing `]`, and unescapes the label afterwards, so this round-trips
/// exactly. Newlines cannot appear in a single-line block and would break the
/// link across a line, so they collapse to spaces.
func escapedLinkLabel(_ label: String) -> String {
    var escaped = ""
    for character in label {
        switch character {
        case "\\", "[", "]":
            escaped.append("\\")
            escaped.append(character)
        case "\n", "\r":
            escaped.append(" ")
        default:
            escaped.append(character)
        }
    }
    return escaped
}

/// The allowlist. Anything else — `javascript:`, `data:`, `file:` — never
/// becomes a link.
private let allowedLinkSchemes: Set<String> = ["http", "https", "mailto", "tel"]

/// Validates a user-typed destination, returning the exact string to embed, or
/// nil when it cannot be made safe.
///
/// The rejections are not fussiness; each one is a URL that `InlineMarkdown`
/// would read back differently from what was written:
///
/// * **`(` and `)`** — `matchLink` ends the destination at the *first* `)` and,
///   unlike `parseImageLine`, does not balance parentheses. It also never
///   unescapes the destination, so `\)` would be stored *with* its backslash.
///   There is no spelling of a parenthesised URL that survives the round trip.
/// * **`\`** — `matchLink` honours escapes while hunting for the closing `)`,
///   so a trailing backslash would swallow it.
/// * **whitespace** — ends the destination in CommonMark.
///
/// A scheme-less input gets `https://`, matching what the web editor does.
/// The result is returned verbatim rather than through `URL.absoluteString`:
/// the backend matches the embedded destination byte for byte.
func sanitizedLinkURL(_ input: String) -> String? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
        !trimmed.contains(where: \.isWhitespace),
        !trimmed.contains("("),
        !trimmed.contains(")"),
        !trimmed.contains("\\")
    else { return nil }

    let candidate = URL(string: trimmed)?.scheme == nil ? "https://" + trimmed : trimmed
    guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
        allowedLinkSchemes.contains(scheme)
    else { return nil }
    // `https://` on its own parses, with no host to go to.
    if scheme == "http" || scheme == "https" {
        guard let host = url.host, !host.isEmpty else { return nil }
    }
    return candidate
}
