import Foundation

/// Paste-oriented Markdown → BlockNote block parser.
///
/// Unlike `parseEditorBlocks` (which conservatively packs unrecognized
/// constructs into `.unknown` for lossless save round-trips), this parser turns
/// pasted Markdown into BlockNote `blockContainer` copies for headings
/// (`#`–`######`, 4–6 clamped to 3), nested bullet/numbered/checklist lists,
/// quotes, fenced code blocks (with language), dividers, GFM tables (reusing
/// `parseMarkdownTable`), `https://` images (reusing `MediaBlock.pastedURL`),
/// and inline marks/sanitized links (reusing `InlineMarkdown`).
///
/// Outside fenced code blocks, each single line break starts a new paragraph.
/// Plain text containing no Markdown syntax produces plain paragraphs
/// line-for-line identical to multi-line plain-text paste.
enum BlockNoteMarkdownPaste {
    enum Error: Swift.Error, Equatable {
        case tooLarge
    }

    /// Parses pasted Markdown or plain text into BlockNote `blockContainer`
    /// copies. Throws `.tooLarge` when UTF-16 length, line count, block count
    /// or table size exceed clipboard bounds. Returns `[]` for empty input or
    /// input whose only elements were dropped (such as non-`https` images).
    static func parse(_ raw: String) throws -> [BlockNoteWriter.Copy] {
        let stripped = NativeClipboard.strippingObjectReplacementCharacters(raw)
        let normalized = NativeClipboard.normalizingLineBreaks(stripped)
        guard !NativeClipboard.isTooLarge(normalized) else { throw Error.tooLarge }
        guard !normalized.isEmpty else { return [] }
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var parser = Parser(lines: lines)
        return try parser.parse()
    }

    /// Parses Markdown and encodes the resulting blocks as a
    /// `BlockNoteSubtreePayload`, or returns `nil` when no blocks remain.
    static func payload(_ raw: String) throws -> Data? {
        let blocks = try parse(raw)
        guard !blocks.isEmpty else { return nil }
        do {
            return try BlockNoteSubtreePayload.encode(blocks)
        } catch BlockNoteSubtreePayload.Error.tooLarge {
            throw Error.tooLarge
        }
    }

    // MARK: - Parser

    private struct Parser {
        private struct ListNode {
            var id: String
            var node: String
            var props: [(key: String, value: YAnyValue)]
            var content: [BlockNoteWriter.Copy]
            var children: [ListNode] = []
            let indent: Int
            let depth: Int
        }

        let lines: [String]
        private var nextID = 1
        private var blockCount = 0
        private var sawMarkdown = false
        private var blocks: [BlockNoteWriter.Copy] = []
        private var listRoots: [ListNode] = []
        /// Path of indices into `listRoots` representing the open ancestor chain.
        private var listPath: [Int] = []

        private mutating func mintID() throws -> String {
            blockCount += 1
            guard blockCount <= BlockNoteSubtreePayload.maxBlocks else { throw Error.tooLarge }
            defer { nextID += 1 }
            return "md-\(nextID)"
        }

