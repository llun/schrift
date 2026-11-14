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
    static func markdown(_ nodes: [Node], interlinkingOrigin: String? = nil) -> String? {
        body(nodes, interlinkingOrigin: interlinkingOrigin).map(trimmed)
    }

    /// The export's Markdown for `nodes` before that trim: a block's edge
    /// whitespace stays, as it does between other blocks of the document.
    static func body(_ nodes: [Node], interlinkingOrigin: String? = nil) -> String? {
        guard let fragment = fragment(nodes, interlinkingOrigin: interlinkingOrigin) else { return nil }
        return fragment.map { serialize($0, indent: "", inListItem: false) }.joined()
    }

    /// `htmlToMarkdown`'s `result.trim() + "\n"`.
    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: jsWhitespace) + "\n"
    }

    // MARK: - Media (PR13a)

    /// The export of a root media block (`toExternalHTML` then `htmlToMarkdown`,
    /// media.mjs): a shown image or video without a caption is
    /// `![name](url)` (nothing escaped); with a caption a raw `<figure>`
    /// (attributes and text HTML-escaped, the caption JS-trimmed, the image's
    /// alt dropped when empty or equal to the caption; a video figure carries
    /// no name); audio is raw `<audio>` HTML, in a figure with a caption; a
    /// hidden preview, and a file always, is `formatLink(name || url)` with
    /// the caption as its own untrimmed paragraph; Docs' pdf preview is an
    /// iframe, which prints nothing (its caption paragraph stays); an empty url
    /// prints an empty block, and `uploadLoader` nothing. Without the trailing
    /// blank line, which the shadow's join adds. `nil` for a pdf whose url the
    /// server would print as a span glued to the next block (not http(s)).
    static func media(node: String, props: [ProjectedProp]) -> String? {
        guard node != MediaBlock.uploadLoader else { return "" }
        let url = MediaBlock.string("url", in: props)
        let name = MediaBlock.string("name", in: props)
        let caption = MediaBlock.string("caption", in: props)
        let preview = MediaBlock.showsPreview(props)
        func link() -> String {
            formatLink((name.isEmpty ? url : name).trimmingCharacters(in: jsWhitespace), url)
        }
        func linked() -> String { caption.isEmpty ? link() : link() + "\n\n" + caption }
        if node == "pdf" {
            var parts: [String] = []
            if !url.isEmpty {
                guard isSafePDFURL(url) else { return nil }
                if !preview { parts.append(link()) }
            }
            if !caption.isEmpty { parts.append(caption) }
            return parts.joined(separator: "\n\n")
        }
        guard !url.isEmpty else { return "" }
        if node == "file" || !preview { return linked() }
        let captionText = caption.trimmingCharacters(in: jsWhitespace)
        let src = escapeAttribute(url)
        let figcaption = captionText.isEmpty ? "" : "<figcaption>\(escapeText(captionText))</figcaption>"
        switch node {
        case "audio" where caption.isEmpty:
            return "<audio src=\"\(src)\" controls></audio>"
        case "audio":
            return "<figure><audio src=\"\(src)\" controls></audio>\(figcaption)</figure>"
        case "video":
            if caption.isEmpty { return "![\(name)](\(url))" }
            return captionText.isEmpty
                ? "![](\(url))" : "<figure><video src=\"\(src)\" controls></video>\(figcaption)</figure>"
        default:  // image
            if caption.isEmpty || captionText.isEmpty { return "![\(name)](\(url))" }
            let alt = name.isEmpty || name == captionText ? "" : " alt=\"\(escapeAttribute(name))\""
            return "<figure><img\(alt) src=\"\(src)\">\(figcaption)</figure>"
        }
    }

    /// Docs' `isSafePdfUrl` (`new URL(url, "http://_")` is http or https),
    /// conservatively: a relative reference or an http(s) URL with a plain
    /// host, invalid path characters percent-encoded as the URL parser does;
    /// anything doubtful (edge whitespace or controls, which that parser
    /// strips, an encoded host) is unsafe (no shadow).
    static func isSafePDFURL(_ url: String) -> Bool {
        let edges = [url.unicodeScalars.first, url.unicodeScalars.last].compactMap { $0 }
        guard !edges.contains(where: { $0.value <= 0x20 }),
            !url.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
            let parsed = URL(string: url, encodingInvalidCharacters: true)
        else { return false }
        guard let scheme = parsed.scheme?.lowercased() else { return !url.hasPrefix("//") }
        guard scheme == "http" || scheme == "https", let host = parsed.host(percentEncoded: true) else { return false }
        return !host.isEmpty && !host.contains("%")
    }

    /// `escapeHtmlAttr`.
    private static func escapeAttribute(_ value: String) -> String {
        escapeText(value).replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// `escapeHtmlText`.
    private static func escapeText(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
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
    static func table(_ grid: TableGrid, interlinkingOrigin: String? = nil) -> String? {
        guard grid.isFamiliar, grid.columnCount > 0 else { return nil }
        var cells = Array(repeating: Array(repeating: "", count: grid.columnCount), count: grid.rows.count)
        for row in grid.rows {
            for cell in row {
                guard let content = cellContent(cell, interlinkingOrigin: interlinkingOrigin) else { return nil }
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

    private static func cellContent(_ cell: TableGrid.Cell, interlinkingOrigin: String?) -> String? {
        guard
            let rendered = inline(
                blockNoteRuns(cell, dropOmittedObjects: true), interlinkingOrigin: interlinkingOrigin)
        else { return nil }
        return rendered.trimmingCharacters(in: jsWhitespace).replacingOccurrences(of: "|", with: "\\|")
    }

    /// BlockNote 0.56's reading of a cell (`nodeToBlock`), as runs: in each
    /// paragraph, text with equal styles is one item (a link groups its own
    /// texts) and a hard break is "\n" appended to the item before it (else a
    /// plain "\n"); paragraphs then join with "\n" when the last item of one
    /// and the first of the next are text with equal styles, and are
    /// concatenated otherwise. Pinned against the exporter
    /// (`BlockNoteTableOracleTests`).
    static func blockNoteRuns(_ cell: TableGrid.Cell, dropOmittedObjects: Bool = false) -> [InlineRun] {
        enum Item {
            case text(String, Set<String>, [TextMark])
            case link(TextMark, [(text: String, styles: Set<String>, marks: [TextMark])])
            case inlineObject(NativeInlineObject)
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
                case .inlineObject?: items.append(.text("\n", [], []))
                case nil: items.append(.text("\n", [], []))
                }
            }
            for run in runs {
                if let object = run.inlineObject {
                    if dropOmittedObjects {
                        switch object {
                        case .math, .mention, .mentionSearch:
                            continue
                        case .interlink:
                            break
                        }
                    }
                    items.append(.inlineObject(object))
                    continue
                }
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
            case .inlineObject(let object): [InlineRun(inlineObject: object)]
            }
        }
    }

    /// What JS `String.prototype.trim` removes: ECMAScript WhiteSpace (tab,
    /// VT, FF, U+FEFF and the Zs spaces) and LineTerminator, exactly. Not
    /// Foundation's `.whitespaces`, which also holds U+200B (JS keeps it), nor
    /// U+0085.
    static let jsWhitespace: CharacterSet = {
        var set = CharacterSet(charactersIn: "\u{9}\u{A}\u{B}\u{C}\u{D}\u{20}\u{A0}\u{1680}\u{2028}\u{2029}")
        set.insert(charactersIn: "\u{202F}\u{205F}\u{3000}\u{FEFF}")
        set.insert(charactersIn: Unicode.Scalar(0x2000)!...Unicode.Scalar(0x200A)!)
        return set
    }()

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
    private static func fragment(_ nodes: [Node], interlinkingOrigin: String?) -> [Element]? {
        var fragment: [Element] = []
        for node in nodes {
            let block = node.block
            if SourceBlock.isSource(block.node) {
                let familiarFidelity =
                    block.fidelity == .modeled || block.fidelity == .opaque(reason: "unknownNode:\(block.node)")
                guard familiarFidelity, block.props.isEmpty,
                    block.runs.allSatisfy({ $0.marks.isEmpty && $0.inlineObject == nil })
                else { return nil }
                continue
            }
            // The classic projection's reading: only the blocks it leaves to the native editor may be opaque.
            if case .opaque(let reason) = block.fidelity, !nativeOnlyReasons.contains(reason) { return nil }
            guard let content = inline(block.runs, interlinkingOrigin: interlinkingOrigin) else { return nil }
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
            guard var children = self.fragment(node.children, interlinkingOrigin: interlinkingOrigin) else {
                return nil
            }
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
    /// link a mark splits is two links). Nothing is escaped. Fails closed
    /// (`nil`) if an enabled non-empty interlink lacks `interlinkingOrigin`.
    private static func inline(_ runs: [InlineRun], interlinkingOrigin: String?) -> String? {
        // `math`, `userMentionInline`, and `mentionSearchInline` are omitted
        // from `y-provider`'s `serverSchema`, so `yDocToBlocks` drops them
        // before ProseMirror builds text nodes and adjacent runs with equal
        // marks coalesce. `interlinkingLinkInline` remains in `serverSchema`,
        // so disabled interlinks still separate runs.
        var coalesced: [InlineRun] = []
        coalesced.reserveCapacity(runs.count)
        func markSet(_ marks: [(key: String, valueJSON: String)]) -> Set<String> {
            Set(marks.map { "\($0.key)\0\($0.valueJSON)" })
        }
        for run in runs {
            if let object = run.inlineObject {
                switch object {
                case .math, .mention, .mentionSearch:
                    continue
                case .interlink:
                    coalesced.append(run)
                }
                continue
            }
            guard !run.text.isEmpty else { continue }
            if let last = coalesced.last, last.inlineObject == nil, markSet(last.marks) == markSet(run.marks) {
                coalesced[coalesced.count - 1].text += run.text
            } else {
                coalesced.append(run)
            }
        }
        var out = ""
        for run in coalesced {
            guard let part = styled(run, interlinkingOrigin: interlinkingOrigin) else { return nil }
            out += part
        }
        return out
    }

    private static func styled(_ run: InlineRun, interlinkingOrigin: String?) -> String? {
        if let object = run.inlineObject {
            return inlineObject(object, interlinkingOrigin: interlinkingOrigin)
        }
        let keys = Set(run.marks.map(\.key))
        // A hard break inside marks: the exporter closes and reopens them
        // around it (`**a**\\` newline `**b**`).
        if !keys.contains("code"), run.text.contains("\n") {
            var pieces: [String] = []
            for segment in run.text.components(separatedBy: "\n") {
                if segment.isEmpty {
                    pieces.append("")
                } else {
                    guard
                        let rendered = styled(
                            InlineRun(segment, marks: run.marks), interlinkingOrigin: interlinkingOrigin)
                    else { return nil }
                    pieces.append(rendered)
                }
            }
            return pieces.joined(separator: "\\\n")
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

    private static func inlineObject(_ object: NativeInlineObject, interlinkingOrigin: String?) -> String? {
        switch object {
        case .math, .mention, .mentionSearch:
            return ""
        case .interlink(let docID, _, let title, let disabled, _):
            guard !disabled, !docID.isEmpty else { return "" }
            guard let interlinkingOrigin, !interlinkingOrigin.isEmpty,
                let encodedDocID = NativeInlineObject.encodeURIComponent(docID)
            else { return nil }
            let origin = NativeInlineObject.trimmingTrailingSlashes(interlinkingOrigin)
            guard !origin.isEmpty else { return nil }
            let label = (title ?? "").isEmpty ? docID : title!
            return formatLink(label, "\(origin)/docs/\(encodedDocID)/")
        }
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
