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
        guard !NativeClipboard.isTooLarge(raw) else { throw Error.tooLarge }
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
        private var payloadBytes = 0
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
            let (cleanedText, hoistedImages) = extractInlineImages(item.text)
            let runs = sanitizedInlineRuns(cleanedText)
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
            guard start + 1 < lines.count, !startsBlockConstruct(lines[start]) else { return nil }
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
            let trimmed = rest.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("![") else { return nil }
            let chars = Array(trimmed)
            let matcher = ImageMatcher(chars: chars)
            guard let match = matcher.match(from: 0), match.next == chars.count else { return nil }
            return (match.alt, match.url)
        }

        private struct MatchedImage {
            let alt: String
            let url: String
            let next: Int
        }

        /// Linear-time image syntax matcher: uses precomputed balanced bracket
        /// pairs and the shared destination parser so nested brackets, `<...>`
        /// destinations, balanced parentheses and optional quoted titles stay
        /// linear.
        private struct ImageMatcher {
            let chars: [Character]
            private let matchingClose: [Int]
            private let suffixCloseParens: [Int]

            init(chars: [Character], backticks: BacktickIndex? = nil) {
                self.chars = chars
                let index = backticks ?? BacktickIndex(chars)
                self.matchingClose = BlockNoteMarkdownPaste.matchingCloseBrackets(chars, backticks: index)
                self.suffixCloseParens = BlockNoteMarkdownPaste.suffixCloseParenCounts(chars)
            }

            func match(from open: Int) -> MatchedImage? {
                guard open + 1 < chars.count, chars[open] == "!", chars[open + 1] == "[" else { return nil }
                let closeBracket = matchingClose[open + 1]
                guard closeBracket >= 0 else { return nil }
                guard
                    let dest = BlockNoteMarkdownPaste.parseDestination(
                        in: chars,
                        from: closeBracket + 1,
                        limit: chars.count,
                        suffixCloseParens: suffixCloseParens)
                else { return nil }
                var alt = ""
                var i = open + 2
                while i < closeBracket {
                    if chars[i] == "\\", i + 1 < closeBracket,
                        BlockNoteMarkdownPaste.isASCIIPunctuation(chars[i + 1])
                    {
                        alt.append(chars[i + 1])
                        i += 2
                        continue
                    }
                    alt.append(chars[i])
                    i += 1
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
        /// (`` ``![...]`` ``).
        private func scanInlineImages(_ text: String) -> (pieces: [ImageScanPiece], matchedAny: Bool) {
            guard text.utf16.count <= BlockNoteMarkdownPaste.maxInlineParseUTF16, text.contains("![") else {
                return ([.text(text)], false)
            }
            let chars = Array(text)
            let backticks = BacktickIndex(chars)
            let matcher = ImageMatcher(chars: chars, backticks: backticks)
            var pieces: [ImageScanPiece] = []
            var current = ""
            var matchedAny = false
            var i = 0
            while i < chars.count {
                if chars[i] == "\\", i + 1 < chars.count {
                    current.append(chars[i])
                    current.append(chars[i + 1])
                    i += 2
                    continue
                }
                if chars[i] == "`" {
                    var count = 0
                    while i + count < chars.count, chars[i + count] == "`" { count += 1 }
                    if let close = backticks.closingRun(length: count, from: i + count, limit: chars.count) {
                        current.append(contentsOf: chars[i..<(close + count)])
                        i = close + count
                    } else {
                        current.append(contentsOf: chars[i..<(i + count)])
                        i += count
                    }
                    continue
                }
                if chars[i] == "!", let match = matcher.match(from: i) {
                    matchedAny = true
                    if let url = BlockNoteHTMLParser.pastedHTTPSImageURL(match.url) {
                        if !current.isEmpty {
                            pieces.append(.text(current))
                            current = ""
                        }
                        pieces.append(.image(url: url, alt: match.alt))
                    }
                    i = match.next
                    continue
                }
                current.append(chars[i])
                i += 1
            }
            if !current.isEmpty { pieces.append(.text(current)) }
            return (pieces, matchedAny)
        }

        private func extractInlineImages(_ text: String) -> (cleaned: String, images: [(url: String, alt: String)]) {
            let scan = scanInlineImages(text)
            guard scan.matchedAny else { return (text, []) }
            var cleaned = ""
            var images: [(url: String, alt: String)] = []
            for piece in scan.pieces {
                switch piece {
                case .text(let s): cleaned += s
                case .image(let url, let alt): images.append((url, alt))
                }
            }
            return (cleaned, images)
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

            let runs = sanitizedInlineRuns(text)
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
        private func sanitizedInlineRuns(_ text: String) -> [InlineRun] {
            guard !text.isEmpty else { return [] }
            guard text.utf16.count <= BlockNoteMarkdownPaste.maxInlineParseUTF16 else {
                return [InlineRun(text)]
            }
            var inline = PasteInlineParser(text)
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

    // MARK: - Backtick span index

    private struct BacktickIndex {
        private let runsByLength: [Int: [Int]]

        init(_ chars: [Character]) {
            var runs: [Int: [Int]] = [:]
            var i = 0
            while i < chars.count {
                guard chars[i] == "`" else {
                    i += 1
                    continue
                }
                let start = i
                while i < chars.count, chars[i] == "`" { i += 1 }
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

    private static func isASCIIPunctuation(_ character: Character) -> Bool {
        guard let value = character.asciiValue else { return false }
        return (0x21...0x2F).contains(value) || (0x3A...0x40).contains(value)
            || (0x5B...0x60).contains(value) || (0x7B...0x7E).contains(value)
    }

    private static func suffixCloseParenCounts(_ chars: [Character]) -> [Int] {
        var counts = [Int](repeating: 0, count: chars.count + 1)
        var i = chars.count - 1
        while i >= 0 {
            counts[i] = counts[i + 1] + (chars[i] == ")" ? 1 : 0)
            i -= 1
        }
        return counts
    }

    /// Maps every balanced `[` index in `chars` to its matching `]` index (or
    /// `-1` when unmatched), honoring backslash escapes and N-backtick code
    /// spans in a single O(n) / O(n log n) pass.
    private static func matchingCloseBrackets(_ chars: [Character], backticks: BacktickIndex) -> [Int] {
        var matching = [Int](repeating: -1, count: chars.count)
        var stack: [Int] = []
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count {
                i += 2
                continue
            }
            if chars[i] == "`" {
                var count = 0
                while i + count < chars.count, chars[i + count] == "`" { count += 1 }
                if let close = backticks.closingRun(length: count, from: i + count, limit: chars.count),
                    close > i + count
                {
                    i = close + count
                } else {
                    i += count
                }
                continue
            }
            if chars[i] == "[" {
                stack.append(i)
            } else if chars[i] == "]" {
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
    /// title (dropped). Stateless, allocation-free on failure, and amortized
    /// linear across a line.
    private static func parseDestination(
        in chars: [Character], from parenOpen: Int, limit: Int, suffixCloseParens: [Int]
    ) -> (url: String, next: Int)? {
        guard parenOpen + 1 < limit, chars[parenOpen] == "(", suffixCloseParens[parenOpen + 1] > 0 else {
            return nil
        }
        var i = parenOpen + 1
        while i < limit, chars[i] == " " || chars[i] == "\t" { i += 1 }
        let destStart: Int
        let destEnd: Int
        var hasEscape = false
        if i < limit, chars[i] == "<" {
            i += 1
            destStart = i
            while i < limit, chars[i] != ">", chars[i] != "<" {
                if chars[i] == "\\", i + 1 < limit, isASCIIPunctuation(chars[i + 1]) {
                    hasEscape = true
                    i += 2
                    continue
                }
                i += 1
            }
            guard i < limit, chars[i] == ">" else { return nil }
            destEnd = i
            i += 1
        } else {
            destStart = i
            var depth = 0
            while i < limit {
                let c = chars[i]
                if c == "\\", i + 1 < limit, isASCIIPunctuation(chars[i + 1]) {
                    hasEscape = true
                    i += 2
                    continue
                }
                if c == "(" {
                    depth += 1
                    guard depth <= maxDestinationParenDepth, i + 1 < limit, depth < suffixCloseParens[i + 1] else {
                        return nil
                    }
                } else if c == ")" {
                    if depth == 0 { break }
                    depth -= 1
                } else if let ascii = c.asciiValue {
                    if ascii == 0x20 || ascii == 0x09 {
                        break
                    } else if ascii < 0x20 || ascii == 0x7F {
                        return nil
                    }
                } else if c.isWhitespace {
                    break
                }
                i += 1
            }
            guard depth == 0 else { return nil }
            destEnd = i
        }
        guard destEnd > destStart else { return nil }
        let afterDestination = i
        while i < limit, chars[i] == " " || chars[i] == "\t" { i += 1 }
        if i > afterDestination, i < limit, chars[i] == "\"" || chars[i] == "'" {
            let quote = chars[i]
            i += 1
            while i < limit, chars[i] != quote {
                if chars[i] == "\\", i + 1 < limit { i += 2 } else { i += 1 }
            }
            guard i < limit else { return nil }
            i += 1
            while i < limit, chars[i] == " " || chars[i] == "\t" { i += 1 }
        }
        guard i < limit, chars[i] == ")" else { return nil }
        let url: String
        if hasEscape {
            var unescaped = ""
            unescaped.reserveCapacity(destEnd - destStart)
            var k = destStart
            while k < destEnd {
                if chars[k] == "\\", k + 1 < destEnd, isASCIIPunctuation(chars[k + 1]) {
                    unescaped.append(chars[k + 1])
                    k += 2
                } else {
                    unescaped.append(chars[k])
                    k += 1
                }
            }
            url = unescaped
        } else {
            url = String(chars[destStart..<destEnd])
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
        private static let escapable: Set<Character> = Set("\\`*_{}[]()#+-.!~>|")

        private let chars: [Character]
        private let backticks: BacktickIndex
        private let matchingClose: [Int]
        private let suffixCloseParens: [Int]
        private var runs: [InlineRun] = []
        private var pendingText = ""
        private var pendingMarks: [(key: String, valueJSON: String)] = []
        private var noTopLevelCloser: Set<String> = []

        init(_ text: String) {
            let chars = Array(text)
            let backticks = BacktickIndex(chars)
            self.chars = chars
            self.backticks = backticks
            self.matchingClose = BlockNoteMarkdownPaste.matchingCloseBrackets(chars, backticks: backticks)
            self.suffixCloseParens = BlockNoteMarkdownPaste.suffixCloseParenCounts(chars)
        }

        mutating func parse() -> [InlineRun] {
            scan(0..<chars.count, marks: [])
            flushPending()
            return runs
        }

        private mutating func emit(_ text: String, marks: [(key: String, valueJSON: String)]) {
            guard !text.isEmpty else { return }
            if !pendingText.isEmpty && Self.marksEqual(pendingMarks, marks) {
                pendingText += text
                return
            }
            flushPending()
            pendingText = text
            pendingMarks = marks
        }

        private mutating func emit(_ char: Character, marks: [(key: String, valueJSON: String)]) {
            if !pendingText.isEmpty && Self.marksEqual(pendingMarks, marks) {
                pendingText.append(char)
                return
            }
            flushPending()
            pendingText = String(char)
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

            while i < n {
                let c = chars[i]

                // Backslash escape of Markdown punctuation.
                if c == "\\", i + 1 < n, Self.escapable.contains(chars[i + 1]) {
                    emit(chars[i + 1], marks: marks)
                    i += 2
                    continue
                }

                // Inline code span (CommonMark N-backtick runs).
                if c == "`" {
                    var count = 0
                    while i + count < n, chars[i + count] == "`" { count += 1 }
                    if let close = backticks.closingRun(length: count, from: i + count, limit: n), close > i + count {
                        var innerStart = i + count
                        var innerEnd = close
                        if innerEnd - innerStart >= 2, chars[innerStart] == " ", chars[innerEnd - 1] == " ",
                            chars[innerStart..<innerEnd].contains(where: { $0 != " " })
                        {
                            innerStart += 1
                            innerEnd -= 1
                        }
                        emit(
                            String(chars[innerStart..<innerEnd]),
                            marks: adding("code", InlineMarkdown.codeValue, to: marks))
                        i = close + count
                        continue
                    }
                    emit(String(chars[i..<(i + count)]), marks: marks)
                    i += count
                    continue
                }

                // Link: [label](url), keeping only sanitized hrefs; rejected links stay literal source text.
                if c == "[", !marks.contains(where: { $0.key == "link" }), let link = matchLink(from: i, limit: n) {
                    if link.url.utf16.count <= MediaBlock.maxURL, sanitizedLinkURL(link.url) == link.url {
                        scan(link.labelRange, marks: adding("link", NativeMark.linkValue(link.url), to: marks))
                    } else {
                        emit(String(chars[i..<link.next]), marks: marks)
                    }
                    i = link.next
                    continue
                }

                // Strong emphasis (`**...**`) and emphasis (`*...*`). A run with
                // no closer is emitted as literal text in one step so long runs
                // stay linear.
                if c == "*" {
                    var runEnd = i
                    while runEnd < n, chars[runEnd] == "*" { runEnd += 1 }
                    let runLen = runEnd - i
                    if runLen >= 2, canOpen(i..<(i + 2)),
                        let close = matchDelimiter(open: i, length: 2, char: "*", limit: n)
                    {
                        scan((i + 2)..<close, marks: adding("bold", InlineMarkdown.boldValue, to: marks))
                        i = close + 2
                        continue
                    }
                    if runLen == 1, isLone(char: "*", at: i, bounds: bounds), canOpen(i..<(i + 1)),
                        let close = matchDelimiter(open: i, length: 1, char: "*", limit: n)
                    {
                        scan((i + 1)..<close, marks: adding("italic", InlineMarkdown.italicValue, to: marks))
                        i = close + 1
                        continue
                    }
                    emit(String(chars[i..<runEnd]), marks: marks)
                    i = runEnd
                    continue
                }

                // Strikethrough: ~~...~~. Emit an unclosed run in one step.
                if c == "~" {
                    var runEnd = i
                    while runEnd < n, chars[runEnd] == "~" { runEnd += 1 }
                    let runLen = runEnd - i
                    if runLen >= 2, canOpen(i..<(i + 2)),
                        let close = matchDelimiter(open: i, length: 2, char: "~", limit: n)
                    {
                        scan((i + 2)..<close, marks: adding("strike", InlineMarkdown.strikeValue, to: marks))
                        i = close + 2
                        continue
                    }
                    emit(String(chars[i..<runEnd]), marks: marks)
                    i = runEnd
                    continue
                }

                // Emphasis: _..._ (lone underscore with flanking). Emit longer runs in one step.
                if c == "_" {
                    var runEnd = i
                    while runEnd < n, chars[runEnd] == "_" { runEnd += 1 }
                    let runLen = runEnd - i
                    if runLen == 1, isLone(char: "_", at: i, bounds: 0..<chars.count), canOpen(i..<(i + 1)),
                        let close = matchDelimiter(open: i, length: 1, char: "_", limit: n)
                    {
                        scan((i + 1)..<close, marks: adding("italic", InlineMarkdown.italicValue, to: marks))
                        i = close + 1
                        continue
                    }
                    emit(String(chars[i..<runEnd]), marks: marks)
                    i = runEnd
                    continue
                }

                emit(c, marks: marks)
                i += 1
            }
        }

        // MARK: - Flanking & delimiter matching

        private func isMarkdownPunctuation(_ character: Character) -> Bool {
            character.isASCII ? BlockNoteMarkdownPaste.isASCIIPunctuation(character) : character.isPunctuation
        }

        private func neighbor(_ index: Int) -> Character? {
            chars.indices.contains(index) ? chars[index] : nil
        }

        private func isLeftFlanking(_ run: Range<Int>) -> Bool {
            guard let next = neighbor(run.upperBound), !next.isWhitespace else { return false }
            guard isMarkdownPunctuation(next) else { return true }
            guard let previous = neighbor(run.lowerBound - 1) else { return true }
            return previous.isWhitespace || isMarkdownPunctuation(previous)
        }

        private func isRightFlanking(_ run: Range<Int>) -> Bool {
            guard let previous = neighbor(run.lowerBound - 1), !previous.isWhitespace else { return false }
            guard isMarkdownPunctuation(previous) else { return true }
            guard let next = neighbor(run.upperBound) else { return true }
            return next.isWhitespace || isMarkdownPunctuation(next)
        }

        /// Intraword-forbidding flanking rule so `2*3*4`, `2 * 3 * 4`, `2**3**4`,
        /// `a~~b~~c` and `snake_case` stay literal while punctuation-adjacent
        /// emphasis (`(**bold**)`, `*em*,`, `***both***`) still opens and closes.
        private func canOpen(_ run: Range<Int>) -> Bool {
            guard isLeftFlanking(run) else { return false }
            guard isRightFlanking(run) else { return true }
            return neighbor(run.lowerBound - 1).map(isMarkdownPunctuation) ?? false
        }

        private func canClose(_ run: Range<Int>) -> Bool {
            guard isRightFlanking(run) else { return false }
            guard isLeftFlanking(run) else { return true }
            return neighbor(run.upperBound).map(isMarkdownPunctuation) ?? false
        }

        private func isLone(char: Character, at index: Int, bounds: Range<Int>) -> Bool {
            let prevSame = index > bounds.lowerBound && chars[index - 1] == char
            let nextSame = index + 1 < bounds.upperBound && chars[index + 1] == char
            return !prevSame && !nextSame
        }

        private mutating func matchDelimiter(open: Int, length: Int, char: Character, limit: Int) -> Int? {
            let key = String(repeating: char, count: length)
            let isTopLevel = limit == chars.count
            if isTopLevel, noTopLevelCloser.contains(key) { return nil }
            let startsTripleStar = char == "*" && length == 2 && open + 2 < limit && chars[open + 2] == "*"
            var i = open + length
            while i < limit {
                if chars[i] == "\\" {
                    i += 2
                    continue
                }
                if chars[i] == "`" {
                    var count = 0
                    while i + count < limit, chars[i + count] == "`" { count += 1 }
                    if let close = backticks.closingRun(length: count, from: i + count, limit: limit), close > i + count
                    {
                        i = close + count
                    } else {
                        i += count
                    }
                    continue
                }
                if chars[i] == "[", let link = matchLink(from: i, limit: limit) {
                    i = link.next
                    continue
                }
                if chars[i] == char {
                    var runEnd = i
                    while runEnd < limit, chars[runEnd] == char { runEnd += 1 }
                    let runLen = runEnd - i
                    if length == 1 {
                        if runLen == 1 {
                            if canClose(i..<(i + 1)) {
                                let inner = chars[(open + 1)..<i]
                                if inner.isEmpty || inner.allSatisfy({ $0 == " " }) { return nil }
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
                            let inner = chars[(open + length)..<closeStart]
                            if inner.isEmpty || inner.allSatisfy({ $0 == " " }) { return nil }
                            return closeStart
                        }
                        if canOpen(i..<(i + length)) { return nil }
                        i = runEnd
                        continue
                    }
                }
                i += 1
            }
            if isTopLevel { noTopLevelCloser.insert(key) }
            return nil
        }

        private func matchLink(from open: Int, limit: Int)
            -> (labelRange: Range<Int>, url: String, next: Int)?
        {
            let closeBracket = matchingClose[open]
            guard closeBracket > open + 1, closeBracket < limit else { return nil }
            guard
                let dest = BlockNoteMarkdownPaste.parseDestination(
                    in: chars,
                    from: closeBracket + 1,
                    limit: limit,
                    suffixCloseParens: suffixCloseParens)
            else { return nil }
            return ((open + 1)..<closeBracket, dest.url, dest.next)
        }
    }
}
