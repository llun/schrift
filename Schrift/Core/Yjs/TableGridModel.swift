import Foundation

/// A BlockNote 0.56 table read from the replica (PR11a): `table → tableRow →
/// tableCell | tableHeader → tableParagraph+`, with each cell's attributes as
/// stored, its paragraphs' runs and the slot grid its spans make. Read-only:
/// the native editor writes cell text through the engine's cell paragraph ids
/// (`paragraphID(table:item:)`), never through this value.
///
/// **Familiar or not.** Only a table every part of which is understood is
/// `familiar`: the four node kinds, readable (single-value) attributes, a
/// rectangular slot grid with no overlap and no span past the table's edge,
/// `colwidth` absent, null or one entry per spanned column, and paragraphs of
/// plain marked text (readable links) or a `hardBreak`. Anything else — an
/// unknown node, a mention or inline math in a cell, the transient shapes
/// prosemirror-tables' `fixTables` would rewrite on the web — is
/// `unfamiliar`: the table stays opaque, so nothing authors it and its bytes
/// stay as written. A table over `maxCells` is unfamiliar too (PR11c lifts it).
struct TableGrid: Equatable, Sendable {
    struct Paragraph: Equatable, Sendable {
        /// The `tableParagraph` element's item: the stable half of its id.
        let itemID: YID
        /// Its text, a `hardBreak` read as "\n" (BlockNote's own reading).
        var runs: [InlineRun]
        /// True when its only child is one `XmlText` (or it is empty): the
        /// shape the engine's text fast path types into.
        var isSimpleText: Bool
    }

    struct Cell: Equatable, Sendable {
        /// The `tableCell`/`tableHeader` element's item.
        let itemID: YID
        var isHeader: Bool
        var colspan: Int
        var rowspan: Int
        /// The cell's every attribute, sorted, as stored (unknown keys kept).
        var props: [ProjectedProp]
        var paragraphs: [Paragraph]
        /// The top-left slot it covers.
        var row: Int
        var column: Int

        func string(_ key: String) -> String? {
            if case .string(let value)? = props.first(where: { $0.key == key })?.value { return value }
            return nil
        }

        /// `colwidth`: one entry per spanned column, nil where unset.
        var widths: [Int?] {
            guard case .array(let values)? = props.first(where: { $0.key == "colwidth" })?.value else {
                return Array(repeating: nil, count: colspan)
            }
            return values.map { if case .int(let width) = $0, width > 0 { width } else { nil } }
        }

        /// What BlockNote reads as the cell's content: its paragraphs joined
        /// by a hard break ("\n").
        var runs: [InlineRun] {
            var joined: [InlineRun] = []
            for (index, paragraph) in paragraphs.enumerated() {
                if index > 0 { joined.append(InlineRun("\n")) }
                joined += paragraph.runs
            }
            return joined
        }
    }

    enum Familiarity: Equatable, Sendable {
        case familiar
        case unfamiliar(String)
    }

    /// Cells in row order, as stored.
    var rows: [[Cell]] = []
    var columnCount = 0
    /// For each slot, the cell covering it (`rows[row][index]`).
    var slots: [[CellRef]] = []
    var familiarity: Familiarity = .familiar
    var isFamiliar: Bool { familiarity == .familiar }

    struct CellRef: Equatable, Hashable, Sendable {
        var row: Int
        var index: Int
    }

    /// BlockNote's `EMPTY_CELL_WIDTH`: a column with no `colwidth`.
    static let defaultColumnWidth = 120
    /// The largest table the native editor reads in full (PR11a).
    static let maxCells = 1_000

    func cell(_ ref: CellRef) -> Cell { rows[ref.row][ref.index] }

    var cellCount: Int { rows.reduce(0) { $0 + $1.count } }

    /// Each column's width in points: the first `colwidth` entry set for it,
    /// else the default.
    var columnWidths: [Int] {
        var widths = [Int?](repeating: nil, count: columnCount)
        for row in rows {
            for cell in row {
                for (offset, width) in cell.widths.enumerated() where cell.column + offset < columnCount {
                    if widths[cell.column + offset] == nil { widths[cell.column + offset] = width }
                }
            }
        }
        return widths.map { $0 ?? Self.defaultColumnWidth }
    }

    // MARK: - Navigation (prosemirror-tables `TableMap`)

    /// Every cell once, in row order (a merged cell at its top-left slot): the
    /// order Tab walks.
    var order: [CellRef] {
        rows.indices.flatMap { row in rows[row].indices.map { CellRef(row: row, index: $0) } }
    }

    /// The next (`forward`) or previous cell in Tab order; nil at either end
    /// (BlockNote's Tab does nothing there and never adds a row).
    func cell(after ref: CellRef, forward: Bool) -> CellRef? {
        let order = self.order
        guard let position = order.firstIndex(of: ref) else { return nil }
        let next = position + (forward ? 1 : -1)
        return order.indices.contains(next) ? order[next] : nil
    }

