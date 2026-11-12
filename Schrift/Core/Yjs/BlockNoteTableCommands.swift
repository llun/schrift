import Foundation

/// A table structure command (PR11b), as BlockNote 0.56's table menus run it:
/// prosemirror-tables 1.8.5's `addRowBefore/After`, `addColumnBefore/After`,
/// `deleteRow`, `deleteColumn`, `mergeCells` and `splitCell` on the selection
/// the table handles make, `columnResizing`'s width write, and the
/// `editor.updateBlock` round trip of the header, colour and alignment menus.
/// Coordinates are slots of the table's grid (`TableGrid.slots`).
enum BlockNoteTableCommand: Equatable, Sendable {
    /// A new row above (`after` false) or below the rows of the cell at
    /// (`row`, 0), the row handle's cell.
    case addRow(row: Int, after: Bool)
    /// A new column left or right of the columns of the cell at (0, `column`).
    case addColumn(column: Int, after: Bool)
    /// Every row the cell at (`row`, 0) spans.
    case deleteRow(row: Int)
    /// Every column the cell at (0, `column`) spans.
    case deleteColumn(column: Int)
    /// The cells covering slots `from`...`to` (rows and columns inclusive)
    /// into one, refused when a cell crosses the rectangle's edge.
    case merge(from: TableSlot, to: TableSlot)
    /// The cell covering `slot` back into single cells.
    case split(TableSlot)
    case toggleHeaderRow
    case toggleHeaderColumn
    /// A cell prop (`backgroundColor`, `textColor`, `textAlignment`) on the
    /// cells starting at `slots`, as the cell, row and column menus set it.
    case setCellProp(key: String, value: String, slots: [TableSlot])
    /// The width (points, BlockNote's px) of slot column `column`.
    case setColumnWidth(column: Int, width: Int)
}

struct TableSlot: Equatable, Hashable, Sendable {
    var row: Int
    var column: Int
}

extension BlockNoteWriter {
    /// The cell props the table menus write (BlockNote's `tableCell` props).
    static let tableCellProps: Set<String> = ["backgroundColor", "textColor", "textAlignment"]

    /// Applies `command` to the familiar table `table` (the content element
    /// of block `block`) in one transaction. Throws `.unsupportedBlockType`
    /// for a command the web would refuse (deleting the whole table's rows,
    /// merging across a span, splitting a single cell) before writing.
    func applyTable(_ command: BlockNoteTableCommand, table: YType, block: String) throws -> Data {
        var model = try prepareTable(command, table: table, block: block)
        return try transaction { tx in try model.write(tx, into: table, writer: self, block: block) }
    }

    /// `applyTable`'s validation and new table, nothing written: the engine
    /// refuses before arming and the menus ask it what is available.
    func prepareTable(_ command: BlockNoteTableCommand, table: YType, block: String) throws -> TableModel {
        let grid = TableGrid.read(table)
        guard grid.isFamiliar else { throw Error.malformedBlock(block) }
        var model = try TableModel(table: table, block: block)
        try model.apply(command, grid: grid)
        return model
    }

    /// Shift-Return in a cell paragraph (BlockNote's `setHardBreak`): one
    /// `hardBreak` at `offset`, splitting the text there into two `XmlText`s,
    /// as y-prosemirror writes `a<hardBreak/>b`.
    func insertHardBreak(in target: Target, at offset: Int) throws -> Data {
        var start = 0
        var left: YItem?
        var split: (text: YType, item: YItem, at: Int, width: Int)?
        for item in children(target.element) {
            guard case .type(let type) = item.content else { throw Error.malformedBlock(target.id) }
            let width = type.typeRef == .xmlText ? Int(type.length) : 1
            if offset <= start { break }
            if type.typeRef == .xmlText, offset < start + width {
                split = (type, item, offset - start, width)
                break
            }
            start += width
            left = item
        }
        let total = try children(target.element).reduce(0) { sum, item in
            guard case .type(let type) = item.content else { throw Error.malformedBlock(target.id) }
            return sum + (type.typeRef == .xmlText ? Int(type.length) : 1)
        }
        guard offset >= 0, offset <= total else { throw Error.malformedBlock(target.id) }
        let tail = try split.map { try snapshot($0.text, range: $0.at..<$0.width, block: target.id, depth: 0) }
        return try transaction { tx in
            let breakType = YType(typeRef: .xmlElement(nodeName: "hardBreak"))
            if let split, let tail {
                try split.text.delete(UInt(split.at), UInt(split.width - split.at))
                let broken = try YWrite.insertAfter(tx, into: target.element, after: split.item, [.type(breakType)])
                try insertText(tx, tail, into: target.element, after: broken)
            } else {
                try YWrite.insertAfter(tx, into: target.element, after: left, [.type(breakType)])
            }
        }
    }
}

/// The table as the prosemirror-tables commands see it: rows of cells with
/// their node, complete attributes and paragraphs. A cell or paragraph that
/// keeps its `source` keeps its Yjs item (so a peer's concurrent text there
/// lands); anything else is written new, as y-prosemirror replaces a node.
struct TableModel {
    struct Cell {
        var source: YItem?
        var node: String
        var attrs: [String: YAnyValue]
        var paragraphs: [Paragraph]

