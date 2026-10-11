import Foundation

/// Parses markdown into editor blocks, line by line.
///
/// Known constructs (heading, checklist, bullet, numbered item, quote, code
/// fence, divider) must start at column 0; anything else — indented content,
/// tables, images, HTML, multi-line runs — is grouped verbatim into `.unknown`
/// blocks so the save round-trip never destroys it.
///
/// The one indented construct that classifies is a **nested list item**: a
/// bullet, numbered or checklist line indented under the list item directly
/// above it (no blank line between), at or past that item's content column and
/// less than four columns past it (four more is indented code in CommonMark).
/// It becomes a list block with `indent` one deeper than its parent. Anything
/// that doesn't fit — a tab, a blank line before it, too little or too much
/// indentation, a line nested under prose, deeper than `maxListIndent` — stays
/// verbatim text exactly as before.
///
/// The other indented construct that classifies is a **nested leaf**: an image
/// line, or a line that is nothing but one `[label](url)` link, indented
/// *exactly* to the content column of an open list item directly above (no
/// blank line between) — the app's own spelling of a photo or a file nested
/// under a list item, as BlockNote nests them (`parseNestedLeaf`). It is read
/// conservatively: only when what follows it cannot be a lazy continuation of
/// it. The server's markdown export never writes this shape — it flattens a
/// nested leaf to a column-zero line after a blank one, which still parses flat.
///
/// Intentional canonicalizations (lossy on re-serialize):
/// - runs of blank lines collapse to a single separator
/// - `*` bullets become `-`; `N)` ordered markers become `N.`; ordered runs renumber from 1
/// - trailing whitespace on classified lines is trimmed (never inside code/unknown blocks)
/// - dividers of any length/character normalize to `---`
/// - a nested list item's (or nested leaf's) indentation normalizes to its parent's content column
///
/// `serverOrigin` enables attachment classification, and defaults to "" — which
/// classifies nothing, so every existing caller keeps exactly today's behavior.
/// Pass it only where the distinction matters: the encoder (a `.attachment`
/// becomes a BlockNote `file` node rather than a paragraph carrying a link) and
/// the editor (leaf semantics and insert verification).
///
/// **Classification lives here, in the single-line branch below, and must stay
/// here.** A `.attachment` serializes back to the identical line and is not
/// column-zero-classified, so an origin-aware parse and an origin-less one
/// produce the *same serialized markdown* for every input. That identity — held
/// by `MarkdownRoundTripTests.testAttachmentClassificationNeverChangesSerializedMarkdown`
/// — is what lets `canonicalMarkdown`, `draftSyncDecision` and the whole save
/// coordinator go on calling this without an origin and stay correct. Classify
/// in `parseClassifiedLine` instead and the identity breaks: an attachment line
/// adjacent to prose would split into two blocks under one parse and stay a
/// single `.unknown` under the other.
///
/// **The one sanctioned exception is a nested leaf** (`parseNestedLeaf`): an
/// indented link line under a list item is classified outside `flushPending`,
/// because it is a child block rather than a pending paragraph. It keeps the
/// identity by deciding *structure* without the origin — whether the line
/// becomes a nested child at all depends only on its origin-free shape
/// (`attachmentLinkShape`) — and letting the origin choose only the child's
/// kind: `.attachment` with one, `.paragraph` carrying the same link without.
/// Both nest alike (`blockNestsAsLeaf`) and serialize to the same line.
func parseEditorBlocks(_ markdown: String, serverOrigin: String = "") -> [EditorBlock] {
    parseEditorBlocksTracingLines(markdownLines(markdown), serverOrigin: serverOrigin).map(\.block)
}

