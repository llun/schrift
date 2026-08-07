import Foundation

/// Parses markdown into editor blocks, line by line.
///
/// Known constructs (heading, checklist, bullet, numbered item, quote, code
/// fence, divider) must start at column 0; anything else — indented content,
/// tables, images, HTML, multi-line runs — is grouped verbatim into `.unknown`
/// blocks so the save round-trip never destroys it.
///
/// Intentional canonicalizations (lossy on re-serialize):
/// - runs of blank lines collapse to a single separator
/// - `*` bullets become `-`; `N)` ordered markers become `N.`; ordered runs renumber from 1
/// - trailing whitespace on classified lines is trimmed (never inside code/unknown blocks)
/// - dividers of any length/character normalize to `---`
func parseEditorBlocks(_ markdown: String) -> [EditorBlock] {
    var blocks: [EditorBlock] = []
    var pendingLines: [String] = []
    let lines = markdownLines(markdown)
    var index = 0

    func flushPending() {
        guard !pendingLines.isEmpty else { return }
        defer { pendingLines = [] }
        if pendingLines.count == 1, isPlainParagraphLine(pendingLines[0]) {
            blocks.append(EditorBlock(kind: .paragraph, text: pendingLines[0].trimmingCharacters(in: .whitespaces)))
        } else {
            blocks.append(EditorBlock(kind: .unknown, text: pendingLines.joined(separator: "\n")))
        }
    }

    while index < lines.count {
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            flushPending()
            index += 1
            continue
        }

        if let fence = parseCodeFenceOpening(line) {
            flushPending()
            index += 1
            var content: [String] = []
            while index < lines.count, !closesCodeFence(lines[index], openingLength: fence.length) {
                content.append(lines[index])
                index += 1
            }
            if index < lines.count {
                index += 1
            }
            blocks.append(
                EditorBlock(kind: .codeBlock(language: fence.language), text: content.joined(separator: "\n")))
            continue
        }

        if isDividerLine(trimmed), line.first != " ", line.first != "\t" {
            flushPending()
            blocks.append(EditorBlock(kind: .divider))
            index += 1
            continue
        }

        if let block = parseClassifiedLine(line) {
            flushPending()
            blocks.append(block)
            index += 1
            continue
        }

        pendingLines.append(line)
        index += 1
    }

    flushPending()
    return blocks
}

/// True when re-parsing the canonical serialization preserves every content
/// line of the source, so block editing can't silently lose anything. When
/// false the editor should default to markdown-source mode for safety.
func markdownSurvivesRoundTrip(_ markdown: String) -> Bool {
    let once = serializeMarkdown(parseEditorBlocks(markdown))
    let twice = serializeMarkdown(parseEditorBlocks(once))
    guard once == twice else { return false }
    return canonicalLineCounts(markdown) == canonicalLineCounts(once)
}

/// Splits into lines with line endings normalized: splitting on the
/// `.newlines` character set would turn every CRLF into a spurious blank line
/// and break multi-line runs apart.
private func markdownLines(_ markdown: String) -> [String] {
    markdown
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .components(separatedBy: "\n")
}

private func canonicalLineCounts(_ markdown: String) -> [String: Int] {
    var counts: [String: Int] = [:]
    for line in markdownLines(markdown) {
        let canonical = canonicalizeLine(line)
        guard !canonical.isEmpty else { continue }
        counts[canonical, default: 0] += 1
    }
    return counts
}

private func canonicalizeLine(_ line: String) -> String {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return "" }

    if isDividerLine(trimmed), line.first != " ", line.first != "\t" {
        return "---"
    }
    // Fence lines normalize to a bare fence plus language so the serializer's
    // canonical (or escalated) fences compare equal to the source's.
    if let fence = parseCodeFenceOpening(line) {
        return "```" + fence.language
    }
    // Mirror the parser's own canonical form for classified lines. This must
    // see the raw line — the individual parsers do their own trimming.
    if let block = parseClassifiedLine(line) {
        return serializeBlock(block, numberedIndex: 1)
    }
    return rstrip(line)
}

