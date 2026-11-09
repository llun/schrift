import UIKit
import XCTest

@testable import Schrift

/// PR06a: the native tree projection (preorder, any depth, handles), the
/// index that mirrors it, nested rendering, and typing, split, join, range,
/// marks and props inside nested blocks. Real `NativeTextView` input over a
/// restored durable replica; every action is exactly one journaled command
/// and storage equals the projection. No sleeps.
@MainActor
final class NativeTreeProjectionTests: NativeEditingTestCase {
    private func nested(_ block: BlockNoteBlock, _ children: [BlockNoteBlock]) -> BlockNoteBlock {
        var block = block
        block.children = children
        return block
    }

    private func numbered(_ id: String, _ text: String) -> BlockNoteBlock {
        BlockNoteBlock(
            node: "numberedListItem", props: Self.paragraphProps + [("start", .undefined)], runs: [InlineRun(text)],
            id: id)
    }

    private func check(_ id: String, _ text: String) -> BlockNoteBlock {
        BlockNoteBlock(
            node: "checkListItem", props: Self.paragraphProps + [("checked", .bool(false))], runs: [InlineRun(text)],
            id: id)
    }

    /// A chain `levels` deep: each block the only child of the one before.
    private func chain(_ levels: Int, prefix: String = "level") -> BlockNoteBlock {
        var block = paragraph("\(prefix)-\(levels - 1)", "Level \(levels - 1)")
        for level in stride(from: levels - 2, through: 0, by: -1) {
            block = nested(paragraph("\(prefix)-\(level)", "Level \(level)"), [block])
        }
        return block
    }

    private func treeSeed() -> [BlockNoteBlock] {
        [
            nested(
                bullet("a", "Alpha"),
                [bullet("a1", "Alpha one"), nested(bullet("a2", "Alpha two"), [paragraph("a2x", "Deep")])]),
            paragraph("b", "Beta"),
        ]
    }

    // MARK: - Projection and index

    func testATreeProjectsInPreorderWithDepthParentAndHandles() throws {
        let doc = try makeDoc(treeSeed() + [chain(20)], clientID: 1)
        defer { doc.destroy() }
        let generation = UUID()
        let tree = NativeBlockProjection.project(doc, generation: generation)
        XCTAssertTrue(tree.isFullyModeled)
        XCTAssertEqual(
            Array(tree.blocks.prefix(5)).map(\.id), ["a", "a1", "a2", "a2x", "b"], "preorder: children after parent")
        XCTAssertEqual(Array(tree.blocks.prefix(5)).map(\.depth), [0, 1, 1, 2, 0])
        XCTAssertEqual(Array(tree.blocks.prefix(5)).map(\.parentID), [nil, "a", "a", "a2", nil])
        XCTAssertEqual(tree.blocks.last?.depth, 19, "any depth below the bound")
        let writer = BlockNoteWriter(doc: doc)
        for block in tree.blocks {
            XCTAssertEqual(block.handle.generation, generation)
            XCTAssertEqual(block.handle.stringID, block.id)
            XCTAssertEqual(block.handle.itemID, try writer.find(block.id).item.id, "the integrated container's id")
        }
        // The index mirrors the projection the engine's patches converge to.
        let index = BlockIndex(doc: doc)
        XCTAssertTrue(index.isCanonical)
        XCTAssertEqual(index.order, tree.blocks.map(\.id))
        XCTAssertEqual(index.order.map { index.entries[$0]?.depth }, tree.blocks.map(\.depth))
        XCTAssertEqual(index.order.map { index.entries[$0]?.parentID }, tree.blocks.map(\.parentID))
        XCTAssertTrue(index.entries["a"]?.isSimpleText == true, "a parent with children keeps its text fast path")
        // A flat document reads exactly as the classic projection reads it.
        let flat = try makeDoc(clientID: 1)
        defer { flat.destroy() }
        XCTAssertEqual(
            NativeBlockProjection.project(flat).blocks.map(BlockSnapshot.init),
            YBlockProjection.project(flat, nativeMarks: true).blocks.map(BlockSnapshot.init))
    }

