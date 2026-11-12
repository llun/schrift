import XCTest

@testable import Schrift

/// PR11b against the web: every table structure operation BlockNote 0.56's
/// menus run (`BlockNoteTableOperationCaptures`: prosemirror-tables'
/// row/column/merge/split commands, the column-resize write and the
/// `updateBlock` round trip of the header, colour and alignment menus), on
/// four web-authored tables, produces the web's XML through the native
/// engine, its save shadow stays the exporter's Markdown, and what the web
/// refuses the engine refuses before writing.
final class BlockNoteTableCommandOracleTests: XCTestCase {
    private func doc(_ base64: String) throws -> YDoc {
        let doc = YDoc(clientID: 2, gc: false)
        try doc.applyUpdate(YUpdateDecoder.decode(try XCTUnwrap(Data(base64Encoded: base64))))
        return doc
    }

    /// The web's relative (row, cell index) as the grid slot it starts at.
    private func slot(_ grid: TableGrid, _ row: Int, _ index: Int) -> TableSlot {
        let cell = grid.rows[row][index]
        return TableSlot(row: cell.row, column: cell.column)
    }

    private func command(_ name: String, _ grid: TableGrid) -> BlockNoteTableCommand? {
        let last = grid.rows.count - 1
        switch name {
        case "rowAbove1": return .addRow(row: 1, after: false)
        case "rowAbove0": return .addRow(row: 0, after: false)
        case "rowBelowLast": return .addRow(row: last, after: true)
        case "colLeft0": return .addColumn(column: 0, after: false)
        case "colRight1": return .addColumn(column: slot(grid, 0, 1).column, after: true)
        case "deleteRow1": return .deleteRow(row: 1)
        case "deleteRow2": return .deleteRow(row: last)
        case "deleteCol0": return .deleteColumn(column: 0)
        case "deleteCol1": return .deleteColumn(column: slot(grid, 0, 1).column)
        case "merge10to11": return .merge(from: slot(grid, 1, 0), to: slot(grid, 1, 1))
        case "merge01to21":
            guard grid.rows.count > 2 else { return .merge(from: slot(grid, 0, 1), to: TableSlot(row: 2, column: 1)) }
            return .merge(from: slot(grid, 0, 1), to: slot(grid, 2, 1))
        case "split10": return .split(slot(grid, 1, 0))
        case "split11": return .split(slot(grid, 1, 1))
        case "headerRowToggle": return .toggleHeaderRow
        case "headerColToggle": return .toggleHeaderColumn
        case "cellBackground11": return .setCellProp(key: "backgroundColor", value: "red", slots: [slot(grid, 1, 1)])
        case "cellText00": return .setCellProp(key: "textColor", value: "blue", slots: [slot(grid, 0, 0)])
        case "rowBackground1":
            return .setCellProp(
                key: "backgroundColor", value: "yellow", slots: grid.rows[1].indices.map { slot(grid, 1, $0) })
        case "alignCenter":
            let cells = [(0, 0), (0, 1), (1, 0)].filter { grid.rows[$0.0].indices.contains($0.1) }
            return .setCellProp(key: "textAlignment", value: "center", slots: cells.map { slot(grid, $0.0, $0.1) })
        case "width1": return .setColumnWidth(column: 1, width: 200)
        case "width0": return .setColumnWidth(column: 0, width: 90)
        default: return nil
        }
    }

    private func apply(_ engine: DocumentEngine, _ command: BlockNoteTableCommand) throws {
        try engine.applyStructural(
            NativeEditCommand(id: UUID(), baseRevision: engine.revision, blockID: "tbl", kind: .table(command)),
            persist: { _ in })
    }

