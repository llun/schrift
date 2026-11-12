import Foundation

/// The server's Markdown export of a block subtree, for the shapes the classic
/// shadow cannot spell: a toggle list item with a non-list descendant
/// (`NativeBlockProjection.markdownShadow`). A port of BlockNote 0.56's
/// `blocksToMarkdownLossy`: `serializeBlocksExternalHTML` builds the external
/// HTML (a toggle's children go into its `<details>`, except the leading lists,
/// which move into its `<li>` after it; a plain block's children flatten after
/// it), and `htmlToMarkdown` prints it (a `<details>` paragraph is an indented
/// continuation paragraph). Inline text is not escaped, as there.
///
/// The classic parser reads the indented lines as verbatim text, so the
/// classic self-check has nothing to compare; `NativeShadowExportParityTests`
/// pins this output against the installed exporter's. `nil` for a block kind
/// this port does not model (a table, media), which has no shadow anyway, and
/// for a callout: Schrift's own block, whose export here is unconfirmed.
enum NativeExportMarkdown {
    /// One block of the projected tree with its children.
    struct Node {
        var block: ProjectedBlock
        var children: [Node]
    }

    /// The preorder snapshots of one subtree (or several roots) as nodes.
    static func nodes(_ snapshots: ArraySlice<NativeBlockSnapshot>) -> [Node] {
        var nodes: [Node] = []
        var index = snapshots.startIndex
        while index < snapshots.endIndex {
            let depth = snapshots[index].depth
            var end = index + 1
            while end < snapshots.endIndex, snapshots[end].depth > depth { end += 1 }
            nodes.append(Node(block: snapshots[index].block, children: self.nodes(snapshots[(index + 1)..<end])))
            index = end
        }
        return nodes
    }

    /// The export's Markdown for `nodes`, trimmed as `htmlToMarkdown` trims it.
    static func markdown(_ nodes: [Node]) -> String? {
        body(nodes).map(trimmed)
    }

    /// The export's Markdown for `nodes` before that trim: a block's edge
    /// whitespace stays, as it does between other blocks of the document.
    static func body(_ nodes: [Node]) -> String? {
        guard let fragment = fragment(nodes) else { return nil }
        return fragment.map { serialize($0, indent: "", inListItem: false) }.joined()
    }