        mutating func parse() throws -> [BlockNoteWriter.Copy] {
            var index = 0
            while index < lines.count {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if trimmed.isEmpty {
                    flushList()
                    index += 1
                    continue
                }

                // 1. Fenced code block (``` or ~~~)
                if let fence = parseFenceOpen(line) {
                    sawMarkdown = true
                    flushList()
                    index += 1
                    var codeLines: [String] = []
                    while index < lines.count {
                        if isFenceClose(lines[index], char: fence.char, count: fence.count) {
                            index += 1
                            break
                        }
                        codeLines.append(lines[index])
                        index += 1
                    }
                    let text = codeLines.joined(separator: "\n")
                    let id = try mintID()
                    let content: [BlockNoteWriter.Copy] = text.isEmpty ? [] : [.text([.run(InlineRun(text))])]
                    blocks.append(
                        .element(
                            "blockContainer", [("id", .string(id))],
                            [.element("codeBlock", [("language", .string(fence.language))], content)]))
                    continue
                }

                // 2. GFM table (header + delimiter + body rows)
                if index + 1 < lines.count,
                    let (table, consumed) = try parseTable(startingAt: index)
                {
                    sawMarkdown = true
                    flushList()
                    blocks.append(table)
                    index += consumed
                    continue
                }

                // 3. Divider (---, ***, ___) — checked before bullet lists.
                if isDivider(line) {
                    sawMarkdown = true
                    flushList()
                    let id = try mintID()
                    blocks.append(.element("blockContainer", [("id", .string(id))], [.element("divider", [], [])]))
                    index += 1
                    continue
                }

                // 4. ATX heading (# to ######, clamped to 1...3)
                if let heading = parseHeading(line) {
                    sawMarkdown = true
                    flushList()
                    let props = headingProps(level: min(heading.level, 3))
                    try emitTextLine(heading.text, node: "heading", props: props, trackMarkdown: false)
                    index += 1
                    continue
                }

                // 5. Blockquote (> ...)
                if let quote = parseQuote(line) {
                    sawMarkdown = true
                    flushList()
                    try emitTextLine(
                        quote, node: "quote", props: BlockNoteWriter.nativePropSchemas["quote"], trackMarkdown: false)
                    index += 1
                    continue
                }

                // 6. List item (checklist, bullet, numbered) with nesting
                if let item = parseListItem(line) {
                    sawMarkdown = true
                    try appendListItem(item)
                    index += 1
                    continue
                }

                // 7. Standalone image (![alt](url))
                if let standalone = parseStandaloneImage(line) {
                    sawMarkdown = true
                    flushList()
                    if let url = BlockNoteHTMLParser.pastedHTTPSImageURL(standalone.url) {
                        let id = try mintID()
                        blocks.append(BlockNoteHTMLParser.imageBlock(id: id, url: url, alt: standalone.alt))
                    }
                    index += 1
                    continue
                }

                // 8. Paragraph line (each single line break starts a new paragraph)
                flushList()
                try emitTextLine(line, node: "paragraph", props: nil, trackMarkdown: true)
                index += 1
            }

            flushList()

            // Plain text with no Markdown syntax must produce plain paragraphs
            // line-for-line identical to today's multi-line plain-text paste.
            if !sawMarkdown {
                let paragraphProps = BlockNoteWriter.nativePropSchemas["paragraph"] ?? []
                guard lines.count <= BlockNoteSubtreePayload.maxBlocks else { throw Error.tooLarge }
                return lines.enumerated().map { offset, text in
                    let content: [BlockNoteWriter.Copy] = text.isEmpty ? [] : [.text([.run(InlineRun(text))])]
                    return .element(
                        "blockContainer", [("id", .string("md-\(offset + 1)"))],
                        [.element("paragraph", paragraphProps, content)])
                }
            }

            return blocks
        }

        // MARK: - Block matchers

        private func leadingIndent(_ line: String) -> (columns: Int, rest: Substring) {
            var columns = 0
            var index = line.startIndex
            while index < line.endIndex {
                let ch = line[index]
                if ch == " " {
                    columns += 1
                } else if ch == "\t" {
                    columns += 4
                } else {
                    break
                }
                index = line.index(after: index)
            }
            return (columns, line[index...])
        }

        private func parseFenceOpen(_ line: String) -> (char: Character, count: Int, language: String)? {
            let (indent, rest) = leadingIndent(line)
            guard indent <= 3, let first = rest.first, first == "`" || first == "~" else { return nil }
            var count = 0
            var cursor = rest.startIndex
            while cursor < rest.endIndex, rest[cursor] == first {
                count += 1
                cursor = rest.index(after: cursor)
            }
            guard count >= 3 else { return nil }
            let info = rest[cursor...].trimmingCharacters(in: .whitespaces)
            // CommonMark: backtick fence info string cannot contain backticks.
            if first == "`", info.contains("`") { return nil }
            let token = info.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            let language = isValidCodeBlockLanguage(token) ? token : "text"
            return (first, count, language)
        }

