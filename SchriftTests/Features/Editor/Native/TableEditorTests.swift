import UIKit
import XCTest

@testable import Schrift

/// PR11a: the native table editor over a durable replica. A table surface
/// (`NativeEditorSession.openTable`) types into a web-authored table's cells
/// through the document's own machinery (prediction, journal, marks, IME,
/// undo), moves between cells with BlockNote's keys without writing, never
/// shows the document a cell paragraph, and preserves everything it does not
/// edit. Unfamiliar tables open read-only.
@MainActor
final class TableEditorTests: NativeEditingTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows { window.isHidden = true }
        windows = []
        try await super.tearDown()
    }

    /// A web fixture's state (11a's captures, else PR11b's operation seeds).
    private func fixture(_ name: String) throws -> Data {
        let base64 =
            name.hasPrefix("ops:")
            ? BlockNoteTableOperationCaptures.seeds[String(name.dropFirst(4))]
            : BlockNoteTableCaptures.fixtures.first { $0.name == name }?.update
        return try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(base64, name)))
    }

    /// The styled fixture (paragraph, table, paragraph) in a typing harness,
    /// with its table surface open and shown in a window.
    private func open(_ name: String = "styled") async throws -> (Harness, NativeEditorSession) {
        let harness = try await makeHarness(state: try fixture(name))
        addTeardownBlock { await harness.close() }
        XCTAssertTrue(harness.session.canType, "a document with a familiar table types")
        let table = try await unwrapped(await harness.session.openTable("tbl"), "the table opens")
        addTeardownBlock { await table.close().value }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.addSubview(table.textView)
        table.textView.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        window.isHidden = false
        windows.append(window)
        return (harness, table)
    }

    private func ids(_ table: NativeEditorSession) -> [String] { table.surface.blocks.map(\.id) }

    private func xml(_ harness: Harness) async -> String {
        await harness.session.replicaDoc { YXMLString.fragment($0) } ?? ""
    }

    private func cellText(_ harness: Harness, _ row: Int, _ index: Int) async -> String? {
        await harness.session.engine { engine -> String? in
            engine.tableGrid("tbl")?.rows[row][index].runs.map(\.text).joined()
        }
    }

    // MARK: - Typing

    func testTypingInACellIsPredictedJournaledAndNeverShownToTheDocument() async throws {
        let (harness, table) = try await open()
        let documentLog = PatchLog(harness.session)
        let input = try XCTUnwrap(table.input)
        XCTAssertEqual(table.surface.blocks.count, 9, "every paragraph of the 3 × 3 table")
        // "Engineer" is row 1's second cell: the fifth paragraph.
        input.showCell([ids(table)[4]])
        XCTAssertEqual(table.surface.focus, [ids(table)[4]])
        XCTAssertEqual(table.surface.hidden.filter { $0 }.count, 8, "one cell laid out")
        XCTAssertEqual(table.textView.selectedRange.length, 8, "the cell's text is selected, as goToNextCell does")
        setSelection(table, NSRange(location: NSMaxRange(table.textView.selectedRange), length: 0))
        for key in [" ", "I", "I"] { table.textView.insertText(key) }
        XCTAssertEqual(table.surface.blocks[4].runs.map(\.text).joined(), "Engineer II", "shown at once")
        await table.settle()
        await harness.settle()
        let text = await cellText(harness, 1, 1)
        XCTAssertEqual(text, "Engineer II")
        XCTAssertEqual(harness.log.commands.count, 3, "one journaled command per key")
        XCTAssertTrue(harness.log.commands.allSatisfy { TableGrid.isParagraphID($0.blockID) })
        // The document never saw a cell paragraph, nor a table rebuild per key.
        XCTAssertFalse(
            documentLog.patches.flatMap(\.changes).contains { change in
                switch change {
                case .text(let id, _), .props(let id, _), .replaceBlock(let id, _):
                    TableGrid.isParagraphID(id) || id == "tbl"
                case .remove(let ids): ids.contains(where: TableGrid.isParagraphID)
                case .insert(_, let blocks): blocks.contains { TableGrid.isParagraphID($0.id) }
                case .reset: true
                }
            })
        // Closing the table refreshes the document's preview once.
        await table.close().value
        await harness.settle()
        guard case .table(let cells, _, _)? = try block(harness.session, "tbl").preview else {
            return XCTFail("still a table preview")
        }
        XCTAssertEqual(cells[1][1], "Engineer II")
        try await assertConsistent(harness, localCommands: 3)
        // Everything but the typed text is as the web wrote it.
        let expected = try XCTUnwrap(BlockNoteTableCaptures.fixtures.first { $0.name == "styled" }).xml
            .replacingOccurrences(of: ">Engineer<", with: ">Engineer II<")
        let written = await xml(harness)
        XCTAssertEqual(written, expected)
    }

    func testMarksAndAPendingMarkInACell() async throws {
        let (harness, table) = try await open()
        let input = try XCTUnwrap(table.input)
        input.showCell([ids(table)[6]])  // "Grace"
        let start = try location(table, ids(table)[6], 0)
        setSelection(table, NSRange(location: start, length: 2))
        let bolded = await table.run { input.toggleMark("bold") }
        XCTAssertTrue(bolded)
        setSelection(table, NSRange(location: start + 5, length: 0))
        XCTAssertTrue(input.toggleMark("italic"), "a caret only sets the typing marks")
        table.textView.insertText("!")
        await table.settle()
        await harness.settle()
        let written = await xml(harness)
        XCTAssertTrue(
            written.contains("<tableparagraph><bold>Gr</bold>ace<italic>!</italic></tableparagraph>"), written)
        XCTAssertEqual(harness.log.commands.count, 2)
    }

    func testCompositionInACellCommitsOnce() async throws {
        let (harness, table) = try await open()
        let input = try XCTUnwrap(table.input)
        input.showCell([ids(table)[8]])  // the empty cell
        XCTAssertEqual(table.textView.selectedRange.length, 0)
        table.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        table.textView.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertTrue(input.composition.isActive)
        table.textView.unmarkText()
        await table.settle()
        await harness.settle()
        let text = await cellText(harness, 2, 2)
        XCTAssertEqual(text, "日本")
        XCTAssertEqual(harness.log.commands.count, 1, "the commit is one command")
        XCTAssertEqual(table.surface.blocks[8].runs.map(\.text).joined(), "日本")
    }

    // MARK: - Cells and keys

    private func editor(_ harness: Harness) async throws -> TableEditorViewController {
        let editor = TableEditorViewController(document: harness.session, tableID: "tbl")
        // A scene's window when there is one, so the cell's text view can be
        // first responder; else a plain window (focus is then not asserted).
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
        await editor.load()  // the one `viewDidLoad` started, or this
        for _ in 0..<300 where !editor.isLoaded { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(editor.isLoaded)
        if let session = editor.cellSession { addTeardownBlock { await session.close().value } }
        return editor
    }

    func testTabShiftTabReturnAndEscapeMoveWithoutWriting() async throws {
        let harness = try await makeHarness(state: try fixture("merged"))
        addTeardownBlock { await harness.close() }
        let editor = try await editor(harness)
        let table = try XCTUnwrap(editor.cellSession)
        let input = try XCTUnwrap(table.input)
        XCTAssertEqual(editor.active, TableGrid.CellRef(row: 0, index: 0))
        // First responder needs the key window, which a full run may hand
        // elsewhere: the move must keep whatever focus the view had, and never
        // re-parent it (that would drop the keyboard).
        let focused = table.textView.isFirstResponder || table.textView.becomeFirstResponder()
        let host = table.textView.superview
        XCTAssertTrue(input.insertTab())
        XCTAssertEqual(editor.active, TableGrid.CellRef(row: 0, index: 1))
        XCTAssertTrue(input.outdent(), "Shift-Tab")
        XCTAssertEqual(editor.active, TableGrid.CellRef(row: 0, index: 0))
        XCTAssertTrue(input.insertNewline(), "Return")
        XCTAssertEqual(editor.active, TableGrid.CellRef(row: 1, index: 0), "the merged d/e cell is below A")
        // A merged cell of two paragraphs: both laid out, the caret at its end.
        XCTAssertEqual(table.surface.focus?.count, 2)
        XCTAssertEqual(table.textView.selectedRange.length, 0)
        XCTAssertTrue(input.insertNewline())
        XCTAssertEqual(editor.active, TableGrid.CellRef(row: 2, index: 0))
        XCTAssertTrue(input.insertNewline(), "the last row keeps the key")
        XCTAssertEqual(editor.active, TableGrid.CellRef(row: 2, index: 0))
        for _ in 0..<10 { input.insertTab() }
        XCTAssertEqual(editor.active, TableGrid.CellRef(row: 2, index: 1), "Tab stops at the last cell")
        XCTAssertTrue(table.textView.superview === host, "the text view never left the grid")
        if focused { XCTAssertTrue(table.textView.isFirstResponder, "the keyboard never dropped") }
        XCTAssertTrue(input.deleteBackwardAtBlockStart(), "Backspace at a start keeps the cell")
        await table.settle()
        XCTAssertEqual(harness.log.commands.count, 0, "moving between cells writes nothing")
        let closed = expectation(description: "closed")
        editor.onClose = { closed.fulfill() }
        XCTAssertEqual(table.textView.keyCommands?.contains { $0.input == UIKeyCommand.inputEscape }, true)
        XCTAssertTrue(editor.move(.exit))
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertNil(editor.cellSession)
    }

    func testTheGridLaysOutSpansWidthsAndTheActiveCell() async throws {
        let harness = try await makeHarness(state: try fixture("styled"))
        addTeardownBlock { await harness.close() }
        let editor = try await editor(harness)
        let frames = editor.cellViews.mapValues(\.frame)
        let first = try XCTUnwrap(frames[TableGrid.CellRef(row: 0, index: 0)])
        let second = try XCTUnwrap(frames[TableGrid.CellRef(row: 0, index: 1)])
        XCTAssertEqual(first.width, 200, "colwidth")
        XCTAssertEqual(second.width, 120, "BlockNote's empty cell width")
        XCTAssertEqual(second.minX, 200)
        XCTAssertEqual(
            editor.cellViews[TableGrid.CellRef(row: 1, index: 0)]?.backgroundColor,
            AttributedDocumentProjection.backgroundColor(named: "green"))
        let table = try XCTUnwrap(editor.cellSession)
        XCTAssertEqual(table.textView.frame, first, "the text view sits over the active cell")
        editor.activate(TableGrid.CellRef(row: 1, index: 1))
        XCTAssertEqual(table.textView.frame, editor.cellViews[TableGrid.CellRef(row: 1, index: 1)]?.frame)
        XCTAssertEqual(table.textView.frame.width, 120)

        let merged = try await makeHarness(state: try fixture("merged"))
        addTeardownBlock { await merged.close() }
        let spans = try await self.editor(merged)
        let de = try XCTUnwrap(spans.cellViews[TableGrid.CellRef(row: 1, index: 0)]?.frame)
        let fi = try XCTUnwrap(spans.cellViews[TableGrid.CellRef(row: 1, index: 1)]?.frame)
        let g = try XCTUnwrap(spans.cellViews[TableGrid.CellRef(row: 2, index: 0)]?.frame)
        XCTAssertEqual(de.width, 240, "colspan 2")
        XCTAssertEqual(fi.height, de.height + g.height, accuracy: 0.5, "rowspan 2")
    }

    // MARK: - Undo, peers, relaunch

    func testUndoAndRedoOfCellText() async throws {
        let (harness, table) = try await open()
        let input = try XCTUnwrap(table.input)
        input.showCell([ids(table)[6]])
        setSelection(table, NSRange(location: try location(table, ids(table)[6], 5), length: 0))
        table.textView.insertText("s")
        await table.settle()
        let undone = await table.run { input.undo() }
        XCTAssertTrue(undone)
        let afterUndo = await cellText(harness, 2, 0)
        XCTAssertEqual(afterUndo, "Grace")
        XCTAssertEqual(table.surface.blocks[6].runs.map(\.text).joined(), "Grace")
        let redone = await table.run { input.redo() }
        XCTAssertTrue(redone)
        let afterRedo = await cellText(harness, 2, 0)
        XCTAssertEqual(afterRedo, "Graces")
        XCTAssertEqual(table.surface.blocks[6].runs.map(\.text).joined(), "Graces")
    }

    /// A peer's update from the same seed: `body` edits the peer's copy of the table.
    private func peerUpdate(_ name: String, _ body: (YDoc, YTransaction, YType) throws -> Void) throws -> Data {
        let peer = YDoc(clientID: 77, gc: true)
        defer { peer.destroy() }
        try peer.applyUpdate(YUpdateDecoder.decode(try fixture(name)))
        let before = YStateEncoder.encodeStateVector(peer)
        let root = try XCTUnwrap(peer.share[BlockNoteYjs.fragmentField])
        guard case .type(let group)? = YBlockProjection.children(of: root, includeFormats: false).first?.content
        else { throw XCTSkip("no root group") }
        let container = try XCTUnwrap(
            YBlockProjection.children(of: group, includeFormats: false).first { item in
                guard case .type(let type) = item.content else { return false }
                return BlockIndex.blockID(of: type) == "tbl"
            })
        guard case .type(let containerType) = container.content,
            case .type(let table)? = YBlockProjection.children(of: containerType, includeFormats: false).first?.content
        else { throw XCTSkip("no table") }
        try peer.transact { tx in try body(peer, tx, table) }
        let vector = try YUpdateDecoder.decodeStateVector(before)
        return try YStateEncoder.encodeStateAsUpdate(
            peer, since: Dictionary(vector.map { ($0.client, $0.clock) }, uniquingKeysWith: { $1 }))
    }

    private func element(_ type: YType, _ path: [Int]) -> YType? {
        var current = type
        for index in path {
            guard
                case .type(let child)? = YBlockProjection.children(of: current, includeFormats: false)[safe: index]?
                    .content
            else { return nil }
            current = child
        }
        return current
    }

    func testAPeerEditInTheActiveCellRebasesTheTypingAndOtherCellsFollow() async throws {
        let (harness, table) = try await open()
        let input = try XCTUnwrap(table.input)
        input.showCell([ids(table)[3]])  // "Ada"
        setSelection(table, NSRange(location: try location(table, ids(table)[3], 3), length: 0))
        table.textView.insertText("!")
        // The peer types at the start of the same cell and into "Grace".
        let update = try peerUpdate("styled") { _, _, table in
            let ada = try XCTUnwrap(self.element(table, [1, 0, 0, 0]))
            try ada.insert(0, "Dr ", nil)
            let grace = try XCTUnwrap(self.element(table, [2, 0, 0, 0]))
            try grace.insert(5, " H", nil)
        }
        try await harness.session.integrateServerState(update)
        await table.settle()
        await harness.settle()
        XCTAssertEqual(table.surface.blocks[3].runs.map(\.text).joined(), "Dr Ada!")
        XCTAssertEqual(table.surface.blocks[6].runs.map(\.text).joined(), "Grace H")
        let ada = await cellText(harness, 1, 0)
        XCTAssertEqual(ada, "Dr Ada!")
        XCTAssertTrue(input.composition.pendingRecoveries.isEmpty, "nothing became a recovery entry")
    }

    func testAPeerDeletingTheActiveRowMovesTheEditorAndDropsItsParagraphs() async throws {
        let harness = try await makeHarness(state: try fixture("styled"))
        addTeardownBlock { await harness.close() }
        let editor = try await editor(harness)
        let table = try XCTUnwrap(editor.cellSession)
        editor.activate(TableGrid.CellRef(row: 1, index: 1))
        let update = try peerUpdate("styled") { _, tx, table in
            let row = try XCTUnwrap(YBlockProjection.children(of: table, includeFormats: false)[safe: 1])
            row.delete(tx)
        }
        try await harness.session.integrateServerState(update)
        await table.settle()
        for _ in 0..<200 where editor.grid?.rows.count != 2 { await Task.yield() }
        XCTAssertEqual(table.surface.blocks.count, 6, "the row's paragraphs left the table surface")
        XCTAssertEqual(editor.grid?.rows.count, 2)
        XCTAssertEqual(editor.active, TableGrid.CellRef(row: 0, index: 0), "a deleted cell gives way to the first")
        let frozen = await harness.engine { $0.nativeWriteFailed }
        XCTAssertEqual(frozen, false)
        XCTAssertTrue(table.input?.composition.pendingRecoveries.isEmpty == true)
    }

    func testCellTextSurvivesRelaunchOffline() async throws {
        let (harness, table) = try await open()
        let input = try XCTUnwrap(table.input)
        input.showCell([ids(table)[8]])
        table.textView.insertText("x")
        await table.settle()
        await table.close().value
        await harness.session.close().value
        let restored = try await unwrapped(
            await NativeEditorSession.restore(store: harness.store, scope: harness.scope), "restored")
        addTeardownBlock { await restored.close().value }
        let text = await restored.engine { $0.tableGrid("tbl")?.rows[2][2].runs.map(\.text).joined() }
        XCTAssertEqual(text, "x")
    }

    // MARK: - Shapes 11a does not author

    /// A hard-break cell is shown as one paragraph with a line separator and,
    /// since PR11b, typed into (barrier by barrier: it is not the text fast path).
    func testAHardBreakCellIsShownAndTypedInto() async throws {
        let capture = try XCTUnwrap(BlockNoteTableCaptures.edits.first { $0.name == "shiftEnter" })
        let seed = YDoc(clientID: 5, gc: true)
        try seed.applyUpdate(YUpdateDecoder.decode(try XCTUnwrap(Data(base64Encoded: capture.seed))))
        try seed.applyUpdate(YUpdateDecoder.decode(try XCTUnwrap(Data(base64Encoded: capture.update))))
        let state = try YStateEncoder.encodeStateAsUpdate(seed)
        seed.destroy()
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }
        let table = try await unwrapped(await harness.session.openTable("tbl"))
        addTeardownBlock { await table.close().value }
        let cell = table.surface.blocks[2]
        XCTAssertEqual(cell.runs.map(\.text).joined(), "Ada\nB")
        XCTAssertTrue(table.textView.textStorage.string.contains("Ada\u{2028}B"), "one paragraph, a line separator")
        let input = try XCTUnwrap(table.input)
        input.showCell([cell.id])
        setSelection(table, NSRange(location: try location(table, cell.id, 5), length: 0))
        table.textView.insertText("z")
        await table.settle()
        XCTAssertEqual(harness.log.commands.count, 1)
        XCTAssertEqual(table.surface.blocks[2].runs.map(\.text).joined(), "Ada\nBz")
        let written = await xml(harness)
        XCTAssertTrue(written.contains("<tableparagraph>Ada<hardbreak></hardbreak>Bz</tableparagraph>"), written)
        XCTAssertTrue(input.composition.pendingRecoveries.isEmpty, "a barrier, never a recovery entry")
        XCTAssertEqual(table.textView.selectedRange.location, try location(table, cell.id, 6), "the caret follows")
    }

    /// Shift-Return (PR11b): one hard break at the caret, then typing after it.
    func testShiftReturnInsertsAHardBreak() async throws {
        let (harness, table) = try await open()
        let input = try XCTUnwrap(table.input)
        input.tableMove = { _ in true }  // in a table editor
        input.showCell([ids(table)[6]])  // "Grace"
        setSelection(table, NSRange(location: try location(table, ids(table)[6], 2), length: 0))
        let broken = await table.run { input.insertLineBreak() }
        XCTAssertTrue(broken)
        table.textView.insertText("x")
        await table.settle()
        let written = await xml(harness)
        XCTAssertTrue(written.contains("<tableparagraph>Gr<hardbreak></hardbreak>xace</tableparagraph>"), written)
        XCTAssertEqual(table.surface.blocks[6].runs.map(\.text).joined(), "Gr\nxace")
        let shadow = await harness.session.replicaDoc { NativeBlockProjection.markdownShadow($0) }
        XCTAssertEqual(shadow??.contains("| Gr\\\nxace"), true)
        // Outside a table Shift-Return is not a hard break.
        XCTAssertFalse(harness.input.insertLineBreak())
        XCTAssertEqual(
            table.textView.keyCommands?.contains { $0.input == "\r" && $0.modifierFlags == .shift }, true,
            "Shift-Return is the cell's key command")
    }

    /// IME after a hard break (PR11b): the composition anchors in the
    /// paragraph's text part after the break and commits once there.
    func testCompositionAfterAHardBreakCommitsInTheRightPart() async throws {
        let (harness, table) = try await open()
        let input = try XCTUnwrap(table.input)
        input.tableMove = { _ in true }
        input.showCell([ids(table)[6]])  // "Grace"
        setSelection(table, NSRange(location: try location(table, ids(table)[6], 5), length: 0))
        let broken = await table.run { input.insertLineBreak() }
        XCTAssertTrue(broken)
        XCTAssertEqual(table.textView.selectedRange.location, try location(table, ids(table)[6], 6))
        table.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertTrue(input.composition.isActive, "the composition began after the break")
        table.textView.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
        table.textView.unmarkText()
        await table.settle()
        let written = await xml(harness)
        XCTAssertTrue(written.contains("<tableparagraph>Grace<hardbreak></hardbreak>日本</tableparagraph>"), written)
        XCTAssertEqual(table.surface.blocks[6].runs.map(\.text).joined(), "Grace\n日本")
    }

    func testAnUnfamiliarTableIsPreservedAndOpensReadOnly() async throws {
        // A mention in a cell: a node 11a does not read.
        let update = try peerUpdate("styled") { _, tx, table in
            let paragraph = try XCTUnwrap(self.element(table, [2, 1, 0]))
            let mention = YType(typeRef: .xmlElement(nodeName: "userMentionInline"))
            try YWrite.insertAfter(tx, into: paragraph, after: nil, [.type(mention)])
        }
        let doc = YDoc(clientID: 3, gc: true)
        try doc.applyUpdate(YUpdateDecoder.decode(try fixture("styled")))
        try doc.applyUpdate(YUpdateDecoder.decode(update))
        let state = try YStateEncoder.encodeStateAsUpdate(doc)
        let before = YXMLString.fragment(doc)
        doc.destroy()
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }
        XCTAssertFalse(harness.session.canType, "no shadow for an unfamiliar table: the document reads only")
        let opened = await harness.session.openTable("tbl")
        XCTAssertNil(opened, "an unfamiliar table is never a text target")
        let grid = await harness.session.tableGrid("tbl")
        XCTAssertEqual(grid?.familiarity, .unfamiliar("unexpected cell content"))
        let editor = try await editor(harness)
        XCTAssertNil(editor.cellSession, "the viewer")
        XCTAssertEqual(editor.cellViews.count, 9)
        let after = await xml(harness)
        XCTAssertEqual(after, before, "preserved")
    }

    func testTheReadOnlyReaderShowsTheGrid() async throws {
        let reader = try await NativeEditorSession.inspect(state: try fixture("merged"))
        addTeardownBlock { await reader.close().value }
        let grid = await reader.tableGrid("tbl")
        XCTAssertEqual(grid?.columnCount, 3)
        let editor = TableEditorViewController(document: reader, tableID: "tbl")
        // The grid realises the cells on screen (PR11c): give it one.
        editor.loadViewIfNeeded()
        editor.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        editor.view.layoutIfNeeded()
        await editor.load()
        for _ in 0..<300 where !editor.isLoaded { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(editor.cellSession)
        XCTAssertEqual(editor.cellViews.count, 7)
    }

    func testTheTableCardOpensTheEditor() async throws {
        let harness = try await makeHarness(state: try fixture("styled"))
        addTeardownBlock { await harness.close() }
        var opened: [String] = []
        harness.view.blockControls.onOpenTable = { opened.append($0) }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(harness.view)
        harness.view.frame = window.bounds
        window.isHidden = false
        windows.append(window)
        harness.view.layoutIfNeeded()
        let card = try XCTUnwrap(
            harness.view.blockControls.visibleAttachmentViews.first { $0.content.blockID == "tbl" })
        XCTAssertTrue(card.accessibilityTraits.contains(.button))
        XCTAssertTrue(card.accessibilityActivate())
        XCTAssertEqual(opened, ["tbl"])
        // Back from the table, the caret starts the block after it.
        harness.input.focus(after: "tbl")
        XCTAssertEqual(harness.view.selectedRange.location, try location(harness.session, "tail", 0))
    }

    // MARK: - Review fixes (PR #278)

    /// T2: a peer's structure change re-reads the grid and re-shows the same
    /// cell without selecting its text, so the next key does not replace it.
    func testAPeerStructureChangeKeepsTheCaretInTheActiveCell() async throws {
        let harness = try await makeHarness(state: try fixture("styled"))
        addTeardownBlock { await harness.close() }
        let editor = try await editor(harness)
        let table = try XCTUnwrap(editor.cellSession)
        editor.activate(TableGrid.CellRef(row: 1, index: 1))  // "Engineer"
        let caret = NSRange(location: try location(table, ids(table)[4], 3), length: 0)
        setSelection(table, caret)
        let update = try peerUpdate("styled") { _, tx, table in
            let cell = try XCTUnwrap(self.element(table, [2, 0]))
            try YWrite.mapSet(tx, on: cell, key: "backgroundColor", .any([.string("red")]))
        }
        try await harness.session.integrateServerState(update)
        await table.settle()
        for _ in 0..<300 where editor.grid?.rows[2][0].string("backgroundColor") != "red" {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(editor.grid?.rows[2][0].string("backgroundColor"), "red", "the grid was read again")
        XCTAssertEqual(editor.active, TableGrid.CellRef(row: 1, index: 1))
        XCTAssertEqual(table.textView.selectedRange, caret, "the caret stayed; the cell is not selected")
        table.textView.insertText("x")
        await table.settle()
        XCTAssertEqual(table.surface.blocks[4].runs.map(\.text).joined(), "Engxineer")
    }

    /// T3a: a merged cell (several paragraphs) is spelled in the shadow only
    /// while unstyled, so it takes no marks, and the document stays savable.
    /// PR11b lifts 11a's limit: a merged cell (several paragraphs) takes marks,
    /// and the shadow spells it as BlockNote reads it (`BlockNoteTableCommandOracleTests`).
    func testAMergedCellTakesMarksAndKeepsTheShadow() async throws {
        let harness = try await makeHarness(state: try fixture("merged"))
        addTeardownBlock { await harness.close() }
        let table = try await unwrapped(await harness.session.openTable("tbl"))
        addTeardownBlock { await table.close().value }
        let input = try XCTUnwrap(table.input)
        let de = [ids(table)[3], ids(table)[4]]  // "d", "e"
        XCTAssertEqual(de.map { try? block(table, $0).runs.map(\.text).joined() }, ["d", "e"])
        input.showCell(de)
        setSelection(table, NSRange(location: try location(table, de[0], 0), length: 1))
        let bolded = await table.run { input.toggleMark("bold") }
        XCTAssertTrue(bolded, "a merged cell takes marks")
        let written = await xml(harness)
        XCTAssertTrue(
            written.contains("<tableparagraph><bold>d</bold></tableparagraph><tableparagraph>e</tableparagraph>"))
        let shadow = await harness.session.replicaDoc { NativeBlockProjection.markdownShadow($0) }
        XCTAssertEqual(shadow??.contains("| **d**e "), true, "BlockNote concatenates differently styled paragraphs")
        XCTAssertEqual(harness.log.commands.count, 1)
    }

    /// T3b and T3c: no command nests a table or gives one children (the
    /// shadow spells only a childless root table): Tab under a table, a move
    /// into a sibling's children, a table pasted into nested content.
    func testNoCommandNestsATable() async throws {
        let harness = try await makeHarness(state: try fixture("styled"))
        addTeardownBlock { await harness.close() }
        let child = UUID().uuidString
        let outcomes = await harness.engine { engine -> [Bool] in
            func apply(_ id: String, _ kind: NativeEditCommand.Kind) -> Bool {
                (try? engine.applyStructural(
                    NativeEditCommand(id: UUID(), baseRevision: engine.revision, blockID: id, kind: kind),
                    persist: { _ in })) != nil
            }
            let tabUnderTable = apply("tail", .indent)
            // "lead" gets a child, so moving the table up would nest it there.
            let inserted = apply("lead", .insertBlock(newID: child, before: false))
            let nested = apply(child, .indent)
            let moveIntoChildren = apply("tbl", .moveUp)
            let payload = engine.subtreePayload(["tbl"]) ?? Data()
            let pasteNested = apply(child, .insertSubtrees(payload: payload))
            let pasteRoot = apply("tail", .insertSubtrees(payload: payload))
            return [tabUnderTable, inserted, nested, moveIntoChildren, pasteNested, pasteRoot]
        }
        XCTAssertEqual(outcomes, [false, true, true, false, false, true])
        let shadow = await harness.session.replicaDoc { NativeBlockProjection.markdownShadow($0) != nil }
        XCTAssertEqual(shadow, true, "the document keeps its shadow")
        // The coordinator's Tab is the same refusal: a quiet no-op.
        setSelection(harness.session, NSRange(location: try location(harness.session, "tail", 0), length: 0))
        let tabbed = await harness.run { harness.input.insertTab() }
        XCTAssertFalse(tabbed)
    }

    /// T4: a block whose id spells a cell paragraph id makes the document
    /// non-canonical (input refused, resets only), and the open table stops
    /// addressing cells; it never overwrites a real paragraph's entry.
    func testABlockIDSpellingACellParagraphIsRefused() async throws {
        let (harness, table) = try await open()
        let spoofed = ids(table)[4]
        let update = try peerUpdate("styled") { _, tx, table in
            let container = try XCTUnwrap(table.item?.parentType)
            let group = try XCTUnwrap(container.item?.parentType)
            let block = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            try YWrite.insertAfter(tx, into: group, after: container.item, [.type(block)])
            let paragraph = YType(typeRef: .xmlElement(nodeName: "paragraph"))
            try YWrite.insertAfter(tx, into: block, after: nil, [.type(paragraph)])
            try YWrite.mapSet(tx, on: block, key: "id", .any([.string(spoofed)]))
        }
        try await harness.session.integrateServerState(update)
        await table.settle()
        await harness.settle()
        let open = await harness.engine { engine -> Int in engine.tableParagraphs("tbl")?.count ?? -1 }
        XCTAssertEqual(open, 0, "no cell is addressed in a non-canonical document")
        XCTAssertTrue(table.surface.blocks.isEmpty, "the table surface dropped its paragraphs")
        let typed = await harness.engine { engine -> Bool in
            (try? engine.replaceText(
                NativeEditCommand(
                    id: UUID(), baseRevision: engine.revision, blockID: spoofed, range: 0..<0, replacement: "x"),
                persist: { _ in })) != nil
        }
        XCTAssertEqual(typed, false)
        let canonical = await harness.session.replicaDoc { doc -> Bool in
            BlockIndex(doc: doc).isCanonical
        }
        XCTAssertEqual(canonical, false)
    }

    // MARK: - Structure commands (PR11b)

    private func seed(_ name: String) throws -> Data {
        try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(BlockNoteTableOperationCaptures.seeds[name])))
    }

    private func capture(_ fixture: String, _ operation: String) throws -> BlockNoteTableOperationCaptures.Operation {
        try XCTUnwrap(
            BlockNoteTableOperationCaptures.operations.first { $0.fixture == fixture && $0.operation == operation })
    }

    /// The editor's menus run each command as one durable barrier: the web's
    /// XML, one journal entry, the grid re-read, the active cell kept, the
    /// shadow the export's, and the document typeable after a relaunch.
    func testTheMenusRunStructureCommandsDurablyAsTheWebDoes() async throws {
        let harness = try await makeHarness(state: try seed("plain"))
        addTeardownBlock { await harness.close() }
        let editor = try await editor(harness)
        let table = try XCTUnwrap(editor.cellSession)
        XCTAssertFalse(editor.controls.isHidden, "the Row, Column, Cell and Format menus show while editing")
        editor.activate(TableGrid.CellRef(row: 2, index: 1))  // "h"
        let kept = editor.grid?.cell(TableGrid.CellRef(row: 2, index: 1)).itemID
        let ran = await table.run { editor.perform(.addRow(row: 1, after: false)) }
        XCTAssertTrue(ran)
        for _ in 0..<300 where editor.grid?.rows.count != 4 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(editor.grid?.rows.count, 4)
        let written = await xml(harness)
        XCTAssertEqual(written, try capture("plain", "rowAbove1").xml)
        XCTAssertEqual(harness.log.commands.count, 1)
        XCTAssertEqual(table.surface.blocks.count, 12, "the new row's paragraphs reached the table surface")
        XCTAssertEqual(editor.active.flatMap { editor.grid?.cell($0).itemID }, kept, "the active cell stayed")
        let shadow = await harness.session.replicaDoc { NativeBlockProjection.markdownShadow($0) }
        XCTAssertEqual(shadow, try capture("plain", "rowAbove1").markdown)
        // Merge and split through the cell menu's commands.
        let merged = await table.run {
            editor.perform(.merge(from: TableSlot(row: 2, column: 0), to: TableSlot(row: 2, column: 1)))
        }
        XCTAssertTrue(merged)
        let split = await table.run { editor.perform(.split(TableSlot(row: 2, column: 0))) }
        XCTAssertTrue(split)
        let refused = await table.run { editor.perform(.split(TableSlot(row: 0, column: 0))) }
        XCTAssertFalse(refused, "a single cell does not split, as on the web")
        XCTAssertEqual(harness.log.commands.count, 3)
        try await assertConsistentTable(harness)
        // Relaunch: the structure is journaled.
        await editor.cellSession?.close().value
        await harness.session.close().value
        let restored = try await unwrapped(
            await NativeEditorSession.restore(store: harness.store, scope: harness.scope), "restored")
        addTeardownBlock { await restored.close().value }
        let rows = await restored.engine { $0.tableGrid("tbl")?.rows.count }
        XCTAssertEqual(rows, 4)
        XCTAssertTrue(restored.canType)
    }

    private func assertConsistentTable(_ harness: Harness, file: StaticString = #filePath, line: UInt = #line)
        async throws
    {
        let grid = await harness.engine { $0.tableGrid("tbl")?.familiarity }
        XCTAssertEqual(grid, .familiar, file: file, line: line)
        let shadow = await harness.session.replicaDoc { NativeBlockProjection.markdownShadow($0) != nil }
        XCTAssertEqual(shadow, true, "the document keeps its shadow", file: file, line: line)
        let failed = await harness.engine { $0.nativeWriteFailed }
        XCTAssertEqual(failed, false, file: file, line: line)
    }

    /// Undo of a structure command with a peer's edit in between: the row
    /// goes, the peer's text stays; redo brings the row back.
    func testUndoingAStructureCommandKeepsAPeersEdit() async throws {
        let harness = try await makeHarness(state: try seed("plain"))
        addTeardownBlock { await harness.close() }
        let editor = try await editor(harness)
        let table = try XCTUnwrap(editor.cellSession)
        let input = try XCTUnwrap(table.input)
        let added = await table.run { editor.perform(.addColumn(column: 2, after: true)) }
        XCTAssertTrue(added)
        let update = try peerUpdate("ops:plain") { _, _, table in
            let g = try XCTUnwrap(self.element(table, [2, 0, 0, 0]))
            try g.insert(1, "!", nil)
        }
        try await harness.session.integrateServerState(update)
        await table.settle()
        let undone = await table.run { input.undo() }
        XCTAssertTrue(undone)
        let grid = await harness.engine { $0.tableGrid("tbl") }
        XCTAssertEqual(grid?.columnCount, 3, "the column is gone")
        XCTAssertEqual(grid?.rows[2][0].runs.map(\.text).joined(), "g!", "the peer's text stayed")
        let redone = await table.run { input.redo() }
        XCTAssertTrue(redone)
        let again = await harness.engine { $0.tableGrid("tbl")?.columnCount }
        XCTAssertEqual(again, 4)
        try await assertConsistentTable(harness)
    }

    /// The colour, alignment and header menus rewrite the table from JSON on
    /// the web; natively a paragraph whose content does not change keeps its
    /// item, so a peer's concurrent typing in it is not lost.
    func testAColourChangeKeepsAPeersConcurrentTyping() async throws {
        let harness = try await makeHarness(state: try seed("plain"))
        addTeardownBlock { await harness.close() }
        let editor = try await editor(harness)
        let table = try XCTUnwrap(editor.cellSession)
        let peer = try peerUpdate("ops:plain") { _, _, table in
            let h = try XCTUnwrap(self.element(table, [2, 1, 0, 0]))
            try h.insert(1, "ello", nil)
        }
        let ran = await table.run {
            editor.perform(.setCellProp(key: "backgroundColor", value: "red", slots: [TableSlot(row: 2, column: 1)]))
        }
        XCTAssertTrue(ran)
        try await harness.session.integrateServerState(peer)
        await table.settle()
        let grid = await harness.engine { $0.tableGrid("tbl") }
        XCTAssertEqual(grid?.rows[2][1].string("backgroundColor"), "red")
        XCTAssertEqual(grid?.rows[2][1].runs.map(\.text).joined(), "hello", "the peer's typing survived")
        try await assertConsistentTable(harness)
    }

    /// A peer's concurrent structure change: our row insert and a web peer's
    /// column insert (with the web's own repair) converge to a familiar grid;
    /// a ragged grid in between (before any repair) keeps a shadow.
    func testConcurrentStructureChangesConverge() async throws {
        let harness = try await makeHarness(state: try seed("plain"))
        addTeardownBlock { await harness.close() }
        let editor = try await editor(harness)
        let table = try XCTUnwrap(editor.cellSession)
        // The peer adds a column (one cell per existing row), unaware of our row.
        let peer = try peerUpdate("ops:plain") { _, tx, table in
            for row in YBlockProjection.children(of: table, includeFormats: false) {
                guard case .type(let rowType) = row.content else { continue }
                let last = YBlockProjection.children(of: rowType, includeFormats: false).last
                let cell = YType(typeRef: .xmlElement(nodeName: "tableCell"))
                try YWrite.insertAfter(tx, into: rowType, after: last, [.type(cell)])
                try YWrite.insertAfter(
                    tx, into: cell, after: nil, [.type(YType(typeRef: .xmlElement(nodeName: "tableParagraph")))])
                for (key, value) in [("colspan", YAnyValue.int(1)), ("rowspan", .int(1))] {
                    try YWrite.mapSet(tx, on: cell, key: key, .any([value]))
                }
            }
        }
        let ran = await table.run { editor.perform(.addRow(row: 2, after: true)) }
        XCTAssertTrue(ran)
        try await harness.session.integrateServerState(peer)
        await table.settle()
        await harness.settle()
        // Our new row has 3 cells, the others 4: ragged, so read-only until repaired,
        // but the save still has a shadow (the repaired grid's).
        let ragged = await harness.engine { $0.tableGrid("tbl")?.familiarity }
        XCTAssertEqual(ragged, .unfamiliar("ragged rows"))
        let shadow = await harness.session.replicaDoc { NativeBlockProjection.markdownShadow($0) != nil }
        XCTAssertEqual(shadow, true, "no capture failure while the grid waits for its repair")
        let frozen = await harness.engine { $0.nativeWriteFailed }
        XCTAssertEqual(frozen, false)
        XCTAssertTrue(table.surface.blocks.isEmpty, "no cell is a text target while the grid is ragged")
        // Review: the editor's menus go with the familiar grid, and building
        // one on the uneven grid never indexes past its (empty) widths.
        for _ in 0..<300 where editor.grid?.isFamiliar != false { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(editor.grid?.isFamiliar, false)
        XCTAssertTrue(editor.controls.isHidden, "no structure menus on an uneven grid")
        for menu in ["row", "column", "cell", "format"] {
            XCTAssertTrue(editor.menuElements(menu).isEmpty || menu == "format", menu)
        }
    }

    func testDuplicatingATableKeepsItsCells() async throws {
        let harness = try await makeHarness(state: try fixture("styled"))
        addTeardownBlock { await harness.close() }
        let before = await xml(harness)
        let newID = UUID().uuidString
        let duplicated = await harness.engine { engine in
            (try? engine.applyStructural(
                NativeEditCommand(
                    id: UUID(), baseRevision: engine.revision, blockID: "tbl", kind: .duplicate(newIDs: [newID])),
                persist: { _ in })) != nil
        }
        XCTAssertEqual(duplicated, true)
        let after = await xml(harness)
        let tableXML = try XCTUnwrap(before.range(of: #"<table .*</table>"#, options: .regularExpression))
        XCTAssertEqual(after.components(separatedBy: String(before[tableXML])).count, 3, "two identical tables")
    }
}

extension TableEditorTests {
    fileprivate func setSelection(_ session: NativeEditorSession, _ range: NSRange) {
        session.textView.selectedRange = range
        session.input?.textViewDidChangeSelection(session.textView)
    }

}

// MARK: - PR11c: the 11a limits

extension TableEditorTests {
    /// The active cell's text view shows the cell's alignment, and follows a change to it.
    func testTheActiveCellEditsInItsAlignment() async throws {
        let harness = try await makeHarness(state: try seed("plain"))
        addTeardownBlock { await harness.close() }
        let editor = try await editor(harness)
        let table = try XCTUnwrap(editor.cellSession)
        let ref = TableGrid.CellRef(row: 1, index: 1)  // "e"
        editor.activate(ref)
        func alignment() throws -> NSTextAlignment? {
            let entry = try XCTUnwrap(table.surface.rangeIndex.entry(for: editor.paragraphIDs(ref)[0]))
            return (table.textView.textStorage.attribute(.paragraphStyle, at: entry.textRange.location, effectiveRange: nil)
                as? NSParagraphStyle)?.alignment
        }
        XCTAssertNotEqual(try alignment(), .center)
        let ran = await table.run {
            editor.perform(.setCellProp(key: "textAlignment", value: "center", slots: [TableSlot(row: 1, column: 1)]))
        }
        XCTAssertTrue(ran)
        for _ in 0..<300 where editor.grid?.cell(ref).string("textAlignment") != "center" {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try alignment(), .center, "the text view edits in the cell's alignment")
        let shown = await table.run {
            editor.perform(.setCellProp(key: "textAlignment", value: "right", slots: [TableSlot(row: 1, column: 1)]))
        }
        XCTAssertTrue(shown)
        XCTAssertEqual(try alignment(), .right)
        table.textView.insertText("!")
        await harness.settle()
        XCTAssertEqual(try alignment(), .right, "typing keeps it")
        try await assertConsistentTable(harness)
    }

    /// A peer's one transaction that types in a cell and colours another
    /// re-reads the grid (11a only did so for a structure-only change).
    func testAPeerTransactionChangingTextAndAColourReReadsTheGrid() async throws {
        let harness = try await makeHarness(state: try fixture("styled"))
        addTeardownBlock { await harness.close() }
        let editor = try await editor(harness)
        let table = try XCTUnwrap(editor.cellSession)
        let update = try peerUpdate("styled") { _, tx, table in
            let grace = try XCTUnwrap(self.element(table, [2, 0, 0, 0]))
            try grace.insert(5, " H", nil)
            let cell = try XCTUnwrap(self.element(table, [2, 0]))
            try YWrite.mapSet(tx, on: cell, key: "backgroundColor", .any([.string("red")]))
        }
        try await harness.session.integrateServerState(update)
        await table.settle()
        await harness.settle()
        let ref = TableGrid.CellRef(row: 2, index: 0)
        for _ in 0..<300 where editor.grid?.cell(ref).string("backgroundColor") != "red" {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(editor.grid?.cell(ref).string("backgroundColor"), "red", "the grid was read again")
        XCTAssertEqual(editor.cellViews[ref]?.backgroundColor, AttributedDocumentProjection.backgroundColor(named: "red"))
        XCTAssertEqual(editor.cellViews[ref]?.label.attributedText?.string, "Grace H")
    }

    /// A collaborator in another cell shows as a badge there (and to
    /// VoiceOver); in the cell being edited, as a caret in its text.
    func testACollaboratorsCursorShowsInTheTableEditor() async throws {
        let harness = try await makeHarness(state: try fixture("styled"))
        addTeardownBlock { await harness.close() }
        let awareness = NativeAwarenessController(replica: try XCTUnwrap(harness.session.replica))
        harness.session.showAwareness(awareness)
        let editor = try await editor(harness)
        let table = try XCTUnwrap(editor.cellSession)
        let ref = TableGrid.CellRef(row: 2, index: 0)  // "Grace"
        let id = editor.paragraphIDs(ref)[0]
        let position = try await unwrapped(
            harness.engine { $0.awarenessPosition(EditorPosition(blockID: id, offset: 2)) })
        awareness.receive([
            AwarenessEntry(
                clientID: 9, clock: 1,
                stateJSON: LocalAwarenessState(
                    name: "Web Peer", color: "#123456", cursor: AwarenessCursor(anchor: position, head: position)
                ).json(wireProtocol: .yWebSocket))
        ])
        for _ in 0..<300 where editor.peerMarks[ref] == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(editor.peerMarks[ref]?.map(\.name), ["Web Peer"])
        XCTAssertEqual(editor.cellViews[ref]?.peerLabel.isHidden, false, "a badge on their cell")
        let element = try XCTUnwrap(editor.gridView.element(ref))
        XCTAssertTrue((element.accessibilityValue ?? "").contains("Web Peer"), element.accessibilityValue ?? "")
        // In the active cell the overlay draws their caret instead.
        editor.activate(ref)
        XCTAssertNil(editor.peerMarks[ref])
        table.textView.setNeedsLayout()
        table.textView.layoutIfNeeded()
        XCTAssertFalse(table.textView.cursorOverlay.subviews.isEmpty, "their caret in the cell's text")
    }

    /// A composition dropped in a cell (its row deleted by a peer) becomes the
    /// document's recovery entry: shown by it, written to its recovery file.
    func testADroppedCellCompositionIsTheDocumentsRecoveryEntry() async throws {
        let (harness, table) = try await open()
        let input = try XCTUnwrap(table.input)
        input.showCell([ids(table)[3]])  // "Ada"
        setSelection(table, NSRange(location: try location(table, ids(table)[3], 3), length: 0))
        table.textView.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        XCTAssertTrue(input.composition.isActive)
        let update = try peerUpdate("styled") { _, tx, table in
            let row = try XCTUnwrap(YBlockProjection.children(of: table, includeFormats: false)[safe: 1])
            row.delete(tx)
        }
        try await harness.session.integrateServerState(update)
        table.textView.unmarkText()
        await table.settle()
        await harness.settle()
        XCTAssertEqual(harness.log.commands.count, 0, "never redirected")
        let pending = harness.session.input?.composition.pendingRecoveries.map(\.text) ?? []
        XCTAssertTrue(pending.contains("にほん"), "the document lists it: \(pending)")
        let stored = harness.store.provisionalRecoveries(for: harness.scope).map(\.text)
        XCTAssertTrue(stored.contains("にほん"), "written to the recovery file: \(stored)")
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
