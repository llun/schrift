import XCTest

@testable import Schrift

/// PR11a against real BlockNote 0.56 tables (`BlockNoteTableCaptures`): every
/// web-authored fixture (header row and column, colours, widths, alignment,
/// marks, a link, a pipe, merged cells holding several paragraphs, a hard
/// break, wide and non-ASCII text) is a familiar grid, its save shadow is the
/// exporter's own Markdown byte for byte, and the native writer's cell edits
/// produce the web's XML.
final class BlockNoteTableOracleTests: XCTestCase {
    private func doc(_ base64: String, clientID: UInt = 9) throws -> YDoc {
        let doc = YDoc(clientID: clientID, gc: false)
        try doc.applyUpdate(YUpdateDecoder.decode(try XCTUnwrap(Data(base64Encoded: base64))))
        return doc
    }

    private func grid(_ doc: YDoc, _ id: String = "tbl") throws -> TableGrid {
        try XCTUnwrap(TableGrid.tables(in: doc)[id])
    }

    func testEveryFixtureIsAFamiliarGridWhoseShadowIsTheExport() throws {
        for fixture in BlockNoteTableCaptures.fixtures {
            let doc = try doc(fixture.update)
            defer { doc.destroy() }
            XCTAssertEqual(YXMLString.fragment(doc), fixture.xml, fixture.name)
            XCTAssertEqual(try grid(doc).familiarity, .familiar, fixture.name)
            let native = NativeBlockProjection.project(doc)
            XCTAssertTrue(native.isFullyModeled, "\(fixture.name): the native projection models the table")
            XCTAssertEqual(NativeBlockProjection.markdownShadow(doc), fixture.markdown, fixture.name)
            // The classic projection keeps a table opaque.
            XCTAssertFalse(YBlockProjection.project(doc).isFullyModeled, fixture.name)
        }
    }