        private func isFenceClose(_ line: String, char: Character, count: Int) -> Bool {
            let (indent, rest) = leadingIndent(line)
            guard indent <= 3 else { return false }
            let trimmed = rest.trimmingCharacters(in: .whitespaces)
            return trimmed.count >= count && trimmed.allSatisfy { $0 == char }
        }

        private func isDivider(_ line: String) -> Bool {
            let (indent, rest) = leadingIndent(line)
            guard indent <= 3 else { return false }
            let compact = rest.filter { $0 != " " && $0 != "\t" }
            guard compact.count >= 3, let marker = compact.first, marker == "-" || marker == "*" || marker == "_" else {
                return false
            }
            return compact.allSatisfy { $0 == marker }
        }

        private func parseHeading(_ line: String) -> (level: Int, text: String)? {
            let (indent, rest) = leadingIndent(line)
            guard indent <= 3, rest.first == "#" else { return nil }
            var level = 0
            var cursor = rest.startIndex
            while cursor < rest.endIndex, rest[cursor] == "#" {
                level += 1
                cursor = rest.index(after: cursor)
            }
            guard (1...6).contains(level), cursor < rest.endIndex, rest[cursor] == " " || rest[cursor] == "\t" else {
                return nil
            }
            var content = String(rest[cursor...]).trimmingCharacters(in: .whitespaces)
            // Strip optional CommonMark closing hashes when preceded by space.
            if content.hasSuffix("#") {
                var end = content.endIndex
                while end > content.startIndex, content[content.index(before: end)] == "#" {
                    end = content.index(before: end)
                }
                if end == content.startIndex {
                    content = ""
                } else if content[content.index(before: end)] == " " || content[content.index(before: end)] == "\t" {
                    content = String(content[..<end]).trimmingCharacters(in: .whitespaces)
                }
            }
            return (level, content)
        }

        private func parseQuote(_ line: String) -> String? {
            let (indent, rest) = leadingIndent(line)
            guard indent <= 3, rest.first == ">" else { return nil }
            var cursor = rest.index(after: rest.startIndex)
            if cursor < rest.endIndex, rest[cursor] == " " { cursor = rest.index(after: cursor) }
            // Flatten nested `> > text` prefixes into the quote's text.
            while cursor < rest.endIndex, rest[cursor] == ">" {
                cursor = rest.index(after: cursor)
                if cursor < rest.endIndex, rest[cursor] == " " { cursor = rest.index(after: cursor) }
            }
            return String(rest[cursor...])
        }

        private struct ParsedListItem {
            let indent: Int
            let node: String
            let checked: Bool?
            let number: Int?
            let text: String
        }

        private func parseListItem(_ line: String) -> ParsedListItem? {
            let (indent, rest) = leadingIndent(line)
            guard !rest.isEmpty else { return nil }

            // Bare checklist: `[ ] text` or `[x] text` / `[X] text` (must have space after `]`).
            if let bare = parseCheckboxPrefix(rest) {
                return ParsedListItem(
                    indent: indent, node: "checkListItem", checked: bare.checked, number: nil, text: bare.text)
            }

            // Bullet or bullet-prefixed checklist: `- `, `* `, `+ `
            if let first = rest.first, first == "-" || first == "*" || first == "+" {
                let after = rest.index(after: rest.startIndex)
                if after < rest.endIndex, rest[after] == " " || rest[after] == "\t" {
                    var contentStart = after
                    while contentStart < rest.endIndex, rest[contentStart] == " " || rest[contentStart] == "\t" {
                        contentStart = rest.index(after: contentStart)
                    }
                    let content = rest[contentStart...]
                    if let check = parseCheckboxPrefix(content) {
                        return ParsedListItem(
                            indent: indent, node: "checkListItem", checked: check.checked, number: nil, text: check.text
                        )
                    }
                    return ParsedListItem(
                        indent: indent, node: "bulletListItem", checked: nil, number: nil, text: String(content))
                }
            }

            // Numbered list: `1. text` or `1) text` (1–9 digits)
            var cursor = rest.startIndex
            var digits = 0
            while cursor < rest.endIndex, rest[cursor].isASCII, rest[cursor].isNumber, digits < 9 {
                cursor = rest.index(after: cursor)
                digits += 1
            }
            if digits > 0, cursor < rest.endIndex, rest[cursor] == "." || rest[cursor] == ")" {
                let number = Int(rest[..<cursor])
                let afterDelim = rest.index(after: cursor)
                if afterDelim < rest.endIndex, rest[afterDelim] == " " || rest[afterDelim] == "\t" {
                    var contentStart = afterDelim
                    while contentStart < rest.endIndex, rest[contentStart] == " " || rest[contentStart] == "\t" {
                        contentStart = rest.index(after: contentStart)
                    }
                    return ParsedListItem(
                        indent: indent, node: "numberedListItem", checked: nil, number: number,
                        text: String(rest[contentStart...]))
                }
            }
            return nil
        }

