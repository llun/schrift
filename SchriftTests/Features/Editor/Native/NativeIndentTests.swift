import UIKit
import XCTest

@testable import Schrift

/// PR06a: Tab / Shift-Tab and the bar's Indent / Outdent are one durable
/// clone-and-delete tree move each (BlockNote's `nestBlock`/`unnestBlock`),
/// validated before arming. Real `NativeTextView` input over a restored
/// durable replica; every action asserts its journaled command count and that
/// storage equals the projection. No sleeps.
@MainActor
final class NativeIndentTests: NativeEditingTestCase {
    private func nested(_ block: BlockNoteBlock, _ children: [BlockNoteBlock]) -> BlockNoteBlock {
        var block = block
        block.children = children
        return block
    }

    private func caret(_ harness: Harness, _ id: String, _ offset: Int) throws {
        setSelection(harness, NSRange(location: try location(harness.session, id, offset), length: 0))
    }

    private func listSeed() -> [BlockNoteBlock] {
        [bullet("a", "Alpha"), bullet("b", "Beta"), bullet("c", "Gamma")]
    }

    func testTabNestsTheSecondBulletAndKeepsTheSelection() async throws {
        let harness = try await makeHarness(listSeed())
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let siblings = try unwrapped(
            await harness.engine { ($0.nativeBlock("a")?.handle, $0.nativeBlock("c")?.handle) })
        let moved = await harness.engine { $0.nativeBlock("b")?.handle } ?? nil
        setSelection(harness, NSRange(location: try location(session, "b", 1), length: 2))
        let projected = try unwrapped(await harness.engine { $0.projectedBlockCount })
        harness.view.insertText("\t")
        await harness.settle()
        // Slices for the moved block and its new parent; a reset projects none.
        let projectedAfter = try unwrapped(await harness.engine { $0.projectedBlockCount })
        XCTAssertEqual(projectedAfter - projected, 2, "slices, never a reset")
        XCTAssertEqual(session.surface.blocks.map(\.depth), [0, 1, 0])
        XCTAssertEqual(try block(session, "b").parentID, "a")
        guard case .indent? = harness.log.commands.last?.kind else { return XCTFail("not an indent") }
        // The text did not move, so neither did the selection.
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(session, "b", 1), length: 2))
        let selection = try unwrapped(await harness.engine { try? $0.currentSelection() } ?? nil)
        XCTAssertEqual([selection.anchor.blockID, selection.head.blockID], ["b", "b"])
        XCTAssertEqual([selection.anchor.offset, selection.head.offset], [1, 3])
        // Siblings keep their integrated items; the moved block is a clone.
        let handleA = await harness.engine { $0.nativeBlock("a")?.handle }
        let handleC = await harness.engine { $0.nativeBlock("c")?.handle }
        let handleB = await harness.engine { $0.nativeBlock("b")?.handle } ?? nil
        XCTAssertEqual(handleA, siblings.0)
        XCTAssertEqual(handleC, siblings.1)
        XCTAssertNotEqual(handleB?.itemID, moved?.itemID)
        try await assertConsistent(harness, localCommands: 1)

        // Shift-Tab (the bar's Outdent) undoes it; Gamma follows unchanged.
        let outdented = await harness.run { harness.input.outdent() }
        XCTAssertTrue(outdented)
        XCTAssertEqual(session.surface.blocks.map(\.depth), [0, 0, 0])
        XCTAssertEqual(texts(session), ["Alpha", "Beta", "Gamma"])
        let handleCAfterOutdent = await harness.engine { $0.nativeBlock("c")?.handle }
        XCTAssertEqual(handleCAfterOutdent, siblings.1)
        try await assertConsistent(harness, localCommands: 2)
    }

    func testIndentAppendsToExistingChildrenAndCarriesItsOwnChildren() async throws {
        let harness = try await makeHarness([
            nested(bullet("a", "Alpha"), [bullet("a1", "First child")]),
            nested(bullet("b", "Beta"), [bullet("b1", "Beta child")]),
        ])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try caret(harness, "b", 0)
        let indented = await harness.run { harness.input.indent() }
        XCTAssertTrue(indented)
        XCTAssertEqual(session.surface.blocks.map(\.id), ["a", "a1", "b", "b1"])
        XCTAssertEqual(session.surface.blocks.map(\.depth), [0, 1, 1, 2])
        XCTAssertEqual(session.surface.blocks.map(\.parentID), [nil, "a", "a", "b"])
        try await assertConsistent(harness, localCommands: 1)
    }

    func testOutdentLiftsAfterTheParentAndTakesTheFollowingSiblings() async throws {
        let harness = try await makeHarness([
            nested(
                bullet("a", "Alpha"),
                [bullet("x", "X"), nested(bullet("y", "Y"), [bullet("y1", "Y1")]), bullet("z", "Z")]),
            paragraph("tail", "Tail"),
        ])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try caret(harness, "y", 1)
        // Shift-Tab, through the view's key command.
        let shiftTab = try XCTUnwrap(harness.view.keyCommands?.first { $0.input == "\t" && $0.modifierFlags == .shift })
        harness.view.perform(try XCTUnwrap(shiftTab.action))
        await harness.settle()
        XCTAssertEqual(session.surface.blocks.map(\.id), ["a", "x", "y", "y1", "z", "tail"])
        XCTAssertEqual(session.surface.blocks.map(\.depth), [0, 1, 0, 1, 1, 0])
        XCTAssertEqual(session.surface.blocks.map(\.parentID), [nil, "a", nil, "y", "y", nil])
        XCTAssertEqual(harness.view.selectedRange.location, try location(session, "y", 1))
        try await assertConsistent(harness, localCommands: 1)
        // The last child leaving removes its parent's group.
        try caret(harness, "x", 0)
        let outdented = await harness.run { harness.input.outdent() }
        XCTAssertTrue(outdented)
        XCTAssertEqual(session.surface.blocks.map(\.depth), [0, 0, 0, 1, 1, 0])
        try await assertConsistent(harness, localCommands: 2)
    }

    /// Where BlockNote does nothing, nothing is written and nothing is shown.
    func testBoundsAreQuietRefusals() async throws {
        // `bound` sits at the deepest level the editor nests to with a sibling
        // after it; `level-15` (its parent) has a previous sibling `side`.
        let max = BlockNoteWriter.maxNestingDepth
        var chain = [
            paragraph("side", "Side"),
            nested(
                paragraph("level-\(max - 1)", "Last parent"), [paragraph("bound", "Bound"), paragraph("next", "Next")]),
        ]
        for level in stride(from: max - 2, through: 0, by: -1) {
            chain = [nested(paragraph("level-\(level)", "Level \(level)"), chain)]
        }
        let harness = try await makeHarness(
            listSeed() + chain + [paragraph("after", "After"), nested(paragraph("p", "P"), [paragraph("q", "Q")])])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        XCTAssertEqual(try block(session, "bound").depth, BlockNoteWriter.maxNestingDepth)
        let original = session.textView.textStorage.string
        try caret(harness, "a", 0)
        let indentRefused1 = await harness.run { harness.input.indent() }
        XCTAssertFalse(indentRefused1, "the first block has nothing to nest under")
        let outdentRefused1 = await harness.run { harness.input.outdent() }
        XCTAssertFalse(outdentRefused1, "a root block cannot unnest")
        try caret(harness, "level-1", 0)
        let indentRefused2 = await harness.run { harness.input.indent() }
        XCTAssertFalse(indentRefused2, "a first child has no previous sibling")
        try caret(harness, "next", 0)
        let indentRefused3 = await harness.run { harness.input.indent() }
        XCTAssertFalse(indentRefused3, "past the depth bound")
        try caret(harness, "level-\(max - 1)", 0)
        let indentRefused4 = await harness.run { harness.input.indent() }
        XCTAssertFalse(indentRefused4, "its children would pass the bound")
        try select(harness, from: ("b", 1), to: ("c", 1))
        let indentRefused5 = await harness.run { harness.input.indent() }
        XCTAssertFalse(indentRefused5, "a selection across blocks")
        XCTAssertNil(harness.input.noticeKey)
        XCTAssertEqual(session.textView.textStorage.string, original)
        try await assertConsistent(harness, localCommands: 0)
        // Within the bound it nests.
        try caret(harness, "b", 0)
        let indented = await harness.run { harness.input.indent() }
        XCTAssertTrue(indented)
        try await assertConsistent(harness, localCommands: 1)
    }

    func testAMoveCopiesRawValuesAndRefusesAnUnreadableSubtree() async throws {
        var rich = bullet("b", "")
        rich.runs = [
            InlineRun("Plain "), InlineRun("custom", marks: [("x-custom", "{\"v\":1}"), ("bold", "{}")]),
            InlineRun(" link", marks: [("link", "{\"href\":\"https://example.test/\"}")]),
        ]
        rich.props += [("x-extra", .string("kept"))]
        let harness = try await makeHarness([
            bullet("a", "Alpha"), nested(rich, [bullet("b1", "Child")]), bullet("c", "Gamma"),
            nested(bullet("d", "Delta"), [BlockNoteBlock(node: "table", props: [], runs: [], id: "table")]),
        ])
        addTeardownBlock { await harness.close() }
        let before = try unwrapped(await harness.engine { $0.nativeBlock("b")?.block })
        let child = try unwrapped(await harness.engine { $0.nativeBlock("b1")?.block })
        try caret(harness, "b", 2)
        let indented = await harness.run { harness.input.indent() }
        XCTAssertTrue(indented)
        let blockB = await harness.engine { $0.nativeBlock("b")?.block }
        let blockB1 = await harness.engine { $0.nativeBlock("b1")?.block }
        let parentB1 = await harness.engine { $0.nativeBlock("b1")?.parentID }
        XCTAssertEqual(blockB, before, "every prop and mark, known or not")
        XCTAssertEqual(blockB1, child)
        XCTAssertEqual(parentB1, "b")
        try await assertConsistent(harness, localCommands: 1)
        // A table cannot be proven lossless here: neither `d` nor its table moves.
        try caret(harness, "d", 0)
        let indentRefused = await harness.run { harness.input.indent() }
        XCTAssertFalse(indentRefused)
        try await assertConsistent(harness, localCommands: 1)
    }

    /// A peer that never saw the move edits a sibling and the moved block.
    /// Both converge; the sibling's edit survives, and the edit inside the
    /// moved block lands in the deleted original, as with BlockNote's own
    /// replace step (identity is not preserved).
    func testAConcurrentPeerEditDuringIndentConverges() async throws {
        let harness = try await makeHarness(listSeed())
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try caret(harness, "b", 4)
        let indented = await harness.run { harness.input.indent() }
        XCTAssertTrue(indented)

        let peer = try makeDoc(listSeed(), clientID: 2)
        defer { peer.destroy() }
        let writer = BlockNoteWriter(doc: peer)
        let edit = try writer.transaction { _ in
            try writer.replaceText(block: "c", range: 5..<5, with: "!")
            try writer.replaceText(block: "b", range: 0..<0, with: "Peer ")
        }
        try await session.integrateServerState(edit)
        XCTAssertEqual(texts(session), ["Alpha", "Beta", "Gamma!"])
        XCTAssertEqual(try block(session, "b").parentID, "a")
        XCTAssertEqual(harness.view.selectedRange.location, try location(session, "b", 4))
        try await assertConsistent(harness, localCommands: 1)

        let restored = try XCTUnwrap(harness.store.restore(for: harness.scope))
        for update in restored.updates { try peer.applyUpdate(YUpdateDecoder.decode(update), origin: .remote) }
        XCTAssertEqual(projection(peer), session.surface.blocks, "both replicas converge")
        // Typing in the moved block afterwards is ordinary nested typing.
        session.textView.insertText("!")
        await harness.settle()
        XCTAssertEqual(text(of: try block(session, "b")), "Beta!")
        try await assertConsistent(harness, localCommands: 2)
    }

    /// Backspace at a nested paragraph's start outdents it only as BlockNote's
    /// last fallback: when the block above (a previous sibling, or a first
    /// child's parent) is code, which cannot take merged text.
    func testBackspaceOutdentsANestedParagraphOnlyWhenItCannotMerge() async throws {
        func code(_ id: String) -> BlockNoteBlock {
            BlockNoteBlock(
                node: "codeBlock", props: [("language", .string("swift"))], runs: [InlineRun("let x")], id: id)
        }
        let harness = try await makeHarness([
            nested(bullet("a", "Alpha"), [code("code"), paragraph("q", "Q")]),
            nested(code("code2"), [paragraph("p", "P")]),
        ])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try caret(harness, "q", 0)
        harness.view.deleteBackward()
        await harness.settle()
        XCTAssertEqual(try block(session, "q").depth, 0, "code above: outdent")
        XCTAssertEqual(text(of: try block(session, "q")), "Q")
        try await assertConsistent(harness, localCommands: 1)
        try caret(harness, "p", 0)
        harness.view.deleteBackward()
        await harness.settle()
        XCTAssertEqual(try block(session, "p").depth, 0, "a code parent: outdent")
        XCTAssertEqual(text(of: try block(session, "code2")), "let x")
        try await assertConsistent(harness, localCommands: 2)
    }

    func testRelaunchReplaysTheTree() async throws {
        let harness = try await makeHarness(listSeed() + [bullet("d", "Delta")])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try caret(harness, "b", 0)
        let indB = await harness.run { harness.input.indent() }
        XCTAssertTrue(indB)
        try caret(harness, "c", 0)
        let indC1 = await harness.run { harness.input.indent() }
        XCTAssertTrue(indC1)
        let indC2 = await harness.run { harness.input.indent() }
        XCTAssertTrue(indC2)
        try caret(harness, "d", 0)
        let indD = await harness.run { harness.input.indent() }
        XCTAssertTrue(indD)
        let outD = await harness.run { harness.input.outdent() }
        XCTAssertTrue(outD)
        try await assertConsistent(harness, localCommands: 5)
        let expected = session.surface.blocks
        let expectedText = session.textView.textStorage.string
        XCTAssertEqual(expected.map(\.depth), [0, 1, 2, 0])
        await session.close().value

        let restored = try unwrapped(try await NativeEditorSession.restore(store: harness.store, scope: harness.scope))
        addTeardownBlock { await restored.close().value }
        XCTAssertEqual(restored.surface.blocks, expected)
        XCTAssertEqual(restored.textView.textStorage.string, expectedText)
        let restoredRevision = await restored.engine { $0.revision }
        XCTAssertEqual(restoredRevision, 5)
        XCTAssertTrue(restored.canType, "a nested list keeps its Markdown shadow")
    }

    func testTabKeysAndCodeBlocks() async throws {
        let harness = try await makeHarness([
            bullet("a", "Alpha"),
            BlockNoteBlock(
                node: "codeBlock", props: [("language", .string("swift"))], runs: [InlineRun("let x")], id: "code"),
        ])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let inputs = (harness.view.keyCommands ?? []).filter { $0.input == "\t" }
        XCTAssertEqual(inputs.map(\.modifierFlags), [[], .shift])
        XCTAssertTrue(inputs.allSatisfy(\.wantsPriorityOverSystemBehavior))
        // Tab in a code block indents its line with two spaces (BlockNote).
        try caret(harness, "code", 0)
        harness.view.insertText("\t")
        await harness.settle()
        XCTAssertEqual(text(of: try block(session, "code")), "  let x")
        XCTAssertEqual(try block(session, "code").depth, 0)
        try await assertConsistent(harness, localCommands: 1)
    }
}