    func testTheHardBreakCaptureExportsItsBreak() throws {
        let capture = try XCTUnwrap(BlockNoteTableCaptures.edits.first { $0.name == "shiftEnter" })
        let doc = try doc(capture.seed)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(try XCTUnwrap(Data(base64Encoded: capture.update))))
        XCTAssertEqual(YXMLString.fragment(doc), capture.xml)
        let cell = try grid(doc).rows[1][0]
        XCTAssertEqual(cell.runs, [InlineRun("Ada\nB")])
        XCTAssertFalse(cell.paragraphs[0].isSimpleText, "a hard break is shown, not typed into")
        XCTAssertEqual(NativeBlockProjection.markdownShadow(doc), capture.markdown)
    }

    func testTheGridReadsSpansWidthsHeadersAndColours() throws {
        let styled = try doc(try XCTUnwrap(BlockNoteTableCaptures.fixtures.first { $0.name == "styled" }).update)
        defer { styled.destroy() }
        let grid = try grid(styled)
        XCTAssertEqual(grid.columnCount, 3)
        XCTAssertEqual(grid.columnWidths, [200, 120, 80])
        XCTAssertEqual(grid.rows[0].map(\.isHeader), [true, true, true])
        XCTAssertEqual(grid.rows[1][0].string("backgroundColor"), "green")
        XCTAssertEqual(grid.rows[1][1].string("textColor"), "red")
        XCTAssertEqual(grid.rows[1][1].string("textAlignment"), "center")
        XCTAssertEqual(grid.rows[1][0].runs, [InlineRun("Ada", marks: [("bold", "{}")])])

        let merged = try doc(try XCTUnwrap(BlockNoteTableCaptures.fixtures.first { $0.name == "merged" }).update)
        defer { merged.destroy() }
        let spans = try self.grid(merged)
        XCTAssertEqual(spans.columnCount, 3)
        XCTAssertEqual(spans.rows.map(\.count), [3, 2, 2])
        let de = spans.rows[1][0]
        XCTAssertEqual([de.colspan, de.rowspan, de.row, de.column], [2, 1, 1, 0])
        XCTAssertEqual(de.paragraphs.map(\.runs), [[InlineRun("d")], [InlineRun("e")]])
        let fi = spans.rows[1][1]
        XCTAssertEqual([fi.colspan, fi.rowspan, fi.row, fi.column], [1, 2, 1, 2])
        // Slots: row 2 column 2 is still the merged f/i cell.
        XCTAssertEqual(spans.slots[2][2], TableGrid.CellRef(row: 1, index: 1))
        XCTAssertEqual(spans.slots[2].map(\.index), [0, 1, 1])
        // Navigation: Tab in row order, Return to the cell covering the slot below.
        let order = spans.order
        XCTAssertEqual(order.count, 7)
        XCTAssertEqual(spans.cell(after: order[3], forward: true), order[4])
        XCTAssertNil(spans.cell(after: order[6], forward: true), "no new row at the end")
        XCTAssertNil(spans.cell(after: order[0], forward: false))
        XCTAssertEqual(spans.cell(below: TableGrid.CellRef(row: 0, index: 1)), TableGrid.CellRef(row: 1, index: 0))
        XCTAssertEqual(spans.cell(below: TableGrid.CellRef(row: 1, index: 0)), TableGrid.CellRef(row: 2, index: 0))
        XCTAssertNil(spans.cell(below: TableGrid.CellRef(row: 1, index: 1)), "f/i spans to the last row")
    }

    /// The native writer, addressing an open table's paragraphs, against the
    /// web's own cell edits: the same XML.
    func testCellEditsMatchTheWebCaptures() throws {
        func edited(_ name: String, _ body: (DocumentEngine, [String]) throws -> Void) throws {
            let capture = try XCTUnwrap(BlockNoteTableCaptures.edits.first { $0.name == name })
            let doc = try doc(capture.seed, clientID: 2)
            defer { doc.destroy() }
            let engine = DocumentEngine(doc: doc, surface: HeadlessSurface())
            XCTAssertTrue(engine.openTable("tbl"), name)
            let ids = try XCTUnwrap(engine.tableParagraphs("tbl")).map(\.id)
            XCTAssertEqual(ids.count, 4, name)
            try body(engine, ids)
            XCTAssertEqual(YXMLString.fragment(doc), capture.xml, name)
            XCTAssertEqual(NativeBlockProjection.markdownShadow(doc), capture.markdown, name)
        }
        func replace(_ engine: DocumentEngine, _ id: String, _ range: Range<Int>, _ text: String) throws {
            try engine.replaceText(
                NativeEditCommand(
                    id: UUID(), baseRevision: engine.revision, blockID: id, range: range, replacement: text),
                persist: { _ in })
        }
        try edited("typeMiddle") { engine, ids in try replace(engine, ids[2], 1..<1, "X") }
        try edited("typeEmpty") { engine, ids in try replace(engine, ids[3], 0..<0, "Eng") }
        try edited("boldPart") { engine, ids in
            try engine.applyStructural(
                NativeEditCommand(
                    id: UUID(), baseRevision: engine.revision, blockID: ids[2],
                    kind: .marks(
                        NativeMarkCommand(
                            startOffset: 0, endBlockID: ids[2], endOffset: 2,
                            attributes: [TextMark(key: "bold", valueJSON: "{}")]))),
                persist: { _ in })
        }
        // Tab, Enter and Backspace at a cell start move or do nothing on the web: no update.
        for name in ["enterMovesDown", "tabNext", "tabAtLast", "backspaceAtCellStart", "backspaceAtStartOfText"] {
            let capture = try XCTUnwrap(BlockNoteTableCaptures.edits.first { $0.name == name })
            XCTAssertLessThanOrEqual(capture.update.count, 140, "\(name): the web wrote only the typed character")
        }
    }

    /// Every structural command refuses a cell paragraph; a mark change may
    /// not leave it.
    func testCellParagraphsTakeTextAndMarksOnly() throws {
        let capture = try XCTUnwrap(BlockNoteTableCaptures.edits.first { $0.name == "typeMiddle" })
        let doc = try doc(capture.seed, clientID: 2)
        defer { doc.destroy() }
        let engine = DocumentEngine(doc: doc, surface: HeadlessSurface())
        XCTAssertTrue(engine.openTable("tbl"))
        let ids = try XCTUnwrap(engine.tableParagraphs("tbl")).map(\.id)
        func command(_ kind: NativeEditCommand.Kind, _ id: String) -> NativeEditCommand {
            NativeEditCommand(id: UUID(), baseRevision: engine.revision, blockID: id, kind: kind)
        }
        let refused: [NativeEditCommand.Kind] = [
            .split(offset: 1, newID: UUID().uuidString, open: []), .join, .indent, .outdent, .moveUp, .moveDown,
            .deleteBlock, .duplicate(newIDs: [UUID().uuidString]),
            .insertBlock(newID: UUID().uuidString, before: false),
            .range(
                NativeRangeCommand(startOffset: 0, endBlockID: ids[3], endOffset: 0, replacement: "", newBlockIDs: [])),
            .marks(
                NativeMarkCommand(
                    startOffset: 0, endBlockID: ids[3], endOffset: 0,
                    attributes: [TextMark(key: "bold", valueJSON: "{}")])),
        ]
        let before = YXMLString.fragment(doc)
        for kind in refused {
            XCTAssertFalse(engine.canApplyStructural(command(kind, ids[2])), "\(kind)")
            XCTAssertThrowsError(try engine.applyStructural(command(kind, ids[2]), persist: { _ in }), "\(kind)")
        }
        XCTAssertEqual(YXMLString.fragment(doc), before, "nothing was written")
        XCTAssertFalse(engine.nativeWriteFailed)
        // A newline is never typed into a cell paragraph.
        XCTAssertThrowsError(
            try engine.replaceText(
                NativeEditCommand(
                    id: UUID(), baseRevision: engine.revision, blockID: ids[2], range: 0..<0, replacement: "a\nb"),
                persist: { _ in }))
        // Closed, the paragraph ids address nothing.
        engine.closeTable("tbl")
        XCTAssertThrowsError(
            try engine.replaceText(
                NativeEditCommand(
                    id: UUID(), baseRevision: engine.revision, blockID: ids[2], range: 0..<0, replacement: "x"),
                persist: { _ in }))
        XCTAssertEqual(YXMLString.fragment(doc), before)
    }

    /// The real test document (`.review/state.bin`, git-ignored) when present:
    /// its web table is familiar and exports as the server does.
    func testTheRealCaptureTableIsFamiliar() throws {
        let review = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".review")
        guard let state = try? Data(contentsOf: review.appendingPathComponent("state.bin")) else {
            throw XCTSkip("no .review capture")
        }
        let doc = YDoc(clientID: 9, gc: false)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(state))
        let tables = TableGrid.tables(in: doc)
        XCTAssertEqual(tables.count, 1)
        let grid = try XCTUnwrap(tables.values.first)
        XCTAssertEqual(grid.familiarity, .familiar)
        XCTAssertEqual(NativeExportMarkdown.table(grid), Self.realTableExport)
    }

    /// `blocksToMarkdownLossy([table])` of the real document's table.
    static let realTableExport = """
        | Name       | Role       | Status     |
        | ---------- | ---------- | ---------- |
        | Ada        | Engineer   | Active     |
        | Grace      | Admiral    | Retired    |
        """
}