private func rstrip(_ line: String) -> String {
    var result = line
    while let last = result.last, last == " " || last == "\t" {
        result.removeLast()
    }
    return result
}

// MARK: - Line classification (column-0 anchored)

private func parseClassifiedLine(_ line: String) -> EditorBlock? {
    if let heading = parseHeading(line) {
        return heading
    }
    if let checklistItem = parseChecklistItem(line) {
        return checklistItem
    }
    if let bullet = parseBulletItem(line) {
        return bullet
    }
    if let quote = parseQuote(line) {
        return quote
    }
    if let numbered = parseNumberedItem(line) {
        return numbered
    }
    if let image = parseImageLine(line) {
        return EditorBlock(kind: .image(alt: image.alt, url: image.url))
    }
    return nil
}

/// A single standalone `![alt](url)` line at column zero with an absolute
/// http(s) URL — or the app's own `schrift-attachment://` placeholder, which is
/// the one non-http scheme that classifies, and only because the editor mints it
/// (see `PendingAttachmentStore`). Anything ambiguous — a relative URL, trailing
/// text, a `]` in the
/// alt, leading indentation, an unbalanced `)` in the url — is left to the
/// `.unknown` path so a full-overwrite save can never corrupt content the editor
/// doesn't fully model. `alt`/`url` are returned as raw substrings, never
/// normalized (the backend matches the url byte-for-byte). Because
/// `parseClassifiedLine` feeds both classification and `canonicalizeLine`, adding
/// this keeps the two consistent automatically.
///
/// A placeholder has to classify here rather than fall to `.unknown` for three
/// reasons that all point the same way: `addsImage` verifies an insertion by
/// re-parsing and counting `.image` blocks, so an unclassified placeholder would
/// report every queued photo as a failed insert; `.unknown` blocks are excluded
/// from live-write eligibility, so a queued photo would silently drop the
/// document out of collaboration; and the block has to survive the round trip as
/// an image so the rewrite below can find it again. What keeps it off the wire is
/// the save hold, not the classification.
private func parseImageLine(_ line: String) -> (alt: String, url: String)? {
    guard line.first == "!" else { return nil }
    let trimmed = rstrip(line)
    guard trimmed.hasPrefix("!["), trimmed.hasSuffix(")") else { return nil }
    guard let separator = trimmed.range(of: "](") else { return nil }

    let alt = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<separator.lowerBound])
    let urlString = String(trimmed[separator.upperBound..<trimmed.index(before: trimmed.endIndex)])
    guard !alt.contains("]"), !urlString.isEmpty else { return nil }
    // The closing `)` is taken to be the line's last character, but CommonMark
    // ends the destination at the first *unbalanced* `)`. When the two disagree
    // (`![a](u)(y)`) the line has trailing content: bail out rather than save a
    // mangled url and silently drop the tail. Balanced pairs (`x(1).png`) are fine.
    guard !urlString.contains(where: \.isWhitespace), hasBalancedParentheses(urlString) else { return nil }
    // The placeholder scheme classifies only when it resolves to an actual record id. Comparing
    // the scheme alone would let `schrift-attachment://<uuid>?x=1`, `schrift-attachment:<uuid>`
    // and friends through as image blocks that `pendingAttachmentID` does not recognise — so no
    // save hold would engage and the unresolvable URL would reach collaborators. Deferring to
    // the same function the hold uses makes the two exact by construction rather than by two
    // tests kept in sync; anything it declines falls to `.unknown` and round-trips verbatim.
    guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
        scheme == "http" || scheme == "https"
            || (scheme == pendingAttachmentURLScheme && pendingAttachmentID(fromPlaceholderURL: urlString) != nil)
    else { return nil }
    return (alt, urlString)
}

// MARK: - Pending attachment placeholders