        var colspan: Int { Self.int(attrs["colspan"]) ?? 1 }
        var rowspan: Int { Self.int(attrs["rowspan"]) ?? 1 }
        var colwidth: [YAnyValue]? {
            if case .array(let values)? = attrs["colwidth"] { return values }
            return nil
        }

        static func int(_ value: YAnyValue?) -> Int? {
            if case .int(let value)? = value { return value }
            return nil
        }

        /// `createAndFill()`: BlockNote's cell defaults and one empty paragraph.
        static func empty(_ node: String, attrs: [String: YAnyValue]? = nil) -> Cell {
            Cell(
                source: nil, node: node,
                attrs: attrs ?? [
                    "colspan": .int(1), "rowspan": .int(1), "backgroundColor": .string("default"),
                    "textColor": .string("default"), "textAlignment": .string("left"),
                ], paragraphs: [.copy(.element("tableParagraph", [], []))])
        }
    }

    enum Paragraph {
        case keep(YItem)
        case copy(BlockNoteWriter.Copy)
    }

    struct Row {
        var source: YItem?
        var cells: [Cell]
    }

    var rows: [Row]
    /// Each paragraph item's runs as the grid reads them (`TableGrid`).
    private var runs: [ObjectIdentifier: [InlineRun]] = [:]

