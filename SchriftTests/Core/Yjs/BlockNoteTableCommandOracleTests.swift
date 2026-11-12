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
