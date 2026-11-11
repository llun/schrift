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

    private func payload(_ session: NativeEditorSession, _ id: String) async throws -> Data {
        let data = await session.engine { $0.subtreePayload([id]) }
        return try XCTUnwrap(data ?? nil, "\(id) has a lossless payload")
    }

    private func availableActions(_ harness: Harness) async -> [NativeBlockAction] {
        _ = harness.input.availableBlockActions()
        await harness.settle()
        return harness.input.availableBlockActions()
    }

    func testMovesCarryADeepSubtreeLosslesslyAndRemapTheSelection() async throws {
        let harness = try await makeHarness(treeSeed())
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let before = try await payload(session, "b")
        let item = await session.engine { $0.nativeBlock("b")?.handle.itemID }
        let sibling = await session.engine { $0.nativeBlock("a")?.handle }
        try caret(harness, "b", 2, length: 3)
        let actions = await availableActions(harness)
        XCTAssertEqual(
            actions,
            [.moveUp, .moveDown, .indent, .insertAbove, .insertBelow, .duplicate, .copy, .delete])

        let movedUp = await harness.run { harness.input.performBlockAction(.moveUp) }
        XCTAssertTrue(movedUp)
        XCTAssertEqual(ids(session), ["b", "b1", "b11", "b111", "a", "c"])
        XCTAssertEqual(session.surface.blocks.map(\.depth), [0, 1, 2, 3, 0, 0])
        let payloadAfterMove = try await payload(session, "b")
        XCTAssertEqual(payloadAfterMove, before, "every raw value, mark and child")
        let newItem = await session.engine { $0.nativeBlock("b")?.handle.itemID }
        XCTAssertNotEqual(newItem, item, "a clone, not the same item")
        let newSibling = await session.engine { $0.nativeBlock("a")?.handle }
        XCTAssertEqual(newSibling, sibling, "siblings keep their items")
        XCTAssertEqual(harness.log.commands.last?.kind, .moveUp)
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(session, "b", 2), length: 3))
        let selection = try unwrapped(await session.engine { try? $0.currentSelection() } ?? nil)
        XCTAssertEqual([selection.anchor.blockID, selection.head.blockID], ["b", "b"])
        try await assertConsistent(harness, localCommands: 1)
        // The first root block cannot move up.
        let actionsFirst = await availableActions(harness)
        XCTAssertFalse(actionsFirst.contains(.moveUp))
        let moveUpRefused = await harness.run { harness.input.performBlockAction(.moveUp) }
        XCTAssertFalse(moveUpRefused)

        let moveDown1 = await harness.run { harness.input.performBlockAction(.moveDown) }
        XCTAssertTrue(moveDown1)
        let moveDown2 = await harness.run { harness.input.performBlockAction(.moveDown) }
        XCTAssertTrue(moveDown2)
        XCTAssertEqual(ids(session), ["a", "c", "b", "b1", "b11", "b111"])
        let payloadFinal = try await payload(session, "b")
        XCTAssertEqual(payloadFinal, before)
        let actionsLast = await availableActions(harness)
        XCTAssertFalse(actionsLast.contains(.moveDown), "the last root block")
        try await assertConsistent(harness, localCommands: 3)
    }

    /// BlockNote's placement: past a sibling with children into its nearest
    /// child, past a group's end out beside the parent (an emptied group goes).
    func testMovesEnterAndLeaveChildrenAsBlockNoteDoes() async throws {
        let harness = try await makeHarness([
            paragraph("a", "Alpha"), nested(paragraph("p", "Parent"), [paragraph("only", "Only")]),
        ])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try caret(harness, "a", 0)
        let moveDown1 = await harness.run { harness.input.performBlockAction(.moveDown) }
        XCTAssertTrue(moveDown1)
        XCTAssertEqual(ids(session), ["p", "a", "only"])
        XCTAssertEqual(try block(session, "a").parentID, "p", "into the sibling's first child")
        try caret(harness, "only", 1)
        let moveDown2 = await harness.run { harness.input.performBlockAction(.moveDown) }
        XCTAssertTrue(moveDown2)
        let moveUp1 = await harness.run { harness.input.performBlockAction(.moveUp) }
        XCTAssertTrue(moveUp1)
        XCTAssertEqual(ids(session), ["p", "a", "only"])
        try caret(harness, "a", 0)
        let moveUp2 = await harness.run { harness.input.performBlockAction(.moveUp) }
        XCTAssertTrue(moveUp2, "a first child: out before its parent")
        XCTAssertEqual(ids(session), ["a", "p", "only"])
        XCTAssertEqual(session.surface.blocks.map(\.depth), [0, 0, 1])
        try await assertConsistent(harness, localCommands: 4)
        // Out of a sole child's group: the group goes with it.
        try caret(harness, "only", 0)
        let moveDown3 = await harness.run { harness.input.performBlockAction(.moveDown) }
        XCTAssertTrue(moveDown3)
        XCTAssertEqual(ids(session), ["a", "p", "only"])
        XCTAssertEqual(session.surface.blocks.map(\.depth), [0, 0, 0])
        XCTAssertNil(try replayNestedGroup(harness, "p"), "the emptied group went")
        try await assertConsistent(harness, localCommands: 5)
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

    /// Only a paste reports the payload's size: a subtree that grew past the payload
    /// bounds in place refuses Delete like any shape without a lossless copy.
    func testAGrownSubtreeRefusesDeleteAsUnsupportedNotAsATooLargePaste() async throws {
        let children = (0...BlockNoteSubtreePayload.maxBlocks).map { paragraph("k\($0)", "x") }
        let harness = try await makeHarness([nested(paragraph("big", "Big"), children), paragraph("z", "Last")])
        addTeardownBlock { await harness.close() }
        let error = await harness.session.engine { engine -> DocumentEngineError? in
            let command = NativeEditCommand(
                id: UUID(), baseRevision: engine.revision, blockID: "big", kind: .deleteBlock)
            do {
                try engine.applyStructural(command) { _ in XCTFail("refused before any write") }
                return nil
            } catch {
                return error as? DocumentEngineError
            }
        }
        XCTAssertEqual(error, .unsupportedNativeInput)
    }

    func testDuplicateCopiesTheSubtreeWithFreshIDs() async throws {
        let harness = try await makeHarness(treeSeed())
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try caret(harness, "b", 1)
        let duplicated = await harness.run { harness.input.performBlockAction(.duplicate) }
        XCTAssertTrue(duplicated)
        guard case .duplicate(let newIDs)? = harness.log.commands.last?.kind else { return XCTFail("not a duplicate") }
        XCTAssertEqual(newIDs.count, 4)
        XCTAssertEqual(ids(session), ["a", "b", "b1", "b11", "b111"] + newIDs + ["c"])
        XCTAssertEqual(texts(session)[5...8], ["Bold tail", "Child", "Grandchild", "Deep"])
        // The copy is the original with only its container ids replaced.
        var fresh = newIDs[...]
        let payloadB = try await payload(session, "b")
        let original = try XCTUnwrap(try BlockNoteSubtreePayload.decode(payloadB).first)
        let expected = try BlockNoteSubtreePayload.encode([original.replacingIDs(&fresh)])
        let payloadNew = try await payload(session, newIDs[0])
        XCTAssertEqual(payloadNew, expected)
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(session, "b", 1), length: 0))
        try await assertConsistent(harness, localCommands: 1)
    }

    func testDeleteRemovesTheSubtreeAndKeepsTheLastBlock() async throws {
        let harness = try await makeHarness(treeSeed())
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try caret(harness, "b", 3)
        let deleted1 = await harness.run { harness.input.performBlockAction(.delete) }
        XCTAssertTrue(deleted1)
        XCTAssertEqual(ids(session), ["a", "c"])
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(session, "c", 0), length: 0))
        try await assertConsistent(harness, localCommands: 1)
        // The last block: the caret goes to the end of the one before.
        let deleted2 = await harness.run { harness.input.performBlockAction(.delete) }
        XCTAssertTrue(deleted2)
        XCTAssertEqual(ids(session), ["a"])
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(session, "a", 5), length: 0))
        // The document keeps one block.
        let actions = await availableActions(harness)
        XCTAssertFalse(actions.contains(.delete))
        let deleted3 = await harness.run { harness.input.performBlockAction(.delete) }
        XCTAssertFalse(deleted3)
        try await assertConsistent(harness, localCommands: 2)
    }

    func testInsertAboveAndBelowAddAnEmptyParagraph() async throws {
        let harness = try await makeHarness(treeSeed())
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try caret(harness, "b", 0)
        let insertedBelow = await harness.run { harness.input.performBlockAction(.insertBelow) }
        XCTAssertTrue(insertedBelow)
        guard case .insertBlock(let below, false)? = harness.log.commands.last?.kind else {
            return XCTFail("not an insert below")
        }
        XCTAssertEqual(ids(session), ["a", "b", "b1", "b11", "b111", below, "c"], "after the whole subtree")
        XCTAssertEqual(try block(session, below).node, "paragraph")
        XCTAssertEqual(try block(session, below).depth, 0)
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(session, below, 0), length: 0))
        try caret(harness, "a", 2)
        let insertedAbove = await harness.run { harness.input.performBlockAction(.insertAbove) }
        XCTAssertTrue(insertedAbove)
        XCTAssertEqual(texts(session).prefix(2), ["", "Alpha"])
        // Typing in the new block is ordinary typing.
        harness.view.insertText("New")
        XCTAssertEqual(texts(session).first, "New")
        try await assertConsistent(harness, localCommands: 3)
    }

    /// A collapsed toggle moves with its hidden children; they stay folded.
    func testMovingAFoldedToggleCarriesItsHiddenChildren() async throws {
        let toggle = BlockNoteBlock(
            node: "toggleListItem", props: Self.paragraphProps, runs: [InlineRun("Title")], id: "t",
            children: [paragraph("c1", "Hidden one"), paragraph("c2", "Hidden two")])
        let harness = try await makeHarness([toggle, paragraph("x", "After")])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        XCTAssertTrue(session.surface.isHidden(blockID: "c1"), "collapsed by default")
        let before = try await payload(session, "t")
        try caret(harness, "t", 2)
        let moved = await harness.run { harness.input.performBlockAction(.moveDown) }
        XCTAssertTrue(moved)
        XCTAssertEqual(ids(session), ["x", "t", "c1", "c2"])
        XCTAssertTrue(session.surface.isHidden(blockID: "c1"))
        XCTAssertTrue(session.surface.isHidden(blockID: "c2"))
        XCTAssertFalse(session.surface.isExpanded("t"))
        let after = try await payload(session, "t")
        XCTAssertEqual(after, before)
        XCTAssertFalse(harness.view.accessibilityValue?.contains("Hidden") ?? true, "still folded for VoiceOver")
        try await assertConsistent(harness, localCommands: 1)
    }

    /// A peer that never saw the move edits the moved block and a sibling.
    /// Both converge; the sibling's edit survives and the edit inside the moved
    /// block lands in the deleted original: the documented loss of a
    /// clone-and-delete move (identity is not preserved).
    func testAConcurrentPeerEditInsideAMovedBlockIsLost() async throws {
        let harness = try await makeHarness(treeSeed())
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try caret(harness, "b1", 2)
        let moved = await harness.run { harness.input.performBlockAction(.moveUp) }
        XCTAssertTrue(moved)
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
        try await session.integrateServerState(edit)
        XCTAssertEqual(text(of: try block(session, "c")), "Gamma!")
        XCTAssertEqual(text(of: try block(session, "b1")), "Child", "the peer's edit is in the deleted original")
        XCTAssertEqual(text(of: try block(session, "b111")), "Deep", "so is an edit in a moved descendant")
        XCTAssertEqual(harness.view.selectedRange.location, try location(session, "b1", 2))
        try await assertConsistent(harness, localCommands: 1)

        let restored = try XCTUnwrap(harness.store.restore(for: harness.scope))
        for update in restored.updates { try peer.applyUpdate(YUpdateDecoder.decode(update), origin: .remote) }
        XCTAssertEqual(projection(peer), session.surface.blocks, "both replicas converge")
    }

    /// Opaque content moves only with a proven lossless copy, which a move
    /// never assumes: a table (plain BlockNote XML) can be copied and
    /// deleted; an unknown node can be neither. Inserting beside both is fine.
    func testOpaqueSubtreesAllowOnlyWhatIsProvenLossless() async throws {
        let harness = try await makeHarness([
            paragraph("a", "Alpha"), BlockNoteBlock(node: "table", props: [], runs: [], id: "table"),
            BlockNoteBlock(node: "fancyWidget", props: [("x", .string("y"))], runs: [], id: "widget"),
            nested(paragraph("p", "Parent"), [BlockNoteBlock(node: "fancyWidget", props: [], runs: [], id: "kid")]),
        ])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        func placeCaret(_ id: String) throws {
            let entry = try XCTUnwrap(session.surface.rangeIndex.entry(for: id))
            setSelection(harness, NSRange(location: entry.range.location, length: 0))
        }
        try placeCaret("table")
        let tableActions = await availableActions(harness)
        XCTAssertEqual(tableActions, [.insertAbove, .insertBelow, .copy, .delete])
        let moveUp = await harness.run { harness.input.performBlockAction(.moveUp) }
        XCTAssertFalse(moveUp)
        let duplicate = await harness.run { harness.input.performBlockAction(.duplicate) }
        XCTAssertFalse(duplicate)
        try placeCaret("widget")
        let widgetActions = await availableActions(harness)
        XCTAssertEqual(widgetActions, [.insertAbove, .insertBelow])
        let delete = await harness.run { harness.input.performBlockAction(.delete) }
        XCTAssertFalse(delete)
        let copy = await harness.run { harness.input.performBlockAction(.copy) }
        XCTAssertFalse(copy)
        // A readable parent with an unknown child: the subtree is not movable.
        try caret(harness, "p", 0)
        let parentActions = await availableActions(harness)
        XCTAssertEqual(parentActions, [.insertAbove, .insertBelow])
        XCTAssertEqual(harness.log.commands.count, 0)
        try await assertConsistent(harness, localCommands: 0)

        try placeCaret("table")
        let deleteTable = await harness.run { harness.input.performBlockAction(.delete) }
        XCTAssertTrue(deleteTable)
        XCTAssertEqual(ids(session), ["a", "widget", "p", "kid"])
        try await assertConsistent(harness, localCommands: 1)
    }

    /// A divider is modeled but not a type the writer edits: it still moves,
    /// duplicates and goes whole, since block commands take the container.
    func testADividerMovesDuplicatesAndDeletes() async throws {
        let harness = try await makeHarness([
            paragraph("a", "Alpha"), BlockNoteBlock(node: "divider", props: [], runs: [], id: "rule"),
            paragraph("c", "Gamma"),
        ])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let rule = try XCTUnwrap(session.surface.rangeIndex.entry(for: "rule"))
        setSelection(harness, NSRange(location: rule.range.location, length: 0))
        let moveUp = await harness.run { harness.input.performBlockAction(.moveUp) }
        XCTAssertTrue(moveUp)
        XCTAssertEqual(ids(session), ["rule", "a", "c"])
        let duplicate = await harness.run { harness.input.performBlockAction(.duplicate) }
        XCTAssertTrue(duplicate)
        XCTAssertEqual(session.surface.blocks.map(\.node), ["divider", "divider", "paragraph", "paragraph"])
        let delete = await harness.run { harness.input.performBlockAction(.delete) }
        XCTAssertTrue(delete)
        XCTAssertEqual(session.surface.blocks.map(\.node), ["divider", "paragraph", "paragraph"])
        try await assertConsistent(harness, localCommands: 3)
    }

    /// The edit menu's Block submenu and VoiceOver's custom actions offer the
    /// same actions; performing one is the same command.
    func testEditMenuAndVoiceOverActionsMatchTheMenu() async throws {
        let harness = try await makeHarness(treeSeed())
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try caret(harness, "c", 1)
        _ = await availableActions(harness)
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
        let handled = await harness.run { moveUp.actionHandler?(moveUp) ?? false }
        XCTAssertTrue(handled)
        XCTAssertEqual(ids(session), ["a", "b", "b1", "b11", "b111", "c"])
        XCTAssertEqual(try block(session, "c").parentID, "b", "past a sibling with children: its last child")
        try await assertConsistent(harness, localCommands: 1)
    }

    /// Review: the menu's Indent and Outdent apply wherever the menu offers
    /// them, through the same target as every other action: a caret at the
    /// document end, or a whole block selected with its separator (a
    /// triple-tap). Tab's own caret rules are unchanged.
    func testMenuIndentAndOutdentApplyWhereverTheMenuOffersThem() async throws {
        let harness = try await makeHarness([bullet("a", "Alpha"), bullet("b", "Beta")])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let end = NSRange(location: harness.view.textStorage.length, length: 0)
        setSelection(harness, end)
        let actionsEnd = await availableActions(harness)
        XCTAssertTrue(actionsEnd.contains(.indent))
        let indented = await harness.run { harness.input.performBlockAction(.indent) }
        XCTAssertTrue(indented)
        XCTAssertEqual(session.surface.blocks.map(\.depth), [0, 1])
        XCTAssertEqual(harness.view.selectedRange, end)
        try await assertConsistent(harness, localCommands: 1)

        let line = try XCTUnwrap(session.surface.rangeIndex.entry(for: "b")).range
        setSelection(harness, line)
        let actionsLine = await availableActions(harness)
        XCTAssertTrue(actionsLine.contains(.outdent))
        let outdented = await harness.run { harness.input.performBlockAction(.outdent) }
        XCTAssertTrue(outdented)
        XCTAssertEqual(session.surface.blocks.map(\.depth), [0, 0])
        XCTAssertEqual(harness.view.selectedRange, line)
        try await assertConsistent(harness, localCommands: 2)
        // Tab over the same selection keeps its quiet refusal.
        let tabRefused = await harness.run { harness.input.indent() }
        XCTAssertFalse(tabRefused)
        try await assertConsistent(harness, localCommands: 2)
    }

    func testRelaunchReplaysBlockCommands() async throws {
        let harness = try await makeHarness(treeSeed())
        addTeardownBlock {
            UIPasteboard.remove(withName: harness.pasteboard.name)
            try? FileManager.default.removeItem(at: harness.directory)
        }
        let session = harness.session
        try caret(harness, "b", 0)
        let dup = await harness.run { harness.input.performBlockAction(.duplicate) }
        XCTAssertTrue(dup)
        let move = await harness.run { harness.input.performBlockAction(.moveUp) }
        XCTAssertTrue(move)
        try caret(harness, "c", 0)
        let ins = await harness.run { harness.input.performBlockAction(.insertAbove) }
        XCTAssertTrue(ins)
        try caret(harness, "a", 0)
        let del = await harness.run { harness.input.performBlockAction(.delete) }
        XCTAssertTrue(del)
        try await assertConsistent(harness, localCommands: 4)
        let expected = session.surface.blocks
        let expectedText = session.textView.textStorage.string
        await session.close().value

        let restored = try unwrapped(try await NativeEditorSession.restore(store: harness.store, scope: harness.scope))
        addTeardownBlock { await restored.close().value }
        XCTAssertEqual(restored.surface.blocks, expected)
        XCTAssertEqual(restored.textView.textStorage.string, expectedText)
        let revision = await restored.engine { $0.revision }
        XCTAssertEqual(revision, 4)
    }
}
