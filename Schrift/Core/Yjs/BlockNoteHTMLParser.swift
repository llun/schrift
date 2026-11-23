import Foundation

/// Parses an untrusted HTML fragment (`public.html` / `text/html`) into
/// validated BlockNote `blockContainer` copies matching `BlockNoteSubtreePayload`.
///
/// Reuses `HTMLNode` for bounded tolerant DOM parsing, `InlineFlattener` for
/// inline mark mapping, `TableClipboard` / `TableModel` for tables, and
/// `MediaBlock.pastedURL` for `https://` image URLs. Unsupported markup
/// (`script`, `style`, `iframe`, forms, arbitrary CSS colors/fonts, non-`https`
/// images) is dropped quietly; layout containers are unwrapped; `h4`–`h6` clamp
/// to heading level 3.
enum BlockNoteHTMLParser {
    enum Error: Swift.Error, Equatable {
        case tooLarge
    }

    /// Parses `html` into BlockNote `blockContainer` copies. Throws `.tooLarge`
    /// when bytes, DOM nodes/depth, block count, table size or UTF-16 length
    /// exceed clipboard bounds. Returns `[]` when no supported content remains.
    static func parse(_ html: String) throws -> [BlockNoteWriter.Copy] {
        guard html.utf8.count <= TableClipboard.maxHTMLBytes else { throw Error.tooLarge }
        guard let root = HTMLNode.parse(html) else { throw Error.tooLarge }
        var parser = Parser()
        var output: [BlockNoteWriter.Copy] = []
        var hoisted: [BlockNoteWriter.Copy] = []
        try parser.walkContainer(root, depth: 0, into: &output, hoisted: &hoisted)
        output += hoisted
        return output
    }

    /// Parses `html` and encodes the resulting blocks as a
    /// `BlockNoteSubtreePayload`, or returns `nil` when no blocks remain.
    static func payload(_ html: String) throws -> Data? {
        let blocks = try parse(html)
        guard !blocks.isEmpty else { return nil }
        do {
            return try BlockNoteSubtreePayload.encode(blocks)
        } catch BlockNoteSubtreePayload.Error.tooLarge {
            throw Error.tooLarge
        }
    }