    func testEveryWebOperationWritesTheWebsXMLAndKeepsTheShadow() throws {
        var checked = 0
        for capture in BlockNoteTableOperationCaptures.operations {
            let context = "\(capture.fixture)/\(capture.operation)"
            let doc = try doc(capture.seed)
            defer { doc.destroy() }
            let engine = DocumentEngine(doc: doc, surface: HeadlessSurface())
            let grid = try XCTUnwrap(engine.tableGrid("tbl"), context)
            let command = try XCTUnwrap(command(capture.operation, grid), context)
            let before = YXMLString.fragment(doc)
            if capture.refused {
                let kind = NativeEditCommand.Kind.table(command)
                XCTAssertFalse(
                    engine.canApplyStructural(
                        NativeEditCommand(id: UUID(), baseRevision: engine.revision, blockID: "tbl", kind: kind)),
                    "\(context): the web refuses it")
                XCTAssertThrowsError(try apply(engine, command), context)
                XCTAssertEqual(YXMLString.fragment(doc), before, "\(context): nothing written")
                continue
            }
            try apply(engine, command)
            XCTAssertEqual(YXMLString.fragment(doc), capture.xml, context)
            XCTAssertEqual(engine.tableGrid("tbl")?.familiarity, .familiar, context)
            XCTAssertEqual(NativeBlockProjection.markdownShadow(doc), capture.markdown, "\(context): the shadow")
            XCTAssertFalse(engine.nativeWriteFailed, context)
            checked += 1
        }
        XCTAssertEqual(checked, 76)
    }

    /// prosemirror-tables' `cellsOverlapRectangle`: a merge whose rectangle
    /// would cut a spanning cell on any edge is refused before writing.
    func testAMergeThatWouldCutASpanningCellIsRefused() throws {
        let doc = try doc(try XCTUnwrap(BlockNoteTableOperationCaptures.seeds["merged"]))
        defer { doc.destroy() }
        let engine = DocumentEngine(doc: doc, surface: HeadlessSurface())
        let before = YXMLString.fragment(doc)
        // h (row 2, column 1) with f/i (rows 1-2, column 2): the rectangle
        // (rows 1-2, columns 1-2) cuts d/e (row 1, columns 0-1) on its left.
        for (from, to) in [(TableSlot(row: 2, column: 1), TableSlot(row: 2, column: 2))] {
            let command = NativeEditCommand(
                id: UUID(), baseRevision: engine.revision, blockID: "tbl", kind: .table(.merge(from: from, to: to)))
            XCTAssertFalse(engine.canApplyStructural(command), "\(from) – \(to)")
        }
        XCTAssertEqual(YXMLString.fragment(doc), before)
    }

    /// The repaired grid the shadow spells for an uneven table
    /// (`TableModel.fixedGrid`) is the one prosemirror's `fixTables` leaves on
    /// the web, for collisions, overlong spans, missing cells and widths
    /// (review: several fixes on one cell are each built from the original).
    func testTheRepairedGridIsTheWebsFixTables() throws {
        func signature(_ grid: TableGrid) -> [[String]] {
            grid.rows.map { row in
                row.map { cell in
                    "\(cell.isHeader ? "th" : "td") \(cell.colspan)x\(cell.rowspan) \(cell.widths) "
                        + cell.runs.map(\.text).joined()
                }
            }
        }
        func table(_ doc: YDoc) throws -> YType {
            let root = try XCTUnwrap(doc.share[BlockNoteYjs.fragmentField])
            guard case .type(let group)? = YBlockProjection.children(of: root, includeFormats: false).first?.content,
                case .type(let container)? = YBlockProjection.children(of: group, includeFormats: false).first?.content,
                case .type(let table)? = YBlockProjection.children(of: container, includeFormats: false).first?.content
            else { throw XCTSkip("no table") }
            return table
        }
        for (name, seed, fixed) in BlockNoteTableFixCaptures.cases {
            let broken = try doc(seed)
            let web = try doc(fixed)
            defer {
                broken.destroy()
                web.destroy()
            }
            // Disagreeing widths are familiar (the shadow ignores widths); the rest are uneven.
            if name != "colwidth" {
                XCTAssertNotEqual(TableGrid.read(try table(broken)).familiarity, .familiar, name)
            }
            let webGrid = TableGrid.read(try table(web))
            XCTAssertEqual(webGrid.familiarity, .familiar, name)
            let native = try XCTUnwrap(TableModel.fixedGrid(try table(broken)), name)
            XCTAssertEqual(signature(native), signature(webGrid), name)
        }
    }

