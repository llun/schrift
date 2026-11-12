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

    private func fixture(_ name: String) throws -> Data {
        try XCTUnwrap(
            Data(base64Encoded: try XCTUnwrap(BlockNoteTableCaptures.fixtures.first { $0.name == name }).update))
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

    func testAHardBreakCellIsShownButNotTypedInto() async throws {
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
        setSelection(table, NSRange(location: try location(table, cell.id, 1), length: 0))
        table.textView.insertText("z")
        await table.settle()
        XCTAssertEqual(harness.log.commands.count, 0)
        XCTAssertEqual(input.noticeKey, .native_editor_input_unavailable)
        XCTAssertTrue(input.composition.pendingRecoveries.isEmpty, "refused, never a recovery entry")
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
    func testAMergedCellTakesNoMarks() async throws {
        let harness = try await makeHarness(state: try fixture("merged"))
        addTeardownBlock { await harness.close() }
        let table = try await unwrapped(await harness.session.openTable("tbl"))
        addTeardownBlock { await table.close().value }
        let input = try XCTUnwrap(table.input)
        let de = [ids(table)[3], ids(table)[4]]  // "d", "e"
        XCTAssertEqual(de.map { try? block(table, $0).runs.map(\.text).joined() }, ["d", "e"])
        input.showCell(de)
        setSelection(table, NSRange(location: try location(table, de[0], 0), length: 1))
        XCTAssertFalse(input.toggleMark("bold"), "no marks in a merged cell")
        setSelection(table, NSRange(location: try location(table, de[0], 1), length: 0))
        XCTAssertFalse(input.toggleMark("italic"), "no pending marks either")
        let refused = await harness.engine { engine -> Bool in
            let mark = NativeEditCommand(
                id: UUID(), baseRevision: engine.revision, blockID: de[0],
                kind: .marks(
                    NativeMarkCommand(
                        startOffset: 0, endBlockID: de[0], endOffset: 1,
                        attributes: [TextMark(key: "bold", valueJSON: "{}")])))
            let typed = NativeEditCommand(
                id: UUID(), baseRevision: engine.revision, blockID: de[0], range: 1..<1, replacement: "x",
                marks: [TextMark(key: "bold", valueJSON: "{}")])
            return !engine.canApplyStructural(mark) && (try? engine.replaceText(typed, persist: { _ in })) == nil
        }
        XCTAssertEqual(refused, true, "the engine refuses both")
        XCTAssertEqual(harness.log.commands.count, 0)
        let shadow = await harness.session.replicaDoc { NativeBlockProjection.markdownShadow($0) != nil }
        XCTAssertEqual(shadow, true)
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

extension Array {
    fileprivate subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
