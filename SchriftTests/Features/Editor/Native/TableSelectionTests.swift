import UIKit
import XCTest

@testable import Schrift

/// PR11c: the table editor's CellSelection, clipboard, arrows and VoiceOver
/// data table over a durable replica. Every write is one journaled table
/// command whose XML equals the web's (`BlockNoteTableClipboardCaptures`).
@MainActor
final class TableSelectionTests: NativeEditingTestCase {
    private typealias Captures = BlockNoteTableClipboardCaptures
    private typealias Ref = TableGrid.CellRef
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows { window.isHidden = true }
        windows = []
        try await super.tearDown()
    }

    private func state(_ seed: String) throws -> Data {
        try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(Captures.seeds[seed])))
    }

    private func open(_ seed: String = "grid") async throws -> (Harness, TableEditorViewController) {
        let harness = try await makeHarness(state: try state(seed))
        addTeardownBlock { await harness.close() }
        let editor = TableEditorViewController(document: harness.session, tableID: "tbl")
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let previous = scene?.windows.first(where: \.isKeyWindow)
        let window =
            scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in
            window.endEditing(true)
            window.isHidden = true
            previous?.makeKey()
        }
        windows.append(window)
        editor.loadViewIfNeeded()
        await editor.load()
        for _ in 0..<300 where !editor.isLoaded { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(editor.isLoaded)
        if let session = editor.cellSession { addTeardownBlock { await session.close().value } }
        return (harness, editor)
    }

    private func xml(_ harness: Harness) async -> String {
        await harness.session.replicaDoc { YXMLString.fragment($0) } ?? ""
    }

    private func edit(_ name: String) throws -> Captures.Edit {
        try XCTUnwrap(Captures.edits.first { $0.name == name })
    }

    private func paste(_ name: String) throws -> Captures.Paste {
        try XCTUnwrap(Captures.pastes.first { $0.name == name })
    }

    private func copyCapture(_ seed: String, _ name: String) throws -> Captures.Copy {
        try XCTUnwrap(Captures.copies.first { $0.seed == seed && $0.name == name })
    }

    private func slot(_ editor: TableEditorViewController, _ ref: Ref) -> TableSlot {
        let cell = editor.grid!.cell(ref)
        return TableSlot(row: cell.row, column: cell.column)
    }

    private func waitForGrid(_ editor: TableEditorViewController, _ done: () -> Bool) async throws {
        for _ in 0..<300 where !done() { try await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: - Selection

    func testShiftArrowsSelectARectangleAndBackspaceEmptiesItAsTheWebDoes() async throws {
        let (harness, editor) = try await open()
        let table = try XCTUnwrap(editor.cellSession)
        editor.activate(Ref(row: 1, index: 0))  // "ab", selected
        XCTAssertTrue(editor.key(.arrow(.right, extend: true)), "past the cell's edge Shift-Right selects cells")
        XCTAssertTrue(editor.key(.arrow(.down, extend: true)))
        XCTAssertEqual(
            editor.selectedCells, [Ref(row: 1, index: 0), Ref(row: 1, index: 1), Ref(row: 2, index: 0), Ref(row: 2, index: 1)])
        XCTAssertFalse(try XCTUnwrap(editor.cellViews[Ref(row: 2, index: 1)]).selectionView.isHidden, "drawn")
        XCTAssertTrue(try XCTUnwrap(editor.cellViews[Ref(row: 0, index: 0)]).selectionView.isHidden)
        let deleted = await table.run {
            table.textView.deleteBackward()
            return true
        }
        XCTAssertTrue(deleted)
        let written = await xml(harness)
        XCTAssertEqual(written, try edit("delete2x2").xml)
        XCTAssertEqual(harness.log.commands.count, 1, "one durable command")
        XCTAssertNotNil(editor.selection, "the CellSelection stays, as on the web")
        // Escape drops the selection before it closes anything.
        XCTAssertTrue(editor.move(.exit))
        XCTAssertNil(editor.selection)
        XCTAssertNotNil(editor.cellSession, "still editing")
    }

    func testTypingOverASelectionClearsItAndTypesIntoTheActiveCell() async throws {
        let (harness, editor) = try await open()
        let table = try XCTUnwrap(editor.cellSession)
        editor.activate(Ref(row: 2, index: 2))  // the empty cell
        editor.select(.init(anchor: TableSlot(row: 1, column: 1), head: TableSlot(row: 2, column: 2)))
        table.textView.insertText("z")
        await harness.settle()
        XCTAssertNil(editor.selection)
        let text = await harness.engine { $0.tableGrid("tbl")?.rows[2][2].runs.map(\.text).joined() }
        XCTAssertEqual(text, "z")
    }

    func testArrowsCrossCellEdges() async throws {
        let (_, editor) = try await open()
        let table = try XCTUnwrap(editor.cellSession)
        editor.activate(Ref(row: 1, index: 0))  // "ab" selected: its end is the cell's end
        XCTAssertTrue(editor.key(.arrow(.right, extend: false)))
        XCTAssertEqual(editor.active, Ref(row: 1, index: 1))
        let c = try XCTUnwrap(table.surface.rangeIndex.entry(for: editor.paragraphIDs(Ref(row: 1, index: 1))[0]))
        XCTAssertEqual(table.textView.selectedRange, NSRange(location: c.textRange.location, length: 0), "at the start")
        XCTAssertTrue(editor.key(.arrow(.left, extend: false)), "at the start, Left goes back")
        XCTAssertEqual(editor.active, Ref(row: 1, index: 0))
        let ab = try XCTUnwrap(table.surface.rangeIndex.entry(for: editor.paragraphIDs(Ref(row: 1, index: 0))[0]))
        XCTAssertEqual(table.textView.selectedRange, NSRange(location: NSMaxRange(ab.textRange), length: 0), "at the end")
        // Inside the text the arrow is the text view's.
        table.textView.selectedRange = NSRange(location: ab.textRange.location + 1, length: 0)
        XCTAssertFalse(editor.key(.arrow(.right, extend: false)))
        XCTAssertFalse(editor.key(.arrow(.left, extend: true)))
        XCTAssertNil(editor.selection)
        XCTAssertTrue(editor.key(.arrow(.down, extend: false)), "one line: Down leaves the cell")
        XCTAssertEqual(editor.active, Ref(row: 2, index: 0))
        XCTAssertFalse(editor.key(.arrow(.down, extend: false)), "nothing below the last row")
        XCTAssertTrue(editor.move(.done))
        XCTAssertNil(editor.cellSession, "⌘Return is Done")
    }

    // MARK: - Clipboard

    func testCopyWritesTheWebsClipboardAndItsPasteIsTheWebsOwn() async throws {
        let (harness, editor) = try await open()
        let table = try XCTUnwrap(editor.cellSession)
        editor.select(.init(anchor: TableSlot(row: 1, column: 0), head: TableSlot(row: 2, column: 1)))
        table.textView.copy(nil)  // ⌘C reaches the editor through the text view
        for _ in 0..<300 where harness.pasteboard.data(forPasteboardType: TableClipboard.htmlType) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let capture = try copyCapture("grid", "body2x2")
        let html = harness.pasteboard.data(forPasteboardType: TableClipboard.htmlType).flatMap {
            String(data: $0, encoding: .utf8)
        }
        XCTAssertEqual(html, capture.html)
        XCTAssertEqual(harness.pasteboard.string, capture.plain)
        XCTAssertNotNil(harness.pasteboard.data(forPasteboardType: BlockNoteSubtreePayload.pasteboardType))
        XCTAssertEqual(harness.log.commands.count, 0, "copy writes nothing")
        // Into one cell: clipped to it, as the web pastes its own copy.
        editor.select(.init(anchor: TableSlot(row: 0, column: 1), head: TableSlot(row: 0, column: 1)))
        let pasted = await table.run {
            table.textView.paste(nil)
            return true
        }
        XCTAssertTrue(pasted)
        let written = await xml(harness)
        XCTAssertEqual(written, try paste("ownCopyIntoOneCell").xml)
        XCTAssertEqual(harness.log.commands.count, 1)
    }

    func testCutCopiesThenEmptiesTheCells() async throws {
        let (harness, editor) = try await open()
        editor.select(.init(anchor: TableSlot(row: 1, column: 0), head: TableSlot(row: 2, column: 1)))
        try XCTUnwrap(editor.cellSession).textView.cut(nil)
        for _ in 0..<300 where harness.log.commands.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        await harness.settle()
        let written = await xml(harness)
        XCTAssertEqual(written, try edit("cut2x2").xml)
        XCTAssertEqual(harness.pasteboard.string, try copyCapture("grid", "body2x2").plain, "copied first")
    }

    func testWebHTMLAtTheCaretGrowsTheTableAndIsSelected() async throws {
        let (harness, editor) = try await open()
        let table = try XCTUnwrap(editor.cellSession)
        let capture = try paste("externalAtCaretGrows")
        harness.pasteboard.setItems([[TableClipboard.htmlType: try XCTUnwrap(capture.html)]])
        editor.activate(Ref(row: 2, index: 2))
        let pasted = await table.run { editor.key(.paste) }
        XCTAssertTrue(pasted)
        let written = await xml(harness)
        XCTAssertEqual(written, capture.xml)
        try await waitForGrid(editor) { editor.grid?.columnCount == 4 && editor.selection != nil }
        XCTAssertEqual(editor.selection, .init(anchor: TableSlot(row: 2, column: 2), head: TableSlot(row: 3, column: 3)))
        let shadow = await harness.session.replicaDoc { NativeBlockProjection.markdownShadow($0) }
        XCTAssertEqual(shadow, capture.markdown)
    }

    func testPlainTextIntoASelectionFillsEachCellAndAtACaretIsText() async throws {
        let (harness, editor) = try await open()
        let table = try XCTUnwrap(editor.cellSession)
        harness.pasteboard.string = "hello"
        editor.activate(Ref(row: 1, index: 1))
        XCTAssertFalse(editor.key(.paste), "no selection, no cells: the text view pastes text")
        editor.select(.init(anchor: TableSlot(row: 1, column: 1), head: TableSlot(row: 2, column: 2)))
        let pasted = await table.run { editor.key(.paste) }
        XCTAssertTrue(pasted)
        let written = await xml(harness)
        XCTAssertEqual(written, try paste("plainIntoSelection").xml)
    }

    func testMergeCellsMergesTheSelectionAndActivatesTheMergedCell() async throws {
        let (harness, editor) = try await open()
        let table = try XCTUnwrap(editor.cellSession)
        editor.select(.init(anchor: TableSlot(row: 1, column: 0), head: TableSlot(row: 2, column: 1)))
        let merge = editor.menuElements("cell").compactMap { $0 as? UIAction }.first {
            $0.accessibilityIdentifier == "nativeEditor.table.mergeCells"
        }
        XCTAssertNotNil(merge, "the Cell menu merges a selection")
        XCTAssertFalse(merge?.attributes.contains(.disabled) ?? true)
        let merged = await table.run { editor.mergeSelection() }
        XCTAssertTrue(merged)
        let written = await xml(harness)
        XCTAssertEqual(written, try edit("merge2x2").xml)
        try await waitForGrid(editor) { editor.grid?.rows[1].first?.colspan == 2 }
        XCTAssertEqual(editor.active, Ref(row: 1, index: 0), "the merged cell")
        XCTAssertNil(editor.selection)
    }

    func testAMergeAcrossASpanIsDisabled() async throws {
        let (_, editor) = try await open("merged")
        // C to h: columns 1–2 of every row, which cuts the colspan-2 cell "d e".
        editor.select(.init(anchor: TableSlot(row: 0, column: 2), head: TableSlot(row: 2, column: 1)))
        let merge = editor.menuElements("cell").compactMap { $0 as? UIAction }.first {
            $0.accessibilityIdentifier == "nativeEditor.table.mergeCells"
        }
        XCTAssertEqual(merge?.attributes.contains(.disabled), true, "a cell crosses the left edge")
    }

    /// Untrusted HTML never crashes the editor or reaches the table unbounded.
    func testAHostilePasteIsRefusedOrPlainText() async throws {
        let (harness, editor) = try await open()
        editor.activate(Ref(row: 1, index: 1))
        let huge = "<table>" + String(repeating: "<tr><td>x</td></tr>", count: 2_000) + "</table>"
        harness.pasteboard.setItems([[TableClipboard.htmlType: huge]])
        XCTAssertFalse(editor.key(.paste), "not cells: the text view pastes its text")
        harness.pasteboard.setItems([[BlockNoteSubtreePayload.pasteboardType: Data("junk".utf8)]])
        XCTAssertFalse(editor.key(.paste))
        await harness.settle()
        XCTAssertEqual(harness.log.commands.count, 0)
    }

    // MARK: - VoiceOver

    func testVoiceOverReadsTheGridAsADataTable() async throws {
        let (_, editor) = try await open("merged")
        let grid = editor.gridView
        XCTAssertEqual(grid.accessibilityContainerType, .dataTable)
        XCTAssertEqual(grid.accessibilityRowCount(), 3)
        XCTAssertEqual(grid.accessibilityColumnCount(), 3)
        XCTAssertEqual(grid.accessibilityElementCount(), 7)
        // The colspan-2 cell "d e" and the rowspan-2 cell "f i".
        let wide = try XCTUnwrap(grid.accessibilityDataTableCellElement(forRow: 1, column: 1))
        XCTAssertEqual(wide.accessibilityColumnRange(), NSRange(location: 0, length: 2))
        XCTAssertEqual((wide as? NSObject)?.accessibilityValue, "d\ne")
        let tall = try XCTUnwrap(grid.accessibilityDataTableCellElement(forRow: 2, column: 2))
        XCTAssertEqual(tall.accessibilityRowRange(), NSRange(location: 1, length: 2))
        // The header row heads each column.
        let headers = try XCTUnwrap(grid.accessibilityHeaderElements(forColumn: 1))
        XCTAssertEqual(headers.compactMap { ($0 as? NSObject)?.accessibilityValue }, ["B"])
        XCTAssertTrue((headers.first as? NSObject)?.accessibilityTraits.contains(.header) == true)
        // The active cell is the text view itself.
        let first = grid.accessibilityElement(at: 0) as AnyObject
        XCTAssertTrue(first === editor.cellSession?.textView)
        XCTAssertEqual(editor.cellSession?.textView.accessibilityRowRange(), NSRange(location: 0, length: 1))
        // Activating a cell edits it.
        let g = try XCTUnwrap(grid.accessibilityDataTableCellElement(forRow: 2, column: 0) as? TableCellElement)
        XCTAssertTrue(g.accessibilityActivate())
        XCTAssertEqual(editor.active, Ref(row: 2, index: 0))
        XCTAssertEqual(g.accessibilityFrameInContainerSpace, editor.frame(of: Ref(row: 2, index: 0)))
    }
}
