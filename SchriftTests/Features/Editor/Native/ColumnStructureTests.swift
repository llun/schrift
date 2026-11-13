import UIKit
import XCTest

@testable import Schrift

/// PR12b in real sessions: the column editor's menu changes the group as the
/// web does and follows the result; a peer's added, removed or dissolved
/// column, a block moved out and a group that turns unfamiliar reach the open
/// editor without a reopen; the slash menu's Columns items and moves across a
/// column's edge are one journaled command each.
@MainActor
final class ColumnStructureTests: NativeEditingTestCase {
    private func seed(_ name: String) throws -> Data {
        let capture = try XCTUnwrap(BlockNoteColumnStructureCaptures.edits.first { $0.name == name }, name)
        return try XCTUnwrap(Data(base64Encoded: capture.seed))
    }

    private func xml(_ harness: Harness) async -> String {
        await harness.session.replicaDoc { YXMLString.fragment($0) } ?? ""
    }

    /// The column editor's model over seed `name`, loaded.
    private func editor(_ name: String = "addColumnRight") async throws -> (Harness, ColumnEditorModel) {
        let harness = try await makeHarness(state: try seed(name))
        addTeardownBlock { await harness.close() }
        XCTAssertTrue(harness.session.canType)
        let model = ColumnEditorModel(document: harness.session, groupID: "cl")
        addTeardownBlock { model.close() }
        await model.load()
        XCTAssertEqual(model.columns.count, model.group?.columns.count)
        return (harness, model)
    }

    private func columnIDs(_ model: ColumnEditorModel) -> [String] { model.columns.compactMap { $0.column?.id } }

    /// A peer's update from seed `name`: `body` edits the peer's group.
    private func peerUpdate(_ name: String, _ body: (YTransaction, YType, YType, BlockNoteWriter) throws -> Void)
        throws -> Data
    {
        let peer = YDoc(clientID: 77, gc: true)
        defer { peer.destroy() }
        try peer.applyUpdate(YUpdateDecoder.decode(try seed(name)))
        let before = YStateEncoder.encodeStateVector(peer)
        let root = try XCTUnwrap(peer.share[BlockNoteYjs.fragmentField])
        guard case .type(let group)? = YBlockProjection.children(of: root, includeFormats: false).first?.content,
            let list = YBlockProjection.children(of: group, includeFormats: false).compactMap({ item -> YType? in
                guard case .type(let type) = item.content, type.typeRef == .xmlElement(nodeName: "columnList") else {
                    return nil
                }
                return type
            }).first
        else { throw XCTSkip("no group") }
        let writer = BlockNoteWriter(doc: peer, schemas: BlockNoteWriter.nativePropSchemas)
        try peer.transact { tx in try body(tx, group, list, writer) }
        let vector = try YUpdateDecoder.decodeStateVector(before)
        return try YStateEncoder.encodeStateAsUpdate(
            peer, since: Dictionary(vector.map { ($0.client, $0.clock) }, uniquingKeysWith: { $1 }))
    }

    // MARK: - The column menu

    func testTheMenuAddsMovesResizesAndRemovesColumnsAndTheEditorFollows() async throws {
        let (harness, model) = try await editor()
        XCTAssertEqual(columnIDs(model), ["c1", "c2"])
        // Add a column right of the first: three columns, the first still shown.
        XCTAssertTrue(model.perform(.addRight))
        await waitUntil { model.columns.count == 3 }
        XCTAssertEqual(model.active, 0)
        XCTAssertEqual(columnIDs(model).first, "c1")
        XCTAssertEqual(columnIDs(model).last, "c2")
        XCTAssertEqual(model.columns[1].surface.blocks.count, 1, "one empty paragraph")
        // Move the shown column right: it stays shown.
        XCTAssertTrue(model.perform(.moveRight))
        await waitUntil { self.columnIDs(model)[1] == "c1" }
        XCTAssertEqual(model.active, 1)
        // Wider: the handle beside it moves by a quarter column.
        XCTAssertTrue(model.perform(.wider))
        await waitUntil { model.group?.columns[1].width == 1.25 }
        XCTAssertEqual(model.group?.columns.map { $0.width ?? 1 }, [1, 1.25, 0.75])
        // Narrower twice: clamped at the web's 0.5 minimum, then unavailable.
        XCTAssertTrue(model.perform(.narrower))
        await waitUntil { model.group?.columns[1].width == 1 }
        XCTAssertTrue(model.perform(.narrower))
        await waitUntil { model.group?.columns[1].width == 0.75 }
        XCTAssertTrue(model.perform(.narrower))
        await waitUntil { model.group?.columns[1].width == 0.5 }
        XCTAssertNil(model.command(.narrower), "the minimum")
        // Delete the shown column: two left, a neighbour shown.
        XCTAssertTrue(model.perform(.delete))
        await waitUntil { model.columns.count == 2 }
        XCTAssertFalse(columnIDs(model).contains("c1"))
        XCTAssertTrue(model.columns.indices.contains(model.active))
        // Delete one of two: the group dissolves and the editor closes.
        var closed = false
        model.onClose = { closed = true }
        model.active = 0
        XCTAssertTrue(model.perform(.delete))
        await waitUntil { closed }
        await harness.settle()
        XCTAssertFalse(harness.session.surface.blocks.contains { $0.id == "cl" }, "the group dissolved")
        XCTAssertTrue(harness.session.surface.blocks.contains { $0.id == "c" }, "into the other column's blocks")
        try await assertConsistent(harness, localCommands: 8)
    }