    func testNestingPastTheBoundIsOpaqueAndPreserved() throws {
        let levels = NativeBlockProjection.maxDepth + 6
        let doc = try makeDoc([chain(levels)], clientID: 1)
        defer { doc.destroy() }
        let tree = NativeBlockProjection.project(doc)
        XCTAssertEqual(tree.blocks.count, NativeBlockProjection.maxDepth + 1, "nothing below the bound is projected")
        XCTAssertTrue(try XCTUnwrap(tree.blocks.last).block.fidelity.isOpaque)
        XCTAssertFalse(tree.isFullyRenderable)
        XCTAssertNoThrow(try BlockNoteWriter(doc: doc).find("level-\(levels - 1)"), "still in the replica")
        let index = BlockIndex(doc: doc)
        XCTAssertEqual(index.order, tree.blocks.map(\.id))
        XCTAssertEqual(index.entries[tree.blocks.last!.id]?.isProjectable, false, "no fast path into it")
    }

    /// A peer's change inside a subtree the index does not descend into (past
    /// the depth bound) is the nearest indexed block's: it is rebuilt, never
    /// dropped (review round 1).
    func testAChangeBelowTheBoundRebuildsTheNearestIndexedBlock() throws {
        let levels = NativeBlockProjection.maxDepth + 3
        let doc = try makeDoc([chain(levels)], clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        let capped = "level-\(NativeBlockProjection.maxDepth)"
        try BlockNoteWriter(doc: doc).replaceText(block: "level-\(levels - 1)", range: 0..<0, with: "Peer ")
        let patch = try XCTUnwrap(surface.appliedPatches.last)
        XCTAssertTrue(
            patch.changes.contains { if case .replaceBlock(capped, _) = $0 { return true } else { return false } },
            "got \(patch.changes)")
        assertSurfaceMatchesProjection(surface, doc, "after the hidden change")
        _ = engine
    }

    func testDuplicateAndMissingIDsMakeThatSubtreeOpaqueAndReadOnly() throws {
        let harness = try makeHarness([
            paragraph("first", "First"), nested(paragraph("dup", "One"), [paragraph("kid", "Kid")]),
            nested(paragraph("dup", "Two"), [paragraph("hidden", "Hidden")]), paragraph("last", "Last"),
        ])
        defer { harness.close() }
        let session = harness.session
        XCTAssertEqual(session.surface.blocks.map(\.id), ["first", "dup", "kid", "dup", "last"])
        XCTAssertEqual(session.surface.blocks.map(\.isOpaque), [false, false, false, true, false])
        XCTAssertFalse(session.canType)
        // Nothing is written anywhere while the index cannot address ids.
        let original = session.textView.textStorage.string
        setSelection(harness, NSRange(location: try location(session, "last", 0), length: 0))
        session.textView.insertText("x")
        XCTAssertFalse(harness.input.indent())
        XCTAssertEqual(session.textView.textStorage.string, original)
        XCTAssertTrue(harness.log.commands.isEmpty)

        // A container without an id: it and its children are one placeholder.
        let doc = try makeDoc(
            [paragraph("p", "P"), nested(paragraph("gone", "Gone"), [paragraph("c", "C")])], clientID: 1)
        defer { doc.destroy() }
        let container = try BlockNoteWriter(doc: doc).find("gone").container
        try doc.transact { tx in container.map["id"]?.delete(tx) }
        let tree = NativeBlockProjection.project(doc)
        XCTAssertEqual(tree.blocks.map(\.id), ["p", ""])
        XCTAssertEqual(tree.blocks.last?.block.fidelity, .opaque(reason: "missing block id"))
        XCTAssertFalse(BlockIndex(doc: doc).isCanonical)
    }

    func testUnknownChildrenArePlaceholdersAndTheirSiblingsStayEditable() throws {
        let harness = try makeHarness([
            nested(
                paragraph("parent", "Parent"),
                [BlockNoteBlock(node: "table", props: [], runs: [], id: "table"), paragraph("sibling", "Sibling")]),
            nested(BlockNoteBlock(node: "mystery", props: [], runs: [], id: "mystery"), [paragraph("under", "Under")]),
        ])
        defer { harness.close() }
        let session = harness.session
        XCTAssertEqual(session.surface.blocks.map(\.id), ["parent", "table", "sibling", "mystery", "under"])
        XCTAssertEqual(session.surface.blocks.map(\.isOpaque), [false, true, false, true, false])
        XCTAssertEqual(session.surface.blocks.map(\.depth), [0, 1, 1, 0, 1])
        // Opacity does not spread: the children of an unknown block are blocks.
        setSelection(harness, NSRange(location: try location(session, "under", 5), length: 0))
        session.textView.insertText("!")
        setSelection(harness, NSRange(location: try location(session, "sibling", 0), length: 0))
        session.textView.insertText("A ")
        XCTAssertEqual(text(of: try block(session, "under")), "Under!")
        XCTAssertEqual(text(of: try block(session, "sibling")), "A Sibling")
        try assertConsistent(harness, localCommands: 2)
        // Nothing nests under or moves an unknown block.
        setSelection(harness, NSRange(location: try location(session, "sibling", 0), length: 0))
        XCTAssertFalse(harness.input.indent(), "the block above is a table")
        try assertConsistent(harness, localCommands: 2)
    }

    // MARK: - Editing inside nested blocks

    func testTypingInANestedBlockKeepsTheTextFastPath() throws {
        let harness = try makeHarness(treeSeed())
        defer { harness.close() }
        let session = harness.session
        let projected = session.engine.projectedBlockCount
        setSelection(harness, NSRange(location: try location(session, "a2x", 4), length: 0))
        for character in " text" { session.textView.insertText(String(character)) }
        XCTAssertEqual(text(of: try block(session, "a2x")), "Deep text")
        XCTAssertEqual(session.engine.projectedBlockCount, projected, "each keystroke is a .text patch")
        XCTAssertEqual(session.textView.selectedRange.location, try location(session, "a2x", 9))
        try assertConsistent(harness, localCommands: 5)
    }

    func testReturnInANestedItemMakesASiblingAtTheSameDepth() throws {
        let harness = try makeHarness(treeSeed())
        defer { harness.close() }
        let session = harness.session
        setSelection(harness, NSRange(location: try location(session, "a1", 5), length: 0))
        session.textView.insertText("\n")
        guard case .split(_, let newID)? = harness.log.commands.last?.kind else { return XCTFail("not a split") }
        let new = try block(session, newID)
        XCTAssertEqual(new.node, "bulletListItem")
        XCTAssertEqual(new.depth, 1)
        XCTAssertEqual(new.parentID, "a")
        XCTAssertEqual(session.surface.blocks.map(\.id), ["a", "a1", newID, "a2", "a2x", "b"])
        XCTAssertEqual(Array(texts(session)[1...2]), ["Alpha", " one"])
        XCTAssertEqual(session.textView.selectedRange.location, try location(session, newID, 0))
        try assertConsistent(harness, localCommands: 1)
        // Return in a block with children: the new block takes them (BlockNote).
        setSelection(harness, NSRange(location: try location(session, "a2", 5), length: 0))
        session.textView.insertText("\n")
        guard case .split(_, let second)? = harness.log.commands.last?.kind else { return XCTFail("not a split") }
        XCTAssertEqual(try block(session, "a2x").parentID, second)
        try assertConsistent(harness, localCommands: 2)
    }

    /// BlockNote's Enter: an empty nested list item first becomes a
    /// paragraph; Enter in an empty nested paragraph outdents it.
    func testReturnOnAnEmptyNestedItemResetsThenOutdents() throws {
        let harness = try makeHarness([nested(bullet("a", "Alpha"), [bullet("e", ""), bullet("f", "After")])])
        defer { harness.close() }
        let session = harness.session
        setSelection(harness, NSRange(location: try location(session, "e", 0), length: 0))
        session.textView.insertText("\n")
        XCTAssertEqual(try block(session, "e").node, "paragraph")
        XCTAssertEqual(try block(session, "e").depth, 1)
        try assertConsistent(harness, localCommands: 1)
        session.textView.insertText("\n")
        XCTAssertEqual(try block(session, "e").depth, 0)
        XCTAssertEqual(try block(session, "f").parentID, "e", "the sibling after it becomes its child")
        XCTAssertEqual(session.textView.selectedRange.location, try location(session, "e", 0))
        try assertConsistent(harness, localCommands: 2)
    }

    func testRangesMarksAndPropsWorkInsideNestedBlocks() throws {
        let harness = try makeHarness([
            nested(
                bullet("a", "Alpha"), [bullet("x", "First child"), bullet("y", "Second child"), check("c", "Task")]),
            paragraph("b", "Beta"),
        ])
        defer { harness.close() }
        let session = harness.session
        // Bold across two nested siblings: one marks command.
        try select(harness, from: ("x", 6), to: ("y", 6))
        XCTAssertTrue(harness.input.toggleMark("bold"))
        XCTAssertEqual(try block(session, "y").runs.first?.marks.map(\.0), ["bold"])
        try assertConsistent(harness, localCommands: 1)
        // A range replacement inside one nested group joins them.
        try select(harness, from: ("x", 5), to: ("y", 6))
        session.textView.insertText(" and")
        XCTAssertEqual(texts(session)[1], "First and child")
        XCTAssertEqual(try block(session, "x").depth, 1)
        try assertConsistent(harness, localCommands: 2)
        // A range across depths waits for subtree commands: refused, no write.
        try select(harness, from: ("x", 2), to: ("b", 2))
        session.textView.insertText("z")
        XCTAssertEqual(harness.input.noticeKey, .native_editor_range_unavailable)
        try assertConsistent(harness, localCommands: 2)
        // A nested checkbox is one prop command.
        XCTAssertTrue(harness.input.toggleCheckbox(blockID: "c"))
        XCTAssertTrue(try block(session, "c").props.contains(ProjectedProp(key: "checked", value: .bool(true))))
        try assertConsistent(harness, localCommands: 3)
    }

    // MARK: - Rendering

    func testNestedBlocksIndentByDepthAndNumberPerSiblingRun() throws {
        let harness = try makeHarness([
            nested(numbered("n1", "One"), [numbered("n1a", "One A"), numbered("n1b", "One B")]),
            numbered("n2", "Two"),
            nested(paragraph("p", "Para"), [numbered("pa", "Under para")]),
        ])
        defer { harness.close() }
        let session = harness.session
        XCTAssertEqual(
            AttributedDocumentProjection.listNumbers(in: session.surface.blocks), [1, 1, 2, 2, nil, 1],
            "children number on their own; the parent's run continues past them")
        let storage = session.textView.textStorage
        func indent(_ id: String) throws -> CGFloat {
            let style = storage.attribute(.paragraphStyle, at: try location(session, id, 0), effectiveRange: nil)
            return try XCTUnwrap(style as? NSParagraphStyle).headIndent
        }
        let gutter = UIFontMetrics(forTextStyle: .body).scaledValue(
            for: NativeBlockMetrics.listGutter, compatibleWith: session.surface.traits)
        XCTAssertEqual(try indent("n1a") - indent("n1"), gutter, accuracy: 0.01)
        XCTAssertEqual(try indent("pa") - indent("n2"), gutter, accuracy: 0.01)
        XCTAssertEqual(try indent("p"), 0, accuracy: 0.01)
        XCTAssertEqual(
            storage.attribute(.nativeDepth, at: try location(session, "n1a", 0), effectiveRange: nil) as? Int, 1)
        XCTAssertNil(storage.attribute(.nativeDepth, at: try location(session, "n2", 0), effectiveRange: nil))
        // Typing renumbers nothing and keeps the slice equal to a fresh projection.
        setSelection(harness, NSRange(location: try location(session, "n1b", 5), length: 0))
        session.textView.insertText("!")
        XCTAssertEqual(
            storage.attribute(.nativeListNumber, at: try location(session, "n1b", 0), effectiveRange: nil) as? Int, 2)
        try assertConsistent(harness, localCommands: 1)
    }

    /// The native save's Markdown shadow nests list items, so a nested
    /// document stays typeable and savable.
    func testTheShadowNestsListItems() throws {
        let doc = try makeDoc(
            [nested(bullet("a", "Alpha"), [bullet("b", "Beta")]), paragraph("p", "Para")], clientID: 1)
        defer { doc.destroy() }
        XCTAssertEqual(NativeBlockProjection.markdownShadow(doc), "- Alpha\n  - Beta\n\nPara\n")
        XCTAssertNil(
            YBlockProjection.projectedMarkdown(YBlockProjection.project(doc)), "the classic shadow is unchanged")
        let flat = try makeDoc(clientID: 1)
        defer { flat.destroy() }
        XCTAssertEqual(
            NativeBlockProjection.markdownShadow(flat),
            YBlockProjection.projectedMarkdown(YBlockProjection.project(flat)))
    }
}
