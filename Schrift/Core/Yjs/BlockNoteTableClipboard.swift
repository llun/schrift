import Foundation

/// One pasted table cell (PR11c) as BlockNote 0.56 parses the clipboard: its
/// node, its attributes and its content as one paragraph of runs (a hard
/// break is "\n"). What prosemirror-tables' `handlePaste` inserts.
struct TablePastedCell: Equatable, Sendable {
    var node: String
    var attrs: [String: YAnyValue]
    var runs: [InlineRun]

    var colspan: Int { TableModel.Cell.int(attrs["colspan"]) ?? 1 }
    var rowspan: Int { TableModel.Cell.int(attrs["rowspan"]) ?? 1 }
}

/// A CellSelection's clipboard (PR11c): what a copy writes.
struct TableCopy: Equatable, Sendable {
    /// Schrift's lossless payload (`BlockNoteSubtreePayload`, one table).
    var payload: Data?
    /// BlockNote's external HTML (`public.html`).
    var html: String
    /// BlockNote's Markdown of it (plain text).
    var plain: String?
}

/// The table clipboard as the web writes and reads it (PR11c), pinned
/// against BlockNote 0.56 + prosemirror-tables 1.8.5
/// (`BlockNoteTableClipboardCaptures`).
///
/// **Copy** (a CellSelection's `content()`): `text/html` is BlockNote's
/// external HTML of the cells (every cell a `td`, its props as `data-*`), the
/// plain text its Markdown, and Schrift's lossless payload a one-table
/// `BlockNoteSubtreePayload` (so a paste outside a table inserts the table).
///
/// **Paste** reads, like the web: HTML through BlockNote's parse
/// (`tryParseHTMLToBlocks` then `blocksToFullHTML`: header rows and columns
/// counted, widths from the first row, content flattened into one paragraph,
/// `parseTableContent`), the payload as BlockNote reads its own clipboard
/// (`blocknote/html`: nodes and spans kept, content flattened), and plain
/// text as one cell. **Everything pasted is untrusted:** the HTML and the
/// payload are bounded (bytes, nodes, depth, cells, spans) before anything
/// is built, a link `sanitizedLinkURL` would not write unchanged loses its
/// mark, and anything that is not one table is not cells.
enum TableClipboard {
    static let maxHTMLBytes = 2 << 20
    /// Elements and text nodes one HTML paste may hold.
    static let maxNodes = 200_000
    static let maxDepth = 256
    /// The pasteboard type of an HTML fragment.
    static let htmlType = "public.html"

    static let defaultAttrs: [String: YAnyValue] = [
        "colspan": .int(1), "rowspan": .int(1), "backgroundColor": .string("default"),
        "textColor": .string("default"), "textAlignment": .string("left"),
    ]

    /// JS `NaN`, as `parseInt("")` leaves an unset width.
    static let notANumber = YAnyValue.float64(Data([0x7F, 0xF8, 0, 0, 0, 0, 0, 0]))

    // MARK: - Paste

    enum TableParseResult {
        case cells([[TablePastedCell]])
        case empty
        case tooLarge
    }

    /// Parses one `<table>` element into BlockNote cells, bounded by
    /// `TableGrid.maxCells`.
    static func cells(table: HTMLNode, paletteColorsOnly: Bool = false) -> TableParseResult {
        var rows: [[TablePastedCell]] = []
        var area = 0
        for row in table.rows() {
            var cells: [TablePastedCell] = []
            for element in row.children where element.name == "td" || element.name == "th" {
                guard let cell = parsedCell(element, paletteColorsOnly: paletteColorsOnly) else { return .tooLarge }
                area += cell.colspan * cell.rowspan
                guard area <= TableGrid.maxCells else { return .tooLarge }
                cells.append(cell)
            }
            if !cells.isEmpty { rows.append(cells) }
        }
        guard !rows.isEmpty else { return .empty }
        return .cells(blockNoteRoundTrip(rows).map { $0.map(raw) })
    }