    init(table: YType, block: String) throws {
        rows = try YBlockProjection.children(of: table, includeFormats: false).map { rowItem in
            guard case .type(let row) = rowItem.content else { throw BlockNoteWriter.Error.malformedBlock(block) }
            let cells = try YBlockProjection.children(of: row, includeFormats: false).map { cellItem -> Cell in
                guard case .type(let cell) = cellItem.content, case .xmlElement(let node)? = cell.typeRef,
                    let props = YBlockProjection.props(of: cell)
                else { throw BlockNoteWriter.Error.malformedBlock(block) }
                return Cell(
                    source: cellItem, node: node,
                    attrs: Dictionary(props.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 }),
                    paragraphs: YBlockProjection.children(of: cell, includeFormats: false).map { .keep($0) })
            }
            return Row(source: rowItem, cells: cells)
        }
        for row in rows {
            for cell in row.cells {
                for case .keep(let item) in cell.paragraphs {
                    guard case .type(let type) = item.content else { continue }
                    runs[ObjectIdentifier(item)] = TableGrid.paragraphRuns(type) ?? []
                }
            }
        }
    }

    // MARK: - The map (prosemirror-tables `TableMap`)

    struct Map {
        var width = 0
        var height = 0
        /// Each slot's cell, as (row index, cell index in the row).
        var slots: [[TableGrid.CellRef]] = []
        /// Each cell's top-left slot column.
        var columns: [[Int]] = []

        func cell(_ row: Int, _ column: Int) -> TableGrid.CellRef { slots[row][column] }
    }

    func map() throws -> Map {
        var map = Map()
        map.height = rows.count
        var slots: [[TableGrid.CellRef?]] = Array(repeating: [], count: rows.count)
        map.columns = rows.map { Array(repeating: 0, count: $0.cells.count) }
        for row in rows.indices {
            var column = 0
            for index in rows[row].cells.indices {
                while slots[row].indices.contains(column), slots[row][column] != nil { column += 1 }
                let cell = rows[row].cells[index]
                map.columns[row][index] = column
                guard row + cell.rowspan <= rows.count else { throw BlockNoteWriter.Error.malformedBlock("table") }
                for spanned in row..<(row + cell.rowspan) {
                    while slots[spanned].count < column + cell.colspan { slots[spanned].append(nil) }
                    for slot in column..<(column + cell.colspan) {
                        guard slots[spanned][slot] == nil else { throw BlockNoteWriter.Error.malformedBlock("table") }
                        slots[spanned][slot] = TableGrid.CellRef(row: row, index: index)
                    }
                }
                column += cell.colspan
            }
        }
        map.width = slots.map(\.count).max() ?? 0
        guard slots.allSatisfy({ $0.count == map.width && !$0.contains(nil) }) else {
            throw BlockNoteWriter.Error.malformedBlock("table")
        }
        map.slots = slots.map { $0.compactMap { $0 } }
        return map
    }

    /// `TableMap.positionAt`: where a cell for slot `column` goes in `row`.
    private func position(_ map: Map, row: Int, column: Int) -> Int {
        map.columns[row].firstIndex { $0 >= column } ?? rows[row].cells.count
    }

    private subscript(_ ref: TableGrid.CellRef) -> Cell {
        get { rows[ref.row].cells[ref.index] }
        set { rows[ref.row].cells[ref.index] = newValue }
    }

    // MARK: - Commands

    mutating func apply(_ command: BlockNoteTableCommand, grid: TableGrid) throws {
        let refuse = BlockNoteWriter.Error.unsupportedBlockType("table")
        var map = try self.map()
        func rect(ofCellAt row: Int, _ column: Int) throws -> (top: Int, bottom: Int, left: Int, right: Int) {
            guard map.slots.indices.contains(row), map.slots[row].indices.contains(column) else { throw refuse }
            let ref = map.cell(row, column)
            let left = map.columns[ref.row][ref.index]
            return (ref.row, ref.row + self[ref].rowspan, left, left + self[ref].colspan)
        }
        switch command {
        case .addRow(let row, let after):
            let rect = try rect(ofCellAt: row, 0)
            try addRow(&map, at: after ? rect.bottom : rect.top)
        case .addColumn(let column, let after):
            let rect = try rect(ofCellAt: 0, column)
            try addColumn(&map, at: after ? rect.right : rect.left)
        case .deleteRow(let row):
            let rect = try rect(ofCellAt: row, 0)
            guard !(rect.top == 0 && rect.bottom == map.height) else { throw refuse }
            for index in stride(from: rect.bottom - 1, through: rect.top, by: -1) {
                try removeRow(&map, index)
                map = try self.map()
            }
        case .deleteColumn(let column):
            let rect = try rect(ofCellAt: 0, column)
            guard !(rect.left == 0 && rect.right == map.width) else { throw refuse }
            for index in stride(from: rect.right - 1, through: rect.left, by: -1) {
                try removeColumn(&map, index)
                map = try self.map()
            }
        case .merge(let from, let to):
            try merge(&map, from: from, to: to)
        case .split(let slot):
            try split(&map, at: slot)
        case .toggleHeaderRow, .toggleHeaderColumn, .setCellProp:
            try roundTrip(map, command: command)
        case .setColumnWidth(let column, let width):
            guard column >= 0, column < map.width, width > 0 else { throw refuse }
            setColumnWidth(map, column: column, width: width)
        }
        // A row left without cells takes one (prosemirror's content fitting:
        // `tableRow` holds `(tableCell | tableHeader)+`), then the web's
        // `fixTables` runs on the changed table.
        for row in rows.indices where rows[row].cells.isEmpty { rows[row].cells = [.empty("tableCell")] }
        for _ in 0..<4 where try fixTable() {}
        _ = try self.map()
    }

    // MARK: - `fixTables`

    /// The grid the web's `fixTables` leaves of a table whose only problem is
    /// its layout (a ragged row, an overlap, a span past the end: what a
    /// concurrent row and column change makes), as the shadow spells it until
    /// a web client writes that fix. Nil for anything else.
    static func fixedGrid(_ table: YType) -> TableGrid? {
        guard var model = try? TableModel(table: table, block: "table") else { return nil }
        for _ in 0..<4 where (try? model.fixTable()) == true {}
        guard let map = try? model.map() else { return nil }
        var grid = TableGrid()
        grid.columnCount = map.width
        grid.rows = model.rows.enumerated().map { row, value in
            value.cells.enumerated().map { index, cell in
                let paragraphs = cell.paragraphs.map { paragraph -> TableGrid.Paragraph in
                    switch paragraph {
                    case .keep(let item):
                        return TableGrid.Paragraph(itemID: item.id, runs: model.runs(of: item), isSimpleText: false)
                    case .copy:
                        return TableGrid.Paragraph(itemID: YID(client: 0, clock: 0), runs: [], isSimpleText: true)
                    }
                }
                return TableGrid.Cell(
                    itemID: cell.source?.id ?? YID(client: 0, clock: 0), isHeader: cell.node == "tableHeader",
                    colspan: cell.colspan, rowspan: cell.rowspan,
                    props: cell.attrs.map { ProjectedProp(key: $0.key, value: $0.value) }.sorted { $0.key < $1.key },
                    paragraphs: paragraphs, row: row, column: map.columns[row][index])
            }
        }
        grid.slots = map.slots
        return grid
    }

    /// prosemirror-tables' `computeMap` problems and `fixTable`, which the web
    /// runs after every transaction that changes a table: an overlong
    /// rowspan shrinks, a collision gives back columns, missing slots get new
    /// cells (at the row's end, or its start when it is the last of a run of
    /// short rows), and a column whose cells disagree on its width takes the
    /// width most of them have. True when something was fixed.
    mutating func fixTable() throws -> Bool {
        // `findWidth`.
        var width = -1
        var hasRowSpan = false
        for row in rows.indices {
            var rowWidth = 0
            if hasRowSpan {
                for previous in 0..<row {
                    for cell in rows[previous].cells where previous + cell.rowspan > row { rowWidth += cell.colspan }
                }
            }
            for cell in rows[row].cells {
                rowWidth += cell.colspan
                if cell.rowspan > 1 { hasRowSpan = true }
            }
            width = width == -1 ? rowWidth : max(width, rowWidth)
        }
        let height = rows.count
        guard width > 0, height > 0 else { throw BlockNoteWriter.Error.unsupportedBlockType("table") }
        enum Problem {
            case collision(row: Int, cell: TableGrid.CellRef, n: Int)
            case missing(row: Int, n: Int)
            case overlong(cell: TableGrid.CellRef, n: Int)
            case colwidth(cell: TableGrid.CellRef, widths: [YAnyValue])
        }
        var problems: [Problem] = []
        var map = [TableGrid.CellRef?](repeating: nil, count: width * height)
        var columnWidths = [(value: Double?, count: Int)](repeating: (nil, 0), count: width)
        var position = 0
        for row in rows.indices {
            for index in rows[row].cells.indices {
                while position < map.count, map[position] != nil { position += 1 }
                let ref = TableGrid.CellRef(row: row, index: index)
                let cell = self[ref]
                for h in 0..<cell.rowspan {
                    if h + row >= height {
                        problems.append(.overlong(cell: ref, n: cell.rowspan - h))
                        break
                    }
                    let start = position + h * width
                    for w in 0..<cell.colspan {
                        if map.indices.contains(start + w), map[start + w] == nil {
                            map[start + w] = ref
                        } else {
                            problems.append(.collision(row: row, cell: ref, n: cell.colspan - w))
                        }
                        if let widths = cell.colwidth, widths.indices.contains(w),
                            let value = TableGrid.number(widths[w]),
                            value != 0
                        {
                            let column = (start + w) % width
                            let previous = columnWidths[column]
                            if previous.value == nil || (previous.value != value && previous.count == 1) {
                                columnWidths[column] = (value, 1)
                            } else if previous.value == value {
                                columnWidths[column].count += 1
                            }
                        }
                    }
                }
                position += cell.colspan
            }
            let expected = (row + 1) * width
            var missing = 0
            while position < expected {
                if map[position] == nil { missing += 1 }
                position += 1
            }
            if missing > 0 { problems.append(.missing(row: row, n: missing)) }
        }
        if columnWidths.contains(where: { $0.value != nil && $0.count < height }) {
            // `findBadColWidths`: each mismatch is put first, in reverse order.
            var seen: Set<TableGrid.CellRef> = []
            for (slot, ref) in map.enumerated() {
                guard let ref, seen.insert(ref).inserted else { continue }
                let cell = self[ref]
                var updated: [YAnyValue]?
                for j in 0..<cell.colspan {
                    guard let width = columnWidths[(slot + j) % width].value else { continue }
                    let current = cell.colwidth.flatMap { $0.indices.contains(j) ? TableGrid.number($0[j]) : nil }
                    if current != width {
                        if updated == nil { updated = cell.colwidth ?? Array(repeating: .int(0), count: cell.colspan) }
                        if updated!.indices.contains(j) { updated![j] = Self.value(width) }
                    }
                }
                if let updated { problems.insert(.colwidth(cell: ref, widths: updated), at: 0) }
            }
        }
        guard !problems.isEmpty else { return false }
        var mustAdd = Array(repeating: 0, count: height)
        for problem in problems {
            switch problem {
            case .collision(let row, let ref, let n):
                for j in 0..<self[ref].rowspan where row + j < height { mustAdd[row + j] += n }
                self[ref].attrs = Self.removeColSpan(self[ref].attrs, at: self[ref].colspan - n, count: n)
            case .missing(let row, let n): mustAdd[row] += n
            case .overlong(let ref, let n): self[ref].attrs["rowspan"] = .int(self[ref].rowspan - n)
            case .colwidth(let ref, let widths): self[ref].attrs["colwidth"] = .array(widths)
            }
        }
        let first = mustAdd.firstIndex { $0 > 0 }
        let last = mustAdd.lastIndex { $0 > 0 }
        for row in rows.indices where mustAdd[row] > 0 {
            let node = rows[row].cells.first?.node == "tableHeader" ? "tableHeader" : "tableCell"
            let cells = (0..<mustAdd[row]).map { _ in Cell.empty(node) }
            if (row == 0 || first == row - 1) && last == row {
                rows[row].cells.insert(contentsOf: cells, at: 0)
            } else {
                rows[row].cells += cells
            }
        }
        return true
    }

    /// A width as yjs keeps a JS number: an int when it is whole.
    private static func value(_ width: Double) -> YAnyValue {
        if let int = Int(exactly: width) { return .int(int) }
        var bits = width.bitPattern.bigEndian
        return .float64(Data(bytes: &bits, count: 8))
    }

    private func isHeader(_ ref: TableGrid.CellRef) -> Bool { self[ref].node == "tableHeader" }

    /// `addRow`: a cell spanning across the new row grows; every other slot
    /// gets a new cell of the reference row's type (the row before, else the
    /// one after; a header reference row at either edge gives a body cell).
    private mutating func addRow(_ map: inout Map, at row: Int) throws {
        var reference: Int? = row > 0 ? -1 : 0
        let referenceRow = row + (reference ?? 0)
        if map.height > 0, map.slots.indices.contains(referenceRow),
            map.slots[referenceRow].allSatisfy({ isHeader($0) })
        {
            reference = row == 0 || row == map.height ? nil : 0
        }
        var cells: [Cell] = []
        var column = 0
        while column < map.width {
            if row > 0, row < map.height, map.cell(row, column) == map.cell(row - 1, column) {
                let ref = map.cell(row, column)
                self[ref].attrs["rowspan"] = .int(self[ref].rowspan + 1)
                column += self[ref].colspan
                continue
            }
            let node = reference.map { self[map.cell(row + $0, column)].node } ?? "tableCell"
            cells.append(.empty(node))
            column += 1
        }
        rows.insert(Row(source: nil, cells: cells), at: row)
        map = try self.map()
    }

    /// `addColumn`, at slot column `column`.
    private mutating func addColumn(_ map: inout Map, at column: Int) throws {
        var reference: Int? = column > 0 ? -1 : 0
        let referenceColumn = column + (reference ?? 0)
        if map.width > 0, (0..<map.height).allSatisfy({ isHeader(map.cell($0, referenceColumn)) }) {
            reference = column == 0 || column == map.width ? nil : 0
        }
        var inserts: [(row: Int, index: Int, cell: Cell)] = []
        var row = 0
        while row < map.height {
            if column > 0, column < map.width, map.cell(row, column - 1) == map.cell(row, column) {
                let ref = map.cell(row, column)
                let start = map.columns[ref.row][ref.index]
                self[ref].attrs = Self.addColSpan(self[ref].attrs, at: column - start, count: 1)
                row += self[ref].rowspan
                continue
            }
            let node = reference.map { self[map.cell(row, column + $0)].node } ?? "tableCell"
            inserts.append((row, position(map, row: row, column: column), .empty(node)))
            row += 1
        }
        for insert in inserts.reversed() { rows[insert.row].cells.insert(insert.cell, at: insert.index) }
        map = try self.map()
    }

    /// `removeRow`: the row goes; a cell spanning into it from above shrinks,
    /// one spanning down from it moves (a copy) to the next row.
    private mutating func removeRow(_ map: inout Map, _ row: Int) throws {
        var moved: [(index: Int, cell: Cell)] = []
        var seen: Set<TableGrid.CellRef> = []
        var column = 0
        while column < map.width {
            let ref = map.cell(row, column)
            defer { column += 1 }
            guard seen.insert(ref).inserted else { continue }
            if row > 0, ref == map.cell(row - 1, column) {
                self[ref].attrs["rowspan"] = .int(self[ref].rowspan - 1)
                column += self[ref].colspan - 1
            } else if row + 1 < map.height, ref == map.cell(row + 1, column) {
                var copy = self[ref]
                copy.source = nil
                copy.attrs["rowspan"] = .int(copy.rowspan - 1)
                moved.append((position(map, row: row + 1, column: column), copy))
                column += copy.colspan - 1
            }
        }
        for move in moved.reversed() { rows[row + 1].cells.insert(move.cell, at: move.index) }
        rows.remove(at: row)
    }

    /// `removeColumn`: a cell spanning across it shrinks, any other goes.
    private mutating func removeColumn(_ map: inout Map, _ column: Int) throws {
        var removals: [TableGrid.CellRef] = []
        var row = 0
        while row < map.height {
            let ref = map.cell(row, column)
            let attrs = self[ref].attrs
            if (column > 0 && map.cell(row, column - 1) == ref)
                || (column < map.width - 1 && map.cell(row, column + 1) == ref)
            {
                self[ref].attrs = Self.removeColSpan(attrs, at: column - map.columns[ref.row][ref.index])
            } else {
                removals.append(ref)
            }
            row += Cell.int(attrs["rowspan"]) ?? 1
        }
        for ref in removals.sorted(by: { ($0.row, $0.index) > ($1.row, $1.index) }) {
            rows[ref.row].cells.remove(at: ref.index)
        }
    }

    /// `mergeCells` on the rectangle the two slots span: the first cell takes
    /// the others' non-empty content and the rectangle's spans.
    private mutating func merge(_ map: inout Map, from: TableSlot, to: TableSlot) throws {
        let refuse = BlockNoteWriter.Error.unsupportedBlockType("table")
        guard
            [from, to].allSatisfy({
                map.slots.indices.contains($0.row) && map.slots[$0.row].indices.contains($0.column)
            })
        else { throw refuse }
        // `rectBetween`: the two cells' rectangles together.
        func rect(_ slot: TableSlot) -> (top: Int, bottom: Int, left: Int, right: Int) {
            let ref = map.cell(slot.row, slot.column)
            let left = map.columns[ref.row][ref.index]
            return (ref.row, ref.row + self[ref].rowspan, left, left + self[ref].colspan)
        }
        let a = rect(from)
        let b = rect(to)
        let top = min(a.top, b.top)
        let bottom = max(a.bottom, b.bottom)
        let left = min(a.left, b.left)
        let right = max(a.right, b.right)
        guard map.cell(from.row, from.column) != map.cell(to.row, to.column) else { throw refuse }
        // `cellsOverlapRectangle`: a cell crossing its edge refuses the merge.
        for row in top..<bottom {
            if left > 0, map.cell(row, left) == map.cell(row, left - 1) { throw refuse }
            if right < map.width, map.cell(row, right - 1) == map.cell(row, right) { throw refuse }
        }
        for column in left..<right {
            if top > 0, map.cell(top, column) == map.cell(top - 1, column) { throw refuse }
            if bottom < map.height, map.cell(bottom - 1, column) == map.cell(bottom, column) { throw refuse }
        }
        var merged: TableGrid.CellRef?
        var content: [Paragraph] = []
        var removals: [TableGrid.CellRef] = []
        var seen: Set<TableGrid.CellRef> = []
        for row in top..<bottom {
            for column in left..<right {
                let ref = map.cell(row, column)
                guard seen.insert(ref).inserted else { continue }
                if merged == nil {
                    merged = ref
                } else {
                    if !isEmpty(self[ref]) { content += self[ref].paragraphs }
                    removals.append(ref)
                }
            }
        }
        guard let merged else { return }
        var cell = self[merged]
        cell.attrs = Self.addColSpan(cell.attrs, at: cell.colspan, count: right - left - cell.colspan)
        cell.attrs["rowspan"] = .int(bottom - top)
        if !content.isEmpty { cell.paragraphs = (isEmpty(cell) ? [] : cell.paragraphs) + content }
        self[merged] = cell
        for ref in removals.sorted(by: { ($0.row, $0.index) > ($1.row, $1.index) }) {
            rows[ref.row].cells.remove(at: ref.index)
        }
        map = try self.map()
    }

    /// `splitCell`: the cell becomes 1 × 1 and every other slot it covered a
    /// new cell of its type with its attributes (and its column's width).
    private mutating func split(_ map: inout Map, at slot: TableSlot) throws {
        guard map.slots.indices.contains(slot.row), map.slots[slot.row].indices.contains(slot.column) else {
            throw BlockNoteWriter.Error.unsupportedBlockType("table")
        }
        let ref = map.cell(slot.row, slot.column)
        let cell = self[ref]
        guard cell.colspan > 1 || cell.rowspan > 1 else { throw BlockNoteWriter.Error.unsupportedBlockType("table") }
        let top = ref.row
        let left = map.columns[ref.row][ref.index]
        var base = cell.attrs
        base["rowspan"] = .int(1)
        base["colspan"] = .int(1)
        let attrs: [[String: YAnyValue]] = (0..<cell.colspan).map { index in
            guard let widths = cell.colwidth else { return base }
            var attrs = base
            if widths.indices.contains(index), let width = TableGrid.number(widths[index]), width != 0 {
                attrs["colwidth"] = .array([widths[index]])
            } else {
                attrs["colwidth"] = nil
            }
            return attrs
        }
        var inserts: [(row: Int, index: Int, cells: [Cell])] = []
        for row in top..<(top + cell.rowspan) {
            var index = position(map, row: row, column: left)
            if row == top { index = ref.index + 1 }
            let cells = (0..<cell.colspan).compactMap { offset -> Cell? in
                row == top && offset == 0 ? nil : .empty(cell.node, attrs: attrs[offset])
            }
            inserts.append((row, index, cells))
        }
        for insert in inserts.reversed() { rows[insert.row].cells.insert(contentsOf: insert.cells, at: insert.index) }
        self[ref].attrs = attrs[0]
        map = try self.map()
    }

    /// `updateColumnWidth` (`columnResizing`): every cell covering the
    /// column gets `width` at the column's place in its `colwidth`.
    private mutating func setColumnWidth(_ map: Map, column: Int, width: Int) {
        for row in 0..<map.height {
            if row > 0, map.cell(row, column) == map.cell(row - 1, column) { continue }
            let ref = map.cell(row, column)
            let cell = self[ref]
            let index = cell.colspan == 1 ? 0 : column - map.columns[ref.row][ref.index]
            if let widths = cell.colwidth, widths.indices.contains(index), widths[index] == .int(width) { continue }
            var widths = cell.colwidth ?? Array(repeating: .int(0), count: cell.colspan)
            guard widths.indices.contains(index) else { continue }
            widths[index] = .int(width)
            self[ref].attrs["colwidth"] = .array(widths)
        }
    }

    /// prosemirror-tables' `isEmpty`: one paragraph with nothing in it.
    private func isEmpty(_ cell: Cell) -> Bool {
        guard cell.paragraphs.count == 1 else { return false }
        switch cell.paragraphs[0] {
        case .keep(let item):
            guard case .type(let paragraph) = item.content else { return false }
            return YBlockProjection.children(of: paragraph, includeFormats: false).allSatisfy {
                if case .type(let type) = $0.content, type.typeRef == .xmlText { type.length == 0 } else { false }
            }
        case .copy(.element(_, _, let children)): return children.isEmpty
        case .copy: return false
        }
    }

    static func addColSpan(_ attrs: [String: YAnyValue], at position: Int, count: Int) -> [String: YAnyValue] {
        var result = attrs
        result["colspan"] = .int((Cell.int(attrs["colspan"]) ?? 1) + count)
        if case .array(var widths)? = attrs["colwidth"] {
            for _ in 0..<max(0, count) { widths.insert(.int(0), at: min(max(0, position), widths.count)) }
            result["colwidth"] = .array(widths)
        }
        return result
    }

    static func removeColSpan(_ attrs: [String: YAnyValue], at position: Int, count: Int = 1) -> [String: YAnyValue] {
        var result = attrs
        result["colspan"] = .int((Cell.int(attrs["colspan"]) ?? 1) - count)
        if case .array(var widths)? = attrs["colwidth"] {
            let lower = min(max(0, position), widths.count)
            widths.removeSubrange(lower..<min(widths.count, lower + count))
            let any = widths.contains { (TableGrid.number($0) ?? 0) > 0 }
            result["colwidth"] = any ? .array(widths) : nil
        }
        return result
    }

    // MARK: - The `updateBlock` round trip

    /// The header, colour and alignment menus rewrite the table from
    /// BlockNote's JSON (`nodeToBlock` then `tableContentToNodes`): header
    /// rows and columns are counted from the cells (every fully-header row,
    /// every cell index header in all rows), each cell's attributes become
    /// exactly its props and its column's width, and its content one
    /// paragraph of BlockNote's reading of it (`NativeExportMarkdown
    /// .blockNoteRuns`: a merged cell's paragraphs join, a hard break stays).
    private mutating func roundTrip(_ map: Map, command: BlockNoteTableCommand) throws {
        var headerRows = rows.filter { !$0.cells.isEmpty && $0.cells.allSatisfy { $0.node == "tableHeader" } }.count
        var headerCols = 0
        for index in (rows.first?.cells ?? []).indices
        where rows.allSatisfy({ $0.cells.indices.contains(index) && $0.cells[index].node == "tableHeader" }) {
            headerCols += 1
        }
        // Column widths from the first row: each cell's `colwidth`, or one
        // unset entry per spanned column.
        var columnWidths: [YAnyValue] = []
        for cell in rows.first?.cells ?? [] {
            columnWidths += cell.colwidth ?? Array(repeating: .undefined, count: cell.colspan)
        }
        switch command {
        case .toggleHeaderRow: headerRows = headerRows > 0 ? 0 : 1
        case .toggleHeaderColumn: headerCols = headerCols > 0 ? 0 : 1
        default: break
        }
        func truthy(_ value: YAnyValue?) -> Bool {
            guard let value, let number = TableGrid.number(value) else { return false }
            return number != 0
        }
        for row in rows.indices {
            for index in rows[row].cells.indices {
                let cell = rows[row].cells[index]
                let column = map.columns[row][index]
                let node = row < headerRows || index < headerCols ? "tableHeader" : "tableCell"
                var attrs: [String: YAnyValue] = [
                    "colspan": .int(cell.colspan), "rowspan": .int(cell.rowspan),
                    "backgroundColor": cell.attrs["backgroundColor"] ?? .string("default"),
                    "textColor": cell.attrs["textColor"] ?? .string("default"),
                    "textAlignment": cell.attrs["textAlignment"] ?? .string("left"),
                ]
                if case .setCellProp(let key, let value, let slots) = command,
                    slots.contains(TableSlot(row: row, column: column))
                {
                    attrs[key] = .string(value)
                }
                if cell.colspan > 1 {
                    attrs["colwidth"] = .array(
                        (0..<cell.colspan).map { offset in
                            columnWidths.indices.contains(column + offset) ? columnWidths[column + offset] : .undefined
                        })
                } else if columnWidths.indices.contains(column), truthy(columnWidths[column]) {
                    attrs["colwidth"] = .array([columnWidths[column]])
                }
                let content = blockNoteContent(cell)
                var next = cell
                next.attrs = attrs
                if node != cell.node { next.source = nil }
                next.node = node
                let paragraph = Self.paragraph(content)
                if let existing = singleParagraph(cell),
                    Self.signature(Self.paragraph(runs(of: existing))) == Self.signature(paragraph)
                {
                    next.paragraphs = [.keep(existing)]
                } else {
                    next.paragraphs = [.copy(paragraph)]
                }
                rows[row].cells[index] = next
            }
        }
    }

    private func singleParagraph(_ cell: Cell) -> YItem? {
        guard cell.paragraphs.count == 1, case .keep(let item) = cell.paragraphs[0] else { return nil }
        return item
    }

    func runs(of item: YItem) -> [InlineRun] { runs[ObjectIdentifier(item)] ?? [] }

    /// A cell's content as BlockNote reads it: its paragraphs' runs merged.
    private func blockNoteContent(_ cell: Cell) -> [InlineRun] {
        let paragraphs = cell.paragraphs.compactMap { paragraph -> TableGrid.Paragraph? in
            guard case .keep(let item) = paragraph else { return nil }
            return TableGrid.Paragraph(itemID: item.id, runs: runs(of: item), isSimpleText: false)
        }
        let grid = TableGrid.Cell(
            itemID: cell.source?.id ?? YID(client: 0, clock: 0), isHeader: false, colspan: cell.colspan,
            rowspan: cell.rowspan, props: [], paragraphs: paragraphs, row: 0, column: 0)
        return NativeExportMarkdown.blockNoteRuns(grid)
    }

    /// `inlineContentToNodes` into one `tableParagraph`: text runs, a
    /// `hardBreak` for each "\n".
    static func paragraph(_ runs: [InlineRun]) -> BlockNoteWriter.Copy {
        var children: [BlockNoteWriter.Copy] = []
        for run in runs {
            for (index, piece) in run.text.components(separatedBy: "\n").enumerated() {
                if index > 0 { children.append(.element("hardBreak", [], [])) }
                guard !piece.isEmpty else { continue }
                let value = BlockNoteWriter.TextValue.run(InlineRun(piece, marks: run.marks))
                if case .text(let values)? = children.last {
                    children[children.count - 1] = .text(values + [value])
                } else {
                    children.append(.text([value]))
                }
            }
        }
        return .element("tableParagraph", [], children)
    }

    /// A paragraph copy's shape: equal for paragraphs y-prosemirror would
    /// leave as they are.
    static func signature(_ copy: BlockNoteWriter.Copy) -> String {
        switch copy {
        case .text(let values):
            return values.map { value in
                guard case .run(let run) = value else { return "embed" }
                return run.text + "|" + run.marks.map { $0.key + "=" + $0.valueJSON }.sorted().joined(separator: ",")
            }.joined(separator: "·")
        case .element(let node, _, let children):
            return "<\(node)>" + children.map(signature).joined(separator: "/")
        }
    }

    // MARK: - Writing

    /// Writes the model into `table`: rows, cells and paragraphs that keep
    /// their source are edited in place (attributes set or removed, children
    /// deleted or inserted); everything else is new. Content taken from a
    /// cell that is deleted or replaced is copied before anything is deleted.
    mutating func write(_ tx: YTransaction, into table: YType, writer: BlockNoteWriter, block: String) throws {
        // Copies first: a deleted cell's paragraphs are unreadable after.
        for row in rows.indices {
            for index in rows[row].cells.indices {
                let cell = rows[row].cells[index]
                rows[row].cells[index].paragraphs = try cell.paragraphs.map { paragraph in
                    guard case .keep(let item) = paragraph else { return paragraph }
                    if let source = cell.source, case .type(let parent) = source.content, item.parentType === parent {
                        return paragraph
                    }
                    guard case .type(let type) = item.content else { throw BlockNoteWriter.Error.malformedBlock(block) }
                    return .copy(try writer.snapshot(type, block: block, depth: 0))
                }
            }
        }
        let keptRows = Set(rows.compactMap(\.source).map(ObjectIdentifier.init))
        for item in YBlockProjection.children(of: table, includeFormats: false)
        where !keptRows.contains(ObjectIdentifier(item)) {
            item.delete(tx)
        }
        var left: YItem?
        for row in rows {
            let item: YItem
            if let source = row.source {
                item = source
            } else {
                item = try writer.insertCopy(tx, .element("tableRow", [], []), into: table, after: left)
            }
            guard case .type(let type) = item.content else { throw BlockNoteWriter.Error.malformedBlock(block) }
            try write(tx, cells: row.cells, into: type, writer: writer, block: block)
            left = item
        }
    }

    private func write(
        _ tx: YTransaction, cells: [Cell], into row: YType, writer: BlockNoteWriter, block: String
    ) throws {
        let kept = Set(cells.compactMap(\.source).map(ObjectIdentifier.init))
        for item in YBlockProjection.children(of: row, includeFormats: false)
        where !kept.contains(ObjectIdentifier(item)) {
            item.delete(tx)
        }
        var left: YItem?
        for cell in cells {
            if let source = cell.source, case .type(let element) = source.content {
                try Self.update(tx, element, attrs: cell.attrs)
                let keptParagraphs = Set(
                    cell.paragraphs.compactMap { if case .keep(let item) = $0 { ObjectIdentifier(item) } else { nil } })
                for item in YBlockProjection.children(of: element, includeFormats: false)
                where !keptParagraphs.contains(ObjectIdentifier(item)) {
                    item.delete(tx)
                }
                var previous: YItem?
                for paragraph in cell.paragraphs {
                    switch paragraph {
                    case .keep(let item): previous = item
                    case .copy(let copy): previous = try writer.insertCopy(tx, copy, into: element, after: previous)
                    }
                }
                left = source
            } else {
                let paragraphs = cell.paragraphs.compactMap { if case .copy(let copy) = $0 { copy } else { nil } }
                left = try writer.insertCopy(
                    tx, .element(cell.node, Self.ordered(cell.attrs), paragraphs), into: row, after: left)
            }
        }
    }

    /// Attributes in prosemirror's schema order (spans and width, then
    /// BlockNote's props, then anything else).
    static func ordered(_ attrs: [String: YAnyValue]) -> [(key: String, value: YAnyValue)] {
        let order = ["colspan", "rowspan", "colwidth", "backgroundColor", "textColor", "textAlignment"]
        return attrs.sorted {
            (order.firstIndex(of: $0.key) ?? 99, $0.key) < (order.firstIndex(of: $1.key) ?? 99, $1.key)
        }
        .map { ($0.key, $0.value) }
    }

    private static func update(_ tx: YTransaction, _ element: YType, attrs: [String: YAnyValue]) throws {
        let current = Dictionary(
            (YBlockProjection.props(of: element) ?? []).map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
        for (key, value) in ordered(attrs) where current[key] != value {
            try YWrite.mapSet(tx, on: element, key: key, .any([value]))
        }
        for key in current.keys where attrs[key] == nil {
            element.map[key]?.delete(tx)
        }
    }
}