    /// A span below 1 has no repair: no grid (so no shadow), never a trap.
    /// Here a colspan-0 cell covers no slot, so the rest of the map is even
    /// and only the span check stops the export reading past the row.
    func testASpanBelowOneHasNoRepairedGrid() throws {
        let doc = YDoc(clientID: 2, gc: false)
        defer { doc.destroy() }
        let root = doc.get(BlockNoteYjs.fragmentField)
        var tableType: YType?
        try doc.transact { tx in
            let group = YType(typeRef: .xmlElement(nodeName: "blockGroup"))
            try YWrite.insertAfter(tx, into: root, after: nil, [.type(group)])
            let container = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            try YWrite.insertAfter(tx, into: group, after: nil, [.type(container)])
            try YWrite.mapSet(tx, on: container, key: "id", .any([.string("tbl")]))
            let table = YType(typeRef: .xmlElement(nodeName: "table"))
            try YWrite.insertAfter(tx, into: container, after: nil, [.type(table)])
            tableType = table
            var lastRow: YItem?
            for cells in [3, 2] {
                let row = YType(typeRef: .xmlElement(nodeName: "tableRow"))
                lastRow = try YWrite.insertAfter(tx, into: table, after: lastRow, [.type(row)])
                var lastCell: YItem?
                for index in 0..<cells {
                    let cell = YType(typeRef: .xmlElement(nodeName: "tableCell"))
                    lastCell = try YWrite.insertAfter(tx, into: row, after: lastCell, [.type(cell)])
                    try YWrite.insertAfter(
                        tx, into: cell, after: nil, [.type(YType(typeRef: .xmlElement(nodeName: "tableParagraph")))])
                    if index == 2 { try YWrite.mapSet(tx, on: cell, key: "colspan", .any([.int(0)])) }
                }
            }
        }
        let table = try XCTUnwrap(tableType)
        XCTAssertNotEqual(TableGrid.read(table).familiarity, .familiar)
        XCTAssertNil(TableModel.fixedGrid(table))
        XCTAssertNil(NativeBlockProjection.markdownShadow(doc), "no shadow, no crash")
    }

    /// Review: a command that would grow a table past `TableGrid.maxCells`
    /// is refused (the grown table would have no shadow and stop saves).
    func testACommandGrowingATablePastTheBoundIsRefused() throws {
        let doc = YDoc(clientID: 2, gc: false)
        defer { doc.destroy() }
        let root = doc.get(BlockNoteYjs.fragmentField)
        try doc.transact { tx in
            let group = YType(typeRef: .xmlElement(nodeName: "blockGroup"))
            try YWrite.insertAfter(tx, into: root, after: nil, [.type(group)])
            let container = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            try YWrite.insertAfter(tx, into: group, after: nil, [.type(container)])
            try YWrite.mapSet(tx, on: container, key: "id", .any([.string("tbl")]))
            let table = YType(typeRef: .xmlElement(nodeName: "table"))
            try YWrite.insertAfter(tx, into: container, after: nil, [.type(table)])
            var lastRow: YItem?
            for _ in 0..<100 {
                let row = YType(typeRef: .xmlElement(nodeName: "tableRow"))
                lastRow = try YWrite.insertAfter(tx, into: table, after: lastRow, [.type(row)])
                var lastCell: YItem?
                for _ in 0..<10 {
                    let cell = YType(typeRef: .xmlElement(nodeName: "tableCell"))
                    lastCell = try YWrite.insertAfter(tx, into: row, after: lastCell, [.type(cell)])
                    try YWrite.insertAfter(
                        tx, into: cell, after: nil, [.type(YType(typeRef: .xmlElement(nodeName: "tableParagraph")))])
                }
            }
        }
        let engine = DocumentEngine(doc: doc, surface: HeadlessSurface())
        XCTAssertEqual(engine.tableGrid("tbl")?.familiarity, .familiar, "exactly 1,000 cells")
        for command in [BlockNoteTableCommand.addRow(row: 99, after: true), .addColumn(column: 9, after: true)] {
            XCTAssertFalse(
                engine.canApplyStructural(
                    NativeEditCommand(id: UUID(), baseRevision: engine.revision, blockID: "tbl", kind: .table(command))),
                "\(command)")
        }
        XCTAssertTrue(
            engine.canApplyStructural(
                NativeEditCommand(
                    id: UUID(), baseRevision: engine.revision, blockID: "tbl", kind: .table(.deleteRow(row: 0)))))
    }

