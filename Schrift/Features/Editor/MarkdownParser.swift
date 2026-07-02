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
            blocks.append(EditorBlock(kind: .codeBlock(language: fence.language), text: content.joined(separator: "\n")))
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
    return nil
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