    /// The cell covering the slot below this cell's bottom-left slot
    /// (BlockNote's Enter: `nextCell(…, "vert", 1)`); nil on the last row.
    func cell(below ref: CellRef) -> CellRef? {
        let cell = self.cell(ref)
        let row = cell.row + cell.rowspan
        guard slots.indices.contains(row), slots[row].indices.contains(cell.column) else { return nil }
        return slots[row][cell.column]
    }

    // MARK: - Cell paragraph ids

    /// The id the engine addresses a cell paragraph by: its table's block id
    /// and its own item. Never a BlockNote id (they cannot hold U+0001), so it
    /// cannot collide with a block.
    static func paragraphID(table: String, item: YID) -> String {
        "\(table)\u{1}\(item.client).\(item.clock)"
    }

    static func isParagraphID(_ id: String) -> Bool { id.contains("\u{1}") }

    /// The table a cell paragraph id belongs to.
    static func tableID(ofParagraph id: String) -> String? {
        guard let separator = id.firstIndex(of: "\u{1}") else { return nil }
        return String(id[..<separator])
    }

    // MARK: - Reading

    /// Every table block of `doc` by block id (the read-only reader's
    /// viewer, which has no replica session to ask).
    static func tables(in doc: YDoc) -> [String: TableGrid] {
        guard let root = doc.share[BlockNoteYjs.fragmentField] else { return [:] }
        var tables: [String: TableGrid] = [:]
        func walk(_ group: YType, depth: Int) {
            guard depth <= NativeBlockProjection.maxDepth else { return }
            for item in YBlockProjection.children(of: group, includeFormats: false) {
                guard case .type(let child) = item.content else { continue }
                if child.typeRef == .xmlElement(nodeName: "blockGroup") {
                    walk(child, depth: depth + 1)
                    continue
                }
                guard child.typeRef == .xmlElement(nodeName: "blockContainer"), let id = BlockIndex.blockID(of: child)
                else { continue }
                for inner in YBlockProjection.children(of: child, includeFormats: false) {
                    guard case .type(let element) = inner.content else { continue }
                    if element.typeRef == .xmlElement(nodeName: "table"), tables[id] == nil {
                        tables[id] = read(element)
                    } else if element.typeRef == .xmlElement(nodeName: "blockGroup") {
                        walk(element, depth: depth + 1)
                    }
                }
            }
        }
        walk(root, depth: 0)
        return tables
    }

    /// The grid of a `table` element. Total: an unexpected shape is an
    /// `unfamiliar` grid (with whatever was read), never a trap.
    static func read(_ table: YType) -> TableGrid {
        var grid = TableGrid()
        func refuse(_ reason: String) -> TableGrid {
            grid.familiarity = .unfamiliar(reason)
            return grid
        }
        guard table.typeRef == .xmlElement(nodeName: "table") else { return refuse("not a table") }
        guard props(of: table) != nil else { return refuse("unreadable table attribute") }
        var count = 0
        for rowItem in YBlockProjection.children(of: table, includeFormats: false) {
            guard case .type(let row) = rowItem.content, row.typeRef == .xmlElement(nodeName: "tableRow"),
                props(of: row) != nil
            else { return refuse("unexpected row") }
            var cells: [Cell] = []
            for cellItem in YBlockProjection.children(of: row, includeFormats: false) {
                count += 1
                guard count <= maxCells else { return refuse("large table") }
                guard case .type(let element) = cellItem.content, case .xmlElement(let node)? = element.typeRef,
                    node == "tableCell" || node == "tableHeader"
                else { return refuse("unexpected cell") }
                guard let cellProps = props(of: element) else { return refuse("unreadable cell attribute") }
                func span(_ key: String) -> Int? {
                    switch cellProps.first(where: { $0.key == key })?.value {
                    case nil: return 1
                    case .int(let value)? where value >= 1 && value <= maxCells: return value
                    default: return nil
                    }
                }
                guard let colspan = span("colspan"), let rowspan = span("rowspan") else {
                    return refuse("unreadable span")
                }
                switch cellProps.first(where: { $0.key == "colwidth" })?.value {
                case nil, .null?, .undefined?: break
                case .array(let values)? where values.count == colspan:
                    guard values.allSatisfy({ if case .int = $0 { true } else { $0 == .null } }) else {
                        return refuse("unreadable colwidth")
                    }
                default: return refuse("unreadable colwidth")
                }
                var paragraphs: [Paragraph] = []
                for paragraphItem in YBlockProjection.children(of: element, includeFormats: false) {
                    guard case .type(let paragraph) = paragraphItem.content,
                        paragraph.typeRef == .xmlElement(nodeName: "tableParagraph"), props(of: paragraph) != nil
                    else { return refuse("unexpected cell content") }
                    if let read = Self.paragraph(paragraph, item: paragraphItem) {
                        paragraphs.append(read)
                    } else {
                        // Content 11a does not read (a mention, inline math):
                        // the table is unfamiliar, but the viewer still shows
                        // the cell's readable text.
                        if grid.familiarity == .familiar { grid.familiarity = .unfamiliar("unexpected cell content") }
                        paragraphs.append(Self.readableText(paragraph, item: paragraphItem))
                    }
                }
                guard !paragraphs.isEmpty else { return refuse("empty cell") }
                cells.append(
                    Cell(
                        itemID: cellItem.id, isHeader: node == "tableHeader", colspan: colspan, rowspan: rowspan,
                        props: cellProps, paragraphs: paragraphs, row: 0, column: 0))
            }
            guard !cells.isEmpty else { return refuse("empty row") }
            grid.rows.append(cells)
        }
        guard !grid.rows.isEmpty else { return refuse("empty table") }
        let familiarity = grid.familiarity
        var laidOut = grid.layingOut()
        if laidOut.isFamiliar { laidOut.familiarity = familiarity }
        return laidOut
    }