/// Whether this markdown contains a queued-photo placeholder **as an image block**.
///
/// This is the predicate the save hold is keyed on, and it is the reason the hold is safe: it
/// asks about the content a save is about to push rather than about the attachment store, so a
/// store that cannot be read stalls the replay instead of leaking a placeholder to the server.
///
/// Parse-based deliberately. A substring test would hold a document's saves forever because
/// someone wrote the scheme inside a code block or a sentence, and the escape from such a hold
/// (deleting the image leaf) would not exist — there would be no leaf. The prefix check is only
/// a fast path, and it is **case-insensitive** to match `parseImageLine`'s scheme comparison: a
/// case-sensitive one would skip the parse for `SCHRIFT-ATTACHMENT://…`, which classifies as an
/// image block, and that placeholder would be pushed to the server.
func markdownReferencesPendingAttachment(_ markdown: String) -> Bool {
    guard markdown.range(of: pendingAttachmentURLPrefix, options: .caseInsensitive) != nil else { return false }
    return parseEditorBlocks(markdown).contains { block in
        guard case .image(_, let url) = block.kind else { return false }
        return pendingAttachmentID(fromPlaceholderURL: url) != nil
    }
}

/// Whether this markdown names **one specific** queued photo as an image block.
///
/// The record-scoped counterpart of the predicate above, used by the replay to decide whether a
/// record is still referenced (and so whether collecting it would strand a placeholder) rather
/// than whether *any* photo is pending.
func markdownReferencesPendingAttachment(_ markdown: String, localID: UUID) -> Bool {
    guard markdown.range(of: pendingAttachmentURLPrefix, options: .caseInsensitive) != nil else { return false }
    return parseEditorBlocks(markdown).contains { block in
        guard case .image(_, let url) = block.kind else { return false }
        return pendingAttachmentID(fromPlaceholderURL: url) == localID
    }
}

/// Replaces a queued photo's placeholder with the media URL its upload resolved to, leaving
/// every other byte of the document alone.
///
/// Targeted replacement rather than a parse-and-re-serialize round trip: a draft can hold
/// server-authored markdown whose serialization is deliberately lossy (blank-line runs collapse,
/// `*` bullets become `-`, ordered runs renumber), and this runs from a background pass, so
/// canonicalizing here would rewrite content the user never touched. Only lines that classify as
/// an image block naming this record are touched, so a mention inside a code block or a sentence
/// is left as the text it is.
///
/// **Keyed on the record, not on the placeholder's spelling.** `pendingAttachmentID` accepts a
/// trailing slash and either case, so the hold predicate treats those as the same photo — and a
/// rewriter matching the canonical URL byte-for-byte would then hold a document it could never
/// release. The two must agree on identity or the difference is a permanent wedge.
func markdownRewritingPendingAttachment(
    _ markdown: String,
    localID: UUID,
    resolvedURL: String
) -> String {
    guard markdown.range(of: pendingAttachmentURLPrefix, options: .caseInsensitive) != nil else { return markdown }
    var lines = markdownLinesWithTerminators(markdown)
    var openFenceLength: Int?

    for index in lines.indices {
        let line = lines[index].content

        if let length = openFenceLength {
            if closesCodeFence(line, openingLength: length) { openFenceLength = nil }
            continue
        }
        if let fence = parseCodeFenceOpening(line) {
            openFenceLength = fence.length
            continue
        }
        guard let image = parseImageLine(line),
            pendingAttachmentID(fromPlaceholderURL: image.url) == localID
        else { continue }
        // Replace the destination as it is actually spelled on the line, searching backwards so
        // an alt text that happens to spell the same placeholder is left alone — the destination
        // is the last occurrence by construction.
        guard let range = line.range(of: image.url, options: .backwards) else { continue }
        lines[index].content = line.replacingCharacters(in: range, with: resolvedURL)
    }

    return lines.map { $0.content + $0.terminator }.joined()
}

/// Splits into (content, terminator) pairs, so rejoining reproduces the input byte for byte.
///
/// `parseEditorBlocks` normalizes CRLF **and a lone CR** to LF before classifying. A rewriter
/// that split on `"\n"` alone would disagree with it on a CR-only document: the predicate would
/// see an image block where the rewriter saw one unparseable line, holding a placeholder it
/// could never rewrite. Agreeing on line boundaries is what keeps the two in step.
private func markdownLinesWithTerminators(_ markdown: String) -> [(content: String, terminator: String)] {
    var lines: [(content: String, terminator: String)] = []
    var current = ""
    var index = markdown.startIndex

    while index < markdown.endIndex {
        let character = markdown[index]
        let next = markdown.index(after: index)
        // CRLF is **one** `Character` in Swift — a single grapheme cluster — so it must be
        // matched as itself. Comparing against "\r" and "\n" separately silently misses every
        // CRLF document, which then collapses into a single line and rewrites nothing.
        if character == "\r\n" || character == "\r" || character == "\n" {
            lines.append((current, String(character)))
            current = ""
        } else {
            current.append(character)
        }
        index = next
    }
    lines.append((current, ""))
    return lines
}

