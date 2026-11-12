import UIKit
import XCTest

@testable import Schrift

/// PR12a: the native column editor over a durable replica. A column surface
/// (`NativeEditorSession.openColumn`) types into a web-authored group's
/// column through the document's own machinery (prediction, journal,
/// structure, marks, IME, undo), never shows the document a column's block,
/// refuses every move across a column's edge, and preserves everything it
/// does not edit.
@MainActor
final class ColumnEditorTests: NativeEditingTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows { window.isHidden = true }
        windows = []
        try await super.tearDown()
    }

    private func fixture(_ name: String) throws -> Data {
        let base64 =
            BlockNoteColumnCaptures.fixtures.first { $0.name == name }?.update
            ?? BlockNoteColumnCaptures.edits.first { $0.name == name }?.seed
        return try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(base64, name)))
    }

    /// Column `column` of the fixture's group "cl" in a typing harness, shown in a window.
    private func open(_ name: String = "two", column: String = "c1") async throws -> (Harness, NativeEditorSession) {
        let harness = try await makeHarness(state: try fixture(name))
        addTeardownBlock { await harness.close() }
        XCTAssertTrue(harness.session.canType, "a document with a familiar group types")
        let session = try await columnSession(harness, column)
        return (harness, session)
    }

    private func columnSession(_ harness: Harness, _ column: String) async throws -> NativeEditorSession {
        let session = try await unwrapped(
            await harness.session.openColumn(group: "cl", column: column), "the column opens")
        addTeardownBlock { await session.close().value }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.addSubview(session.textView)
        session.textView.frame = window.bounds
        window.isHidden = false
        windows.append(window)
        return session
    }

    private func xml(_ harness: Harness) async -> String {
        await harness.session.replicaDoc { YXMLString.fragment($0) } ?? ""
    }

    private static let columnIDs: Set<String> = ["a", "b", "b2", "c", "d", "1"]

    /// Whether the document surface was ever shown a column's block or a reset.
    private func sawColumnBlocks(_ log: PatchLog) -> Bool {
        log.patches.flatMap(\.changes).contains { change in
            switch change {
            case .text(let id, _), .props(let id, _), .replaceBlock(let id, _): Self.columnIDs.contains(id)
            case .remove(let ids): ids.contains(where: Self.columnIDs.contains)
            case .insert(_, let blocks): blocks.contains { Self.columnIDs.contains($0.id) }
            case .reset: true
            }
        }
    }

    // MARK: - Typing

    func testTypingInAColumnIsPredictedJournaledAndNeverShownToTheDocument() async throws {
        let (harness, column) = try await open()
        let documentLog = PatchLog(harness.session)
        XCTAssertEqual(column.surface.blocks.map(\.id), ["a", "b", "b2"])
        XCTAssertEqual(column.surface.blocks.map(\.depth), [0, 0, 1])
        XCTAssertTrue(column.textView.isEditable)
        setSelection(column, NSRange(location: try location(column, "a", 9), length: 0))
        for key in [" ", "I", "I"] { column.textView.insertText(key) }
        XCTAssertEqual(column.surface.blocks[0].runs.map(\.text).joined(), "Left text II", "shown at once")
        await column.settle()
        await harness.settle()
        XCTAssertEqual(harness.log.commands.count, 3, "one journaled command per key")
        XCTAssertTrue(harness.log.commands.allSatisfy { $0.blockID == "a" })
        XCTAssertFalse(sawColumnBlocks(documentLog), "the document never saw a column's block")
        XCTAssertFalse(
            documentLog.patches.flatMap(\.changes).contains {
                if case .replaceBlock("cl", _) = $0 { true } else { false }
            },
            "nor a group preview per key")
        // Closing the column refreshes the document's preview once.
        await column.close().value
        await harness.settle()
        guard case .columns(let lines, let count)? = try block(harness.session, "cl").preview else {
            return XCTFail("still a column preview")
        }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(lines[0].first?.text, "Left text II")
        try await assertConsistent(harness, localCommands: 3)
        let expected = try XCTUnwrap(BlockNoteColumnCaptures.fixtures.first { $0.name == "two" }).xml
            .replacingOccurrences(of: ">Left text<", with: ">Left text II<")
        let written = await xml(harness)
        XCTAssertEqual(written, expected, "everything but the typed text is as the web wrote it")
    }

    func testReturnAndBackspaceStayInTheColumn() async throws {
        let (harness, column) = try await open()
        // Return at the end of the column's first block: a new block in the column.
        setSelection(column, NSRange(location: try location(column, "a", 9), length: 0))
        column.textView.insertText("\n")
        await column.settle()
        XCTAssertEqual(column.surface.blocks.count, 4)
        column.textView.insertText("x")
        await column.settle()
        await harness.settle()
        let newID = column.surface.blocks[1].id
        XCTAssertEqual(column.surface.blocks[1].runs.map(\.text).joined(), "x")
        var written = await xml(harness)
        XCTAssertTrue(
            written.contains(
                "<column id=\"c1\" width=\"1\"><blockcontainer id=\"a\"><paragraph backgroundColor=\"default\" textAlignment=\"left\" textColor=\"default\">Left text</paragraph></blockcontainer><blockcontainer id=\"\(newID)\"><paragraph backgroundColor=\"default\" textAlignment=\"left\" textColor=\"default\">x</paragraph></blockcontainer>"
            ), written)
        // Backspace at the new block's start joins it back.
        setSelection(column, NSRange(location: try location(column, newID, 0), length: 0))
        column.textView.deleteBackward()
        await column.settle()
        await harness.settle()
        XCTAssertEqual(column.surface.blocks.map(\.id), ["a", "b", "b2"])
        XCTAssertEqual(column.surface.blocks[0].runs.map(\.text).joined(), "Left textx")
        // Backspace at the column's first block writes nothing (PR12b moves it).
        let commands = harness.log.commands.count
        setSelection(column, NSRange(location: try location(column, "a", 0), length: 0))
        column.textView.deleteBackward()
        await column.settle()
        await harness.settle()
        XCTAssertEqual(harness.log.commands.count, commands)
        written = await xml(harness)
        XCTAssertTrue(written.contains("<columnlist id=\"cl\"><column id=\"c1\""), "the group is where it was")
        try await assertConsistent(harness, localCommands: commands)
    }

    func testTabNestsInsideTheColumn() async throws {
        let (harness, column) = try await open("typeMiddle")
        setSelection(column, NSRange(location: try location(column, "b", 1), length: 0))
        column.textView.insertText("\t")
        await column.settle()
        await harness.settle()
        XCTAssertEqual(column.surface.blocks.map(\.depth), [0, 1])
        XCTAssertEqual(column.surface.blocks[1].parentID, "a")
        let capture = try XCTUnwrap(BlockNoteColumnCaptures.edits.first { $0.name == "tabNest" })
        let written = await xml(harness)
        XCTAssertEqual(written, capture.xml)
    }

    func testCompositionInAColumnCommitsOnce() async throws {
        let (harness, column) = try await open()
        let input = try XCTUnwrap(column.input)
        setSelection(column, NSRange(location: try location(column, "a", 4), length: 0))
        column.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        column.textView.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertTrue(input.composition.isActive)
        column.textView.unmarkText()
        await column.settle()
        await harness.settle()
        XCTAssertEqual(harness.log.commands.count, 1, "the commit is one command")
        XCTAssertEqual(column.surface.blocks[0].runs.map(\.text).joined(), "Left日本 text")
        let written = await xml(harness)
        XCTAssertTrue(written.contains(">Left日本 text<"), written)
    }

    func testUndoAndRedoInAColumn() async throws {
        let (harness, column) = try await open()
        let input = try XCTUnwrap(column.input)
        setSelection(column, NSRange(location: try location(column, "a", 9), length: 0))
        column.textView.insertText("s")
        await column.settle()
        let undone = await column.run { input.undo() }
        XCTAssertTrue(undone)
        XCTAssertEqual(column.surface.blocks[0].runs.map(\.text).joined(), "Left text")
        let redone = await column.run { input.redo() }
        XCTAssertTrue(redone)
        XCTAssertEqual(column.surface.blocks[0].runs.map(\.text).joined(), "Left texts")
        await harness.settle()
        let written = await xml(harness)
        XCTAssertTrue(written.contains(">Left texts<"))
    }

    func testColumnTextSurvivesRelaunchOffline() async throws {
        let (harness, column) = try await open()
        setSelection(column, NSRange(location: try location(column, "b2", 6), length: 0))
        column.textView.insertText("!")
        await column.settle()
        await column.close().value
        await harness.session.close().value
        let restored = try await unwrapped(
            await NativeEditorSession.restore(store: harness.store, scope: harness.scope), "restored")
        addTeardownBlock { await restored.close().value }
        let reopened = try await unwrapped(await restored.openColumn(group: "cl", column: "c1"))
        addTeardownBlock { await reopened.close().value }
        XCTAssertEqual(reopened.surface.blocks[2].runs.map(\.text).joined(), "nested!")
    }

    /// A save the coordinator cannot capture freezes the document's authoring;
    /// its columns share the journal, so they stop too.
    func testAFrozenDocumentFreezesItsColumns() async throws {
        let (harness, column) = try await open()
        harness.session.freezeAuthoring()
        setSelection(column, NSRange(location: try location(column, "a", 9), length: 0))
        column.textView.insertText("x")
        await column.settle()
        await harness.settle()
        XCTAssertTrue(harness.log.commands.isEmpty, "nothing more is journaled")
        let written = await xml(harness)
        XCTAssertTrue(written.contains(">Left text<"))
    }

    // MARK: - Peers

    /// A peer's update from the same seed: `body` edits the peer's copy of the group.
    private func peerUpdate(_ name: String, _ body: (YTransaction, YType) throws -> Void) throws -> Data {
        let peer = YDoc(clientID: 77, gc: true)
        defer { peer.destroy() }
        try peer.applyUpdate(YUpdateDecoder.decode(try fixture(name)))
        let before = YStateEncoder.encodeStateVector(peer)
        let root = try XCTUnwrap(peer.share[BlockNoteYjs.fragmentField])
        guard case .type(let group)? = YBlockProjection.children(of: root, includeFormats: false).first?.content
        else { throw XCTSkip("no root group") }
        let list = try XCTUnwrap(
            YBlockProjection.children(of: group, includeFormats: false).compactMap { item -> YType? in
                guard case .type(let type) = item.content, type.typeRef == .xmlElement(nodeName: "columnList") else {
                    return nil
                }
                return type
            }.first)
        try peer.transact { tx in try body(tx, list) }
        let vector = try YUpdateDecoder.decodeStateVector(before)
        return try YStateEncoder.encodeStateAsUpdate(
            peer, since: Dictionary(vector.map { ($0.client, $0.clock) }, uniquingKeysWith: { $1 }))
    }

    /// The text of block `path` (column, container) under `list`.
    private func text(_ list: YType, column: Int, block: Int) throws -> YType {
        var current = list
        for index in [column, block, 0, 0] {
            guard
                case .type(let child)? = YBlockProjection.children(of: current, includeFormats: false)[safe: index]?
                    .content
            else { throw XCTSkip("no such element") }
            current = child
        }
        return current
    }

    func testPeerEditsReachTheirColumnsAndNeverTheDocument() async throws {
        let (harness, first) = try await open()
        let second = try await columnSession(harness, "c2")
        let documentLog = PatchLog(harness.session)
        setSelection(first, NSRange(location: try location(first, "a", 9), length: 0))
        first.textView.insertText("!")
        let update = try peerUpdate("two") { _, list in
            try self.text(list, column: 0, block: 0).insert(0, "Dr ", nil)
            try self.text(list, column: 1, block: 0).insert(5, " side", nil)
        }
        try await harness.session.integrateServerState(update)
        await first.settle()
        await second.settle()
        await harness.settle()
        XCTAssertEqual(first.surface.blocks[0].runs.map(\.text).joined(), "Dr Left text!")
        XCTAssertEqual(second.surface.blocks[0].runs.map(\.text).joined(), "Right side")
        XCTAssertFalse(sawColumnBlocks(documentLog))
        XCTAssertTrue(first.input?.composition.pendingRecoveries.isEmpty ?? false)
    }

    func testAPeerAddingABlockToTheColumnInsertsItThere() async throws {
        let (harness, column) = try await open()
        let update = try peerUpdate("two") { tx, list in
            guard case .type(let c1)? = YBlockProjection.children(of: list, includeFormats: false).first?.content
            else { throw XCTSkip("no column") }
            let container = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            try YWrite.insertAfter(tx, into: c1, after: nil, [.type(container)])
            let paragraph = YType(typeRef: .xmlElement(nodeName: "paragraph"))
            try YWrite.insertAfter(tx, into: container, after: nil, [.type(paragraph)])
            let text = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: paragraph, after: nil, [.type(text)])
            try text.insert(0, "peer", nil)
            try YWrite.mapSet(tx, on: container, key: "id", .any([.string("p1")]))
        }
        try await harness.session.integrateServerState(update)
        await column.settle()
        XCTAssertEqual(column.surface.blocks.map(\.id), ["p1", "a", "b", "b2"])
        XCTAssertEqual(column.surface.blocks[0].runs.map(\.text).joined(), "peer")
        // The document's shadow spells the peer's block in its column.
        let shadow = await harness.session.replicaDoc { NativeBlockProjection.markdownShadow($0) } ?? nil
        XCTAssertEqual(shadow?.hasPrefix("Before\n\npeer\n\nLeft text"), true, shadow ?? "nil")
    }

    // MARK: - The editor

    func testSwitchingColumnsKeepsTheKeyboardAndHidesTheOtherColumn() async throws {
        let harness = try await makeHarness(state: try fixture("two"))
        addTeardownBlock { await harness.close() }
        let model = ColumnEditorModel(document: harness.session, groupID: "cl")
        await model.load()
        addTeardownBlock { model.close() }
        XCTAssertEqual(model.columns.count, 2)
        XCTAssertEqual(model.group?.columns.map(\.id), ["c1", "c2"])
        let container = ColumnTextContainer(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        window.addSubview(container)
        window.makeKeyAndVisible()
        windows.append(window)
        let views = model.columns.map(\.textView)
        guard views.count == 2 else { return XCTFail("both columns attached") }
        container.show(views, active: 0)
        XCTAssertFalse(views[0].isHidden)
        XCTAssertTrue(views[1].isHidden)
        let focused = views[0].isFirstResponder
        model.active = 1
        container.show(views, active: model.active)
        XCTAssertFalse(views[1].isHidden)
        XCTAssertTrue(views[0].isHidden)
        if focused { XCTAssertTrue(views[1].isFirstResponder, "first responder moved with the column") }
        model.active = 5
        XCTAssertEqual(model.active, 1, "no column past the group's")
        // Escape closes the editor and every column surface.
        var closed = false
        model.onClose = { closed = true }
        model.columns[1].input?.onExit?()
        XCTAssertTrue(closed)
        XCTAssertTrue(model.columns.isEmpty)
    }

    /// The screen's `.task` running again (a table editor's cover dismissed over
    /// it, here a remove and re-add) never attaches the columns twice: the
    /// presenter's model loads once.
    func testTheScreenAttachesEachColumnOnceWhenItReappears() async throws {
        let harness = try await makeHarness(state: try fixture("two"))
        addTeardownBlock { await harness.close() }
        let model = ColumnEditorModel(document: harness.session, groupID: "cl")
        addTeardownBlock { model.close() }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let host = UIHostingController(
            rootView: ColumnEditorScreen(model: model, serverOrigin: "https://example.invalid")
                .environment(LocalizationStore(userDefaults: defaults)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = host
        window.isHidden = false
        windows.append(window)
        func columnViews() -> [UIView] {
            var found: [UIView] = []
            func walk(_ view: UIView) {
                if view.accessibilityIdentifier?.hasPrefix("nativeEditor.column.") == true { found.append(view) }
                view.subviews.forEach(walk)
            }
            walk(host.view)
            return found
        }
        for _ in 0..<500 where !(model.isLoaded && columnViews().count == 2) { await Task.yield() }
        XCTAssertEqual(columnViews().count, 2)
        let sessions = model.columns.map(ObjectIdentifier.init)
        host.view.removeFromSuperview()
        for _ in 0..<50 { await Task.yield() }
        window.addSubview(host.view)
        for _ in 0..<200 { await Task.yield() }
        XCTAssertEqual(columnViews().count, 2, "one text view per column")
        XCTAssertEqual(model.columns.map(ObjectIdentifier.init), sessions, "the same surfaces")
        XCTAssertFalse(model.isClosed)
    }

    func testATableInAColumnOpensTheTableEditorAndTypes() async throws {
        let (harness, column) = try await open("table")
        XCTAssertEqual(column.surface.blocks.map(\.id), ["x", "tbl"])
        let table = try await unwrapped(await column.openTable("tbl"), "the table in the column opens")
        addTeardownBlock { await table.close().value }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.addSubview(table.textView)
        table.textView.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        window.isHidden = false
        windows.append(window)
        let ids = table.surface.blocks.map(\.id)
        XCTAssertEqual(ids.count, 4)
        table.input?.showCell([ids[0]])
        setSelection(table, NSRange(location: try location(table, ids[0], 1), length: 0))
        table.textView.insertText("Z")
        await table.settle()
        await harness.settle()
        let written = await xml(harness)
        XCTAssertTrue(written.contains("<tableparagraph>AZ</tableparagraph>"), written)
        // Closing the table refreshes the column's card, not the document's.
        await table.close().value
        await column.settle()
        guard case .table(let cells, _, _)? = try block(column, "tbl").preview else {
            return XCTFail("the column shows the table's card")
        }
        XCTAssertEqual(cells[0][0], "AZ")
    }

    func testAReaderShowsColumnsReadOnly() async throws {
        let reader = try await NativeEditorSession.inspect(state: try fixture("two"))
        let column = try await unwrapped(await reader.openColumn(group: "cl", column: "c2"))
        XCTAssertEqual(column.surface.blocks.map(\.id), ["c", "d"])
        XCTAssertFalse(column.textView.isEditable)
        XCTAssertNil(column.input)
        let group = await reader.columnGroup("cl")
        XCTAssertEqual(group?.columns.count, 2)
    }

    /// A group of one column (the transient shape `fixLayoutBlocks` repairs on
    /// the web) is unfamiliar: preserved, not opened, and the document stays
    /// read-only.
    func testAnUnfamiliarGroupIsPreservedAndDoesNotOpen() async throws {
        let seed = YDoc(clientID: 5, gc: true)
        try seed.applyUpdate(YUpdateDecoder.decode(try fixture("two")))
        let root = try XCTUnwrap(seed.share[BlockNoteYjs.fragmentField])
        guard case .type(let group)? = YBlockProjection.children(of: root, includeFormats: false).first?.content,
            case .type(let list)? = YBlockProjection.children(of: group, includeFormats: false)[safe: 1]?.content
        else { return XCTFail("no group") }
        try seed.transact { tx in
            YBlockProjection.children(of: list, includeFormats: false)[1].delete(tx)
        }
        let state = try YStateEncoder.encodeStateAsUpdate(seed)
        let xml = YXMLString.fragment(seed)
        seed.destroy()
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }
        XCTAssertFalse(harness.session.canType)
        let column = await harness.session.openColumn(group: "cl", column: "c1")
        XCTAssertNil(column)
        let model = ColumnEditorModel(document: harness.session, groupID: "cl")
        await model.load()
        XCTAssertTrue(model.columns.isEmpty)
        let written = await self.xml(harness)
        XCTAssertEqual(written, xml, "preserved as written")
    }

    func testTheDocumentTypesAroundAGroup() async throws {
        let harness = try await makeHarness(state: try fixture("two"))
        addTeardownBlock { await harness.close() }
        XCTAssertTrue(harness.session.canType)
        XCTAssertEqual(harness.session.surface.blocks.map(\.id), ["lead", "cl", "tail"])
        setSelection(harness, NSRange(location: try location(harness.session, "lead", 6), length: 0))
        harness.view.insertText("!")
        await harness.settle()
        // Backspace at the start of the block after the group writes nothing
        // (the web moves it into the last column: PR12b).
        setSelection(harness, NSRange(location: try location(harness.session, "tail", 0), length: 0))
        harness.view.deleteBackward()
        await harness.settle()
        try await assertConsistent(harness, localCommands: 1)
        let written = await xml(harness)
        XCTAssertTrue(written.contains(">Before!<"))
        XCTAssertTrue(
            written.hasSuffix(
                "<blockcontainer id=\"tail\"><paragraph backgroundColor=\"default\" textAlignment=\"left\" textColor=\"default\">After</paragraph></blockcontainer></blockgroup>"
            ))
    }
}

extension ColumnEditorTests {
    fileprivate func setSelection(_ session: NativeEditorSession, _ range: NSRange) {
        session.textView.selectedRange = range
        session.input?.textViewDidChangeSelection(session.textView)
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