    /// The plain text of a paragraph's `XmlText`s, nothing else: the viewer's
    /// reading of content it does not model.
    private static func readableText(_ paragraph: YType, item: YItem) -> Paragraph {
        let text = YBlockProjection.children(of: paragraph, includeFormats: false).compactMap { child -> String? in
            guard case .type(let type) = child.content, type.typeRef == .xmlText else { return nil }
            return YBlockProjection.textRuns(type)?.map(\.text).joined()
        }.joined()
        return Paragraph(itemID: item.id, runs: text.isEmpty ? [] : [InlineRun(text)], isSimpleText: false)
    }

    /// Places every cell at the first free slot of its row (`TableMap`).
    private func layingOut() -> TableGrid {
        var grid = self
        var slots: [[CellRef?]] = Array(repeating: [], count: rows.count)
        for row in rows.indices {
            var column = 0
            for index in rows[row].indices {
                while slots[row].indices.contains(column), slots[row][column] != nil { column += 1 }
                let cell = rows[row][index]
                grid.rows[row][index].row = row
                grid.rows[row][index].column = column
                guard row + cell.rowspan <= rows.count else {
                    grid.familiarity = .unfamiliar("span past the last row")
                    return grid
                }
                for spanned in row..<(row + cell.rowspan) {
                    while slots[spanned].count < column + cell.colspan { slots[spanned].append(nil) }
                    for slot in column..<(column + cell.colspan) {
                        guard slots[spanned][slot] == nil else {
                            grid.familiarity = .unfamiliar("overlapping cells")
                            return grid
                        }
                        slots[spanned][slot] = CellRef(row: row, index: index)
                    }
                }
                column += cell.colspan
            }
        }
        let width = slots.map(\.count).max() ?? 0
        guard slots.allSatisfy({ $0.count == width && !$0.contains(nil) }) else {
            grid.familiarity = .unfamiliar("ragged rows")
            return grid
        }
        grid.columnCount = width
        grid.slots = slots.map { $0.compactMap { $0 } }
        return grid
    }

    /// A `tableParagraph`'s runs as `read` reads them, or nil.
    static func paragraphRuns(_ paragraph: YType) -> [InlineRun]? {
        guard let item = paragraph.item else { return nil }
        return Self.paragraph(paragraph, item: item)?.runs
    }

    /// A paragraph's runs, or nil for content 11a does not read (an inline
    /// node other than `hardBreak`, an embed, an unreadable link).
    private static func paragraph(_ paragraph: YType, item: YItem) -> Paragraph? {
        let children = YBlockProjection.children(of: paragraph, includeFormats: false)
        var runs: [InlineRun] = []
        var isSimpleText = children.isEmpty
        for child in children {
            guard case .type(let type) = child.content else { return nil }
            if type.typeRef == .xmlText {
                guard BlockIndex.projectsAsText(type), let text = YBlockProjection.textRuns(type) else { return nil }
                runs += text
                isSimpleText = children.count == 1
            } else if type.typeRef == .xmlElement(nodeName: "hardBreak") {
                runs.append(InlineRun("\n"))
            } else {
                return nil
            }
        }
        return Paragraph(itemID: item.id, runs: merged(runs), isSimpleText: isSimpleText)
    }

    /// Adjacent runs with equal marks as one (two `XmlText`s around a break).
    private static func merged(_ runs: [InlineRun]) -> [InlineRun] {
        var out: [InlineRun] = []
        for run in runs where !run.text.isEmpty {
            if let last = out.last, InlineRun("", marks: last.marks) == InlineRun("", marks: run.marks) {
                out[out.count - 1].text += run.text
            } else {
                out.append(run)
            }
        }
        return out
    }

    /// An element's attributes, sorted, or nil when one is unreadable.
    private static func props(of element: YType) -> [ProjectedProp]? {
        YBlockProjection.props(of: element)
    }
}