        private func parseCheckboxPrefix(_ text: Substring) -> (checked: Bool, text: String)? {
            guard text.count >= 3, text.first == "[" else { return nil }
            let i1 = text.index(after: text.startIndex)
            let i2 = text.index(after: i1)
            let mark = text[i1]
            guard mark == " " || mark == "x" || mark == "X", text[i2] == "]" else { return nil }
            let i3 = text.index(after: i2)
            if i3 == text.endIndex { return (mark != " ", "") }
            guard text[i3] == " " || text[i3] == "\t" else { return nil }
            var start = i3
            while start < text.endIndex, text[start] == " " || text[start] == "\t" {
                start = text.index(after: start)
            }
            return (mark != " ", String(text[start...]))
        }

        // MARK: - List tree assembly

        private mutating func appendListItem(_ item: ParsedListItem) throws {
            let (cleanedText, hoistedImages) = extractInlineImages(item.text)
            let runs = sanitizedInlineRuns(cleanedText)
            let content: [BlockNoteWriter.Copy] = runs.isEmpty ? [] : [.text(runs.map { .run($0) })]

            while let lastIndent = indentAt(path: listPath), item.indent <= lastIndent {
                listPath.removeLast()
            }

            let targetDepth = listPath.count
            let clampedDepth = min(targetDepth, BlockNoteWriter.maxNestingDepth)
            if targetDepth > BlockNoteWriter.maxNestingDepth {
                listPath = Array(listPath.prefix(BlockNoteWriter.maxNestingDepth))
            }

            let previousSiblingIsNumbered = lastSiblingNode(atParentPath: listPath) == "numberedListItem"
            let props: [(key: String, value: YAnyValue)]
            switch item.node {
            case "checkListItem":
                props = (BlockNoteWriter.nativePropSchemas["checkListItem"] ?? []).map {
                    $0.key == "checked" ? ("checked", .bool(item.checked ?? false)) : $0
                }
            case "numberedListItem":
                let explicitStart: Int? =
                    if !previousSiblingIsNumbered, let n = item.number, n != 1, (1...999_999).contains(n) {
                        n
                    } else {
                        nil
                    }
                props = (BlockNoteWriter.nativePropSchemas["numberedListItem"] ?? []).map {
                    if $0.key == "start", let explicitStart { return ("start", .int(explicitStart)) }
                    return $0
                }
            default:
                props = BlockNoteWriter.nativePropSchemas["bulletListItem"] ?? []
            }

            let id = try mintID()
            let node = ListNode(
                id: id, node: item.node, props: props, content: content, indent: item.indent, depth: clampedDepth)
            let insertedIndex = appendChild(node, toParentPath: listPath)
            listPath.append(insertedIndex)

            if !hoistedImages.isEmpty {
                // Keep images at root level so `nestsTable` never rejects them.
                flushList()
                for img in hoistedImages {
                    let imgID = try mintID()
                    blocks.append(BlockNoteHTMLParser.imageBlock(id: imgID, url: img.url, alt: img.alt))
                }
            }
        }