/// `parseEditorBlocks` over lines already split by `markdownLines`, with the index of the line
/// each block starts on.
///
/// The line index is what lets a targeted rewrite of the source (the queued-photo rewriter and
/// remover below) touch **exactly** the lines the parser classified — never a second, hand-kept
/// copy of its rules, which would drift: an indented image line is an image block only at an
/// open list item's content column with a safe run after it (`parseNestedLeaf`), and verbatim
/// text (indented code, say) everywhere else.
private func parseEditorBlocksTracingLines(
    _ lines: [String], serverOrigin: String
) -> [(block: EditorBlock, line: Int)] {
    var blocks: [(block: EditorBlock, line: Int)] = []
    var pendingLines: [String] = []
    var index = 0
    // Content columns of the open list items, outermost first: what a nested
    // item's indentation is measured against. Empty whenever the previous line
    // wasn't a classified list item, so nesting never reaches across prose, a
    // blank line or verbatim text.
    var listContentColumns: [Int] = []

    func flushPending() {
        guard !pendingLines.isEmpty else { return }
        defer { pendingLines = [] }
        // Every pending line was consumed one by one, so the run started this many lines back.
        let start = index - pendingLines.count
        if pendingLines.count == 1, isPlainParagraphLine(pendingLines[0]) {
            let text = pendingLines[0].trimmingCharacters(in: .whitespaces)
            if let attachment = parseAttachmentLink(text, serverOrigin: serverOrigin) {
                blocks.append(
                    (EditorBlock(kind: .attachment(name: attachment.name, url: attachment.urlString)), start))
            } else {
                blocks.append((EditorBlock(kind: .paragraph, text: text), start))
            }
        } else {
            blocks.append((EditorBlock(kind: .unknown, text: pendingLines.joined(separator: "\n")), start))
        }
    }

    while index < lines.count {
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            flushPending()
            listContentColumns = []
            index += 1
            continue
        }

        if pendingLines.isEmpty, let nested = parseNestedListItem(line, contentColumns: &listContentColumns) {
            blocks.append((nested, index))
            index += 1
            continue
        }

        if pendingLines.isEmpty,
            let leaf = parseNestedLeaf(line, contentColumns: listContentColumns, serverOrigin: serverOrigin),
            nestedLeafRunEndsSafely(lines, after: index, contentColumns: Array(listContentColumns.prefix(leaf.indent)))
        {
            blocks.append((leaf, index))
            // A leaf opens no level of its own: what follows nests at most
            // beside it, under the same parent.
            listContentColumns = Array(listContentColumns.prefix(leaf.indent))
            index += 1
            continue
        }

        if let fence = parseCodeFenceOpening(line) {
            flushPending()
            listContentColumns = []
            let start = index
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
                (EditorBlock(kind: .codeBlock(language: fence.language), text: content.joined(separator: "\n")), start))
            continue
        }

        if isDividerLine(trimmed), line.first != " ", line.first != "\t" {
            flushPending()
            listContentColumns = []
            blocks.append((EditorBlock(kind: .divider), index))
            index += 1
            continue
        }

        if let block = parseClassifiedLine(line) {
            flushPending()
            listContentColumns = blockIsListItem(block.kind) ? [listMarkerWidth(of: line)] : []
            blocks.append((block, index))
            index += 1
            continue
        }

        pendingLines.append(line)
        listContentColumns = []
        index += 1
    }

    flushPending()
    return blocks
}

/// True when re-parsing the canonical serialization preserves every content
/// line of the source, so block editing can't silently lose anything. When
/// false the editor should default to markdown-source mode for safety.
func markdownSurvivesRoundTrip(_ markdown: String, serverOrigin: String = "") -> Bool {
    let once = serializeMarkdown(parseEditorBlocks(markdown, serverOrigin: serverOrigin))
    let twice = serializeMarkdown(parseEditorBlocks(once, serverOrigin: serverOrigin))
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
    // A nested list item's indentation is canonicalized like its marker: the
    // serializer re-indents it to its parent's content column, so the count
    // compares the item itself. Indentation is spaces only, as the parser's.
    let unindented = line.drop { $0 == " " }
    if unindented.count < line.count, let block = parseClassifiedLine(String(unindented)),
        blockIsListItem(block.kind)
    {
        return serializeBlock(block, numberedIndex: 1)
    }
    // A nested leaf is re-indented the same way, so it too compares unindented.
    // Applied to every indented leaf-shaped line, classified or not: a line kept
    // verbatim keeps its indentation on both sides, so both sides canonicalize
    // it alike.
    if unindented.count < line.count, isNestedLeafShape(String(unindented)) {
        return rstrip(String(unindented))
    }
    return rstrip(line)
}