    /// HTML from another app or the web (`text/html`): its one table's cells,
    /// or nil when it holds anything else (the web pastes that as text).
    static func cells(html: String) -> [[TablePastedCell]]? {
        guard html.utf8.count <= maxHTMLBytes, let document = HTMLNode.parse(html) else { return nil }
        guard let table = document.onlyTable() else { return nil }
        if case .cells(let rows) = cells(table: table) { return rows }
        return nil
    }

    /// Schrift's own copy (`BlockNoteSubtreePayload`): its table's cells, as
    /// the web reads its `blocknote/html` (spans and nodes kept, content one
    /// paragraph). Nil for any payload that is not exactly one table.
    static func cells(payload: Data) -> [[TablePastedCell]]? {
        guard let rawCopies = try? BlockNoteSubtreePayload.decode(payload),
            let copies = try? BlockNoteSubtreePayload.validatingPastable(rawCopies),
            copies.count == 1,
            case .element("blockContainer", _, let children) = copies[0],
            case .element("table", _, let rowCopies)? = children.first
        else { return nil }
        var rows: [[TablePastedCell]] = []
        var area = 0
        for case .element("tableRow", _, let cellCopies) in rowCopies {
            var cells: [TablePastedCell] = []
            for case .element(let node, let props, let paragraphs) in cellCopies
            where node == "tableCell" || node == "tableHeader" {
                var runs: [InlineRun] = []
                for case .element("tableParagraph", _, let inline) in paragraphs {
                    for child in inline {
                        switch child {
                        case .text(let values):
                            for case .run(let run) in values { runs.append(run) }
                        case .element("hardBreak", _, _): runs.append(InlineRun("\n"))
                        case .element(let inlineNode, let inlineProps, let inlineChildren):
                            let projected = inlineProps.map { ProjectedProp(key: $0.key, value: $0.value) }
                            if let object = NativeInlineObject.read(
                                node: inlineNode, props: projected, children: inlineChildren)
                            {
                                runs.append(InlineRun(inlineObject: object))
                            }
                        }
                    }
                }
                let cell = raw(
                    TablePastedCell(
                        node: node, attrs: Dictionary(props.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 }),
                        runs: runs))
                guard (1...TableGrid.maxCells).contains(cell.colspan), (1...TableGrid.maxCells).contains(cell.rowspan)
                else { return nil }
                area += cell.colspan * cell.rowspan
                guard area <= TableGrid.maxCells else { return nil }
                cells.append(cell)
            }
            if !cells.isEmpty { rows.append(cells) }
        }
        return rows.isEmpty ? nil : rows
    }

    /// Whether `cells`, repeated `repeated` times over a selection, hold more
    /// text than one paste may (`NativeClipboard`'s UTF-16 and line bounds).
    static func isTooLarge(_ cells: [[TablePastedCell]], repeated: Int) -> Bool {
        var units = 0
        var lines = 0
        for row in cells {
            for cell in row {
                for run in cell.runs {
                    let runUnits = run.text.utf16.count
                    let mathUnits: Int =
                        if case .math(let source)? = run.inlineObject {
                            source.utf16.count
                        } else {
                            0
                        }
                    let (sum1, ov1) = units.addingReportingOverflow(runUnits)
                    let (sum2, ov2) = sum1.addingReportingOverflow(mathUnits)
                    if ov1 || ov2 || sum2 > NativeClipboard.maxPasteUTF16 { return true }
                    units = sum2
                    lines += run.text.utf16.lazy.filter { $0 == 0x0A }.count
                }
            }
        }
        let times = max(1, repeated)
        return units.multipliedReportingOverflow(by: times).partialValue > NativeClipboard.maxPasteUTF16
            || units.multipliedReportingOverflow(by: times).overflow
            || lines * times >= NativeClipboard.maxPasteLines
    }

    /// The pasted cells' rectangle (`ensureRectangular`'s width and height).
    static func size(_ rows: [[TablePastedCell]]) -> (width: Int, height: Int) {
        var widths: [Int] = []
        for (index, row) in rows.enumerated() {
            for cell in row {
                for spanned in index..<(index + max(1, cell.rowspan)) {
                    while widths.count <= spanned { widths.append(0) }
                    widths[spanned] += max(1, cell.colspan)
                }
            }
        }
        return (widths.max() ?? 0, max(rows.count, widths.count))
    }

    /// Plain text into a CellSelection (`fitSlice` of the pasted paragraph):
    /// one default cell, a line break a hard break.
    static func cell(text: String) -> TablePastedCell {
        let text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TablePastedCell(node: "tableCell", attrs: defaultAttrs, runs: text.isEmpty ? [] : [InlineRun(text)])
    }

    /// What BlockNote's parse of its own rendered cell keeps: spans, the
    /// three props (defaults filled) and `colwidth` through `parseInt` (an
    /// unset entry is `NaN`).
    static func raw(_ cell: TablePastedCell) -> TablePastedCell {
        var attrs: [String: YAnyValue] = [
            "colspan": .int(cell.colspan), "rowspan": .int(cell.rowspan),
            "backgroundColor": stringValue(cell.attrs["backgroundColor"]) ?? .string("default"),
            "textColor": stringValue(cell.attrs["textColor"]) ?? .string("default"),
            "textAlignment": stringValue(cell.attrs["textAlignment"]) ?? .string("left"),
        ]
        if case .array(let widths)? = cell.attrs["colwidth"] { attrs["colwidth"] = .array(widths.map(parsedInt)) }
        return TablePastedCell(node: cell.node, attrs: attrs, runs: cell.runs)
    }

    private static func stringValue(_ value: YAnyValue?) -> YAnyValue? {
        if case .string? = value { value } else { nil }
    }

    /// `parseInt` of a width as `renderHTML` spelled it.
    private static func parsedInt(_ value: YAnyValue) -> YAnyValue {
        switch value {
        case .int: return value
        case .float64, .float32:
            guard let number = TableGrid.number(value) ?? float32(value), number.isFinite,
                abs(number) < Double(Int.max / 2)
            else { return notANumber }
            return .int(Int(number.rounded(.towardZero)))
        default: return notANumber
        }
    }

    private static func float32(_ value: YAnyValue) -> Double? {
        guard case .float32(let data) = value, data.count == 4 else { return nil }
        return Double(Float(bitPattern: data.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }))
    }

    /// `tryParseHTMLToBlocks` then `blocksToFullHTML`: BlockNote's JSON of the
    /// pasted table. Header rows and columns are counted from the cells, each
    /// cell's width comes from the first row, and its props get defaults.
    private static func blockNoteRoundTrip(_ rows: [[TablePastedCell]]) -> [[TablePastedCell]] {
        let headerRows = rows.filter { $0.allSatisfy { $0.node == "tableHeader" } }.count
        let headerCols = (rows.first ?? []).indices.filter { index in
            rows.allSatisfy { $0.indices.contains(index) && $0[index].node == "tableHeader" }
        }.count
        var columnWidths: [YAnyValue] = []
        for cell in rows.first ?? [] {
            if case .array(let widths)? = cell.attrs["colwidth"] {
                columnWidths += widths
            } else {
                columnWidths += Array(repeating: .undefined, count: cell.colspan)
            }
        }
        let columns = layout(rows)
        return rows.enumerated().map { row, cells in
            cells.enumerated().map { index, cell in
                var attrs = defaultAttrs
                attrs["colspan"] = .int(cell.colspan)
                attrs["rowspan"] = .int(cell.rowspan)
                for key in ["backgroundColor", "textColor", "textAlignment"] {
                    if let value = stringValue(cell.attrs[key]) { attrs[key] = value }
                }
                let column = columns[row][index]
                if cell.colspan > 1 {
                    attrs["colwidth"] = .array(
                        (0..<cell.colspan).map { offset in
                            columnWidths.indices.contains(column + offset) ? columnWidths[column + offset] : .undefined
                        })
                } else if columnWidths.indices.contains(column), let width = TableGrid.number(columnWidths[column]),
                    width != 0, !width.isNaN
                {
                    attrs["colwidth"] = .array([columnWidths[column]])
                }
                let node = row < headerRows || index < headerCols ? "tableHeader" : "tableCell"
                return TablePastedCell(node: node, attrs: attrs, runs: cell.runs)
            }
        }
    }

    /// Each cell's first slot column (`TableMap`), tolerant of ragged rows.
    private static func layout(_ rows: [[TablePastedCell]]) -> [[Int]] {
        var taken: [Int: Set<Int>] = [:]
        return rows.enumerated().map { row, cells in
            var column = 0
            return cells.map { cell in
                while taken[row]?.contains(column) == true { column += 1 }
                let start = column
                for spanned in row..<(row + min(cell.rowspan, rows.count)) {
                    for slot in start..<(start + cell.colspan) { taken[spanned, default: []].insert(slot) }
                }
                column += cell.colspan
                return start
            }
        }
    }

    /// A `td`/`th` as BlockNote's schema parses it (`addAttributes`, the
    /// default props' `parseHTML`, `parseTableContent`). Nil for a span the
    /// bound refuses.
    private static func parsedCell(_ element: HTMLNode, paletteColorsOnly: Bool) -> TablePastedCell? {
        func span(_ key: String) -> Int? {
            guard let value = element.attributes[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
                return 1
            }
            guard let number = Int(value) else { return 1 }
            return (1...TableGrid.maxCells).contains(number) ? number : nil
        }
        guard let colspan = span("colspan"), let rowspan = span("rowspan") else { return nil }
        var attrs: [String: YAnyValue] = ["colspan": .int(colspan), "rowspan": .int(rowspan)]
        if let widths = element.attributes["colwidth"], !widths.isEmpty {
            attrs["colwidth"] = .array(
                widths.split(separator: ",", omittingEmptySubsequences: false).map { piece in
                    Int(String(piece).trimmingCharacters(in: .whitespaces).prefix { $0.isNumber || $0 == "-" })
                        .map { .int($0) } ?? notANumber
                })
        }
        let style = element.style
        let props: [(key: String, data: String, css: String?)] = [
            ("backgroundColor", "data-background-color", "background-color"), ("textColor", "data-text-color", "color"),
            ("textAlignment", "data-text-alignment", nil),
        ]
        for prop in props {
            if let value = element.attributes[prop.data] {
                attrs[prop.key] = .string(String(value.prefix(64)))
            } else if let css = prop.css, let value = style[css]?.lowercased(), NativeMark.colors.contains(value) {
                // shortcut: only BlockNote's colour names are read from CSS;
                // the web keeps any CSS value (which it then does not show).
                attrs[prop.key] = .string(value)
            }
        }
        return TablePastedCell(
            node: element.name == "th" ? "tableHeader" : "tableCell", attrs: attrs,
            runs: InlineFlattener.runs(element, paletteColorsOnly: paletteColorsOnly))
    }

    // MARK: - Copy

    /// The clipboard of a copied rectangle (`TableModel.contentGrid`).
    static func copy(
        _ grid: TableGrid, tableProps: [ProjectedProp], serverOrigin: String? = nil
    ) -> TableCopy {
        let rows = grid.rows.map { row -> BlockNoteWriter.Copy in
            .element(
                "tableRow", [],
                row.map { cell in
                    .element(
                        cell.isHeader ? "tableHeader" : "tableCell",
                        TableModel.ordered(Dictionary(cell.props.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })),
                        cell.paragraphs.map { TableModel.paragraph($0.runs) })
                })
        }
        let table = BlockNoteWriter.Copy.element(
            "table", tableProps.map { ($0.key, $0.value) }, rows)
        let payload = try? BlockNoteSubtreePayload.encode(
            [.element("blockContainer", [("id", .string("table"))], [table])])
        return TableCopy(
            payload: payload,
            html: html(grid, serverOrigin: serverOrigin),
            plain: markdown(grid, serverOrigin: serverOrigin))
    }

    /// BlockNote's mark order (schema rank), outermost first.
    static let markRank = ["bold", "italic", "underline", "strike", "code", "textColor", "backgroundColor", "link"]

    /// BlockNote 0.56's palette (`COLORS_DEFAULT`), as its external HTML spells it.
    static let palette: [String: (text: String, background: String)] = [
        "gray": ("rgb(155, 154, 151)", "rgb(235, 236, 237)"), "brown": ("rgb(100, 71, 58)", "rgb(233, 229, 227)"),
        "red": ("rgb(224, 62, 62)", "rgb(251, 228, 228)"), "orange": ("rgb(217, 115, 13)", "rgb(246, 233, 217)"),
        "yellow": ("rgb(223, 171, 1)", "rgb(251, 243, 219)"), "green": ("rgb(77, 100, 97)", "rgb(221, 237, 234)"),
        "blue": ("rgb(11, 110, 153)", "rgb(221, 235, 241)"), "purple": ("rgb(105, 64, 165)", "rgb(234, 228, 242)"),
        "pink": ("rgb(173, 26, 114)", "rgb(244, 223, 235)"),
    ]

    /// The copied cells as BlockNote's external HTML (`text/html`).
    static func html(_ grid: TableGrid, serverOrigin: String? = nil) -> String {
        var columnWidths: [YAnyValue] = []
        for cell in grid.rows.first ?? [] {
            if case .array(let widths)? = cell.props.first(where: { $0.key == "colwidth" })?.value {
                columnWidths += widths
            } else {
                columnWidths += Array(repeating: .undefined, count: cell.colspan)
            }
        }
        var out = "<table>"
        for row in grid.rows {
            out += "<tr>"
            for cell in row {
                var attrs = ""
                for (key, name, fallback) in [
                    ("textColor", "data-text-color", "default"),
                    ("backgroundColor", "data-background-color", "default"),
                    ("textAlignment", "data-text-alignment", "left"),
                ] {
                    if let value = cell.string(key), value != fallback {
                        attrs += " \(name)=\"\(escape(value, quote: true))\""
                    }
                }
                attrs += " colspan=\"\(cell.colspan)\" rowspan=\"\(cell.rowspan)\""
                if cell.colspan > 1 {
                    let widths = (0..<cell.colspan).map { offset -> String in
                        let column = cell.column + offset
                        return columnWidths.indices.contains(column) ? jsString(columnWidths[column]) : ""
                    }
                    attrs += " colwidth=\"\(widths.joined(separator: ","))\""
                }
                out +=
                    "<td\(attrs)><p>\(inlineHTML(NativeExportMarkdown.blockNoteRuns(cell), serverOrigin: serverOrigin))</p></td>"
            }
            out += "</tr>"
        }
        return out + "</table>"
    }

    /// The copied cells' Markdown (`text/plain`): every cell is a `td`, so the
    /// header line is empty.
    static func markdown(_ grid: TableGrid, serverOrigin: String? = nil) -> String? {
        var plain = grid
        for row in plain.rows.indices {
            for index in plain.rows[row].indices { plain.rows[row][index].isHeader = false }
        }
        return NativeExportMarkdown.table(plain, interlinkingOrigin: serverOrigin).map { $0 + "\n" }
    }

    /// A JS number's `toString`, an unset entry as "" (`Array.join`).
    private static func jsString(_ value: YAnyValue) -> String {
        switch value {
        case .int(let number): return String(number)
        case .float64, .float32:
            guard let number = TableGrid.number(value) ?? float32(value) else { return "NaN" }
            if number.isNaN { return "NaN" }
            if number.isInfinite { return number > 0 ? "Infinity" : "-Infinity" }
            if number == number.rounded(), abs(number) < 1e21 { return String(Int(number)) }
            return String(number)
        case .string(let string): return string
        default: return ""
        }
    }

    /// prosemirror's `DOMSerializer` over the runs: marks in rank order, kept
    /// open across neighbours that share them, closed around a hard break.
    static func inlineHTML(_ runs: [InlineRun], serverOrigin: String? = nil) -> String {
        var out = ""
        var active: [TextMark] = []
        func close(to count: Int) {
            while active.count > count { out += closing(active.removeLast()) }
        }
        for run in runs {
            if let inline = run.inlineObject {
                close(to: 0)
                out += inlineObjectHTML(inline, serverOrigin: serverOrigin)
                continue
            }
            let marks = run.marks.compactMap { mark -> TextMark? in
                markRank.contains(mark.key) ? TextMark(key: mark.key, valueJSON: mark.valueJSON) : nil
            }.sorted { markRank.firstIndex(of: $0.key)! < markRank.firstIndex(of: $1.key)! }
            for (index, piece) in run.text.components(separatedBy: "\n").enumerated() {
                if index > 0 {
                    close(to: 0)
                    out += "<br>"
                }
                guard !piece.isEmpty else { continue }
                var keep = 0
                while keep < min(active.count, marks.count), marks[keep] == active[keep] { keep += 1 }
                close(to: keep)
                for mark in marks[keep...] {
                    out += opening(mark)
                    active.append(mark)
                }
                out += escape(piece, quote: false)
            }
        }
        close(to: 0)
        return out
    }

    private static func inlineObjectHTML(_ inline: NativeInlineObject, serverOrigin: String?) -> String {
        switch inline {
        case .interlink(let docID, _, let title, let disabled, _):
            let label = (title?.isEmpty == false ? title! : docID)
            if !disabled, !docID.isEmpty,
                let origin = serverOrigin.map(NativeInlineObject.trimmingTrailingSlashes), !origin.isEmpty,
                let encodedDocID = NativeInlineObject.encodeURIComponent(docID)
            {
                let href = escape("\(origin)/docs/\(encodedDocID)/", quote: true)
                return "<a href=\"\(href)\" target=\"_blank\" rel=\"noopener noreferrer nofollow\" "
                    + "classname=\"bn-inline-content-section\" data-inline-content-type=\"link\">"
                    + "\(escape(label, quote: false))</a>"
            }
            return "<span data-inline-content-type=\"interlinkingLinkInline\">\(escape(label, quote: false))</span>"
        case .mention(let userID, _):
            return
                "<span data-inline-content-type=\"userMentionInline\" data-user-id=\"\(escape(userID, quote: true))\">"
                + "\(escape(inline.visibleText, quote: false))</span>"
        case .mentionSearch:
            return "<span data-inline-content-type=\"mentionSearchInline\"></span>"
        case .math(let source):
            return "<span data-inline-content-type=\"math\">\(escape(source, quote: false))</span>"
        }
    }

    private static func opening(_ mark: TextMark) -> String {
        switch mark.key {
        case "bold": return "<strong>"
        case "italic": return "<em>"
        case "underline": return "<u>"
        case "strike": return "<s>"
        case "code": return "<code>"
        case "link":
            let href = escape(YBlockProjection.linkHref(from: mark.valueJSON) ?? "", quote: true)
            return "<a href=\"\(href)\" target=\"_blank\" rel=\"noopener noreferrer nofollow\" "
                + "classname=\"bn-inline-content-section\" data-inline-content-type=\"link\">"
        default:
            let name = NativeMark.colorName(from: mark.valueJSON) ?? ""
            let css = palette[name].map {
                mark.key == "textColor" ? "color: \($0.text);" : "background-color: \($0.background);"
            }
            let style = css.map { " style=\"\($0)\"" } ?? ""
            return
                "<span\(style) data-style-type=\"\(mark.key)\" data-value=\"\(escape(name, quote: true))\" data-editable=\"\">"
        }
    }

    private static func closing(_ mark: TextMark) -> String {
        switch mark.key {
        case "bold": "</strong>"
        case "italic": "</em>"
        case "underline": "</u>"
        case "strike": "</s>"
        case "code": "</code>"
        case "link": "</a>"
        default: "</span>"
        }
    }

    static func escape(_ text: String, quote: Bool) -> String {
        var out = ""
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<" where !quote: out += "&lt;"
            case ">" where !quote: out += "&gt;"
            case "\"" where quote: out += "&quot;"
            case "\u{00A0}": out += "&nbsp;"
            default: out.append(character)
            }
        }
        return out
    }
}