        private func indentAt(path: [Int]) -> Int? {
            guard !path.isEmpty else { return nil }
            var current = listRoots[path[0]]
            for step in path.dropFirst() { current = current.children[step] }
            return current.indent
        }

        private func lastSiblingNode(atParentPath path: [Int]) -> String? {
            if path.isEmpty { return listRoots.last?.node }
            var current = listRoots[path[0]]
            for step in path.dropFirst() { current = current.children[step] }
            return current.children.last?.node
        }

        private mutating func appendChild(_ node: ListNode, toParentPath path: [Int]) -> Int {
            if path.isEmpty {
                listRoots.append(node)
                return listRoots.count - 1
            }
            func insert(into nodes: inout [ListNode], path: ArraySlice<Int>) -> Int {
                let idx = path.first!
                if path.count == 1 {
                    nodes[idx].children.append(node)
                    return nodes[idx].children.count - 1
                }
                return insert(into: &nodes[idx].children, path: path.dropFirst())
            }
            return insert(into: &listRoots, path: path[...])
        }

        private mutating func flushList() {
            guard !listRoots.isEmpty else { return }
            func build(_ node: ListNode) -> BlockNoteWriter.Copy {
                var children: [BlockNoteWriter.Copy] = [.element(node.node, node.props, node.content)]
                if !node.children.isEmpty {
                    children.append(.element("blockGroup", [], node.children.map(build)))
                }
                return .element("blockContainer", [("id", .string(node.id))], children)
            }
            blocks += listRoots.map(build)
            listRoots = []
            listPath = []
        }

        // MARK: - GFM tables

        private mutating func parseTable(startingAt start: Int) throws -> (BlockNoteWriter.Copy, Int)? {
            guard start + 1 < lines.count else { return nil }
            let firstTwo = lines[start] + "\n" + lines[start + 1]
            guard parseMarkdownTable(firstTwo) != nil else { return nil }

            var end = start + 2
            while end < lines.count {
                let candidate = lines[end]
                if candidate.trimmingCharacters(in: .whitespaces).isEmpty
                    || candidate.hasPrefix("    ") || candidate.hasPrefix("\t")
                    || !containsUnescapedPipe(candidate)
                {
                    break
                }
                end += 1
            }
            var parsed: MarkdownTable?
            while end >= start + 2 {
                if let table = parseMarkdownTable(lines[start..<end].joined(separator: "\n")) {
                    parsed = table
                    break
                }
                end -= 1
            }
            guard let table = parsed else { return nil }
            let totalCells = (1 + table.rows.count) * table.columnCount
            guard totalCells <= TableGrid.maxCells else { throw Error.tooLarge }

            func makeCell(_ rawText: String, isHeader: Bool, alignment: MarkdownTable.Alignment) -> TablePastedCell {
                let align: String =
                    switch alignment {
                    case .unspecified, .leading: "left"
                    case .center: "center"
                    case .trailing: "right"
                    }
                var attrs = TableClipboard.defaultAttrs
                attrs["textAlignment"] = .string(align)
                let runs = tableCellRuns(rawText)
                return TablePastedCell(node: isHeader ? "tableHeader" : "tableCell", attrs: attrs, runs: runs)
            }

            var pastedRows: [[TablePastedCell]] = [
                table.header.enumerated().map { col, text in
                    makeCell(text, isHeader: true, alignment: table.alignments[col])
                }
            ]
            for row in table.rows {
                pastedRows.append(
                    row.enumerated().map { col, text in
                        makeCell(text, isHeader: false, alignment: table.alignments[col])
                    })
            }
            let id = try mintID()
            do {
                guard let copy = try BlockNoteHTMLParser.tableBlock(id: id, rows: pastedRows) else { return nil }
                return (copy, end - start)
            } catch BlockNoteHTMLParser.Error.tooLarge {
                throw Error.tooLarge
            }
        }

        private func containsUnescapedPipe(_ line: String) -> Bool {
            var escaped = false
            for ch in line {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "|" {
                    return true
                }
            }
            return false
        }