/// A list line indented under the list item directly above it, as a list
/// block one level deeper than the item it nests under — or nil, leaving the
/// line to the verbatim path.
///
/// `contentColumns` holds the open items' content columns, outermost first.
/// The line nests under the deepest item whose content column it reaches, and
/// must stay within three columns of it: four more is indented code under that
/// item, not a child list. Indentation is spaces only — a tab's width is the
/// reader's to decide, so a tab-indented line stays verbatim.
private func parseNestedListItem(_ line: String, contentColumns: inout [Int]) -> EditorBlock? {
    guard !contentColumns.isEmpty, line.first == " " else { return nil }
    let leading = line.prefix { $0 == " " }.count
    let rest = String(line.dropFirst(leading))
    guard rest.first != "\t", var block = parseClassifiedLine(rest), blockIsListItem(block.kind) else { return nil }
    guard let parent = contentColumns.lastIndex(where: { $0 <= leading }),
        leading - contentColumns[parent] < 4, parent + 1 <= maxListIndent
    else { return nil }
    block.indent = parent + 1
    contentColumns = Array(contentColumns.prefix(parent + 1)) + [leading + listMarkerWidth(of: rest)]
    return block
}

/// An image line, or a line that is a single `[label](url)` link and nothing
/// else — what may nest under a list item as a leaf. Origin-free: this decides
/// structure, and structure must not depend on the origin.
private func isNestedLeafShape(_ rest: String) -> Bool {
    if parseImageLine(rest) != nil { return true }
    return isPlainParagraphLine(rest) && attachmentLinkShape(rstrip(rest)) != nil
}

/// An image or link line indented *exactly* to the content column of an open
/// list item, as a leaf nested one level under that item — or nil, leaving the
/// line to the paths that ran before nested leaves existed.
///
/// Stricter than `parseNestedListItem` on purpose: an exact column, not a band,
/// because the app's serializer is the only writer of this shape and always
/// writes the exact column; anything else stays verbatim. Spaces only, never a
/// tab, and no deeper than `maxListIndent`.
///
/// The kind is the one thing the origin decides: an image line is an `.image`;
/// a link line is an `.attachment` when `parseAttachmentLink` accepts it against
/// `serverOrigin` and a `.paragraph` carrying the link otherwise. Whether the
/// line nests at all never depends on the origin, which is what keeps an
/// origin-aware parse and an origin-less one serializing identically.
private func parseNestedLeaf(_ line: String, contentColumns: [Int], serverOrigin: String) -> EditorBlock? {
    guard !contentColumns.isEmpty, line.first == " " else { return nil }
    let leading = line.prefix { $0 == " " }.count
    let rest = String(line.dropFirst(leading))
    guard let parent = contentColumns.firstIndex(of: leading), parent + 1 <= maxListIndent else { return nil }
    if let image = parseImageLine(rest) {
        return EditorBlock(kind: .image(alt: image.alt, url: image.url), indent: parent + 1)
    }
    let link = rstrip(rest)
    guard isPlainParagraphLine(rest), attachmentLinkShape(link) != nil else { return nil }
    if let attachment = parseAttachmentLink(link, serverOrigin: serverOrigin) {
        return EditorBlock(kind: .attachment(name: attachment.name, url: attachment.urlString), indent: parent + 1)
    }
    return EditorBlock(kind: .paragraph, text: link, indent: parent + 1)
}