    /// The shadow of styled merged cells and hard breaks (11a had none):
    /// BlockNote joins equal-styled paragraphs with a break, concatenates the
    /// rest, and closes marks around a break.
    func testMergedStyledCellsAndHardBreaksExportAsTheWebDoes() throws {
        for capture in BlockNoteTableOperationCaptures.exports where capture.operation.hasPrefix("merge") {
            let doc = try doc(capture.seed)
            defer { doc.destroy() }
            let engine = DocumentEngine(doc: doc, surface: HeadlessSurface())
            let grid = try XCTUnwrap(engine.tableGrid("tbl"))
            let to = capture.operation == "mergeThree" ? slot(grid, 1, 2) : slot(grid, 1, 1)
            try apply(engine, .merge(from: slot(grid, 1, 0), to: to))
            XCTAssertEqual(YXMLString.fragment(doc), capture.xml, capture.operation)
            XCTAssertEqual(NativeBlockProjection.markdownShadow(doc), capture.markdown, capture.operation)
        }
    }

    /// Shift-Return (`setHardBreak`) in a cell: one `hardBreak`, the text split
    /// around it, typing after it unmarked, as the web writes it.
    func testAHardBreakInACellIsTheWebsHardBreak() throws {
        func open(_ name: String) throws -> (YDoc, DocumentEngine, [String], BlockNoteTableOperationCaptures.Operation)
        {
            let capture = try XCTUnwrap(BlockNoteTableOperationCaptures.exports.first { $0.operation == name })
            let doc = try doc(capture.seed)
            let engine = DocumentEngine(doc: doc, surface: HeadlessSurface())
            XCTAssertTrue(engine.openTable("tbl"))
            return (doc, engine, try XCTUnwrap(engine.tableParagraphs("tbl")).map(\.id), capture)
        }
        func command(_ engine: DocumentEngine, _ id: String, _ kind: NativeEditCommand.Kind) throws {
            try engine.applyStructural(
                NativeEditCommand(id: UUID(), baseRevision: engine.revision, blockID: id, kind: kind), persist: { _ in }
            )
        }
        let (middle, middleEngine, middleIDs, middleCapture) = try open("breakAtEnd")
        defer { middle.destroy() }
        try command(middleEngine, middleIDs[3], .lineBreak(offset: 1))
        XCTAssertEqual(YXMLString.fragment(middle), middleCapture.xml)
        XCTAssertEqual(NativeBlockProjection.markdownShadow(middle), middleCapture.markdown)

        let (start, engine, ids, capture) = try open("breakBold")
        defer { start.destroy() }
        try command(engine, ids[3], .lineBreak(offset: 0))
        // Typing after the break: a cell paragraph of several parts takes text.
        try engine.replaceText(
            NativeEditCommand(
                id: UUID(), baseRevision: engine.revision, blockID: ids[3], range: 1..<1, replacement: "Z", marks: []),
            persist: { _ in })
        XCTAssertEqual(YXMLString.fragment(start), capture.xml)
        XCTAssertEqual(NativeBlockProjection.markdownShadow(start), capture.markdown)
        XCTAssertEqual(engine.tableParagraphs("tbl")?[3].runs.map(\.text).joined(), "\nZab")
    }
}