    /// `htmlToMarkdown`'s `result.trim() + "\n"`.
    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: jsWhitespace) + "\n"
    }

    // MARK: - Tables (PR11a)

    /// `serializeTable` over a familiar grid: the span-expanded grid (a
    /// spanned slot is empty), each cell's `serializeInlineContent` trimmed
    /// like JS `trim()` with `|` escaped, every column padded (UTF-16, as JS
    /// `padEnd`) to the longest cell and at least 10, and a header row only
    /// when the first row has a header cell (else an empty one). Lines are
    /// joined without the trailing blank line, which the shadow's join adds.
    ///
    /// `nil` for a cell BlockNote's reading merges in a way this port does
    /// not model: marked text next to a hard break or a paragraph join (its
    /// `nodeToBlock` joins equal-styled text with "\n" and concatenates
    /// anything else, so the export depends on mark order). Plain cells and
    /// single-paragraph cells are pinned against the exporter
    /// (`BlockNoteTableOracleTests`).
    static func table(_ grid: TableGrid) -> String? {
        guard grid.isFamiliar, grid.columnCount > 0 else { return nil }
        var cells = Array(repeating: Array(repeating: "", count: grid.columnCount), count: grid.rows.count)
        for row in grid.rows {
            for cell in row {
                guard let content = cellContent(cell) else { return nil }
                cells[cell.row][cell.column] = content
            }
        }
        let widths = (0..<grid.columnCount).map { column in
            max(10, cells.map { $0[column].utf16.count }.max() ?? 0)
        }
        func line(_ row: [String]) -> String {
            let parts = row.enumerated().map { column, text in
                " " + text + String(repeating: " ", count: max(0, widths[column] - text.utf16.count)) + " "
            }
            return "|" + parts.joined(separator: "|") + "|"
        }
        let separator = "|" + widths.map { " " + String(repeating: "-", count: $0) + " " }.joined(separator: "|") + "|"
        // The export renders BlockNote's JSON: the first `headerRows` rows and
        // `headerCols` cell indices are `th`, where `nodeToBlock` counts every
        // fully-header row (anywhere) and every cell index that is header in
        // all rows. Row 0 has a `th`, and so a header line, when either is set.
        let headerRows = grid.rows.filter { $0.allSatisfy(\.isHeader) }.count
        let headerCols = grid.rows[0].indices.filter { index in
            grid.rows.allSatisfy { $0.indices.contains(index) && $0[index].isHeader }
        }.count
        let lines =
            headerRows > 0 || headerCols > 0
            ? [line(cells[0]), separator] + cells.dropFirst().map(line)
            : [line(Array(repeating: "", count: grid.columnCount)), separator] + cells.map(line)
        return lines.joined(separator: "\n")
    }

    private static func cellContent(_ cell: TableGrid.Cell) -> String? {
        inline(blockNoteRuns(cell)).trimmingCharacters(in: jsWhitespace).replacingOccurrences(of: "|", with: "\\|")
    }

    /// BlockNote 0.56's reading of a cell (`nodeToBlock`), as runs: in each
    /// paragraph, text with equal styles is one item (a link groups its own
    /// texts) and a hard break is "\n" appended to the item before it (else a
    /// plain "\n"); paragraphs then join with "\n" when the last item of one
    /// and the first of the next are text with equal styles, and are
    /// concatenated otherwise. Pinned against the exporter
    /// (`BlockNoteTableOracleTests`).
    static func blockNoteRuns(_ cell: TableGrid.Cell) -> [InlineRun] {
        enum Item {
            case text(String, Set<String>, [TextMark])
            case link(TextMark, [(text: String, styles: Set<String>, marks: [TextMark])])
        }
        func style(_ marks: [TextMark]) -> Set<String> { Set(marks.map { $0.key + "=" + $0.valueJSON }) }
        func items(_ runs: [InlineRun]) -> [Item] {
            var items: [Item] = []
            func newline() {
                switch items.last {
                case .text(let text, let styles, let marks)?: items[items.count - 1] = .text(text + "\n", styles, marks)
                case .link(let link, var texts)?:
                    texts[texts.count - 1].text += "\n"
                    items[items.count - 1] = .link(link, texts)
                case nil: items.append(.text("\n", [], []))
                }
            }
            for run in runs {
                let marks = run.marks.map { TextMark(key: $0.key, valueJSON: $0.valueJSON) }
                let link = marks.first { $0.key == "link" }
                let styles = marks.filter { $0.key != "link" }
                let pieces = run.text.components(separatedBy: "\n")
                for (index, piece) in pieces.enumerated() {
                    if index > 0 { newline() }
                    guard !piece.isEmpty else { continue }
                    switch (items.last, link) {
                    case (.text(let text, let current, let currentMarks)?, nil) where current == style(styles):
                        items[items.count - 1] = .text(text + piece, current, currentMarks)
                    case (.link(let currentLink, var texts)?, let link?) where currentLink == link:
                        if texts[texts.count - 1].styles == style(styles) {
                            texts[texts.count - 1].text += piece
                        } else {
                            texts.append((piece, style(styles), styles))
                        }
                        items[items.count - 1] = .link(currentLink, texts)
                    case (_, let link?): items.append(.link(link, [(piece, style(styles), styles)]))
                    case (_, nil): items.append(.text(piece, style(styles), styles))
                    }
                }
            }
            return items
        }
        var joined: [Item] = []
        for paragraph in cell.paragraphs {
            var next = items(paragraph.runs)
            guard !joined.isEmpty else {
                joined = next
                continue
            }
            if case .text(let last, let lastStyles, let marks)? = joined.last,
                case .text(let first, let firstStyles, _)? = next.first, lastStyles == firstStyles
            {
                joined[joined.count - 1] = .text(last + "\n" + first, lastStyles, marks)
                next.removeFirst()
            }
            joined += next
        }
        return joined.flatMap { item -> [InlineRun] in
            switch item {
            case .text(let text, _, let marks): [InlineRun(text, marks: marks.map { ($0.key, $0.valueJSON) })]
            case .link(let link, let texts):
                texts.map { InlineRun($0.text, marks: ($0.marks + [link]).map { ($0.key, $0.valueJSON) }) }
            }
        }
    }

    /// What JS `String.prototype.trim` removes: WhiteSpace (with U+FEFF) and
    /// LineTerminator, but not U+0085.
    private static let jsWhitespace = CharacterSet.whitespaces.union(
        CharacterSet(charactersIn: "\n\u{B}\u{C}\r\u{2028}\u{2029}\u{FEFF}"))

    // MARK: - External HTML

    private enum Kind: Equatable {
        case bullet, numbered, check(Bool), toggle
        var ordered: Bool { self == .numbered }
    }

    private struct Item {
        var kind: Kind
        var content: String
        var details: [Element] = []  // a toggle's `<details>` after its summary
        var lists: [Element] = []  // nested lists moved into the `<li>`
    }

    private indirect enum Element {
        case paragraph(String)
        case heading(Int, String)
        case toggleHeading(Int, String, [Element])
        case list(ordered: Bool, start: Int, items: [Item])
        case quote(String)
        case code(language: String, text: String)
        case rule
        case empty  // a page break's `<div>`, which prints nothing
    }

    /// `serializeBlocksToFragment`: list items join the list before them when
    /// it has their tag; children are serialized, their leading lists move into
    /// the last list item, and the rest goes into the block's `<details>` or,
    /// for every other block, after it.
    private static func fragment(_ nodes: [Node]) -> [Element]? {
        var fragment: [Element] = []
        for node in nodes {
            let block = node.block
            // The classic projection's reading: only the blocks it leaves to the native editor may be opaque.
            if case .opaque(let reason) = block.fidelity, !nativeOnlyReasons.contains(reason) { return nil }
            let content = inline(block.runs)
            var kind: Kind?
            switch block.node {
            case "paragraph": fragment.append(.paragraph(content))
            case "callout":
                // Schrift's own block: its export with children or nested is unknown.
                return nil
            case "heading":
                guard case .int(let level)? = prop("level", block) else { return nil }
                if case .bool(true)? = prop("isToggleable", block) {
                    fragment.append(.toggleHeading(level, content, []))
                } else {
                    fragment.append(.heading(level, content))
                }
            case "quote": fragment.append(.quote(content))
            case "codeBlock":
                let language: String
                if case .string(let value)? = prop("language", block) { language = value } else { language = "text" }
                fragment.append(.code(language: language, text: block.runs.map(\.text).joined()))
            case "divider": fragment.append(.rule)
            case "pageBreak": fragment.append(.empty)
            case "bulletListItem": kind = .bullet
            case "numberedListItem": kind = .numbered
            case "toggleListItem": kind = .toggle
            case "checkListItem":
                guard case .bool(let checked)? = prop("checked", block) else { return nil }
                kind = .check(checked)
            default: return nil
            }
            if let kind {
                let item = Item(kind: kind, content: content)
                if case .list(let ordered, let start, let items)? = fragment.last, ordered == kind.ordered {
                    fragment[fragment.count - 1] = .list(ordered: ordered, start: start, items: items + [item])
                } else {
                    var start = 1
                    if case .int(let value)? = prop("start", block), value != 0 { start = value }
                    fragment.append(.list(ordered: kind.ordered, start: kind.ordered ? start : 1, items: [item]))
                }
            }
            guard !node.children.isEmpty else { continue }
            guard var children = self.fragment(node.children) else { return nil }
            if case .list(let ordered, let start, var items)? = fragment.last {
                while let first = children.first, case .list = first {
                    items[items.count - 1].lists.append(first)
                    children.removeFirst()
                }
                if kind == .toggle {
                    items[items.count - 1].details += children
                    children = []
                }
                fragment[fragment.count - 1] = .list(ordered: ordered, start: start, items: items)
            } else if case .toggleHeading(let level, let text, let details)? = fragment.last {
                fragment[fragment.count - 1] = .toggleHeading(level, text, details + children)
                children = []
            }
            fragment += children
        }
        return fragment
    }

    private static let nativeOnlyReasons: Set<String> = [
        "unknownNode:callout", "unknownNode:toggleListItem", "unknownNode:pageBreak", "toggleable heading",
    ]

    private static func prop(_ key: String, _ block: ProjectedBlock) -> YAnyValue? {
        block.props.first { $0.key == key }?.value
    }

    // MARK: - htmlToMarkdown

    private static func serialize(_ element: Element, indent: String, inListItem: Bool) -> String {
        switch element {
        case .paragraph(let content):
            let trimmed = trimHardBreaks(content)
            return inListItem ? trimmed : indent + trimmed + "\n\n"
        case .heading(let level, let content):
            return indent + String(repeating: "#", count: level) + " " + content + "\n\n"
        case .toggleHeading(let level, let content, let children):
            return serialize(.heading(level, content), indent: indent, inListItem: inListItem)
                + children.map { serialize($0, indent: indent, inListItem: inListItem) }.joined()
        case .list(let ordered, let start, let items):
            let body = items.enumerated().map { offset, item in
                serialize(item, number: ordered ? start + offset : nil, indent: indent)
            }
            return body.joined() + (inListItem ? "" : "\n")
        case .quote(let content):
            return content.components(separatedBy: "\n").map { indent + "> " + $0 }.joined(separator: "\n") + "\n\n"
        case .code(let language, let text):
            let fence = String(repeating: "`", count: max(3, longestRun(of: "`", in: text) + 1))
            if text.isEmpty { return indent + fence + language + "\n" + indent + fence + "\n\n" }
            let body = text.hasSuffix("\n") ? String(text.dropLast()) : text
            let lines = [fence + language] + body.components(separatedBy: "\n") + [fence]
            return lines.map { $0.isEmpty ? $0 : indent + $0 }.joined(separator: "\n") + "\n\n"
        case .rule:
            return indent + "***\n\n"
        case .empty:
            return ""
        }
    }

    /// `serializeListItem`: the marker line, then a toggle's `<details>`
    /// children (a paragraph after a blank line), then the moved lists.
    private static func serialize(_ item: Item, number: Int?, indent: String) -> String {
        let marker: String
        let width: Int
        switch item.kind {
        case .check(let checked): (marker, width) = ("* " + (checked ? "[x]" : "[ ]") + " ", 2)
        case .numbered:
            marker = "\(number ?? 1). "
            width = marker.count
        case .bullet, .toggle: (marker, width) = ("* ", 2)
        }
        var result = indent + marker + item.content + "\n"
        let childIndent = indent + String(repeating: " ", count: width)
        for child in item.details {
            if case .paragraph(let content) = child {
                result += "\n" + childIndent + content + "\n"
            } else {
                result += serialize(child, indent: childIndent, inListItem: true)
            }
        }
        for list in item.lists { result += serialize(list, indent: childIndent, inListItem: true) }
        return result
    }

    /// `serializeInlineContent` over the external HTML of `runs`: each run is
    /// one ProseMirror text node wrapped in its own marks, bold outermost, then
    /// italic, strike, code, and its link innermost (`<a>` per text node, so a
    /// link a mark splits is two links). Nothing is escaped.
    private static func inline(_ runs: [InlineRun]) -> String {
        runs.map(styled).joined()
    }

    private static func styled(_ run: InlineRun) -> String {
        let keys = Set(run.marks.map(\.key))
        // A hard break inside marks: the exporter closes and reopens them
        // around it (`**a**\\` newline `**b**`).
        if !keys.contains("code"), run.text.contains("\n") {
            return run.text.components(separatedBy: "\n").map {
                $0.isEmpty ? "" : styled(InlineRun($0, marks: run.marks))
            }.joined(separator: "\\\n")
        }
        var text: String
        if keys.contains("code") {
            // `<code>` prints its text content: the link inside it is dropped.
            let fence = String(repeating: "`", count: longestRun(of: "`", in: run.text) + 1)
            text = fence + (run.text.hasPrefix("`") || run.text.hasSuffix("`") ? " \(run.text) " : run.text) + fence
        } else {
            text = run.text
            if let href = run.marks.first(where: { $0.key == "link" }).flatMap({
                YBlockProjection.linkHref(from: $0.valueJSON)
            }) {
                text = formatLink(text, href)
            }
        }
        if keys.contains("strike") { text = "~~\(text)~~" }
        if keys.contains("italic") { text = emphasis(text, "*") }
        if keys.contains("bold") { text = emphasis(text, "**") }
        return text
    }

    /// `formatLink`: the bare URL when the label is empty, or is the URL and
    /// either not `http(s)://`/`www.` or one `parseAutolinkLiteral` reads back
    /// whole; else `[label](url)` with `\`, `(` and `)` escaped.
    private static func formatLink(_ text: String, _ href: String) -> String {
        if text.isEmpty { return href }
        if text == href {
            let web = href.range(of: #"^(https?://|www\.)"#, options: [.regularExpression, .caseInsensitive]) != nil
            if !web || readsBackAsAutolink(href) { return href }
        }
        let escaped = href.replacingOccurrences(of: #"([\\()])"#, with: #"\\$1"#, options: .regularExpression)
        return "[\(text)](\(escaped))"
    }

    /// Whether `parseAutolinkLiteral(href)` is `{value: href, href: href}`. Its
    /// first match must start at 0: for a `www.` URL that is a schemeless match
    /// whose href gains `http://`, so never; for `http(s)://` it is the
    /// case-sensitive protocol match (`[^\s]+`) after an entity suffix is cut
    /// and `trimTrailing` drops trailing punctuation and unbalanced closers.
    private static func readsBackAsAutolink(_ href: String) -> Bool {
        guard href.hasPrefix("http://") || href.hasPrefix("https://"),
            !href.contains(where: \.isWhitespace)
        else { return false }
        let value = href.replacingOccurrences(of: #"&[a-zA-Z0-9]+;$"#, with: "", options: .regularExpression)
        guard value.count > (href.hasPrefix("https") ? 8 : 7) else { return false }
        return trimTrailing(value) == href
    }

    /// The link detector's `trimTrailing`.
    private static func trimTrailing(_ value: String) -> String {
        var value = value
        var changed = true
        while changed {
            changed = false
            let trimmed = value.replacingOccurrences(of: #"[.,;:!?"']+$"#, with: "", options: .regularExpression)
            if trimmed != value {
                value = trimmed
                changed = true
            }
            for (open, close) in [("(", ")"), ("[", "]")] as [(Character, Character)] {
                while value.last == close, value.filter({ $0 == close }).count > value.filter({ $0 == open }).count {
                    value.removeLast()
                    changed = true
                }
            }
        }
        return value
    }

    /// Emphasis moves trailing whitespace outside its delimiters, and wraps
    /// nothing when the text is only whitespace.
    private static func emphasis(_ text: String, _ delimiter: String) -> String {
        let content = text.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        let trailing = String(text.dropFirst(content.count))
        return content.isEmpty ? trailing : delimiter + content + delimiter + trailing
    }

    private static func trimHardBreaks(_ text: String) -> String {
        text.replacingOccurrences(of: #"^(\\\n)+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(\\\n)+$"#, with: "", options: .regularExpression)
    }

    private static func longestRun(of character: Character, in text: String) -> Int {
        var longest = 0
        var current = 0
        for scalar in text {
            current = scalar == character ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }
}
