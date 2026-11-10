import UIKit
import XCTest

@testable import Schrift

/// PR06d: the block menu's subtree commands (move up/down, duplicate, delete,
/// insert above/below) are one durable clone-and-delete or insert command
/// each, validated before arming, over a real `NativeTextView` and a restored
/// durable replica. Losslessness is checked byte for byte through the
/// subtree payload (`BlockNoteSubtreePayload` encodes the raw copy). No sleeps.
@MainActor
final class NativeBlockCommandsTests: NativeEditingTestCase {
    private func nested(_ block: BlockNoteBlock, _ children: [BlockNoteBlock]) -> BlockNoteBlock {
        var block = block
        block.children = children
        return block
    }

    private func caret(_ harness: Harness, _ id: String, _ offset: Int, length: Int = 0) throws {
        setSelection(harness, NSRange(location: try location(harness.session, id, offset), length: length))
    }

    /// A heading with a colour, an unknown prop, a bold run and an unknown
    /// mark, over three nested levels (a checked task and a paragraph inside).
    private func treeSeed() -> [BlockNoteBlock] {
        var rich = heading("b", "")
        rich.props = rich.props.map { $0.key == "textColor" ? ($0.key, .string("red")) : $0 }
        rich.props += [("x-schrift-test", .string("kept"))]
        rich.runs = [
            InlineRun("Bold", marks: [("bold", "{}")]), InlineRun(" tail", marks: [("x-unknown", #"{"v":1}"#)]),
        ]
        let task = BlockNoteBlock(
            node: "checkListItem", props: Self.paragraphProps + [("checked", .bool(true))],
            runs: [InlineRun("Grandchild")], id: "b11")
        return [
            paragraph("a", "Alpha"),
            nested(rich, [nested(bullet("b1", "Child"), [nested(task, [paragraph("b111", "Deep")])])]),
            paragraph("c", "Gamma"),
        ]
    }

    private func ids(_ session: NativeEditorSession) -> [String] { session.surface.blocks.map(\.id) }

    private func payload(_ session: NativeEditorSession, _ id: String) throws -> Data {
        try XCTUnwrap(session.engine.subtreePayload([id]), "\(id) has a lossless payload")
    }

    func testMovesCarryADeepSubtreeLosslesslyAndRemapTheSelection() throws {
        let harness = try makeHarness(treeSeed())
        defer { harness.close() }
        let session = harness.session
        let before = try payload(session, "b")
        let item = session.engine.nativeBlock("b")?.handle.itemID
        let sibling = session.engine.nativeBlock("a")?.handle
        try caret(harness, "b", 2, length: 3)
        XCTAssertEqual(
            harness.input.availableBlockActions(),
            [.moveUp, .moveDown, .indent, .insertAbove, .insertBelow, .duplicate, .copy, .delete])

        XCTAssertTrue(harness.input.performBlockAction(.moveUp))
        XCTAssertEqual(ids(session), ["b", "b1", "b11", "b111", "a", "c"])
        XCTAssertEqual(session.surface.blocks.map(\.depth), [0, 1, 2, 3, 0, 0])
        XCTAssertEqual(try payload(session, "b"), before, "every raw value, mark and child")
        XCTAssertNotEqual(session.engine.nativeBlock("b")?.handle.itemID, item, "a clone, not the same item")
        XCTAssertEqual(session.engine.nativeBlock("a")?.handle, sibling, "siblings keep their items")
        XCTAssertEqual(harness.log.commands.last?.kind, .moveUp)
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(session, "b", 2), length: 3))
        let selection = try XCTUnwrap(try session.engine.currentSelection())
        XCTAssertEqual([selection.anchor.blockID, selection.head.blockID], ["b", "b"])
        try assertConsistent(harness, localCommands: 1)
        // The first root block cannot move up.
        XCTAssertFalse(harness.input.availableBlockActions().contains(.moveUp))
        XCTAssertFalse(harness.input.performBlockAction(.moveUp))

        XCTAssertTrue(harness.input.performBlockAction(.moveDown))
        XCTAssertTrue(harness.input.performBlockAction(.moveDown))
        XCTAssertEqual(ids(session), ["a", "c", "b", "b1", "b11", "b111"])
        XCTAssertEqual(try payload(session, "b"), before)
        XCTAssertFalse(harness.input.availableBlockActions().contains(.moveDown), "the last root block")
        try assertConsistent(harness, localCommands: 3)
    }

    /// BlockNote's placement: past a sibling with children into its nearest
    /// child, past a group's end out beside the parent (an emptied group goes).
    func testMovesEnterAndLeaveChildrenAsBlockNoteDoes() throws {
        let harness = try makeHarness([
            paragraph("a", "Alpha"), nested(paragraph("p", "Parent"), [paragraph("only", "Only")]),
        ])
        defer { harness.close() }
        let session = harness.session
        try caret(harness, "a", 0)
        XCTAssertTrue(harness.input.performBlockAction(.moveDown))
        XCTAssertEqual(ids(session), ["p", "a", "only"])
        XCTAssertEqual(try block(session, "a").parentID, "p", "into the sibling's first child")
        try caret(harness, "only", 1)
        XCTAssertTrue(harness.input.performBlockAction(.moveDown))
        XCTAssertTrue(harness.input.performBlockAction(.moveUp))
        XCTAssertEqual(ids(session), ["p", "a", "only"])
        try caret(harness, "a", 0)
        XCTAssertTrue(harness.input.performBlockAction(.moveUp), "a first child: out before its parent")
        XCTAssertEqual(ids(session), ["a", "p", "only"])
        XCTAssertEqual(session.surface.blocks.map(\.depth), [0, 0, 1])
        try assertConsistent(harness, localCommands: 4)
        // Out of a sole child's group: the group goes with it.
        try caret(harness, "only", 0)
        XCTAssertTrue(harness.input.performBlockAction(.moveDown))
        XCTAssertEqual(ids(session), ["a", "p", "only"])
        XCTAssertEqual(session.surface.blocks.map(\.depth), [0, 0, 0])
        XCTAssertNil(try replayNestedGroup(harness, "p"), "the emptied group went")
        try assertConsistent(harness, localCommands: 5)
    }

    /// Whether the replayed replica gives `id` a nested group (nil when not).
    private func replayNestedGroup(_ harness: Harness, _ id: String) throws -> Bool? {
        let restored = try XCTUnwrap(harness.store.restore(for: harness.scope))
        let replica = YDoc(clientID: 98)
        defer { replica.destroy() }
        try replica.applyUpdate(YUpdateDecoder.decode(restored.checkpoint), origin: .remote)
        for update in restored.updates { try replica.applyUpdate(YUpdateDecoder.decode(update), origin: .remote) }
        let writer = BlockNoteWriter(doc: replica, schemas: BlockNoteWriter.nativePropSchemas)
        return try writer.find(id).nested == nil ? nil : true
    }

    func testDuplicateCopiesTheSubtreeWithFreshIDs() throws {
        let harness = try makeHarness(treeSeed())
        defer { harness.close() }
        let session = harness.session
        try caret(harness, "b", 1)
        XCTAssertTrue(harness.input.performBlockAction(.duplicate))
        guard case .duplicate(let newIDs)? = harness.log.commands.last?.kind else { return XCTFail("not a duplicate") }
        XCTAssertEqual(newIDs.count, 4)
        XCTAssertEqual(ids(session), ["a", "b", "b1", "b11", "b111"] + newIDs + ["c"])
        XCTAssertEqual(texts(session)[5...8], ["Bold tail", "Child", "Grandchild", "Deep"])
        // The copy is the original with only its container ids replaced.
        var fresh = newIDs[...]
        let original = try XCTUnwrap(try BlockNoteSubtreePayload.decode(try payload(session, "b")).first)
        let expected = try BlockNoteSubtreePayload.encode([original.replacingIDs(&fresh)])
        XCTAssertEqual(try payload(session, newIDs[0]), expected)
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(session, "b", 1), length: 0))
        try assertConsistent(harness, localCommands: 1)
    }

    func testDeleteRemovesTheSubtreeAndKeepsTheLastBlock() throws {
        let harness = try makeHarness(treeSeed())
        defer { harness.close() }
        let session = harness.session
        try caret(harness, "b", 3)
        XCTAssertTrue(harness.input.performBlockAction(.delete))
        XCTAssertEqual(ids(session), ["a", "c"])
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(session, "c", 0), length: 0))
        try assertConsistent(harness, localCommands: 1)
        // The last block: the caret goes to the end of the one before.
        XCTAssertTrue(harness.input.performBlockAction(.delete))
        XCTAssertEqual(ids(session), ["a"])
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(session, "a", 5), length: 0))
        // The document keeps one block.
        XCTAssertFalse(harness.input.availableBlockActions().contains(.delete))
        XCTAssertFalse(harness.input.performBlockAction(.delete))
        try assertConsistent(harness, localCommands: 2)
    }

    func testInsertAboveAndBelowAddAnEmptyParagraph() throws {
        let harness = try makeHarness(treeSeed())
        defer { harness.close() }
        let session = harness.session
        try caret(harness, "b", 0)
        XCTAssertTrue(harness.input.performBlockAction(.insertBelow))
        guard case .insertBlock(let below, false)? = harness.log.commands.last?.kind else {
            return XCTFail("not an insert below")
        }
        XCTAssertEqual(ids(session), ["a", "b", "b1", "b11", "b111", below, "c"], "after the whole subtree")
        XCTAssertEqual(try block(session, below).node, "paragraph")
        XCTAssertEqual(try block(session, below).depth, 0)
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(session, below, 0), length: 0))
        try caret(harness, "a", 2)
        XCTAssertTrue(harness.input.performBlockAction(.insertAbove))
        XCTAssertEqual(texts(session).prefix(2), ["", "Alpha"])
        // Typing in the new block is ordinary typing.
        harness.view.insertText("New")
        XCTAssertEqual(texts(session).first, "New")
        try assertConsistent(harness, localCommands: 3)
    }

    /// A collapsed toggle moves with its hidden children; they stay folded.
    func testMovingAFoldedToggleCarriesItsHiddenChildren() throws {
        let toggle = BlockNoteBlock(
            node: "toggleListItem", props: Self.paragraphProps, runs: [InlineRun("Title")], id: "t",
            children: [paragraph("c1", "Hidden one"), paragraph("c2", "Hidden two")])
        let harness = try makeHarness([toggle, paragraph("x", "After")])
        defer { harness.close() }
        let session = harness.session
        XCTAssertTrue(session.surface.isHidden(blockID: "c1"), "collapsed by default")
        let before = try payload(session, "t")
        try caret(harness, "t", 2)
        XCTAssertTrue(harness.input.performBlockAction(.moveDown))
        XCTAssertEqual(ids(session), ["x", "t", "c1", "c2"])
        XCTAssertTrue(session.surface.isHidden(blockID: "c1"))
        XCTAssertTrue(session.surface.isHidden(blockID: "c2"))
        XCTAssertFalse(session.surface.isExpanded("t"))
        XCTAssertEqual(try payload(session, "t"), before)
        XCTAssertFalse(harness.view.accessibilityValue?.contains("Hidden") ?? true, "still folded for VoiceOver")
        try assertConsistent(harness, localCommands: 1)
    }

    /// A peer that never saw the move edits the moved block and a sibling.
    /// Both converge; the sibling's edit survives and the edit inside the moved
    /// block lands in the deleted original: the documented loss of a
    /// clone-and-delete move (identity is not preserved).
    func testAConcurrentPeerEditInsideAMovedBlockIsLost() throws {
        let harness = try makeHarness(treeSeed())
        defer { harness.close() }
        let session = harness.session
        try caret(harness, "b1", 2)
        XCTAssertTrue(harness.input.performBlockAction(.moveUp))
        XCTAssertEqual(ids(session), ["a", "b1", "b11", "b111", "b", "c"], "out before its parent")
        XCTAssertEqual(try block(session, "b1").depth, 0)

        let peer = try makeDoc(treeSeed(), clientID: 2)
        defer { peer.destroy() }
        let writer = BlockNoteWriter(doc: peer, schemas: BlockNoteWriter.nativePropSchemas)
        let edit = try writer.transaction { _ in
            try writer.replaceText(block: "c", range: 5..<5, with: "!")
            try writer.replaceText(block: "b1", range: 0..<0, with: "Peer ")
            try writer.replaceText(block: "b111", range: 4..<4, with: "er")
        }
        try session.integrateServerState(edit)
        XCTAssertEqual(text(of: try block(session, "c")), "Gamma!")
        XCTAssertEqual(text(of: try block(session, "b1")), "Child", "the peer's edit is in the deleted original")
        XCTAssertEqual(text(of: try block(session, "b111")), "Deep", "so is an edit in a moved descendant")
        XCTAssertEqual(harness.view.selectedRange.location, try location(session, "b1", 2))
        try assertConsistent(harness, localCommands: 1)

        let restored = try XCTUnwrap(harness.store.restore(for: harness.scope))
        for update in restored.updates { try peer.applyUpdate(YUpdateDecoder.decode(update), origin: .remote) }
        XCTAssertEqual(projection(peer), session.surface.blocks, "both replicas converge")
    }

    /// Opaque content moves only with a proven lossless copy, which a move
    /// never assumes: a table (plain BlockNote XML) can be copied and
    /// deleted; an unknown node can be neither. Inserting beside both is fine.
    func testOpaqueSubtreesAllowOnlyWhatIsProvenLossless() throws {
        let harness = try makeHarness([
            paragraph("a", "Alpha"), BlockNoteBlock(node: "table", props: [], runs: [], id: "table"),
            BlockNoteBlock(node: "fancyWidget", props: [("x", .string("y"))], runs: [], id: "widget"),
            nested(paragraph("p", "Parent"), [BlockNoteBlock(node: "fancyWidget", props: [], runs: [], id: "kid")]),
        ])
        defer { harness.close() }
        let session = harness.session
        func placeCaret(_ id: String) throws {
            let entry = try XCTUnwrap(session.surface.rangeIndex.entry(for: id))
            setSelection(harness, NSRange(location: entry.range.location, length: 0))
        }
        try placeCaret("table")
        XCTAssertEqual(harness.input.availableBlockActions(), [.insertAbove, .insertBelow, .copy, .delete])
        XCTAssertFalse(harness.input.performBlockAction(.moveUp))
        XCTAssertFalse(harness.input.performBlockAction(.duplicate))
        try placeCaret("widget")
        XCTAssertEqual(harness.input.availableBlockActions(), [.insertAbove, .insertBelow])
        XCTAssertFalse(harness.input.performBlockAction(.delete))
        XCTAssertFalse(harness.input.performBlockAction(.copy))
        // A readable parent with an unknown child: the subtree is not movable.
        try caret(harness, "p", 0)
        XCTAssertEqual(harness.input.availableBlockActions(), [.insertAbove, .insertBelow])
        XCTAssertEqual(harness.log.commands.count, 0)
        try assertConsistent(harness, localCommands: 0)

        try placeCaret("table")
        XCTAssertTrue(harness.input.performBlockAction(.delete))
        XCTAssertEqual(ids(session), ["a", "widget", "p", "kid"])
        try assertConsistent(harness, localCommands: 1)
    }

    /// A divider is modeled but not a type the writer edits: it still moves,
    /// duplicates and goes whole, since block commands take the container.
    func testADividerMovesDuplicatesAndDeletes() throws {
        let harness = try makeHarness([
            paragraph("a", "Alpha"), BlockNoteBlock(node: "divider", props: [], runs: [], id: "rule"),
            paragraph("c", "Gamma"),
        ])
        defer { harness.close() }
        let session = harness.session
        let rule = try XCTUnwrap(session.surface.rangeIndex.entry(for: "rule"))
        setSelection(harness, NSRange(location: rule.range.location, length: 0))
        XCTAssertTrue(harness.input.performBlockAction(.moveUp))
        XCTAssertEqual(ids(session), ["rule", "a", "c"])
        XCTAssertTrue(harness.input.performBlockAction(.duplicate))
        XCTAssertEqual(session.surface.blocks.map(\.node), ["divider", "divider", "paragraph", "paragraph"])
        XCTAssertTrue(harness.input.performBlockAction(.delete))
        XCTAssertEqual(session.surface.blocks.map(\.node), ["divider", "paragraph", "paragraph"])
        try assertConsistent(harness, localCommands: 3)
    }

    /// The edit menu's Block submenu and VoiceOver's custom actions offer the
    /// same actions; performing one is the same command.
    func testEditMenuAndVoiceOverActionsMatchTheMenu() throws {
        let harness = try makeHarness(treeSeed())
        defer { harness.close() }
        let session = harness.session
        try caret(harness, "c", 1)
        let menu = try XCTUnwrap(
            harness.input.textView(harness.view, editMenuForTextIn: harness.view.selectedRange, suggestedActions: []))
        let submenu = try XCTUnwrap(menu.children.last as? UIMenu)
        XCTAssertEqual(submenu.title, "Block actions")
        let actions = submenu.children.compactMap { $0 as? UIAction }
        XCTAssertEqual(actions.map(\.title), NativeBlockAction.allCases.map { NativeEditorLabels().blockActions[$0]! })
        XCTAssertEqual(actions.filter { $0.attributes.contains(.disabled) }.map(\.title), ["Move down", "Outdent"])
        let custom = try XCTUnwrap(harness.view.accessibilityCustomActions)
        XCTAssertEqual(
            custom.map(\.name),
            [
                "Move up", "Indent", "Insert block above", "Insert block below", "Duplicate", "Copy block",
                "Delete block",
            ])
        let moveUp = try XCTUnwrap(custom.first)
        XCTAssertTrue(moveUp.actionHandler?(moveUp) ?? false)
        XCTAssertEqual(ids(session), ["a", "b", "b1", "b11", "b111", "c"])
        XCTAssertEqual(try block(session, "c").parentID, "b", "past a sibling with children: its last child")
        try assertConsistent(harness, localCommands: 1)
    }

    /// Review: the menu's Indent and Outdent apply wherever the menu offers
    /// them, through the same target as every other action: a caret at the
    /// document end, or a whole block selected with its separator (a
    /// triple-tap). Tab's own caret rules are unchanged.
    func testMenuIndentAndOutdentApplyWhereverTheMenuOffersThem() throws {
        let harness = try makeHarness([bullet("a", "Alpha"), bullet("b", "Beta")])
        defer { harness.close() }
        let session = harness.session
        let end = NSRange(location: harness.view.textStorage.length, length: 0)
        setSelection(harness, end)
        XCTAssertTrue(harness.input.availableBlockActions().contains(.indent))
        XCTAssertTrue(harness.input.performBlockAction(.indent))
        XCTAssertEqual(session.surface.blocks.map(\.depth), [0, 1])
        XCTAssertEqual(harness.view.selectedRange, end)
        try assertConsistent(harness, localCommands: 1)

        let line = try XCTUnwrap(session.surface.rangeIndex.entry(for: "b")).range
        setSelection(harness, line)
        XCTAssertTrue(harness.input.availableBlockActions().contains(.outdent))
        XCTAssertTrue(harness.input.performBlockAction(.outdent))
        XCTAssertEqual(session.surface.blocks.map(\.depth), [0, 0])
        XCTAssertEqual(harness.view.selectedRange, line)
        try assertConsistent(harness, localCommands: 2)
        // Tab over the same selection keeps its quiet refusal.
        XCTAssertFalse(harness.input.indent())
        try assertConsistent(harness, localCommands: 2)
    }

    func testRelaunchReplaysBlockCommands() throws {
        let harness = try makeHarness(treeSeed())
        let session = harness.session
        try caret(harness, "b", 0)
        XCTAssertTrue(harness.input.performBlockAction(.duplicate))
        XCTAssertTrue(harness.input.performBlockAction(.moveUp))
        try caret(harness, "c", 0)
        XCTAssertTrue(harness.input.performBlockAction(.insertAbove))
        try caret(harness, "a", 0)
        XCTAssertTrue(harness.input.performBlockAction(.delete))
        try assertConsistent(harness, localCommands: 4)
        let expected = session.surface.blocks
        let expectedText = session.textView.textStorage.string
        session.close()

        let restored = try XCTUnwrap(NativeEditorSession.restore(store: harness.store, scope: harness.scope))
        defer {
            restored.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }
        XCTAssertEqual(restored.surface.blocks, expected)
        XCTAssertEqual(restored.textView.textStorage.string, expectedText)
        XCTAssertEqual(restored.engine.revision, 4)
    }
}