    /// Validates a pasted image URL: must canonicalize via `MediaBlock.pastedURL`
    /// and use `https://` (`http:`, `data:`, `file:`, `javascript:` and relative
    /// URLs are dropped).
    static func pastedHTTPSImageURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            let canonical = MediaBlock.pastedURL(trimmed),
            !canonical.isEmpty,
            canonical.lowercased().hasPrefix("https://")
        else { return nil }
        return canonical
    }

    /// Sanitizes an image `alt` attribute into a bounded single-line `name` prop
    /// that always satisfies `MediaBlock.isPastable`.
    static func sanitizedImageName(_ alt: String?) -> String {
        guard let alt else { return "" }
        var scalars = String.UnicodeScalarView()
        var utf16 = 0
        for scalar in alt.unicodeScalars {
            if scalar.value == 0xFFFC { continue }
            let mapped: Unicode.Scalar =
                (CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar))
                ? " " : scalar
            let width = mapped.utf16.count
            guard utf16 + width <= MediaBlock.maxName else { break }
            scalars.append(mapped)
            utf16 += width
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    /// Builds a `blockContainer` holding a BlockNote `image` block for a
    /// validated `https://` URL.
    static func imageBlock(id: String, url: String, alt: String?) -> BlockNoteWriter.Copy {
        let name = sanitizedImageName(alt)
        let schema = MediaBlock.schemas["image"] ?? []
        let props = schema.map { field -> (key: String, value: YAnyValue) in
            switch field.key {
            case "name": return ("name", .string(name))
            case "url": return ("url", .string(url))
            default: return field
            }
        }
        return .element("blockContainer", [("id", .string(id))], [.element("image", props, [])])
    }

    /// Builds a `blockContainer` holding a normalized BlockNote `table` block
    /// from parsed `TablePastedCell` rows, or throws `.tooLarge` if the
    /// normalized grid exceeds `TableGrid.maxCells`.
    static func tableBlock(id: String, rows: [[TablePastedCell]]) throws -> BlockNoteWriter.Copy? {
        guard !rows.isEmpty else { return nil }
        let modelRows = rows.map { cells in
            TableModel.Row(
                source: nil,
                cells: cells.map { cell in
                    TableModel.Cell(
                        source: nil, node: cell.node, attrs: cell.attrs,
                        paragraphs: [.copy(TableModel.paragraph(cell.runs))])
                })
        }
        var model = TableModel(rows: modelRows)
        do {
            _ = try model.fixTable()
            let map = try model.map()
            guard map.width * map.height <= TableGrid.maxCells else { throw Error.tooLarge }
        } catch let error as Error {
            throw error
        } catch {
            return nil
        }
        let rowCopies = model.rows.map { row -> BlockNoteWriter.Copy in
            .element(
                "tableRow", [],
                row.cells.map { cell in
                    let paragraphs = cell.paragraphs.compactMap { paragraph -> BlockNoteWriter.Copy? in
                        if case .copy(let copy) = paragraph { return copy }
                        return nil
                    }
                    return .element(cell.node, TableModel.ordered(cell.attrs), paragraphs)
                })
        }
        guard !rowCopies.isEmpty else { return nil }
        let table = BlockNoteWriter.Copy.element("table", [("textColor", .string("default"))], rowCopies)
        return .element("blockContainer", [("id", .string(id))], [table])
    }

    // MARK: - Parser state

    private struct Parser {
        static let droppedElements: Set<String> = [
            "script", "style", "head", "title", "meta", "link", "noscript", "template",
            "iframe", "object", "embed", "svg", "canvas", "audio", "video",
            "form", "input", "select", "option", "optgroup", "textarea", "button",
            "fieldset", "legend", "datalist", "output", "map", "area", "source", "track",
            "colgroup", "col",
        ]

        static let layoutContainers: Set<String> = [
            "#document", "html", "body", "div", "section", "article", "main", "header",
            "footer", "nav", "aside", "figure", "figcaption", "details", "summary",
            "dl", "dt", "dd", "center", "address", "hgroup", "search", "dialog",
        ]

        static let blockElements: Set<String> = layoutContainers.union([
            "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote", "pre", "hr", "table",
        ])

        private var nextID = 1
        private var blockCount = 0
        private var utf16Count = 0

        private mutating func mintID() throws -> String {
            blockCount += 1
            guard blockCount <= BlockNoteSubtreePayload.maxBlocks else { throw Error.tooLarge }
            defer { nextID += 1 }
            return "html-\(nextID)"
        }

        private mutating func addUTF16(_ count: Int) throws {
            let (sum, overflow) = utf16Count.addingReportingOverflow(count)
            guard !overflow, sum <= NativeClipboard.maxPasteUTF16 else { throw Error.tooLarge }
            utf16Count = sum
        }

        // MARK: - Block walking

        mutating func walkContainer(
            _ node: HTMLNode, depth: Int, into output: inout [BlockNoteWriter.Copy],
            hoisted: inout [BlockNoteWriter.Copy]
        ) throws {
            var inline = InlineBuffer()
            var sawBreakOnly = false
            var emittedBlock = false

            func flushInline(allowBreakOnlyEmpty: Bool = false) throws {
                let items = inline.finish()
                if items.isEmpty {
                    if allowBreakOnlyEmpty && sawBreakOnly && !emittedBlock {
                        try output.append(makeTextContainer(node: "paragraph", props: nil, inline: []))
                    }
                    sawBreakOnly = false
                    return
                }
                sawBreakOnly = false
                try emitInlineWithImages(
                    items, node: "paragraph", props: nil, depth: depth, into: &output, hoisted: &hoisted)
                emittedBlock = true
            }

            for child in node.children {
                if child.name == "#text" {
                    inline.appendText(child.text, marks: [])
                    continue
                }
                if Self.droppedElements.contains(child.name) { continue }
                if child.name == "br" {
                    if !inline.hasContent { sawBreakOnly = true }
                    inline.appendBreak()
                    continue
                }
                if child.name == "img" {
                    if let img = makeImage(child) {
                        try flushInline()
                        let container = try makeImageContainer(url: img.url, alt: img.alt)
                        if depth == 0 { output.append(container) } else { hoisted.append(container) }
                        emittedBlock = true
                    }
                    continue
                }
                if isBlockLevel(child) {
                    try flushInline()
                    try parseBlock(child, depth: depth, into: &output, hoisted: &hoisted)
                    emittedBlock = true
                } else {
                    try collectInline(child, marks: [], into: &inline)
                }
            }
            try flushInline(allowBreakOnlyEmpty: node.name == "div" || node.name == "p")
        }

        private func isBlockLevel(_ node: HTMLNode) -> Bool {
            if Self.blockElements.contains(node.name) { return true }
            if node.attributes["data-content-type"] != nil || node.attributes["data-node-type"] != nil {
                return true
            }
            return false
        }

        private mutating func parseBlock(
            _ element: HTMLNode, depth: Int, into output: inout [BlockNoteWriter.Copy],
            hoisted: inout [BlockNoteWriter.Copy]
        ) throws {
            if Self.droppedElements.contains(element.name) { return }

            // BlockNote's own full HTML container wrapper (`data-node-type="blockContainer"`).
            if element.attributes["data-node-type"] == "blockContainer" {
                try parseBlockNoteContainer(element, depth: depth, into: &output, hoisted: &hoisted)
                return
            }

            // BlockNote's `data-content-type` blocks (checkListItem, heading, etc.).
            if let contentType = element.attributes["data-content-type"] {
                try parseBlockNoteContent(
                    element, contentType: contentType, depth: depth, into: &output, hoisted: &hoisted)
                return
            }

            switch element.name {
            case "p":
                try parseParagraph(
                    element, node: "paragraph", props: nil, depth: depth, into: &output, hoisted: &hoisted)
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let rawLevel = Int(String(element.name.dropFirst())) ?? 1
                let level = min(max(rawLevel, 1), 3)
                let props = headingProps(level: level)
                try parseParagraph(
                    element, node: "heading", props: props, depth: depth, into: &output, hoisted: &hoisted)
            case "ul":
                try parseList(element, ordered: false, depth: depth, into: &output, hoisted: &hoisted)
            case "ol":
                try parseList(element, ordered: true, depth: depth, into: &output, hoisted: &hoisted)
            case "li":
                try parseListItem(
                    element, ordered: false, start: nil, depth: depth, into: &output, hoisted: &hoisted)
            case "blockquote":
                try parseBlockquote(element, depth: depth, into: &output, hoisted: &hoisted)
            case "pre":
                try parsePre(element, into: &output)
            case "hr":
                let id = try mintID()
                output.append(.element("blockContainer", [("id", .string(id))], [.element("divider", [], [])]))
            case "table":
                if depth == 0 {
                    try parseTable(element, into: &output)
                } else {
                    try parseTable(element, into: &hoisted)
                }
            case "img":
                if let img = makeImage(element) {
                    let container = try makeImageContainer(url: img.url, alt: img.alt)
                    if depth == 0 { output.append(container) } else { hoisted.append(container) }
                }
            default:
                if Self.layoutContainers.contains(element.name) {
                    try walkContainer(element, depth: depth, into: &output, hoisted: &hoisted)
                } else {
                    try parseParagraph(
                        element, node: "paragraph", props: nil, depth: depth, into: &output, hoisted: &hoisted)
                }
            }
        }

        // MARK: - BlockNote HTML markers

        private mutating func parseBlockNoteContainer(
            _ element: HTMLNode, depth: Int, into output: inout [BlockNoteWriter.Copy],
            hoisted: inout [BlockNoteWriter.Copy]
        ) throws {
            var contentElement: HTMLNode?
            var groupElement: HTMLNode?
            for child in element.children {
                if child.attributes["data-content-type"] != nil, contentElement == nil {
                    contentElement = child
                } else if child.attributes["data-node-type"] == "blockGroup", groupElement == nil {
                    groupElement = child
                }
            }
            guard let contentElement, let contentType = contentElement.attributes["data-content-type"] else {
                try walkContainer(element, depth: depth, into: &output, hoisted: &hoisted)
                return
            }
            var emitted: [BlockNoteWriter.Copy] = []
            try parseBlockNoteContent(
                contentElement, contentType: contentType, depth: depth, into: &emitted, hoisted: &hoisted)
            if let groupElement, !emitted.isEmpty {
                let childDepth = depth + 1
                if childDepth <= BlockNoteWriter.maxNestingDepth,
                    canTakeNestedChildren(emitted[emitted.count - 1])
                {
                    var nested: [BlockNoteWriter.Copy] = []
                    try walkContainer(groupElement, depth: childDepth, into: &nested, hoisted: &hoisted)
                    if !nested.isEmpty {
                        emitted[emitted.count - 1] = attachingChildren(nested, to: emitted[emitted.count - 1])
                    }
                    output += emitted
                } else {
                    output += emitted
                    try walkContainer(groupElement, depth: depth, into: &output, hoisted: &hoisted)
                }
            } else {
                output += emitted
            }
        }

        private mutating func parseBlockNoteContent(
            _ element: HTMLNode, contentType: String, depth: Int, into output: inout [BlockNoteWriter.Copy],
            hoisted: inout [BlockNoteWriter.Copy]
        ) throws {
            switch contentType {
            case "checkListItem":
                let checked = isChecklistChecked(element)
                let props = checklistProps(checked: checked)
                try parseParagraph(
                    element, node: "checkListItem", props: props, depth: depth, into: &output, hoisted: &hoisted)
            case "bulletListItem":
                try parseParagraph(
                    element, node: "bulletListItem", props: nil, depth: depth, into: &output, hoisted: &hoisted)
            case "numberedListItem":
                let start = element.attributes["data-start"].flatMap(Int.init).flatMap {
                    (1...999_999).contains($0) ? $0 : nil
                }
                try parseParagraph(
                    element, node: "numberedListItem", props: numberedProps(start: start), depth: depth,
                    into: &output, hoisted: &hoisted)
            case "heading":
                let rawLevel = element.attributes["data-level"].flatMap(Int.init) ?? 1
                let level = min(max(rawLevel, 1), 3)
                try parseParagraph(
                    element, node: "heading", props: headingProps(level: level), depth: depth,
                    into: &output, hoisted: &hoisted)
            case "quote":
                try parseParagraph(
                    element, node: "quote", props: BlockNoteWriter.nativePropSchemas["quote"], depth: depth,
                    into: &output, hoisted: &hoisted)
            case "codeBlock":
                try parsePre(element, into: &output)
            case "divider":
                let id = try mintID()
                output.append(.element("blockContainer", [("id", .string(id))], [.element("divider", [], [])]))
            case "image":
                if let img = findFirstImage(in: element) {
                    let container = try makeImageContainer(url: img.url, alt: img.alt)
                    if depth == 0 { output.append(container) } else { hoisted.append(container) }
                } else if let src = element.attributes["data-url"] ?? element.attributes["src"],
                    let url = BlockNoteHTMLParser.pastedHTTPSImageURL(src)
                {
                    let container = try makeImageContainer(url: url, alt: element.attributes["data-name"])
                    if depth == 0 { output.append(container) } else { hoisted.append(container) }
                }
            case "table":
                if let table = findFirstTag("table", in: element) {
                    if depth == 0 {
                        try parseTable(table, into: &output)
                    } else {
                        try parseTable(table, into: &hoisted)
                    }
                }
            default:
                try parseParagraph(
                    element, node: "paragraph", props: nil, depth: depth, into: &output, hoisted: &hoisted)
            }
        }

        // MARK: - Paragraphs, headings, quotes

        private mutating func parseParagraph(
            _ element: HTMLNode, node: String, props: [(key: String, value: YAnyValue)]?, depth: Int,
            into output: inout [BlockNoteWriter.Copy], hoisted: inout [BlockNoteWriter.Copy]
        ) throws {
            var inline = InlineBuffer()
            var sawBreak = false
            for child in element.children {
                if child.name == "br" { sawBreak = true }
                try collectInline(child, marks: [], into: &inline)
            }
            let items = inline.finish()
            if items.isEmpty {
                if sawBreak {
                    try output.append(makeTextContainer(node: node, props: props, inline: []))
                }
                return
            }
            try emitInlineWithImages(items, node: node, props: props, depth: depth, into: &output, hoisted: &hoisted)
        }

        private mutating func parseBlockquote(
            _ element: HTMLNode, depth: Int, into output: inout [BlockNoteWriter.Copy],
            hoisted: inout [BlockNoteWriter.Copy]
        ) throws {
            let quoteProps = BlockNoteWriter.nativePropSchemas["quote"]
            var inline = InlineBuffer()
            func flushQuote() throws {
                let items = inline.finish()
                guard !items.isEmpty else { return }
                try emitInlineWithImages(
                    items, node: "quote", props: quoteProps, depth: depth, into: &output, hoisted: &hoisted)
            }
            for child in element.children {
                if child.name == "#text" {
                    inline.appendText(child.text, marks: [])
                } else if Self.droppedElements.contains(child.name) {
                    continue
                } else if child.name == "p" || child.name == "div" || child.name == "blockquote" {
                    try flushQuote()
                    if child.name == "blockquote" {
                        try parseBlockquote(child, depth: depth, into: &output, hoisted: &hoisted)
                    } else {
                        try parseParagraph(
                            child, node: "quote", props: quoteProps, depth: depth, into: &output, hoisted: &hoisted)
                    }
                } else if isBlockLevel(child) {
                    try flushQuote()
                    try parseBlock(child, depth: depth, into: &output, hoisted: &hoisted)
                } else {
                    try collectInline(child, marks: [], into: &inline)
                }
            }
            try flushQuote()
        }

        // MARK: - Lists & checklists

        private mutating func parseList(
            _ list: HTMLNode, ordered: Bool, depth: Int, into output: inout [BlockNoteWriter.Copy],
            hoisted: inout [BlockNoteWriter.Copy]
        ) throws {
            let explicitStart: Int? =
                if ordered, let raw = list.attributes["start"]?.trimmingCharacters(in: .whitespaces),
                    let number = Int(raw), (1...999_999).contains(number)
                {
                    number
                } else {
                    nil
                }
            var firstItem = true
            for child in list.children {
                if Self.droppedElements.contains(child.name) { continue }
                if child.name == "li" {
                    let start = firstItem ? explicitStart : nil
                    firstItem = false
                    try parseListItem(
                        child, ordered: ordered, start: start, depth: depth, into: &output, hoisted: &hoisted)
                } else if child.name == "ul" || child.name == "ol" {
                    // Malformed HTML: nested list directly inside a list attaches to the previous item if any.
                    let nestedOrdered = child.name == "ol"
                    let childDepth = depth + 1
                    if !output.isEmpty, childDepth <= BlockNoteWriter.maxNestingDepth,
                        canTakeNestedChildren(output[output.count - 1])
                    {
                        var nested: [BlockNoteWriter.Copy] = []
                        try parseList(
                            child, ordered: nestedOrdered, depth: childDepth, into: &nested, hoisted: &hoisted)
                        if !nested.isEmpty {
                            output[output.count - 1] = attachingChildren(nested, to: output[output.count - 1])
                        }
                    } else {
                        try parseList(child, ordered: nestedOrdered, depth: depth, into: &output, hoisted: &hoisted)
                    }
                } else if Self.layoutContainers.contains(child.name) {
                    try walkContainer(child, depth: depth, into: &output, hoisted: &hoisted)
                }
            }
        }

        private mutating func parseListItem(
            _ li: HTMLNode, ordered: Bool, start: Int?, depth: Int, into output: inout [BlockNoteWriter.Copy],
            hoisted: inout [BlockNoteWriter.Copy]
        ) throws {
            let checklist = detectChecklist(in: li)
            let node: String
            let props: [(key: String, value: YAnyValue)]?
            if let checked = checklist.checked {
                node = "checkListItem"
                props = checklistProps(checked: checked)
            } else if ordered {
                node = "numberedListItem"
                props = numberedProps(start: start)
            } else {
                node = "bulletListItem"
                props = nil
            }

            var inline = InlineBuffer()
            var childBlocks: [BlockNoteWriter.Copy] = []
            var itemHoisted: [BlockNoteWriter.Copy] = []
            var sawFirstParagraph = false

            func appendChildBlock(_ block: BlockNoteWriter.Copy) {
                childBlocks.append(block)
            }

            let childDepth = min(depth + 1, BlockNoteWriter.maxNestingDepth)
            for child in li.children {
                if child === checklist.checkboxNode { continue }
                if child.name == "#text" {
                    inline.appendText(child.text, marks: [])
                    continue
                }
                if Self.droppedElements.contains(child.name) { continue }
                if child.name == "ul" || child.name == "ol" {
                    try parseList(
                        child, ordered: child.name == "ol", depth: childDepth,
                        into: &childBlocks, hoisted: &itemHoisted)
                } else if child.name == "p", !sawFirstParagraph, !inline.hasContent {
                    sawFirstParagraph = true
                    for grand in child.children {
                        if grand === checklist.checkboxNode { continue }
                        try collectInline(grand, marks: [], into: &inline)
                    }
                } else if child.name == "img" {
                    if let img = makeImage(child) {
                        itemHoisted.append(try makeImageContainer(url: img.url, alt: img.alt))
                    }
                } else if child.name == "table" {
                    try parseTable(child, into: &itemHoisted)
                } else if isBlockLevel(child) {
                    var sub: [BlockNoteWriter.Copy] = []
                    try parseBlock(child, depth: childDepth, into: &sub, hoisted: &itemHoisted)
                    for block in sub { appendChildBlock(block) }
                } else {
                    try collectInline(child, marks: [], skipping: checklist.checkboxNode, into: &inline)
                }
            }

            let items = inline.finish()
            var mainParts: [BlockNoteWriter.Copy] = []
            var inlineHoisted: [BlockNoteWriter.Copy] = []
            if items.isEmpty {
                if !childBlocks.isEmpty || checklist.checked != nil {
                    try mainParts.append(makeTextContainer(node: node, props: props, inline: []))
                }
            } else {
                try emitInlineWithImages(
                    items, node: node, props: props, depth: depth, into: &mainParts, hoisted: &inlineHoisted)
            }

            if !mainParts.isEmpty {
                if !childBlocks.isEmpty {
                    if depth + 1 <= BlockNoteWriter.maxNestingDepth {
                        mainParts[mainParts.count - 1] = attachingChildren(
                            childBlocks, to: mainParts[mainParts.count - 1])
                        output += mainParts
                    } else {
                        output += mainParts
                        output += childBlocks
                    }
                } else {
                    output += mainParts
                }
            } else {
                output += childBlocks
            }

            // Root-only blocks (images, tables) hoisted out of nested list items.
            if depth == 0 {
                output += inlineHoisted
                output += itemHoisted
            } else {
                hoisted += inlineHoisted
                hoisted += itemHoisted
            }
        }

        private func detectChecklist(in li: HTMLNode) -> (checked: Bool?, checkboxNode: HTMLNode?) {
            if li.attributes["data-content-type"] == "checkListItem"
                || li.attributes["data-type"] == "taskItem"
            {
                let checkbox = findLeadingCheckbox(in: li)
                let attrChecked = li.attributes["data-checked"]?.lowercased() == "true"
                let inputChecked = checkbox.map(isCheckboxInputChecked) ?? false
                return (attrChecked || inputChecked, checkbox)
            }
            if let checkbox = findLeadingCheckbox(in: li) {
                return (isCheckboxInputChecked(checkbox), checkbox)
            }
            return (nil, nil)
        }

        private func isChecklistChecked(_ element: HTMLNode) -> Bool {
            if element.attributes["data-checked"]?.lowercased() == "true" { return true }
            if let checkbox = findLeadingCheckbox(in: element) { return isCheckboxInputChecked(checkbox) }
            return false
        }

        private func isCheckboxInputChecked(_ input: HTMLNode) -> Bool {
            guard let attr = input.attributes["checked"] else { return false }
            return attr.lowercased() != "false"
        }

        /// Finds a leading `<input type="checkbox">` (ignoring leading whitespace
        /// and unwrapping one leading `<p>`, `<label>`, `<span>` or `<div>`).
        private func findLeadingCheckbox(in node: HTMLNode, depth: Int = 0) -> HTMLNode? {
            guard depth < 4 else { return nil }
            for child in node.children {
                if child.name == "#text" {
                    if child.text.contains(where: { !" \t\n\r\u{0C}".contains($0) }) { return nil }
                    continue
                }
                if child.name == "input", child.attributes["type"]?.lowercased() == "checkbox" {
                    return child
                }
                if ["p", "label", "span", "div"].contains(child.name) {
                    return findLeadingCheckbox(in: child, depth: depth + 1)
                }
                return nil
            }
            return nil
        }

        // MARK: - Code blocks

        private mutating func parsePre(_ element: HTMLNode, into output: inout [BlockNoteWriter.Copy]) throws {
            let codeNode = element.children.first(where: { $0.name == "code" })
            let language = extractCodeLanguage(from: codeNode) ?? extractCodeLanguage(from: element) ?? "text"
            var raw = ""
            collectRawText(codeNode ?? element, into: &raw)
            var normalized = NativeClipboard.normalizingLineBreaks(
                NativeClipboard.strippingObjectReplacementCharacters(raw))
            if normalized.hasSuffix("\n") { normalized.removeLast() }
            try addUTF16(normalized.utf16.count)
            let id = try mintID()
            let content: [BlockNoteWriter.Copy] = normalized.isEmpty ? [] : [.text([.run(InlineRun(normalized))])]
            output.append(
                .element(
                    "blockContainer", [("id", .string(id))],
                    [.element("codeBlock", [("language", .string(language))], content)]))
        }

        private func collectRawText(_ node: HTMLNode, into out: inout String) {
            for child in node.children {
                if child.name == "#text" {
                    out += child.text
                } else if child.name == "br" {
                    out += "\n"
                } else if !Self.droppedElements.contains(child.name) {
                    collectRawText(child, into: &out)
                }
            }
        }

        private func extractCodeLanguage(from node: HTMLNode?) -> String? {
            guard let node else { return nil }
            if let dataLang = node.attributes["data-language"]?.trimmingCharacters(in: .whitespaces),
                isValidCodeBlockLanguage(dataLang)
            {
                return dataLang
            }
            guard let classAttr = node.attributes["class"] else { return nil }
            for token in classAttr.split(whereSeparator: \.isWhitespace) {
                let lower = token.lowercased()
                let candidate: String?
                if lower.hasPrefix("language-") {
                    candidate = String(token.dropFirst("language-".count))
                } else if lower.hasPrefix("lang-") {
                    candidate = String(token.dropFirst("lang-".count))
                } else {
                    candidate = nil
                }
                if let candidate, isValidCodeBlockLanguage(candidate) { return candidate }
            }
            return nil
        }

        // MARK: - Tables & images

        private mutating func parseTable(_ table: HTMLNode, into output: inout [BlockNoteWriter.Copy]) throws {
            let rows: [[TablePastedCell]]
            switch TableClipboard.cells(table: table) {
            case .empty: return
            case .tooLarge: throw Error.tooLarge
            case .cells(let parsed): rows = parsed
            }
            for row in rows {
                for cell in row {
                    for run in cell.runs {
                        try addUTF16(run.text.utf16.count)
                    }
                }
            }
            let id = try mintID()
            if let copy = try BlockNoteHTMLParser.tableBlock(id: id, rows: rows) {
                output.append(copy)
            }
        }

        private func makeImage(_ node: HTMLNode) -> (url: String, alt: String?)? {
            guard let src = node.attributes["src"], let url = BlockNoteHTMLParser.pastedHTTPSImageURL(src) else {
                return nil
            }
            return (url, node.attributes["alt"])
        }

        private func findFirstImage(in node: HTMLNode) -> (url: String, alt: String?)? {
            for child in node.children {
                if child.name == "img" { return makeImage(child) }
                if let found = findFirstImage(in: child) { return found }
            }
            return nil
        }

        private func findFirstTag(_ tag: String, in node: HTMLNode) -> HTMLNode? {
            for child in node.children {
                if child.name == tag { return child }
                if let found = findFirstTag(tag, in: child) { return found }
            }
            return nil
        }

        private mutating func makeImageContainer(url: String, alt: String?) throws -> BlockNoteWriter.Copy {
            let id = try mintID()
            return BlockNoteHTMLParser.imageBlock(id: id, url: url, alt: alt)
        }

        // MARK: - Inline collection

        private enum InlineItem {
            case run(InlineRun)
            case hardBreak
            case image(url: String, alt: String?)
        }

        private struct InlineBuffer {
            private(set) var items: [InlineItem] = []
            private var lastWasSpaceOrBreak = true
            var hasContent: Bool { !items.isEmpty }

            mutating func appendText(_ raw: String, marks: [(key: String, valueJSON: String)]) {
                let collapsible: Set<Character> = [" ", "\t", "\n", "\r", "\u{0C}"]
                var text = ""
                var inSpace = false
                for character in raw {
                    if character == "\u{FFFC}" { continue }
                    if collapsible.contains(character) {
                        inSpace = true
                    } else {
                        if inSpace { text.append(" ") }
                        inSpace = false
                        text.append(character)
                    }
                }
                if inSpace { text.append(" ") }
                if text == " ", !hasContent { return }
                if text.hasPrefix(" "), lastWasSpaceOrBreak { text.removeFirst() }
                guard !text.isEmpty else { return }
                appendRun(text, marks: marks)
                lastWasSpaceOrBreak = text.hasSuffix(" ")
            }

            mutating func appendBreak() {
                trimTrailingSpace()
                items.append(.hardBreak)
                lastWasSpaceOrBreak = true
            }

            mutating func appendImage(url: String, alt: String?) {
                trimTrailingSpace()
                items.append(.image(url: url, alt: alt))
                lastWasSpaceOrBreak = true
            }

            mutating func finish() -> [InlineItem] {
                trimTrailingSpace()
                // Drop a trailing sentinel `<br>` when it is the only item or at the very end?
                // Keep explicit breaks between runs; drop a lone leading/trailing break with no text.
                let hasTextOrImage = items.contains {
                    if case .hardBreak = $0 { false } else { true }
                }
                let result = hasTextOrImage ? items : []
                items = []
                lastWasSpaceOrBreak = true
                return result
            }

            private mutating func appendRun(_ text: String, marks: [(key: String, valueJSON: String)]) {
                if case .run(var last)? = items.last,
                    InlineRun("", marks: last.marks) == InlineRun("", marks: marks)
                {
                    last.text += text
                    items[items.count - 1] = .run(last)
                } else {
                    items.append(.run(InlineRun(text, marks: marks)))
                }
            }

            private mutating func trimTrailingSpace() {
                if case .run(var last)? = items.last, last.text.hasSuffix(" ") {
                    last.text.removeLast()
                    if last.text.isEmpty {
                        items.removeLast()
                    } else {
                        items[items.count - 1] = .run(last)
                    }
                }
            }
        }

        private func collectInline(
            _ node: HTMLNode, marks: [(key: String, valueJSON: String)], skipping: HTMLNode? = nil,
            into buffer: inout InlineBuffer
        ) throws {
            if node === skipping { return }
            if node.name == "#text" {
                buffer.appendText(node.text, marks: marks)
                return
            }
            if node.name == "br" {
                buffer.appendBreak()
                return
            }
            if node.name == "img" {
                if let img = makeImage(node) { buffer.appendImage(url: img.url, alt: img.alt) }
                return
            }
            if Self.droppedElements.contains(node.name) { return }
            let nextMarks = marks + InlineFlattener.addedMarks(for: node, current: marks)
            for child in node.children {
                try collectInline(child, marks: nextMarks, skipping: skipping, into: &buffer)
            }
        }

        private mutating func emitInlineWithImages(
            _ items: [InlineItem], node: String, props: [(key: String, value: YAnyValue)]?, depth: Int,
            into output: inout [BlockNoteWriter.Copy], hoisted: inout [BlockNoteWriter.Copy]
        ) throws {
            var currentCopies: [BlockNoteWriter.Copy] = []
            func flushCopies() throws {
                // Trim leading/trailing stray hardBreaks created right next to split images.
                while case .element("hardBreak", _, _)? = currentCopies.first { currentCopies.removeFirst() }
                while case .element("hardBreak", _, _)? = currentCopies.last { currentCopies.removeLast() }
                guard !currentCopies.isEmpty else { return }
                output.append(try makeTextContainer(node: node, props: props, inline: currentCopies))
                currentCopies = []
            }
            for item in items {
                switch item {
                case .run(let run):
                    try addUTF16(run.text.utf16.count)
                    let value = BlockNoteWriter.TextValue.run(run)
                    if case .text(let existing)? = currentCopies.last {
                        currentCopies[currentCopies.count - 1] = .text(existing + [value])
                    } else {
                        currentCopies.append(.text([value]))
                    }
                case .hardBreak:
                    try addUTF16(1)
                    currentCopies.append(.element("hardBreak", [], []))
                case .image(let url, let alt):
                    try flushCopies()
                    let image = try makeImageContainer(url: url, alt: alt)
                    if depth == 0 {
                        output.append(image)
                    } else {
                        hoisted.append(image)
                    }
                }
            }
            try flushCopies()
        }

        // MARK: - Block container builders

        private mutating func makeTextContainer(
            node: String, props: [(key: String, value: YAnyValue)]?, inline: [BlockNoteWriter.Copy]
        ) throws -> BlockNoteWriter.Copy {
            let id = try mintID()
            let resolvedProps = props ?? BlockNoteWriter.nativePropSchemas[node] ?? []
            return .element("blockContainer", [("id", .string(id))], [.element(node, resolvedProps, inline)])
        }

        private func headingProps(level: Int) -> [(key: String, value: YAnyValue)] {
            (BlockNoteWriter.nativePropSchemas["heading"] ?? []).map { prop in
                prop.key == "level" ? ("level", .int(level)) : prop
            }
        }

        private func checklistProps(checked: Bool) -> [(key: String, value: YAnyValue)] {
            (BlockNoteWriter.nativePropSchemas["checkListItem"] ?? []).map { prop in
                prop.key == "checked" ? ("checked", .bool(checked)) : prop
            }
        }

        private func numberedProps(start: Int?) -> [(key: String, value: YAnyValue)] {
            (BlockNoteWriter.nativePropSchemas["numberedListItem"] ?? []).map { prop in
                if prop.key == "start", let start { return ("start", .int(start)) }
                return prop
            }
        }

        private func canTakeNestedChildren(_ container: BlockNoteWriter.Copy) -> Bool {
            guard case .element("blockContainer", _, let children) = container,
                case .element(let node, _, _)? = children.first
            else { return false }
            return !MediaBlock.isMediaLike(node) && node != "table"
        }

        private func attachingChildren(
            _ newChildren: [BlockNoteWriter.Copy], to container: BlockNoteWriter.Copy
        ) -> BlockNoteWriter.Copy {
            guard case .element("blockContainer", let props, var children) = container, !newChildren.isEmpty else {
                return container
            }
            if children.count == 2, case .element("blockGroup", _, let existing) = children[1] {
                children[1] = .element("blockGroup", [], existing + newChildren)
            } else if children.count == 1 {
                children.append(.element("blockGroup", [], newChildren))
            }
            return .element("blockContainer", props, children)
        }
    }
}