private func hasBalancedParentheses(_ text: String) -> Bool {
    var depth = 0
    for character in text {
        if character == "(" {
            depth += 1
        } else if character == ")" {
            depth -= 1
            if depth < 0 { return false }
        }
    }
    return depth == 0
}

private func parseHeading(_ line: String) -> EditorBlock? {
    var level = 0
    var index = line.startIndex
    while index < line.endIndex, line[index] == "#", level < 6 {
        level += 1
        index = line.index(after: index)
    }
    guard level > 0, index < line.endIndex, line[index] == " " else { return nil }
    let text = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
    return EditorBlock(kind: .heading(level: level), text: text)
}

private func parseChecklistItem(_ line: String) -> EditorBlock? {
    for prefix in ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] ", "* [X] "] {
        if line.hasPrefix(prefix) {
            let checked = prefix.contains("x") || prefix.contains("X")
            let text = rstrip(String(line.dropFirst(prefix.count)))
            return EditorBlock(kind: .checklistItem(checked: checked), text: text)
        }
    }
    return nil
}

private func parseBulletItem(_ line: String) -> EditorBlock? {
    for prefix in ["- ", "* "] {
        if line.hasPrefix(prefix) {
            return EditorBlock(kind: .bulletItem, text: rstrip(String(line.dropFirst(prefix.count))))
        }
    }
    return nil
}

private func parseQuote(_ line: String) -> EditorBlock? {
    guard line.hasPrefix(">") else { return nil }
    // The marker consumes exactly one optional space; further leading
    // whitespace is significant content (e.g. indented code in a blockquote)
    // and must survive the round trip.
    var rest = String(line.dropFirst())
    if rest.hasPrefix(" ") {
        rest.removeFirst()
    }
    return EditorBlock(kind: .quote, text: rstrip(rest))
}

private func parseNumberedItem(_ line: String) -> EditorBlock? {
    var index = line.startIndex
    var digits = 0
    while index < line.endIndex, line[index].isNumber, digits < 10 {
        digits += 1
        index = line.index(after: index)
    }
    guard digits >= 1, digits <= 9, index < line.endIndex else { return nil }
    guard line[index] == "." || line[index] == ")" else { return nil }
    index = line.index(after: index)
    guard index < line.endIndex, line[index] == " " else { return nil }
    let text = rstrip(String(line[line.index(after: index)...]))
    return EditorBlock(kind: .numberedItem, text: text)
}

// MARK: - Code fences and dividers

private func parseCodeFenceOpening(_ line: String) -> (length: Int, language: String)? {
    guard line.hasPrefix("```") else { return nil }
    var length = 0
    var index = line.startIndex
    while index < line.endIndex, line[index] == "`" {
        length += 1
        index = line.index(after: index)
    }
    let rest = line[index...].trimmingCharacters(in: .whitespaces)
    guard !rest.contains("`") else { return nil }
    return (length, rest)
}

private func closesCodeFence(_ line: String, openingLength: Int) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.count >= openingLength else { return false }
    return trimmed.allSatisfy { $0 == "`" }
}

private func isDividerLine(_ trimmed: String) -> Bool {
    guard trimmed.count >= 3, let first = trimmed.first else { return false }
    guard first == "-" || first == "*" || first == "_" else { return false }
    return trimmed.allSatisfy { $0 == first }
}

private func isPlainParagraphLine(_ line: String) -> Bool {
    guard let first = line.first, first != " ", first != "\t" else { return false }
    return !line.hasPrefix("|") && !line.hasPrefix("![") && !line.hasPrefix("<")
}
