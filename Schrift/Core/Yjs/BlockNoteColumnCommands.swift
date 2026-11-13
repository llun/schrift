import Foundation

/// A column group's structure command (PR12b), on the group's block id:
/// what the web writes for the same change, checked against BlockNote 0.56's
/// captures (`BlockNoteColumnStructureCaptures`). Column indices are the
/// group's column order when the command was made.
enum BlockNoteColumnCommand: Equatable, Sendable {
    /// A new column of one empty paragraph at `index` (0...count), as the
    /// column drop handler's `updateBlock` writes one: the other columns'
    /// widths normalised to an average of 1 first when it is outside 0.99...1.01.
    case add(index: Int, columnID: String, paragraphID: String)
    /// `removeBlocks([column])`: the column and its blocks go; a group left
    /// with one column dissolves into that column's blocks (`fixLayoutBlock`).
    case remove(index: Int)
    /// `updateBlock` with the columns reordered.
    case move(from: Int, to: Int)
    /// The resize handle between `left` and `left + 1`: both widths set, as
    /// `ColumnResizeExtension` writes them (no other column changes).
    case resize(left: Int, leftWidth: Double, rightWidth: Double)

    /// BlockNote's `COLUMN_MIN_WIDTH_PERCENT`: the resize handle keeps every
    /// column at least this wide.
    static let minimumWidth = 0.5
}

extension BlockNoteWriter {
    // MARK: - Groups (PR12b)

    /// An empty paragraph's container, as BlockNote writes a new block.
    func emptyParagraph(_ id: String) -> Copy {
        .element("blockContainer", [("id", .string(id))], [.element("paragraph", schemas["paragraph"] ?? [], [])])
    }

    /// A new column of one empty paragraph, width 1 (BlockNote's default).
    func emptyColumn(_ columnID: String, paragraph paragraphID: String) -> Copy {
        .element("column", [("id", .string(columnID)), ("width", .int(1))], [emptyParagraph(paragraphID)])
    }

    /// The slash menu's "Two columns" / "Three columns" (`insertColumnList`):
    /// a group of `columns` columns of one empty paragraph each. `ids` are the
    /// group's (unless it replaces `target`, whose id it then takes, as
    /// `insertOrUpdateBlockForSlashMenu`'s `updateBlock` keeps it), then each
    /// column's and its paragraph's, in order. An empty block is replaced;
    /// anything else gets the group after it.
    @discardableResult
    func insertColumnList(after item: YItem, in group: YType, replacing: Bool, ids: [String], columns: Int) throws
        -> Data
    {
        guard (2...ColumnGroup.maxColumns).contains(columns), ids.count == 2 * columns + (replacing ? 0 : 1),
            case .type(let container) = item.content, let oldID = BlockIndex.blockID(of: container)
        else { throw Error.malformedBlock("columnList") }
        var ids = ids[...]
        let listID = replacing ? oldID : ids.removeFirst()
        var children: [Copy] = []
        for _ in 0..<columns {
            children.append(emptyColumn(ids.removeFirst(), paragraph: ids.removeFirst()))
        }
        let list = Copy.element("columnList", [("id", .string(listID))], children)
        return try transaction { tx in
            try insertCopy(tx, list, into: group, after: item)
            if replacing { item.delete(tx) }
        }
    }