        private func tableCellRuns(_ raw: String) -> [InlineRun] {
            let normalized = raw.replacingOccurrences(
                of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
            let segments = normalized.components(separatedBy: "\n")
            var out: [InlineRun] = []
            for (index, segment) in segments.enumerated() {
                if index > 0 { out.append(InlineRun("\n")) }
                out += sanitizedInlineRuns(segment)
            }
            return coalesceRuns(out)
        }

        // MARK: - Images

        private func parseStandaloneImage(_ line: String) -> (alt: String, url: String)? {
            let (indent, rest) = leadingIndent(line)
            guard indent <= 3 else { return nil }
            let trimmed = rest.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("![") else { return nil }
            let chars = Array(trimmed)
            guard let match = matchImage(chars, from: 0), match.next == chars.count else { return nil }
            return (match.alt, match.url)
        }

        private struct MatchedImage {
            let alt: String
            let url: String
            let next: Int
        }

        private func matchImage(_ chars: [Character], from open: Int) -> MatchedImage? {
            guard open + 1 < chars.count, chars[open] == "!", chars[open + 1] == "[" else { return nil }
            var i = open + 2
            var alt = ""
            while i < chars.count, chars[i] != "]" {
                if chars[i] == "\\", i + 1 < chars.count {
                    alt.append(chars[i + 1])
                    i += 2
                    continue
                }
                alt.append(chars[i])
                i += 1
            }
            guard i < chars.count, chars[i] == "]", i + 1 < chars.count, chars[i + 1] == "(" else { return nil }
            i += 2
            while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
            var url = ""
            if i < chars.count, chars[i] == "<" {
                i += 1
                while i < chars.count, chars[i] != ">" {
                    url.append(chars[i])
                    i += 1
                }
                guard i < chars.count, chars[i] == ">" else { return nil }
                i += 1
            } else {
                var depth = 0
                while i < chars.count {
                    let c = chars[i]
                    if c == "\\" && i + 1 < chars.count {
                        url.append(chars[i + 1])
                        i += 2
                        continue
                    }
                    if c == "(" {
                        depth += 1
                        url.append(c)
                    } else if c == ")" {
                        if depth == 0 { break }
                        depth -= 1
                        url.append(c)
                    } else if c == " " || c == "\t" {
                        break
                    } else {
                        url.append(c)
                    }
                    i += 1
                }
            }
            // Skip optional title up to closing `)`
            while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
            if i < chars.count, chars[i] == "\"" || chars[i] == "'" {
                let quote = chars[i]
                i += 1
                while i < chars.count, chars[i] != quote {
                    if chars[i] == "\\", i + 1 < chars.count { i += 2 } else { i += 1 }
                }
                guard i < chars.count else { return nil }
                i += 1
                while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
            }
            guard i < chars.count, chars[i] == ")" else { return nil }
            return MatchedImage(alt: alt, url: url, next: i + 1)
        }

        private func extractInlineImages(_ text: String) -> (cleaned: String, images: [(url: String, alt: String)]) {
            guard text.contains("![") else { return (text, []) }
            let chars = Array(text)
            var out = ""
            var images: [(url: String, alt: String)] = []
            var i = 0
            while i < chars.count {
                if chars[i] == "`" {
                    // Skip inline code spans verbatim.
                    var close = i + 1
                    while close < chars.count, chars[close] != "`" { close += 1 }
                    if close < chars.count {
                        out.append(contentsOf: chars[i...close])
                        i = close + 1
                        continue
                    }
                }
                if chars[i] == "!", let match = matchImage(chars, from: i) {
                    if let url = BlockNoteHTMLParser.pastedHTTPSImageURL(match.url) {
                        images.append((url, match.alt))
                    }
                    i = match.next
                    continue
                }
                out.append(chars[i])
                i += 1
            }
            return (out, images)
        }

        // MARK: - Inline parsing & emission

        private mutating func emitTextLine(
            _ text: String, node: String, props: [(key: String, value: YAnyValue)]?, trackMarkdown: Bool
        ) throws {
            if text.contains("![") {
                let chars = Array(text)
                var segments: [(text: String?, image: (url: String, alt: String)?)] = []
                var current = ""
                var matchedAnyImage = false
                var i = 0
                while i < chars.count {
                    if chars[i] == "`" {
                        var close = i + 1
                        while close < chars.count, chars[close] != "`" { close += 1 }
                        if close < chars.count {
                            current.append(contentsOf: chars[i...close])
                            i = close + 1
                            continue
                        }
                    }
                    if chars[i] == "!", let match = matchImage(chars, from: i) {
                        matchedAnyImage = true
                        if let url = BlockNoteHTMLParser.pastedHTTPSImageURL(match.url) {
                            if !current.trimmingCharacters(in: .whitespaces).isEmpty {
                                segments.append((current, nil))
                            }
                            current = ""
                            segments.append((nil, (url, match.alt)))
                        }
                        i = match.next
                        continue
                    }
                    current.append(chars[i])
                    i += 1
                }
                if matchedAnyImage {
                    sawMarkdown = true
                    if !current.trimmingCharacters(in: .whitespaces).isEmpty {
                        segments.append((current, nil))
                    }
                    for segment in segments {
                        if let img = segment.image {
                            let id = try mintID()
                            blocks.append(BlockNoteHTMLParser.imageBlock(id: id, url: img.url, alt: img.alt))
                        } else if let piece = segment.text {
                            let runs = sanitizedInlineRuns(piece)
                            let id = try mintID()
                            let resolved = props ?? BlockNoteWriter.nativePropSchemas[node] ?? []
                            let content: [BlockNoteWriter.Copy] = runs.isEmpty ? [] : [.text(runs.map { .run($0) })]
                            blocks.append(
                                .element(
                                    "blockContainer", [("id", .string(id))], [.element(node, resolved, content)]))
                        }
                    }
                    return
                }
            }

            let runs = sanitizedInlineRuns(text)
            if trackMarkdown {
                let isPlain =
                    (text.isEmpty && runs.isEmpty)
                    || (runs.count == 1 && runs[0].marks.isEmpty && runs[0].text == text)
                if !isPlain { sawMarkdown = true }
            }
            let id = try mintID()
            let resolvedProps = props ?? BlockNoteWriter.nativePropSchemas[node] ?? []
            let content: [BlockNoteWriter.Copy] = runs.isEmpty ? [] : [.text(runs.map { .run($0) })]
            blocks.append(.element("blockContainer", [("id", .string(id))], [.element(node, resolvedProps, content)]))
        }

        /// Runs `InlineMarkdown.parse` and strips any link mark whose href
        /// `sanitizedLinkURL` would not write unchanged (e.g. `javascript:`,
        /// `data:`, `file:`, relative URLs), keeping the label text.
        private func sanitizedInlineRuns(_ text: String) -> [InlineRun] {
            guard !text.isEmpty else { return [] }
            let raw = InlineMarkdown.parse(text)
            let cleaned = raw.map { run -> InlineRun in
                var copy = run
                copy.marks = run.marks.filter { mark in
                    guard mark.key == "link" else { return true }
                    guard let href = YBlockProjection.linkHref(from: mark.valueJSON) else { return false }
                    return sanitizedLinkURL(href) == href
                }
                return copy
            }
            return coalesceRuns(cleaned)
        }

        private func coalesceRuns(_ runs: [InlineRun]) -> [InlineRun] {
            var out: [InlineRun] = []
            for run in runs where !run.text.isEmpty {
                if let last = out.last, last.inlineObject == nil, run.inlineObject == nil,
                    InlineRun("", marks: last.marks) == InlineRun("", marks: run.marks)
                {
                    out[out.count - 1].text += run.text
                } else {
                    out.append(run)
                }
            }
            return out
        }

        private func headingProps(level: Int) -> [(key: String, value: YAnyValue)] {
            (BlockNoteWriter.nativePropSchemas["heading"] ?? []).map {
                $0.key == "level" ? ("level", .int(level)) : $0
            }
        }
    }
}