    // MARK: - Peers

    func testAPeersNewColumnShowsWithoutReopening() async throws {
        let (harness, model) = try await editor()
        let update = try peerUpdate("addColumnRight") { tx, _, list, writer in
            try writer.insertCopy(
                tx, writer.emptyColumn("p1", paragraph: "pp"), into: list,
                after: YBlockProjection.children(of: list, includeFormats: false).last)
        }
        try await harness.session.integrateServerState(update)
        await waitUntil { model.columns.count == 3 }
        XCTAssertEqual(columnIDs(model), ["c1", "c2", "p1"])
        XCTAssertEqual(model.columns[2].surface.blocks.map(\.id), ["pp"])
        XCTAssertEqual(model.columns[2].textView.accessibilityIdentifier, "nativeEditor.column.2")
    }

    func testAPeerDeletingTheShownColumnMovesTheEditorToAnother() async throws {
        let (harness, model) = try await editor("removeColumnOfThree")
        model.active = 1
        let update = try peerUpdate("removeColumnOfThree") { tx, _, list, _ in
            YBlockProjection.children(of: list, includeFormats: false)[1].delete(tx)
        }
        try await harness.session.integrateServerState(update)
        await waitUntil { model.columns.count == 2 }
        XCTAssertEqual(columnIDs(model), ["c1", "c3"])
        XCTAssertEqual(model.active, 1, "the next column is shown")
    }

    func testAPeerDissolvingTheGroupClosesTheEditor() async throws {
        let (harness, model) = try await editor()
        var closed = false
        model.onClose = { closed = true }
        // The web's `fixLayoutBlock`: the group replaced by one column's blocks.
        let update = try peerUpdate("addColumnRight") { tx, group, list, writer in
            guard case .type(let first) = YBlockProjection.children(of: list, includeFormats: false)[0].content,
                let listItem = list.item
            else { return }
            var left: YItem = listItem
            for block in YBlockProjection.children(of: first, includeFormats: false) {
                guard case .type(let container) = block.content else { continue }
                left = try writer.insertCopy(
                    tx, try writer.snapshot(container, block: "x", depth: 0), into: group, after: left)
            }
            listItem.delete(tx)
        }
        try await harness.session.integrateServerState(update)
        await waitUntil { closed }
        await harness.settle()
        XCTAssertEqual(harness.session.surface.blocks.map(\.id), ["lead", "a", "b", "tail"])
    }

    func testAGroupTurningUnfamiliarClosesTheEditorAndStaysPreserved() async throws {
        let (harness, model) = try await editor()
        var closed = false
        model.onClose = { closed = true }
        // An empty column: the transient shape the web repairs.
        let update = try peerUpdate("addColumnRight") { tx, _, list, _ in
            guard case .type(let second) = YBlockProjection.children(of: list, includeFormats: false)[1].content else {
                return
            }
            for block in YBlockProjection.children(of: second, includeFormats: false) { block.delete(tx) }
        }
        try await harness.session.integrateServerState(update)
        await waitUntil { closed }
        await harness.settle()
        XCTAssertTrue(harness.session.surface.blocks.contains { $0.id == "cl" }, "the card stays")
        let written = await xml(harness)
        XCTAssertTrue(written.contains("<column id=\"c2\" width=\"1\"></column>"), written)
    }

    func testAPeerMovingTheShownBlockOutReachesTheDocument() async throws {
        let (harness, model) = try await editor()
        let column = try XCTUnwrap(model.columns.first)
        let update = try peerUpdate("addColumnRight") { tx, group, list, writer in
            guard case .type(let first) = YBlockProjection.children(of: list, includeFormats: false)[0].content,
                let listItem = list.item
            else { return }
            let moved = YBlockProjection.children(of: first, includeFormats: false)[0]
            guard case .type(let container) = moved.content else { return }
            try writer.insertCopy(
                tx, try writer.snapshot(container, block: "a", depth: 0), into: group, after: listItem.left)
            moved.delete(tx)
        }
        try await harness.session.integrateServerState(update)
        await column.settle()
        await harness.settle()
        XCTAssertEqual(column.surface.blocks.map(\.id), ["b"], "it left the column")
        XCTAssertEqual(harness.session.surface.blocks.map(\.id), ["lead", "a", "cl", "tail"])
        XCTAssertEqual(model.columns.count, 2)
    }