    /// One column structure command on group `list` (a familiar group:
    /// prepared by the engine, which validated every index).
    @discardableResult
    func applyColumns(_ command: BlockNoteColumnCommand, list listItem: YItem, block: String) throws -> Data {
        guard case .type(let list) = listItem.content, let group = listItem.parentType else {
            throw Error.missingBlock(block)
        }
        let columns = children(list)
        func width(_ column: YItem) -> Double {
            guard case .type(let type) = column.content, let item = type.map["width"], !item.deleted,
                case .any(let values) = item.content, values.count == 1, let number = TableGrid.number(values[0])
            else { return 1 }
            return number
        }
        func setWidth(_ tx: YTransaction, _ column: YItem, _ value: Double) throws {
            guard case .type(let type) = column.content else { throw Error.malformedBlock(block) }
            try YWrite.mapSet(tx, on: type, key: "width", .any([Self.number(value)]))
        }
        switch command {
        case .add(let index, let columnID, let paragraphID):
            guard (0...columns.count).contains(index) else { throw Error.malformedBlock(block) }
            let widths = columns.map(width)
            let average = widths.reduce(0, +) / Double(widths.count)
            return try transaction { tx in
                if average < 0.99 || average > 1.01 {
                    for (column, value) in zip(columns, widths) { try setWidth(tx, column, value / average) }
                }
                try insertCopy(
                    tx, emptyColumn(columnID, paragraph: paragraphID), into: list,
                    after: index == 0 ? nil : columns[index - 1])
            }
        case .remove(let index):
            guard columns.indices.contains(index) else { throw Error.malformedBlock(block) }
            guard columns.count == 2 else { return try transaction { tx in columns[index].delete(tx) } }
            // `fixLayoutBlock`: one column left is just its blocks.
            guard case .type(let survivor) = columns[1 - index].content else { throw Error.malformedBlock(block) }
            let blocks = try children(survivor).map { item -> Copy in
                guard case .type(let container) = item.content else { throw Error.malformedBlock(block) }
                return try snapshot(container, block: block, depth: 0)
            }
            return try transaction { tx in
                var left: YItem = listItem
                for copy in blocks { left = try insertCopy(tx, copy, into: group, after: left) }
                listItem.delete(tx)
            }
        case .move(let from, let to):
            guard columns.indices.contains(from), columns.indices.contains(to), from != to,
                case .type(let moved) = columns[from].content
            else { throw Error.malformedBlock(block) }
            let copy = try snapshot(moved, block: block, depth: 0)
            var order = columns
            order.remove(at: from)
            let left = to == 0 ? nil : order[to - 1]
            return try transaction { tx in
                try insertCopy(tx, copy, into: list, after: left)
                columns[from].delete(tx)
            }
        case .resize(let left, let leftWidth, let rightWidth):
            guard columns.indices.contains(left), columns.indices.contains(left + 1), leftWidth.isFinite,
                rightWidth.isFinite, leftWidth >= BlockNoteColumnCommand.minimumWidth,
                rightWidth >= BlockNoteColumnCommand.minimumWidth
            else { throw Error.malformedBlock(block) }
            return try transaction { tx in
                try setWidth(tx, columns[left], leftWidth)
                try setWidth(tx, columns[left + 1], rightWidth)
            }
        }
    }

    /// Moves a block and its subtree to after `left` in `destination` (a
    /// group or a column; nil: first), the web's move across a column's edge
    /// (Backspace, Move up/down). A column the move empties keeps one empty
    /// paragraph `padID`, as ProseMirror refills it (`[1:]` in the captures).
    @discardableResult
    func moveAcross(_ item: YItem, id: String, into destination: YType, after left: YItem?, padID: String) throws
        -> Data
    {
        guard !item.deleted, case .type(let container) = item.content, let source = item.parentType else {
            throw Error.missingBlock(id)
        }
        let copy = try snapshot(container, block: id, depth: 0)
        let empties = source.typeRef == .xmlElement(nodeName: "column") && children(source).count == 1
        return try transaction { tx in
            try insertCopy(tx, copy, into: destination, after: left)
            item.delete(tx)
            if empties { try insertCopy(tx, emptyParagraph(padID), into: source, after: nil) }
        }
    }

    /// A number as lib0's `writeAny` keeps it: an int when whole and within
    /// 31 bits, a float32 when that holds it exactly, else a float64.
    static func number(_ value: Double) -> YAnyValue {
        if value == value.rounded(), abs(value) <= Double(Int32.max), let int = Int(exactly: value) {
            return .int(int)
        }
        if Double(Float(value)) == value {
            var bits = Float(value).bitPattern.bigEndian
            return .float32(Data(bytes: &bits, count: 4))
        }
        var bits = value.bitPattern.bigEndian
        return .float64(Data(bytes: &bits, count: 8))
    }
}
