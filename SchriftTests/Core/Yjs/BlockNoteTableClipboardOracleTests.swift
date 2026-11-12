import XCTest

@testable import Schrift

/// PR11c against the web: a CellSelection's copy writes BlockNote 0.56's
/// `text/html` and `text/plain`, and paste (HTML from the web or another app,
/// Schrift's own payload, plain text) into a CellSelection or at a caret,
/// `deleteCellSelection`, cut and merging a rectangle produce the web's XML
/// through the native engine (`BlockNoteTableClipboardCaptures`), with the
/// save shadow equal to the exporter's Markdown. Pasted content is untrusted.
final class BlockNoteTableClipboardOracleTests: XCTestCase {
    private typealias Captures = BlockNoteTableClipboardCaptures

    private func engine(_ seed: String) throws -> (YDoc, DocumentEngine) {
        let doc = YDoc(clientID: 2, gc: false)
        try doc.applyUpdate(
            YUpdateDecoder.decode(try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(Captures.seeds[seed])))))
        return (doc, DocumentEngine(doc: doc, surface: HeadlessSurface()))
    }

    /// The web's (row, cell index) as the slot its cell starts at.
    private func slot(_ engine: DocumentEngine, _ cell: Captures.Cell) throws -> TableSlot {
        let grid = try XCTUnwrap(engine.tableGrid("tbl"))
        let found = grid.rows[cell.row][cell.index]
        return TableSlot(row: found.row, column: found.column)
    }

    private func apply(_ engine: DocumentEngine, _ command: BlockNoteTableCommand) throws {
        try engine.applyStructural(
            NativeEditCommand(id: UUID(), baseRevision: engine.revision, blockID: "tbl", kind: .table(command)),
            persist: { _ in })
    }

    private func copy(_ seed: String, _ name: String) throws -> TableCopy {
        let capture = try XCTUnwrap(Captures.copies.first { $0.seed == seed && $0.name == name })
        let (doc, engine) = try engine(seed)
        defer { doc.destroy() }
        return try XCTUnwrap(
            engine.tableCopy("tbl", from: try slot(engine, capture.anchor), to: try slot(engine, capture.head)))
    }

    func testCopyWritesTheWebsHTMLAndMarkdown() throws {
        for capture in Captures.copies {
            let context = "\(capture.seed)/\(capture.name)"
            let copied = try copy(capture.seed, capture.name)
            XCTAssertEqual(copied.html, capture.html, context)
            XCTAssertEqual(copied.plain, capture.plain, context)
            XCTAssertNotNil(copied.payload.flatMap(TableClipboard.cells(payload:)), "\(context): the payload reads back")
        }
    }

    /// Each capture's cells as the native editor reads the pasteboard: the
    /// web's HTML, Schrift's own copy of the cells the web copied, or text.
    private func pasted(_ capture: Captures.Paste) throws -> [[TablePastedCell]] {
        if let html = capture.html { return try XCTUnwrap(TableClipboard.cells(html: html), capture.name) }
        if capture.webCopy != nil {
            // The web pasted its own `blocknote/html`; natively that is the payload.
            let source = capture.name == "ownCopyIntoOneCell" ? ("grid", "body2x2") : ("merged", "whole")
            let payload = try XCTUnwrap(try copy(source.0, source.1).payload)
            return try XCTUnwrap(TableClipboard.cells(payload: payload), capture.name)
        }
        return [[TableClipboard.cell(text: try XCTUnwrap(capture.plain))]]
    }

    func testPasteWritesTheWebsXMLAndKeepsTheShadow() throws {
        for capture in Captures.pastes {
            let context = "\(capture.seed)/\(capture.name)"
            let (doc, engine) = try engine(capture.seed)
            defer { doc.destroy() }
            let anchor = try slot(engine, capture.anchor)
            let head = try capture.head.map { try slot(engine, $0) }
            try apply(engine, .paste(cells: try pasted(capture), anchor: anchor, head: head))
            XCTAssertEqual(YXMLString.fragment(doc), capture.xml, context)
            XCTAssertEqual(NativeBlockProjection.markdownShadow(doc), capture.markdown, "\(context): the shadow")
            XCTAssertEqual(engine.tableGrid("tbl")?.familiarity, .familiar, context)
        }
    }

    func testClearCutAndMergeOfARectangleAreTheWebs() throws {
        let rectangles: [String: (Captures.Cell, Captures.Cell)] = [
            "delete2x2": ((1, 0), (2, 1)), "cut2x2": ((1, 0), (2, 1)), "merge2x2": ((1, 0), (2, 1)),
            "mergeColumn": ((0, 2), (2, 2)), "mergeAll": ((0, 0), (2, 1)), "deleteAcrossSpan": ((1, 1), (2, 0)),
        ]
        for capture in Captures.edits {
            let context = "\(capture.seed)/\(capture.name)"
            let (doc, engine) = try engine(capture.seed)
            defer { doc.destroy() }
            let rectangle = try XCTUnwrap(rectangles[capture.name], context)
            let from = try slot(engine, rectangle.0)
            let to = try slot(engine, rectangle.1)
            try apply(engine, capture.name.hasPrefix("merge") ? .merge(from: from, to: to) : .clear(from: from, to: to))
            XCTAssertEqual(YXMLString.fragment(doc), capture.xml, context)
            XCTAssertEqual(NativeBlockProjection.markdownShadow(doc), capture.markdown, "\(context): the shadow")
        }
    }

    // MARK: - Untrusted paste

    func testHostileHTMLIsBoundedAndNeverCells() {
        XCTAssertNil(TableClipboard.cells(html: "<p>not a table</p>"))
        XCTAssertNil(TableClipboard.cells(html: "text <table><tr><td>a</td></tr></table>"), "text beside the table")
        XCTAssertNil(
            TableClipboard.cells(html: "<table><tr><td>a</td></tr></table><table><tr><td>b</td></tr></table>"),
            "two tables")
        XCTAssertNil(TableClipboard.cells(html: "<table><tr><td colspan=\"5000\">a</td></tr></table>"), "a huge span")
        XCTAssertNil(
            TableClipboard.cells(html: "<table>" + String(repeating: "<tr><td>x</td></tr>", count: 1_001) + "</table>"),
            "past the bound")
        XCTAssertNil(
            TableClipboard.cells(html: "<table><tr><td>" + String(repeating: "<span>", count: 300) + "</td></tr></table>"),
            "too deep")
        XCTAssertNil(TableClipboard.cells(html: String(repeating: "x", count: TableClipboard.maxHTMLBytes + 1)))
        // Malformed markup still parses to something or nothing, never a trap.
        for html in ["<table", "<table><tr><td", "<<<>>>", "<table><tr><td>&#xFFFFFFFF;&#0;&bogus;</td></tr></table>",
            "<table><tr><td><a href='javascript:alert(1)'>x</a></td></tr></table>", "</td></tr></table>"]
        {
            _ = TableClipboard.cells(html: html)
        }
        let cells = TableClipboard.cells(
            html: "<table><tr><td><a href=\"javascript:alert(1)\">x</a>&#0;&#xFFFFFFFF;</td></tr></table>")
        XCTAssertEqual(cells?.first?.first?.runs.first?.text.hasPrefix("x"), true)
        XCTAssertEqual(cells?.first?.first?.runs.first?.marks.count, 0, "an unsafe link loses its mark")
    }

    func testAHostilePayloadIsNotCells() throws {
        XCTAssertNil(TableClipboard.cells(payload: Data("not yjs".utf8)))
        // A valid payload of paragraphs is not cells.
        let payload = try BlockNoteSubtreePayload.encode([
            .element(
                "blockContainer", [("id", .string("a"))],
                [.element("paragraph", [], [.text([.run(InlineRun("hi"))])])])
        ])
        XCTAssertNil(TableClipboard.cells(payload: payload))
    }

    /// A paste that would grow the table past the bound is refused before
    /// anything is allocated or written.
    func testAPasteGrowingTheTablePastTheBoundIsRefused() throws {
        let (doc, engine) = try engine("grid")
        defer { doc.destroy() }
        let before = YXMLString.fragment(doc)
        let row = Array(repeating: TableClipboard.cell(text: "x"), count: 40)
        let cells = Array(repeating: row, count: 40)
        XCTAssertThrowsError(try apply(engine, .paste(cells: cells, anchor: TableSlot(row: 2, column: 2), head: nil)))
        XCTAssertEqual(YXMLString.fragment(doc), before)
    }
}