    // MARK: - Commands from the surfaces

    func testMovingABlockToTheNextColumnShowsItThere() async throws {
        let (harness, model) = try await editor()
        let first = model.columns[0]
        let second = model.columns[1]
        // "Second" is the first column's last block: Move down takes it to the next column's top.
        first.textView.selectedRange = NSRange(location: try location(first, "b", 2), length: 0)
        first.input?.textViewDidChangeSelection(first.textView)
        let moved = await first.run { first.input?.performBlockAction(.moveDown) ?? false }
        XCTAssertTrue(moved)
        await second.settle()
        await harness.settle()
        XCTAssertEqual(first.surface.blocks.map(\.id), ["a"])
        XCTAssertEqual(second.surface.blocks.map(\.id), ["b", "c", "d"])
        let capture = try XCTUnwrap(BlockNoteColumnStructureCaptures.edits.first { $0.name == "moveDownFromColumnEnd" })
        let written = await xml(harness)
        XCTAssertEqual(written, capture.xml)
    }

    func testTheSlashMenusColumnsItemMakesAGroupInTheDocument() async throws {
        let harness = try await makeHarness(state: try seed("slashTwoEmpty"))
        addTeardownBlock { await harness.close() }
        setSelection(harness, NSRange(location: try location(harness.session, "q", 0), length: 0))
        for key in ["/", "c", "o", "l"] { harness.view.insertText(key) }
        await harness.settle()
        XCTAssertNotNil(harness.input.slashMenuQuery)
        let item = try XCTUnwrap(NativeInputCoordinator.slashItems.first { $0.id == "twoColumns" })
        let applied = await harness.run { harness.input.applySlashItem(item) }
        XCTAssertTrue(applied)
        XCTAssertEqual(harness.session.surface.blocks.map(\.id), ["lead", "q", "tail"])
        XCTAssertEqual(harness.session.surface.blocks[1].node, "columnList", "the paragraph became the group")
        let groups = await harness.session.replicaDoc { ColumnGroup.groups(in: $0) } ?? [:]
        XCTAssertEqual(groups["q"]?.group.columns.count, 2)
        try await assertConsistent(harness, localCommands: 5)
    }

    /// The document's block menu on the group's card acts on the whole group:
    /// move, duplicate (fresh ids throughout), copy and delete.
    func testTheDocumentsBlockMenuActsOnTheWholeGroup() async throws {
        let harness = try await makeHarness(state: try seed("addColumnRight"))
        addTeardownBlock { await harness.close() }
        setSelection(harness, NSRange(location: try location(harness.session, "cl", 0), length: 0))
        XCTAssertEqual(harness.input.blockActionTarget(), "cl")
        _ = harness.input.availableBlockActions()
        await waitUntil { !harness.input.availableBlockActions().isEmpty }
        let actions = Set(harness.input.availableBlockActions())
        XCTAssertTrue(actions.isSuperset(of: [.moveUp, .duplicate, .copy, .delete]), "\(actions)")
        XCTAssertFalse(actions.contains(.indent))
        let duplicated = await harness.run { harness.input.performBlockAction(.duplicate) }
        XCTAssertTrue(duplicated)
        var groups = await harness.session.replicaDoc { ColumnGroup.groups(in: $0) } ?? [:]
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(harness.session.surface.blocks.filter { $0.node == "columnList" }.count, 2)
        setSelection(harness, NSRange(location: try location(harness.session, "cl", 0), length: 0))
        let deleted = await harness.run { harness.input.performBlockAction(.delete) }
        XCTAssertTrue(deleted)
        groups = await harness.session.replicaDoc { ColumnGroup.groups(in: $0) } ?? [:]
        XCTAssertEqual(groups.count, 1)
        XCTAssertNil(groups["cl"])
        try await assertConsistent(harness, localCommands: 2)
    }

    /// Awareness per column: a peer's position in a column's block resolves
    /// to that block while the group is open (its column shows the caret) and
    /// to the group (its card) while it is closed.
    func testPeerPositionsInAColumnResolveToTheBlockOrTheCard() async throws {
        let harness = try await makeHarness(state: try seed("addColumnRight"))
        addTeardownBlock { await harness.close() }
        let resolved = await harness.session.engine { engine -> [PeerCursorPlace?] in
            _ = engine.openColumns("cl")
            guard let json = engine.awarenessPosition(EditorPosition(blockID: "c", offset: 2, assoc: 0)) else {
                return []
            }
            let open = engine.peerPlace(json)
            engine.closeColumns("cl")
            return [open, engine.peerPlace(json)]
        }
        XCTAssertEqual(resolved, [.text(EditorPosition(blockID: "c", offset: 2, assoc: 0)), .block("cl")])
    }
}
