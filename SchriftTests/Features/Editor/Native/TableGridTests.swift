import XCTest

@testable import Schrift

/// PR11a: `TableGrid` reads only the tables it understands. Every shape
/// prosemirror-tables would rewrite (`fixTables`) or the native editor does
/// not model is unfamiliar: the table stays opaque, the document gets no
/// shadow (so it is read-only), and nothing addresses its cells.
final class TableGridTests: XCTestCase {
    private indirect enum Node {
        case element(String, [(String, YAnyValue)], [Node])
        case text(String)
    }

    private static func cell(
        _ text: String, colspan: Int = 1, rowspan: Int = 1, header: Bool = false,
        extra: [(String, YAnyValue)] = []
    ) -> Node {
        .element(
            header ? "tableHeader" : "tableCell",
            [("colspan", .int(colspan)), ("rowspan", .int(rowspan)), ("textAlignment", .string("left"))] + extra,
            [.element("tableParagraph", [], text.isEmpty ? [] : [.text(text)])])
    }

    private static func row(_ cells: [Node]) -> Node { .element("tableRow", [], cells) }

    /// A document of one table block holding `rows`.
    private func doc(_ rows: [Node]) throws -> YDoc {
        let doc = YDoc(clientID: 4, gc: true)
        let root = doc.get(BlockNoteYjs.fragmentField)
        try doc.transact { tx in
            let group = YType(typeRef: .xmlElement(nodeName: "blockGroup"))
            try YWrite.insertAfter(tx, into: root, after: nil, [.type(group)])
            try insert(
                .element("blockContainer", [("id", .string("tbl"))], [.element("table", [], rows)]), into: group,
                after: nil, tx)
        }
        return doc
    }

    @discardableResult
    private func insert(_ node: Node, into parent: YType, after left: YItem?, _ tx: YTransaction) throws -> YItem? {
        switch node {
        case .element(let name, let attributes, let children):
            let type = YType(typeRef: .xmlElement(nodeName: name))
            let item = try YWrite.insertAfter(tx, into: parent, after: left, [.type(type)])
            var last: YItem?
            for child in children { last = try insert(child, into: type, after: last, tx) }
            for (key, value) in attributes { try YWrite.mapSet(tx, on: type, key: key, .any([value])) }
            return item
        case .text(let string):
            let text = YType(typeRef: .xmlText)
            let item = try YWrite.insertAfter(tx, into: parent, after: left, [.type(text)])
            try text.insert(0, string, nil)
            return item
        }
    }

    private func grid(_ rows: [Node]) throws -> TableGrid {
        let doc = try doc(rows)
        defer { doc.destroy() }
        return try XCTUnwrap(TableGrid.tables(in: doc)["tbl"])
    }

    func testARectangularGridWithSpansIsFamiliar() throws {
        let grid = try grid([
            Self.row([Self.cell("a", colspan: 2, header: true), Self.cell("b", rowspan: 2)]),
            Self.row([Self.cell("c"), Self.cell("d")]),
        ])
        XCTAssertEqual(grid.familiarity, .familiar)
        XCTAssertEqual(grid.columnCount, 3)
        XCTAssertEqual(grid.slots[1].map(\.index), [0, 1, 1])
        XCTAssertEqual(NativeExportMarkdown.table(grid).map { $0.split(separator: "\n").count }, 3)
    }

    func testShapesTheWebWouldRewriteAreUnfamiliar() throws {
        let cases: [(String, [Node])] = [
            (
                "overlapping cells",
                [
                    Self.row([Self.cell("a"), Self.cell("b", rowspan: 2)]),
                    Self.row([Self.cell("c", colspan: 2), Self.cell("d")]),
                ]
            ),
            ("ragged rows", [Self.row([Self.cell("a"), Self.cell("b")]), Self.row([Self.cell("c")])]),
            ("span past the last row", [Self.row([Self.cell("a", rowspan: 3)])]),
            ("unreadable colwidth", [Self.row([Self.cell("a", extra: [("colwidth", .array([.int(1), .int(2)]))])])]),
            ("unreadable span", [Self.row([Self.cell("a", colspan: 0)])]),
            ("empty cell", [Self.row([.element("tableCell", [], [])])]),
            ("unexpected cell", [Self.row([.element("paragraph", [], [])])]),
            ("unexpected cell content", [Self.row([.element("tableCell", [], [.element("paragraph", [], [])])])]),
            ("empty row", [Self.row([])]),
            ("empty table", []),
        ]
        for (reason, rows) in cases {
            XCTAssertEqual(try grid(rows).familiarity, .unfamiliar(reason), reason)
        }
    }

    func testAMentionKeepsTheTableOpaqueButReadable() throws {
        let doc = try doc([
            Self.row([
                .element(
                    "tableCell", [],
                    [.element("tableParagraph", [], [.text("Hi "), .element("userMentionInline", [], [])])])
            ])
        ])
        defer { doc.destroy() }
        let grid = try XCTUnwrap(TableGrid.tables(in: doc)["tbl"])
        XCTAssertEqual(grid.familiarity, .unfamiliar("unexpected cell content"))
        XCTAssertEqual(grid.rows[0][0].runs, [InlineRun("Hi ")], "the viewer still shows the text")
        XCTAssertNil(NativeExportMarkdown.table(grid))
        XCTAssertTrue(NativeBlockProjection.project(doc).blocks[0].block.fidelity.isOpaque)
        XCTAssertNil(NativeBlockProjection.markdownShadow(doc), "no shadow: the document reads only")
        let engine = DocumentEngine(doc: doc, surface: HeadlessSurface())
        XCTAssertFalse(engine.openTable("tbl"))
    }

    func testATableOverTheBoundIsUnfamiliar() throws {
        let cells = (0..<(TableGrid.maxCells + 1)).map { _ in Self.cell("x") }
        XCTAssertEqual(try grid([Self.row(cells)]).familiarity, .unfamiliar("large table"))
    }

    /// Review T1: spans are bounded by the slots they claim before any slot is
    /// allocated (a crafted 1,000-row table of full-width, row-spanning cells
    /// asked for ~5 × 10⁸ slots on open).
    func testSpansClaimingTooManySlotsAreLargeBeforeLayout() throws {
        let rows = (0..<3).map { index in
            Self.row([Self.cell("x", colspan: TableGrid.maxCells, rowspan: 3 - index)])
        }
        XCTAssertEqual(try grid(rows).familiarity, .unfamiliar("large table"))
        // At the bound a spanned table is still familiar.
        let wide = try grid([Self.row([Self.cell("a", colspan: 500, rowspan: 2)]), Self.row([])])
        XCTAssertNotEqual(wide.familiarity, .unfamiliar("large table"))
    }

    /// The export trims a cell with JS `trim()`: U+FEFF goes, U+0085 stays.
    func testCellsTrimLikeJavaScript() throws {
        let grid = try grid([Self.row([Self.cell("\u{FEFF}x\u{85}", header: true)])])
        let first = try XCTUnwrap(NativeExportMarkdown.table(grid)?.split(separator: "\n").first)
        XCTAssertTrue(first.hasPrefix("| x\u{85} "), String(first))
    }

    func testParagraphIDsAreTheirTablesAndNeverABlockID() {
        let id = TableGrid.paragraphID(table: "tbl", item: YID(client: 7, clock: 42))
        XCTAssertTrue(TableGrid.isParagraphID(id))
        XCTAssertEqual(TableGrid.tableID(ofParagraph: id), "tbl")
        XCTAssertFalse(TableGrid.isParagraphID("tbl"))
        XCTAssertNil(TableGrid.tableID(ofParagraph: "tbl"))
    }
}