/// Whether the nested leaf on line `index` — together with any further nested
/// leaves straight after it — is followed by something that cannot be read as
/// a lazy continuation of it: the end of the document, a blank line, a
/// column-zero fence, divider or classified line, or a nested list item.
///
/// Anything else (indented prose, a column-zero paragraph) would make the run
/// one paragraph in CommonMark, so the leaf declines and the whole run takes
/// the verbatim path it took before nested leaves existed. Scanning the *run*
/// rather than one line ahead is what makes that all-or-nothing: a leaf is
/// never classified while the sibling after it falls to verbatim text, which
/// would split one source paragraph into two blocks.
///
/// `contentColumns` is the list as it stands *after* the leaf on `index`.
private func nestedLeafRunEndsSafely(_ lines: [String], after index: Int, contentColumns: [Int]) -> Bool {
    var columns = contentColumns
    var cursor = index + 1
    while cursor < lines.count {
        let next = lines[cursor]
        let trimmed = next.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        var listColumns = columns
        if parseNestedListItem(next, contentColumns: &listColumns) != nil { return true }
        if let sibling = parseNestedLeaf(next, contentColumns: columns, serverOrigin: "") {
            columns = Array(columns.prefix(sibling.indent))
            cursor += 1
            continue
        }
        if parseCodeFenceOpening(next) != nil { return true }
        if isDividerLine(trimmed), next.first != " ", next.first != "\t" { return true }
        return parseClassifiedLine(next) != nil
    }
    return true
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

    // The lines the parser itself reads as this record's image block — so a column-zero image
    // line, and an indented one exactly where the parser nests it under a list item, and
    // nothing else: not one inside a code fence, and not an indented code line that merely
    // spells one (a rewrite there would change verbatim text the hold never counted).
    for index in pendingAttachmentImageLines(lines.map(\.content), localID: localID) {
        let line = lines[index].content
        guard let image = parseImageLine(String(line.drop { $0 == " " })) else { continue }
        // Replace the destination as it is actually spelled on the line, searching backwards so
        // an alt text that happens to spell the same placeholder is left alone — the destination
        // is the last occurrence by construction.
        guard let range = line.range(of: image.url, options: .backwards) else { continue }
        lines[index].content = line.replacingCharacters(in: range, with: resolvedURL)
    }

    return lines.map { $0.content + $0.terminator }.joined()
}

/// Removes the image line naming a queued photo, leaving every other byte alone.
///
/// The counterpart to the rewriter, and needed for the same reason it is: in reading mode
/// `currentMarkdown()` is `rawMarkdown`, not a serialization of `blocks`, so dropping the block
/// alone leaves the placeholder in the body that actually gets saved — and once the record is
/// discarded nothing can ever resolve it, which parks the document's saves with no image left
/// on screen to remove.
///
/// Takes the line's terminator with it so removal doesn't leave a stray blank line behind.
func markdownRemovingPendingAttachment(_ markdown: String, localID: UUID) -> String {
    guard markdown.range(of: pendingAttachmentURLPrefix, options: .caseInsensitive) != nil else { return markdown }
    let lines = markdownLinesWithTerminators(markdown)
    // Exactly the lines the parser reads as this record's image block — see the rewriter above.
    let removed = pendingAttachmentImageLines(lines.map(\.content), localID: localID)
    return lines.indices.filter { !removed.contains($0) }.map { lines[$0].content + lines[$0].terminator }.joined()
}

/// The indices of the lines `parseEditorBlocks` reads as an image block naming `localID`.
///
/// Asked of the parser rather than re-derived, because the hold predicate
/// (`markdownReferencesPendingAttachment`) *is* the parser: whatever it counts as this record's
/// image, the rewriter must rewrite and the remover must remove, and nothing else. A column-zero
/// image line, or an indented one at an open list item's content column (a photo nested under
/// an item); never a line inside a code fence, and never an indented line the parser keeps
/// verbatim — indented code, or an image line under prose.
private func pendingAttachmentImageLines(_ lines: [String], localID: UUID) -> Set<Int> {
    Set(
        parseEditorBlocksTracingLines(lines, serverOrigin: "").compactMap { entry in
            guard case .image(_, let url) = entry.block.kind, pendingAttachmentID(fromPlaceholderURL: url) == localID
            else { return nil }
            return entry.line
        })
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
