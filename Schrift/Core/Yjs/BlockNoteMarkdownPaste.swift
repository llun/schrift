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

    // shortcut: lines longer than 8,192 UTF-16 code units skip inline Markdown
    // and image parsing and stay plain text so pathological lines cannot stall paste.
    static let maxInlineParseUTF16 = 8_192

    /// Parses pasted Markdown or plain text into BlockNote `blockContainer`
    /// copies. Throws `.tooLarge` when UTF-16 length, line count, block count
    /// or table size exceed clipboard bounds. Returns `[]` for empty input or
    /// input whose only elements were dropped (such as non-`https` images).
    static func parse(_ raw: String) throws -> [BlockNoteWriter.Copy] {
        try parseDetailed(raw).blocks
    }

    /// Parses `raw` into blocks and reports whether any Markdown syntax was
    /// recognized (`sawMarkdown`). Plain text without Markdown syntax returns
    /// `sawMarkdown == false` so callers can keep the existing plain-text path.
    static func parseDetailed(_ raw: String) throws -> (blocks: [BlockNoteWriter.Copy], sawMarkdown: Bool) {
        guard !NativeClipboard.isTooLarge(raw) else { throw Error.tooLarge }
        let stripped = NativeClipboard.strippingObjectReplacementCharacters(raw)
        let normalized = NativeClipboard.normalizingLineBreaks(stripped)
        guard !NativeClipboard.isTooLarge(normalized) else { throw Error.tooLarge }
        guard !normalized.isEmpty else { return ([], false) }
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var parser = Parser(lines: lines)
        let blocks = try parser.parse()
        return (blocks, parser.sawMarkdown)
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

    /// Parses `raw` and encodes a `BlockNoteSubtreePayload` only when Markdown
    /// syntax was recognized and yielded at least one block. Returns `nil` for
    /// plain text (no Markdown seen) or when every construct was dropped.
    static func markdownPayload(_ raw: String) throws -> Data? {
        let result = try parseDetailed(raw)
        guard result.sawMarkdown, !result.blocks.isEmpty else { return nil }
        do {
            return try BlockNoteSubtreePayload.encode(result.blocks)
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
        private var payloadBytes = 0
        private(set) var sawMarkdown = false
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

        private mutating func addPayloadBytes(_ count: Int) throws {
            let (sum, overflow) = payloadBytes.addingReportingOverflow(count)
            guard !overflow, sum <= BlockNoteSubtreePayload.maxBytes else { throw Error.tooLarge }
            payloadBytes = sum
        }

        private mutating func accountRuns(_ runs: [InlineRun]) throws {
            for run in runs {
                let markBytes = run.marks.reduce(0) { $0 + $1.key.utf8.count + $1.valueJSON.utf8.count }
                try addPayloadBytes(run.text.utf8.count + markBytes)
            }
        }

        mutating func parse() throws -> [BlockNoteWriter.Copy] {
            var index = 0
            while index < lines.count {
                let line = lines[index]

                if isBlankLine(line) {
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
                    try addPayloadBytes(text.utf8.count)
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
                if let item = parseListItem(line, listOpen: !listRoots.isEmpty) {
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
                        try addPayloadBytes(
                            url.utf8.count + BlockNoteHTMLParser.sanitizedImageName(standalone.alt).utf8.count)
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

        private func isBlankLine(_ line: String) -> Bool {
            if let first = line.utf8.first, first > 0x20, first < 0x7F {
                return false
            }
            return line.trimmingCharacters(in: .whitespaces).isEmpty
        }

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
            guard indent <= 3,
                let marker = rest.utf8.first,
                marker == Byte.dash || marker == Byte.star || marker == Byte.underscore
            else {
                return false
            }
            var count = 0
            for byte in rest.utf8 {
                if byte == marker {
                    count += 1
                } else if byte != Byte.space && byte != Byte.tab {
                    return false
                }
            }
            return count >= 3
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

        private func parseListItem(_ line: String, listOpen: Bool) -> ParsedListItem? {
            let (indent, rest) = leadingIndent(line)
            guard !rest.isEmpty, listOpen || indent <= 3 else { return nil }

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
            let (cleanedText, hoistedImages, reusedSyntax) = extractInlineImages(item.text)
            let runs = sanitizedInlineRuns(cleanedText, syntax: reusedSyntax)
            try accountRuns(runs)
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
                    try addPayloadBytes(
                        img.url.utf8.count + BlockNoteHTMLParser.sanitizedImageName(img.alt).utf8.count)
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

        private func startsBlockConstruct(_ line: String) -> Bool {
            parseFenceOpen(line) != nil
                || isDivider(line)
                || parseHeading(line) != nil
                || parseQuote(line) != nil
                || parseListItem(line, listOpen: false) != nil
        }

        private mutating func parseTable(startingAt start: Int) throws -> (BlockNoteWriter.Copy, Int)? {
            guard start + 1 < lines.count,
                BlockNoteMarkdownPaste.containsASCII(lines[start], Byte.pipe),
                BlockNoteMarkdownPaste.containsASCII(lines[start + 1], Byte.pipe),
                BlockNoteMarkdownPaste.containsASCII(lines[start + 1], Byte.dash),
                !startsBlockConstruct(lines[start])
            else { return nil }
            let firstTwo = lines[start] + "\n" + lines[start + 1]
            guard parseMarkdownTable(firstTwo) != nil else { return nil }

            var end = start + 2
            while end < lines.count {
                let candidate = lines[end]
                if candidate.trimmingCharacters(in: .whitespaces).isEmpty
                    || leadingIndent(candidate).columns > 3
                    || startsBlockConstruct(candidate)
                    || markdownTableRowCells(candidate) == nil
                {
                    break
                }
                end += 1
            }
            guard let table = parseMarkdownTable(lines[start..<end].joined(separator: "\n")) else { return nil }
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
            for row in pastedRows {
                for cell in row {
                    try accountRuns(cell.runs)
                }
            }
            let id = try mintID()
            do {
                guard let copy = try BlockNoteHTMLParser.tableBlock(id: id, rows: pastedRows) else { return nil }
                return (copy, end - start)
            } catch BlockNoteHTMLParser.Error.tooLarge {
                throw Error.tooLarge
            }
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
            guard line.utf16.count <= BlockNoteMarkdownPaste.maxInlineParseUTF16 else { return nil }
            let (indent, rest) = leadingIndent(line)
            guard indent <= 3 else { return nil }
            if let first = rest.utf8.first, first < 0x80, first != Byte.bang { return nil }
            let trimmed = rest.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("![") && trimmed.hasSuffix(")") else { return nil }
            let syntax = LineSyntax(trimmed)
            let matcher = ImageMatcher(syntax: syntax)
            guard let match = matcher.match(from: 0), match.next == syntax.bytes.count else { return nil }
            return (match.alt, match.url)
        }

        private struct MatchedImage {
            let alt: String
            let url: String
            let next: Int
        }

        /// Linear-time image syntax matcher: uses precomputed balanced bracket
        /// pairs and the shared UTF-8 destination parser so nested brackets,
        /// `<...>` destinations, balanced parentheses and optional quoted titles
        /// stay linear.
        private struct ImageMatcher {
            let syntax: LineSyntax

            func match(from open: Int) -> MatchedImage? {
                let bytes = syntax.bytes
                guard open + 1 < bytes.count, bytes[open] == Byte.bang, bytes[open + 1] == Byte.openBracket else {
                    return nil
                }
                guard syntax.hasLinkTokens else { return nil }
                let closeBracket = syntax.matchingClose[open + 1]
                guard closeBracket >= 0 else { return nil }
                guard
                    let dest = BlockNoteMarkdownPaste.parseDestination(
                        in: syntax,
                        from: closeBracket + 1,
                        limit: bytes.count)
                else { return nil }
                let altStart = open + 2
                let alt: String
                if BlockNoteMarkdownPaste.containsASCII(bytes, Byte.backslash, in: altStart..<closeBracket) {
                    var unescaped: [UInt8] = []
                    unescaped.reserveCapacity(closeBracket - altStart)
                    var i = altStart
                    while i < closeBracket {
                        if bytes[i] == Byte.backslash, i + 1 < closeBracket,
                            BlockNoteMarkdownPaste.isASCIIPunctuation(bytes[i + 1])
                        {
                            unescaped.append(bytes[i + 1])
                            i += 2
                            continue
                        }
                        unescaped.append(bytes[i])
                        i += 1
                    }
                    alt = String(decoding: unescaped, as: UTF8.self)
                } else {
                    alt = String(decoding: bytes[altStart..<closeBracket], as: UTF8.self)
                }
                return MatchedImage(alt: alt, url: dest.url, next: dest.next)
            }
        }

        private enum ImageScanPiece {
            case text(String)
            case image(url: String, alt: String)
        }

        /// Linearly splits `text` around Markdown images while respecting
        /// backslash escapes (`\![...]`) and arbitrary-length backtick code spans
        /// (`` ``![...]`` ``). When no image matches, returns the precomputed
        /// `LineSyntax` so `PasteInlineParser` can reuse it without rescanning.
        private func scanInlineImages(
            _ text: String
        ) -> (pieces: [ImageScanPiece], matchedAny: Bool, syntax: LineSyntax?) {
            // Every valid `![alt](dest)` contains all five ASCII delimiters; skipping
            // early avoids indexing lines that cannot contain an image.
            guard text.utf16.count <= BlockNoteMarkdownPaste.maxInlineParseUTF16,
                BlockNoteMarkdownPaste.containsASCII(text, Byte.bang),
                BlockNoteMarkdownPaste.containsASCII(text, Byte.closeParen),
                BlockNoteMarkdownPaste.containsASCII(text, Byte.openBracket),
                BlockNoteMarkdownPaste.containsASCII(text, Byte.closeBracket),
                BlockNoteMarkdownPaste.containsASCII(text, Byte.openParen)
            else {
                return ([.text(text)], false, nil)
            }
            let syntax = LineSyntax(text)
            let bytes = syntax.bytes
            let matcher = ImageMatcher(syntax: syntax)
            var pieces: [ImageScanPiece] = []
            var current = ""
            var literalStart = 0
            var matchedAny = false
            var i = 0
            let count = bytes.count
            while i < count {
                let b = bytes[i]
                if b == Byte.backslash, i + 1 < count {
                    let step = 1 + BlockNoteMarkdownPaste.utf8ScalarLength(bytes[i + 1])
                    i = min(i + step, count)
                    continue
                }
                if b == Byte.backtick, let backticks = syntax.backticks {
                    var runLen = 0
                    while i + runLen < count, bytes[i + runLen] == Byte.backtick { runLen += 1 }
                    if let close = backticks.closingRun(length: runLen, from: i + runLen, limit: count) {
                        i = close + runLen
                    } else {
                        i += runLen
                    }
                    continue
                }
                if b == Byte.bang, let match = matcher.match(from: i) {
                    if i > literalStart {
                        current += String(decoding: bytes[literalStart..<i], as: UTF8.self)
                    }
                    matchedAny = true
                    if let url = BlockNoteHTMLParser.pastedHTTPSImageURL(match.url) {
                        if !current.isEmpty {
                            pieces.append(.text(current))
                            current = ""
                        }
                        pieces.append(.image(url: url, alt: match.alt))
                    }
                    i = match.next
                    literalStart = i
                    continue
                }
                i += 1
            }
            guard matchedAny else { return ([.text(text)], false, syntax) }
            if literalStart < count {
                current += String(decoding: bytes[literalStart..<count], as: UTF8.self)
            }
            if !current.isEmpty { pieces.append(.text(current)) }
            return (pieces, true, nil)
        }

        private func extractInlineImages(
            _ text: String
        ) -> (cleaned: String, images: [(url: String, alt: String)], syntax: LineSyntax?) {
            let scan = scanInlineImages(text)
            guard scan.matchedAny else { return (text, [], scan.syntax) }
            var cleaned = ""
            var images: [(url: String, alt: String)] = []
            for piece in scan.pieces {
                switch piece {
                case .text(let s): cleaned += s
                case .image(let url, let alt): images.append((url, alt))
                }
            }
            return (cleaned, images, nil)
        }

        // MARK: - Inline parsing & emission

        private mutating func emitTextLine(
            _ text: String, node: String, props: [(key: String, value: YAnyValue)]?, trackMarkdown: Bool
        ) throws {
            let scan = scanInlineImages(text)
            if scan.matchedAny {
                sawMarkdown = true
                for piece in scan.pieces {
                    switch piece {
                    case .image(let url, let alt):
                        try addPayloadBytes(
                            url.utf8.count + BlockNoteHTMLParser.sanitizedImageName(alt).utf8.count)
                        let id = try mintID()
                        blocks.append(BlockNoteHTMLParser.imageBlock(id: id, url: url, alt: alt))
                    case .text(let chunk):
                        guard !chunk.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                        let runs = sanitizedInlineRuns(chunk)
                        try accountRuns(runs)
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

            let runs = sanitizedInlineRuns(text, syntax: scan.syntax)
            try accountRuns(runs)
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

        /// Runs the paste inline Markdown parser (with flanking rules so plain
        /// arithmetic like `2*3*4` stays literal, multi-backtick code spans,
        /// linear scans, and sanitized links). Lines longer than
        /// `maxInlineParseUTF16` stay plain text.
        private func sanitizedInlineRuns(_ text: String, syntax: LineSyntax? = nil) -> [InlineRun] {
            guard !text.isEmpty else { return [] }
            guard text.utf16.count <= BlockNoteMarkdownPaste.maxInlineParseUTF16 else {
                return [InlineRun(text)]
            }
            if syntax == nil, !BlockNoteMarkdownPaste.hasPotentialInlineSyntax(text) {
                return [InlineRun(text)]
            }
            var inline = PasteInlineParser(syntax: syntax ?? LineSyntax(text))
            return coalesceRuns(inline.parse())
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

    // MARK: - ASCII & UTF-8 byte helpers

    private enum Byte {
        static let tab: UInt8 = 0x09
        static let lineFeed: UInt8 = 0x0A
        static let verticalTab: UInt8 = 0x0B
        static let formFeed: UInt8 = 0x0C
        static let carriageReturn: UInt8 = 0x0D
        static let space: UInt8 = 0x20
        static let bang: UInt8 = 0x21
        static let quote: UInt8 = 0x22
        static let apostrophe: UInt8 = 0x27
        static let openParen: UInt8 = 0x28
        static let closeParen: UInt8 = 0x29
        static let star: UInt8 = 0x2A
        static let dash: UInt8 = 0x2D
        static let lt: UInt8 = 0x3C
        static let gt: UInt8 = 0x3E
        static let openBracket: UInt8 = 0x5B
        static let backslash: UInt8 = 0x5C
        static let closeBracket: UInt8 = 0x5D
        static let underscore: UInt8 = 0x5F
        static let backtick: UInt8 = 0x60
        static let pipe: UInt8 = 0x7C
        static let tilde: UInt8 = 0x7E
        static let del: UInt8 = 0x7F
    }

    private static func containsASCII(_ string: String, _ byte: UInt8) -> Bool {
        if let found = string.utf8.withContiguousStorageIfAvailable({ buf -> Bool in
            guard let base = buf.baseAddress, !buf.isEmpty else { return false }
            return memchr(base, Int32(byte), buf.count) != nil
        }) {
            return found
        }
        return string.utf8.contains(byte)
    }

    private static func containsAtLeastTwoASCII(_ string: String, _ byte: UInt8) -> Bool {
        if let found = string.utf8.withContiguousStorageIfAvailable({ buf -> Bool in
            guard let base = buf.baseAddress, buf.count >= 2 else { return false }
            guard let first = memchr(base, Int32(byte), buf.count) else { return false }
            let offset = base.distance(to: first.assumingMemoryBound(to: UInt8.self)) + 1
            guard offset < buf.count else { return false }
            return memchr(base + offset, Int32(byte), buf.count - offset) != nil
        }) {
            return found
        }
        var seen = false
        for b in string.utf8 where b == byte {
            if seen { return true }
            seen = true
        }
        return false
    }

    private static func containsASCII(_ bytes: [UInt8], _ byte: UInt8, in range: Range<Int>? = nil) -> Bool {
        let bounds = range ?? 0..<bytes.count
        guard !bounds.isEmpty else { return false }
        return bytes.withUnsafeBufferPointer { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            return memchr(base + bounds.lowerBound, Int32(byte), bounds.count) != nil
        }
    }

    private static func containsAtLeastTwoASCII(_ bytes: [UInt8], _ byte: UInt8) -> Bool {
        guard bytes.count >= 2 else { return false }
        return bytes.withUnsafeBufferPointer { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            guard let first = memchr(base, Int32(byte), buf.count) else { return false }
            let offset = base.distance(to: first.assumingMemoryBound(to: UInt8.self)) + 1
            guard offset < buf.count else { return false }
            return memchr(base + offset, Int32(byte), buf.count - offset) != nil
        }
    }

    private static func lastIndexOfASCII(_ bytes: [UInt8], _ byte: UInt8) -> Int? {
        var i = bytes.count - 1
        while i >= 0 {
            if bytes[i] == byte { return i }
            i -= 1
        }
        return nil
    }

    private static func hasPotentialInlineSyntax(_ text: String) -> Bool {
        if containsASCII(text, Byte.backslash) { return true }
        if containsAtLeastTwoASCII(text, Byte.star) { return true }
        if containsAtLeastTwoASCII(text, Byte.underscore) { return true }
        if containsAtLeastTwoASCII(text, Byte.backtick) { return true }
        if containsAtLeastTwoASCII(text, Byte.tilde) { return true }
        return containsASCII(text, Byte.closeParen)
            && containsASCII(text, Byte.openParen)
            && containsASCII(text, Byte.openBracket)
            && containsASCII(text, Byte.closeBracket)
    }

    private static func utf8ScalarLength(_ leading: UInt8) -> Int {
        if leading < 0x80 { return 1 }
        if leading & 0xE0 == 0xC0 { return 2 }
        if leading & 0xF0 == 0xE0 { return 3 }
        if leading & 0xF8 == 0xF0 { return 4 }
        return 1
    }

    private static func decodeUTF8Scalar(
        in bytes: [UInt8], at i: Int, limit: Int
    ) -> (scalar: Unicode.Scalar?, length: Int) {
        let b0 = bytes[i]
        if b0 < 0x80 {
            return (Unicode.Scalar(b0), 1)
        }
        if b0 & 0xE0 == 0xC0, i + 1 < limit {
            let value = (UInt32(b0 & 0x1F) << 6) | UInt32(bytes[i + 1] & 0x3F)
            return (Unicode.Scalar(value), 2)
        }
        if b0 & 0xF0 == 0xE0, i + 2 < limit {
            let value =
                (UInt32(b0 & 0x0F) << 12)
                | (UInt32(bytes[i + 1] & 0x3F) << 6)
                | UInt32(bytes[i + 2] & 0x3F)
            return (Unicode.Scalar(value), 3)
        }
        if b0 & 0xF8 == 0xF0, i + 3 < limit {
            let value =
                (UInt32(b0 & 0x07) << 18)
                | (UInt32(bytes[i + 1] & 0x3F) << 12)
                | (UInt32(bytes[i + 2] & 0x3F) << 6)
                | UInt32(bytes[i + 3] & 0x3F)
            return (Unicode.Scalar(value), 4)
        }
        return (nil, 1)
    }

    // MARK: - Line syntax index

    /// Precomputed UTF-8 byte view and lazy syntax tables shared between the
    /// inline image scan and `PasteInlineParser` for a single line.
    private struct LineSyntax {
        let text: String
        let bytes: [UInt8]
        let hasLinkTokens: Bool
        let hasStarPair: Bool
        let hasTildePair: Bool
        let hasUnderscorePair: Bool
        let backticks: BacktickIndex?
        let matchingClose: [Int]
        let lastCloseParen: Int
        private let suffixCloseParens: [Int]

        init(_ text: String) {
            let bytes = Array(text.utf8)
            self.text = text
            self.bytes = bytes

            let hasBacktickPair = BlockNoteMarkdownPaste.containsAtLeastTwoASCII(bytes, Byte.backtick)
            let backticks = hasBacktickPair ? BacktickIndex(bytes) : nil
            self.backticks = backticks

            self.hasStarPair = BlockNoteMarkdownPaste.containsAtLeastTwoASCII(bytes, Byte.star)
            self.hasTildePair = BlockNoteMarkdownPaste.containsAtLeastTwoASCII(bytes, Byte.tilde)
            self.hasUnderscorePair = BlockNoteMarkdownPaste.containsAtLeastTwoASCII(bytes, Byte.underscore)

            let hasCloseParen = BlockNoteMarkdownPaste.containsASCII(bytes, Byte.closeParen)
            let hasLinkTokens =
                hasCloseParen
                && BlockNoteMarkdownPaste.containsASCII(bytes, Byte.openParen)
                && BlockNoteMarkdownPaste.containsASCII(bytes, Byte.openBracket)
                && BlockNoteMarkdownPaste.containsASCII(bytes, Byte.closeBracket)
            self.hasLinkTokens = hasLinkTokens

            if hasLinkTokens {
                self.matchingClose = BlockNoteMarkdownPaste.matchingCloseBrackets(bytes, backticks: backticks)
                self.lastCloseParen = BlockNoteMarkdownPaste.lastIndexOfASCII(bytes, Byte.closeParen) ?? -1
                if BlockNoteMarkdownPaste.containsAtLeastTwoASCII(bytes, Byte.closeParen) {
                    self.suffixCloseParens = BlockNoteMarkdownPaste.suffixCloseParenCounts(bytes)
                } else {
                    self.suffixCloseParens = []
                }
            } else {
                self.matchingClose = []
                self.lastCloseParen = -1
                self.suffixCloseParens = []
            }
        }

        func suffixCloseParenCount(from index: Int) -> Int {
            if !suffixCloseParens.isEmpty {
                return suffixCloseParens[index]
            }
            return index <= lastCloseParen ? 1 : 0
        }
    }

    // MARK: - Backtick span index

    private struct BacktickIndex {
        private let runsByLength: [Int: [Int]]

        init(_ bytes: [UInt8]) {
            var runs: [Int: [Int]] = [:]
            var i = 0
            let count = bytes.count
            while i < count {
                guard bytes[i] == Byte.backtick else {
                    i += 1
                    continue
                }
                let start = i
                while i < count, bytes[i] == Byte.backtick { i += 1 }
                runs[i - start, default: []].append(start)
            }
            self.runsByLength = runs
        }

        /// Next maximal backtick run of exact length `length` starting at or
        /// after `from` and ending at or before `limit`.
        func closingRun(length: Int, from: Int, limit: Int) -> Int? {
            guard let positions = runsByLength[length], !positions.isEmpty else { return nil }
            var lo = 0
            var hi = positions.count
            while lo < hi {
                let mid = lo + (hi - lo) / 2
                if positions[mid] < from {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
            guard lo < positions.count else { return nil }
            let pos = positions[lo]
            return pos + length <= limit ? pos : nil
        }
    }

    // MARK: - Shared bracket & destination helpers

    private static let maxDestinationParenDepth = 32

    private static func isASCIIPunctuation(_ byte: UInt8) -> Bool {
        (0x21...0x2F).contains(byte) || (0x3A...0x40).contains(byte)
            || (0x5B...0x60).contains(byte) || (0x7B...0x7E).contains(byte)
    }

    private static func suffixCloseParenCounts(_ bytes: [UInt8]) -> [Int] {
        var counts = [Int](repeating: 0, count: bytes.count + 1)
        var i = bytes.count - 1
        while i >= 0 {
            counts[i] = counts[i + 1] + (bytes[i] == Byte.closeParen ? 1 : 0)
            i -= 1
        }
        return counts
    }

    /// Maps every balanced `[` byte index in `bytes` to its matching `]` byte
    /// index (or `-1` when unmatched), honoring backslash escapes and
    /// N-backtick code spans in a single O(n) / O(n log n) pass.
    private static func matchingCloseBrackets(_ bytes: [UInt8], backticks: BacktickIndex?) -> [Int] {
        var matching = [Int](repeating: -1, count: bytes.count)
        var stack: [Int] = []
        var i = 0
        let count = bytes.count
        while i < count {
            let b = bytes[i]
            if b == Byte.backslash, i + 1 < count {
                i += 2
                continue
            }
            if b == Byte.backtick, let backticks {
                var runLen = 0
                while i + runLen < count, bytes[i + runLen] == Byte.backtick { runLen += 1 }
                if let close = backticks.closingRun(length: runLen, from: i + runLen, limit: count),
                    close > i + runLen
                {
                    i = close + runLen
                } else {
                    i += runLen
                }
                continue
            }
            if b == Byte.openBracket {
                stack.append(i)
            } else if b == Byte.closeBracket {
                if let open = stack.popLast() {
                    matching[open] = i
                }
            }
            i += 1
        }
        return matching
    }

    /// Parses a CommonMark-subset `(destination [quoted-title])` starting at
    /// `parenOpen` (`(`) and bounded by `limit`. Supports optional
    /// leading/trailing spaces/tabs, `<...>` destinations (forbidding nested
    /// `<`), bare destinations with balanced parentheses up to
    /// `maxDestinationParenDepth` (rejecting unescaped whitespace and control
    /// characters), and an optional whitespace-separated `"..."` or `'...'`
    /// title (dropped).
    ///
    /// Amortized linear across a line: angle destinations stop at the next
    /// unescaped `<` or `>` (and every opener's `<` follows `(` or space/tab,
    /// so angle scans across openers are pairwise disjoint); quoted titles
    /// similarly stop at the next unescaped matching quote; bare destinations
    /// bound nested `(` depth to `maxDestinationParenDepth` and require enough
    /// remaining `)` to close them.
    private static func parseDestination(
        in syntax: LineSyntax, from parenOpen: Int, limit: Int
    ) -> (url: String, next: Int)? {
        let bytes = syntax.bytes
        guard parenOpen + 1 < limit,
            bytes[parenOpen] == Byte.openParen,
            syntax.suffixCloseParenCount(from: parenOpen + 1) > 0
        else {
            return nil
        }
        var i = parenOpen + 1
        while i < limit, bytes[i] == Byte.space || bytes[i] == Byte.tab { i += 1 }
        let destStart: Int
        let destEnd: Int
        var hasEscape = false
        if i < limit, bytes[i] == Byte.lt {
            i += 1
            destStart = i
            while i < limit, bytes[i] != Byte.gt, bytes[i] != Byte.lt {
                if bytes[i] == Byte.backslash, i + 1 < limit, isASCIIPunctuation(bytes[i + 1]) {
                    hasEscape = true
                    i += 2
                    continue
                }
                i += 1
            }
            guard i < limit, bytes[i] == Byte.gt else { return nil }
            destEnd = i
            i += 1
        } else {
            destStart = i
            var depth = 0
            while i < limit {
                let b = bytes[i]
                if b == Byte.backslash, i + 1 < limit, isASCIIPunctuation(bytes[i + 1]) {
                    hasEscape = true
                    i += 2
                    continue
                }
                if b == Byte.openParen {
                    depth += 1
                    guard depth <= maxDestinationParenDepth,
                        i + 1 < limit,
                        depth < syntax.suffixCloseParenCount(from: i + 1)
                    else {
                        return nil
                    }
                } else if b == Byte.closeParen {
                    if depth == 0 { break }
                    depth -= 1
                } else if b < 0x80 {
                    if b == Byte.space || b == Byte.tab {
                        break
                    } else if b < 0x20 || b == Byte.del {
                        return nil
                    }
                } else {
                    let (scalar, len) = decodeUTF8Scalar(in: bytes, at: i, limit: limit)
                    if let scalar, scalar.properties.isWhitespace {
                        break
                    }
                    i += len
                    continue
                }
                i += 1
            }
            guard depth == 0 else { return nil }
            destEnd = i
        }
        guard destEnd > destStart else { return nil }
        let afterDestination = i
        while i < limit, bytes[i] == Byte.space || bytes[i] == Byte.tab { i += 1 }
        if i > afterDestination, i < limit, bytes[i] == Byte.quote || bytes[i] == Byte.apostrophe {
            let quote = bytes[i]
            i += 1
            while i < limit, bytes[i] != quote {
                if bytes[i] == Byte.backslash, i + 1 < limit { i += 2 } else { i += 1 }
            }
            guard i < limit else { return nil }
            i += 1
            while i < limit, bytes[i] == Byte.space || bytes[i] == Byte.tab { i += 1 }
        }
        guard i < limit, bytes[i] == Byte.closeParen else { return nil }
        let url: String
        if hasEscape {
            var unescaped: [UInt8] = []
            unescaped.reserveCapacity(destEnd - destStart)
            var k = destStart
            while k < destEnd {
                if bytes[k] == Byte.backslash, k + 1 < destEnd, isASCIIPunctuation(bytes[k + 1]) {
                    unescaped.append(bytes[k + 1])
                    k += 2
                } else {
                    unescaped.append(bytes[k])
                    k += 1
                }
            }
            url = String(decoding: unescaped, as: UTF8.self)
        } else {
            url = String(decoding: bytes[destStart..<destEnd], as: UTF8.self)
        }
        return (url, i + 1)
    }

    // MARK: - Paste inline Markdown parser

    /// Linear-time paste inline Markdown parser with flanking rules for `*`,
    /// `**`, `~~` and `_` (so `2*3*4`, `2 * 3 * 4`, `2**3**4`, `a~~b~~c` and
    /// `snake_case` stay literal), multi-backtick code spans, and sanitized links.
    /// Kept separate from `InlineMarkdown` so classic editor & save round-trips
    /// stay byte-identical.
    private struct PasteInlineParser {
        private enum NeighborClass {
            case none
            case whitespace
            case punctuation
            case other
        }

        private let syntax: LineSyntax
        private let bytes: [UInt8]
        private var runs: [InlineRun] = []
        private var pendingText = ""
        private var pendingMarks: [(key: String, valueJSON: String)] = []
        private var noCloserByLimit: [Int: UInt8] = [:]

        init(syntax: LineSyntax) {
            self.syntax = syntax
            self.bytes = syntax.bytes
        }

        mutating func parse() -> [InlineRun] {
            scan(0..<bytes.count, marks: [])
            flushPending()
            return runs
        }

        private static func isEscapable(_ byte: UInt8) -> Bool {
            switch byte {
            case UInt8(ascii: "\\"), UInt8(ascii: "`"), UInt8(ascii: "*"), UInt8(ascii: "_"),
                UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "["), UInt8(ascii: "]"),
                UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "#"), UInt8(ascii: "+"),
                UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "!"), UInt8(ascii: "~"),
                UInt8(ascii: ">"), UInt8(ascii: "|"):
                return true
            default:
                return false
            }
        }

        private mutating func emitSlice(_ range: Range<Int>, marks: [(key: String, valueJSON: String)]) {
            guard !range.isEmpty else { return }
            let text = String(decoding: bytes[range], as: UTF8.self)
            if !pendingText.isEmpty && Self.marksEqual(pendingMarks, marks) {
                pendingText += text
                return
            }
            flushPending()
            pendingText = text
            pendingMarks = marks
        }

        private mutating func flushPending() {
            guard !pendingText.isEmpty else { return }
            runs.append(InlineRun(pendingText, marks: pendingMarks))
            pendingText = ""
            pendingMarks = []
        }

        private static func marksEqual(
            _ a: [(key: String, valueJSON: String)], _ b: [(key: String, valueJSON: String)]
        ) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.valueJSON == $1.valueJSON }
        }

        private func adding(_ key: String, _ valueJSON: String, to marks: [(key: String, valueJSON: String)])
            -> [(key: String, valueJSON: String)]
        {
            marks.contains { $0.key == key } ? marks : marks + [(key, valueJSON)]
        }

        private mutating func scan(_ bounds: Range<Int>, marks: [(key: String, valueJSON: String)]) {
            var i = bounds.lowerBound
            let n = bounds.upperBound
            var literalStart = i

            while i < n {
                let b = bytes[i]

                // Backslash escape of Markdown punctuation.
                if b == Byte.backslash, i + 1 < n, Self.isEscapable(bytes[i + 1]) {
                    if i > literalStart { emitSlice(literalStart..<i, marks: marks) }
                    emitSlice((i + 1)..<(i + 2), marks: marks)
                    i += 2
                    literalStart = i
                    continue
                }

                // Inline code span (CommonMark N-backtick runs).
                if b == Byte.backtick, let backticks = syntax.backticks {
                    var count = 0
                    while i + count < n, bytes[i + count] == Byte.backtick { count += 1 }
                    if let close = backticks.closingRun(length: count, from: i + count, limit: n), close > i + count {
                        if i > literalStart { emitSlice(literalStart..<i, marks: marks) }
                        var innerStart = i + count
                        var innerEnd = close
                        if innerEnd - innerStart >= 2,
                            bytes[innerStart] == Byte.space,
                            bytes[innerEnd - 1] == Byte.space,
                            bytes[innerStart..<innerEnd].contains(where: { $0 != Byte.space })
                        {
                            innerStart += 1
                            innerEnd -= 1
                        }
                        emitSlice(
                            innerStart..<innerEnd,
                            marks: adding("code", InlineMarkdown.codeValue, to: marks))
                        i = close + count
                        literalStart = i
                        continue
                    }
                    i += count
                    continue
                }

                // Link: [label](url), keeping only sanitized hrefs; rejected links stay literal source text.
                if b == Byte.openBracket, syntax.hasLinkTokens,
                    !marks.contains(where: { $0.key == "link" }),
                    let link = matchLink(from: i, limit: n)
                {
                    if link.url.utf16.count <= MediaBlock.maxURL, sanitizedLinkURL(link.url) == link.url {
                        if i > literalStart { emitSlice(literalStart..<i, marks: marks) }
                        scan(link.labelRange, marks: adding("link", NativeMark.linkValue(link.url), to: marks))
                        i = link.next
                        literalStart = i
                    } else {
                        i = link.next
                    }
                    continue
                }

                // Strong emphasis (`**...**`) and emphasis (`*...*`). A run with
                // no closer stays in the literal slice and advances in one step
                // so long runs stay linear.
                if b == Byte.star, syntax.hasStarPair {
                    var runEnd = i
                    while runEnd < n, bytes[runEnd] == Byte.star { runEnd += 1 }
                    let runLen = runEnd - i
                    if runLen >= 2, canOpen(i..<(i + 2)),
                        let close = matchDelimiter(open: i, length: 2, byte: Byte.star, limit: n)
                    {
                        if i > literalStart { emitSlice(literalStart..<i, marks: marks) }
                        scan((i + 2)..<close, marks: adding("bold", InlineMarkdown.boldValue, to: marks))
                        i = close + 2
                        literalStart = i
                        continue
                    }
                    if runLen == 1, isLone(byte: Byte.star, at: i, bounds: bounds), canOpen(i..<(i + 1)),
                        let close = matchDelimiter(open: i, length: 1, byte: Byte.star, limit: n)
                    {
                        if i > literalStart { emitSlice(literalStart..<i, marks: marks) }
                        scan((i + 1)..<close, marks: adding("italic", InlineMarkdown.italicValue, to: marks))
                        i = close + 1
                        literalStart = i
                        continue
                    }
                    i = runEnd
                    continue
                }

                // Strikethrough: ~~...~~. Unclosed runs advance in one step.
                if b == Byte.tilde, syntax.hasTildePair {
                    var runEnd = i
                    while runEnd < n, bytes[runEnd] == Byte.tilde { runEnd += 1 }
                    let runLen = runEnd - i
                    if runLen >= 2, canOpen(i..<(i + 2)),
                        let close = matchDelimiter(open: i, length: 2, byte: Byte.tilde, limit: n)
                    {
                        if i > literalStart { emitSlice(literalStart..<i, marks: marks) }
                        scan((i + 2)..<close, marks: adding("strike", InlineMarkdown.strikeValue, to: marks))
                        i = close + 2
                        literalStart = i
                        continue
                    }
                    i = runEnd
                    continue
                }

                // Emphasis: _..._ (lone underscore with flanking). Longer runs advance in one step.
                if b == Byte.underscore, syntax.hasUnderscorePair {
                    var runEnd = i
                    while runEnd < n, bytes[runEnd] == Byte.underscore { runEnd += 1 }
                    let runLen = runEnd - i
                    if runLen == 1, isLone(byte: Byte.underscore, at: i, bounds: 0..<bytes.count),
                        canOpen(i..<(i + 1)),
                        let close = matchDelimiter(open: i, length: 1, byte: Byte.underscore, limit: n)
                    {
                        if i > literalStart { emitSlice(literalStart..<i, marks: marks) }
                        scan((i + 1)..<close, marks: adding("italic", InlineMarkdown.italicValue, to: marks))
                        i = close + 1
                        literalStart = i
                        continue
                    }
                    i = runEnd
                    continue
                }

                i += 1
            }

            if literalStart < n {
                if literalStart == 0, n == bytes.count, marks.isEmpty, runs.isEmpty, pendingText.isEmpty {
                    runs.append(InlineRun(syntax.text))
                } else {
                    emitSlice(literalStart..<n, marks: marks)
                }
            }
        }

        // MARK: - Flanking & delimiter matching

        private static func classifyASCII(_ byte: UInt8) -> NeighborClass {
            switch byte {
            case Byte.space, Byte.tab, Byte.lineFeed, Byte.verticalTab, Byte.formFeed, Byte.carriageReturn:
                return .whitespace
            default:
                return BlockNoteMarkdownPaste.isASCIIPunctuation(byte) ? .punctuation : .other
            }
        }

        private func classifyByteBefore(_ index: Int) -> NeighborClass {
            guard index > 0 else { return .none }
            let last = bytes[index - 1]
            if last < 0x80 { return Self.classifyASCII(last) }
            var start = index - 1
            while start > 0, (bytes[start] & 0xC0) == 0x80 { start -= 1 }
            let (scalar, _) = BlockNoteMarkdownPaste.decodeUTF8Scalar(in: bytes, at: start, limit: index)
            guard let scalar else { return .other }
            if scalar.properties.isWhitespace { return .whitespace }
            return Character(scalar).isPunctuation ? .punctuation : .other
        }

        private func classifyByteAt(_ index: Int) -> NeighborClass {
            guard index < bytes.count else { return .none }
            let first = bytes[index]
            if first < 0x80 { return Self.classifyASCII(first) }
            let (scalar, _) = BlockNoteMarkdownPaste.decodeUTF8Scalar(in: bytes, at: index, limit: bytes.count)
            guard let scalar else { return .other }
            if scalar.properties.isWhitespace { return .whitespace }
            return Character(scalar).isPunctuation ? .punctuation : .other
        }

        private func isLeftFlanking(_ run: Range<Int>) -> Bool {
            let next = classifyByteAt(run.upperBound)
            guard next != .none, next != .whitespace else { return false }
            guard next == .punctuation else { return true }
            let previous = classifyByteBefore(run.lowerBound)
            return previous == .none || previous == .whitespace || previous == .punctuation
        }

        private func isRightFlanking(_ run: Range<Int>) -> Bool {
            let previous = classifyByteBefore(run.lowerBound)
            guard previous != .none, previous != .whitespace else { return false }
            guard previous == .punctuation else { return true }
            let next = classifyByteAt(run.upperBound)
            return next == .none || next == .whitespace || next == .punctuation
        }

        /// Intraword-forbidding flanking rule so `2*3*4`, `2 * 3 * 4`, `2**3**4`,
        /// `a~~b~~c` and `snake_case` stay literal while punctuation-adjacent
        /// emphasis (`(**bold**)`, `*em*,`, `***both***`) still opens and closes.
        private func canOpen(_ run: Range<Int>) -> Bool {
            guard isLeftFlanking(run) else { return false }
            guard isRightFlanking(run) else { return true }
            return classifyByteBefore(run.lowerBound) == .punctuation
        }

        private func canClose(_ run: Range<Int>) -> Bool {
            guard isRightFlanking(run) else { return false }
            guard isLeftFlanking(run) else { return true }
            return classifyByteAt(run.upperBound) == .punctuation
        }

        private func isLone(byte: UInt8, at index: Int, bounds: Range<Int>) -> Bool {
            let prevSame = index > bounds.lowerBound && bytes[index - 1] == byte
            let nextSame = index + 1 < bounds.upperBound && bytes[index + 1] == byte
            return !prevSame && !nextSame
        }

        private static func delimiterBit(byte: UInt8, length: Int, startsTripleStar: Bool) -> UInt8 {
            switch (byte, length, startsTripleStar) {
            case (Byte.star, 1, _): return 1 << 0
            case (Byte.star, 2, false): return 1 << 1
            case (Byte.star, 2, true): return 1 << 4
            case (Byte.tilde, 2, _): return 1 << 2
            case (Byte.underscore, 1, _): return 1 << 3
            default: return 0
            }
        }

        private mutating func matchDelimiter(open: Int, length: Int, byte: UInt8, limit: Int) -> Int? {
            let startsTripleStar = byte == Byte.star && length == 2 && open + 2 < limit && bytes[open + 2] == Byte.star
            let bit = Self.delimiterBit(byte: byte, length: length, startsTripleStar: startsTripleStar)
            if (noCloserByLimit[limit, default: 0] & bit) != 0 { return nil }
            var i = open + length
            while i < limit {
                let b = bytes[i]
                if b == Byte.backslash {
                    if i + 1 < limit {
                        i += 1 + BlockNoteMarkdownPaste.utf8ScalarLength(bytes[i + 1])
                    } else {
                        i += 2
                    }
                    continue
                }
                if b == Byte.backtick, let backticks = syntax.backticks {
                    var count = 0
                    while i + count < limit, bytes[i + count] == Byte.backtick { count += 1 }
                    if let close = backticks.closingRun(length: count, from: i + count, limit: limit), close > i + count
                    {
                        i = close + count
                    } else {
                        i += count
                    }
                    continue
                }
                if b == Byte.openBracket, syntax.hasLinkTokens, let link = matchLink(from: i, limit: limit) {
                    i = link.next
                    continue
                }
                if b == byte {
                    var runEnd = i
                    while runEnd < limit, bytes[runEnd] == byte { runEnd += 1 }
                    let runLen = runEnd - i
                    if length == 1 {
                        if runLen == 1 {
                            if canClose(i..<(i + 1)) {
                                let inner = bytes[(open + 1)..<i]
                                if inner.isEmpty || inner.allSatisfy({ $0 == Byte.space }) { return nil }
                                return i
                            }
                            if canOpen(i..<(i + 1)) { return nil }
                        }
                        i = runEnd
                        continue
                    } else if runLen >= length {
                        // For `***bold italic***`, close outer `**` at the end of
                        // a 3-star run so the inner `*` keeps its closing `*`.
                        let closeStart = (startsTripleStar && runLen == 3) ? (runEnd - 2) : i
                        if canClose(closeStart..<(closeStart + length)) {
                            let inner = bytes[(open + length)..<closeStart]
                            if inner.isEmpty || inner.allSatisfy({ $0 == Byte.space }) { return nil }
                            return closeStart
                        }
                        if canOpen(i..<(i + length)) { return nil }
                        i = runEnd
                        continue
                    }
                }
                i += 1
            }
            noCloserByLimit[limit, default: 0] |= bit
            return nil
        }

        private func matchLink(from open: Int, limit: Int)
            -> (labelRange: Range<Int>, url: String, next: Int)?
        {
            let closeBracket = syntax.matchingClose[open]
            guard closeBracket > open + 1, closeBracket < limit else { return nil }
            guard
                let dest = BlockNoteMarkdownPaste.parseDestination(
                    in: syntax,
                    from: closeBracket + 1,
                    limit: limit)
            else { return nil }
            return ((open + 1)..<closeBracket, dest.url, dest.next)
        }
    }
}
