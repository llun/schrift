import XCTest

@testable import Schrift

/// One test per review-round-1 finding on the B6a engine. Each is written to
/// fail with its fix reverted; the PR records the break/run/restore table.
@MainActor
final class DocumentEngineReviewFixTests: DocumentEngineTestCase {
    private static let parentID = "b0000000-0000-4000-8000-0000000000c1"
    private static let childID = "b0000000-0000-4000-8000-0000000000c2"
    private static let splitID = "b0000000-0000-4000-8000-0000000000c3"

    private func nestedSeed() -> [BlockNoteBlock] {
        [
            BlockNoteBlock(
                node: "paragraph", props: Self.paragraphProps, runs: [InlineRun("Parent")],
                id: Self.parentID,
                children: [
                    BlockNoteBlock(
                        node: "paragraph", props: Self.paragraphProps, runs: [InlineRun("Child")],
                        id: Self.childID)
                ])
        ]
    }

    // MARK: - 1. Nested text is the nested block's own text (PR06a)

    func testNestedBlockTextChangeIsTheNestedBlocksText() throws {
        let doc = try makeDoc(nestedSeed(), clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)

        try engine.replaceText(block: Self.childID, range: 0..<0, with: "X")

        let patch = try XCTUnwrap(surface.appliedPatches.last)
        XCTAssertEqual(
            patch.changes,
            [.text(blockID: Self.childID, deltas: [TextDelta(range: 0..<0, replacement: "X", marks: [])])],
            "a nested text change keeps the text fast path, never the parent's offsets")
        assertSurfaceMatchesProjection(surface, doc, "after the nested text change")
    }

    // MARK: - 2. A nested split inserts after the nested block

    func testNestedSplitInsertsTheNewBlockAfterTheNestedOne() throws {
        let doc = try makeDoc(nestedSeed(), clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)

        try engine.splitBlock(block: Self.childID, at: 3, newID: Self.splitID)

        let patch = try XCTUnwrap(surface.appliedPatches.last)
        XCTAssertTrue(
            patch.changes.contains {
                if case .insert(Self.childID?, let blocks) = $0 { return blocks.map(\.id) == [Self.splitID] }
                return false
            }, "the new sibling follows the nested block, got \(patch.changes)")
        XCTAssertEqual(surface.blocks.map(\.depth), [0, 1, 1])
        assertSurfaceMatchesProjection(surface, doc, "after the nested split")
    }

    // MARK: - 3. A move reorders the surface

    func testAReorderInTheRootGroupEmitsRemoveAndInsert() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        // A peer's move is a clone and delete under the same id: [first,
        // second, third] becomes [second, third, first]. Membership is
        // unchanged, so only the order says something moved.
        let writer = BlockNoteWriter(doc: doc)
        let first = try writer.find(Self.firstID)
        let third = try writer.find(Self.thirdID)
        let copy = try writer.snapshot(first.container, block: Self.firstID, depth: 0)
        try writer.transaction { tx in
            try writer.insertCopy(tx, copy, into: first.group, after: third.item)
            first.item.delete(tx)
        }

        let patch = try XCTUnwrap(surface.appliedPatches.last)
        XCTAssertTrue(patch.changes.contains { if case .remove = $0 { return true } else { return false } })
        let inserted = patch.changes.compactMap { change -> [BlockSnapshot]? in
            if case .insert(_, let blocks) = change { return blocks } else { return nil }
        }.flatMap { $0 }
        XCTAssertEqual(inserted.map(\.id), [Self.secondID, Self.thirdID, Self.firstID])
        assertSurfaceMatchesProjection(surface, doc, "after the move")
        _ = engine
    }

    // MARK: - 4. The root is re-resolved after an empty start

    func testAnEngineCreatedOnAnEmptyDocumentPatchesOnceTheRootAppears() throws {
        let doc = YDoc(clientID: 1, gc: true)
        defer { doc.destroy() }
        let surface = HeadlessSurface()
        let engine = DocumentEngine(doc: doc, surface: surface)

        try doc.applyUpdate(YUpdateDecoder.decode(BlockNoteYjs.encode(Self.seedBlocks(), clientID: 1)))
        assertSurfaceMatchesProjection(surface, doc, "after the seed")

        try engine.replaceText(block: Self.firstID, range: 0..<0, with: "A")
        assertSurfaceMatchesProjection(surface, doc, "after the first edit")
    }

    // MARK: - 5. Insert marks follow the projection's format-item order

    func testInsertMarksFollowTheProjectionsOrder() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)

        // The delta's attributes are a Dictionary; the text's format items keep
        // the caller's order. Insert in the reverse of the Dictionary's order so
        // the two are guaranteed to differ.
        let dictionaryOrder = Array(["bold": 0, "italic": 0].keys)
        let marks = dictionaryOrder.reversed().map { TextMark(key: $0, valueJSON: "{}") }
        try engine.replaceText(block: Self.firstID, range: 0..<0, with: "X", marks: marks)

        assertSurfaceMatchesProjection(surface, doc, "after a two-mark insert")
        let run = try XCTUnwrap(block(surface, Self.firstID)?.runs.first)
        XCTAssertEqual(run.marks.map(\.0), marks.map(\.key))
    }

    // MARK: - 6. No marks in force is an explicit empty set

    func testInsertingAtTheStartOfABoldRunIsPlain() throws {
        let blocks = [
            BlockNoteBlock(
                node: "paragraph", props: Self.paragraphProps,
                runs: [InlineRun("bold", marks: [("bold", "{}")]), InlineRun(" plain")],
                id: Self.firstID)
        ]
        let doc = try makeDoc(blocks, clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)

        try engine.replaceText(block: Self.firstID, range: 0..<0, with: "X")

        assertSurfaceMatchesProjection(surface, doc, "after inserting at offset 0")
        let run = try XCTUnwrap(block(surface, Self.firstID)?.runs.first)
        XCTAssertEqual(run.text, "X")
        XCTAssertTrue(run.marks.isEmpty, "the insertion must not inherit the bold to its right")
    }

    // MARK: - 7. Props and text in one transaction rebuild the block

    func testPropsAndTextChangedTogetherRebuildTheBlock() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)

        let index = BlockIndex(doc: doc)
        let entry = try XCTUnwrap(index.entries[Self.firstID])
        let element = try XCTUnwrap(entry.element)
        let text = try XCTUnwrap(entry.textType)
        try doc.transact { tx in
            try YWrite.mapSet(tx, on: element, key: "textColor", .any([.string("red")]))
            try text.insert(0, "X")
        }

        let patch = try XCTUnwrap(surface.appliedPatches.last)
        XCTAssertTrue(
            patch.changes.contains {
                if case .replaceBlock(let id, _) = $0 { return id == Self.firstID } else { return false }
            },
            "props and text together are not a text-only change, got \(patch.changes)")
        assertSurfaceMatchesProjection(surface, doc, "after props and text together")
    }

    // MARK: - 8. A surface that transacts from applyPatch is not re-entered

    func testASurfaceThatTransactsFromApplyPatchIsNotReentered() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let surface = TransactingSurface(doc: doc, blockID: Self.firstID)
        let engine = DocumentEngine(doc: doc, surface: surface)

        try engine.replaceText(block: Self.secondID, range: 0..<0, with: "A")

        XCTAssertEqual(surface.maxDepth, 1, "patches produced during delivery must be drained by the outermost flush")
        XCTAssertEqual(surface.patches.count, 2)
    }
}

/// A surface that opens a transaction from `applyPatch`, as a UIKit text view
/// does when it mutates its storage synchronously.
private final class TransactingSurface: EditorSurface {
    private let doc: YDoc
    private let blockID: String
    private let writer: BlockNoteWriter
    private var didTransact = false
    private var depth = 0
    private(set) var maxDepth = 0
    private(set) var patches: [BlockPatch] = []
    private(set) var blocks: [BlockSnapshot]

    init(doc: YDoc, blockID: String) {
        self.doc = doc
        self.blockID = blockID
        self.writer = BlockNoteWriter(doc: doc)
        self.blocks = YBlockProjection.project(doc).blocks.map(BlockSnapshot.init)
    }

    func applyPatch(_ patch: BlockPatch) {
        depth += 1
        maxDepth = max(maxDepth, depth)
        patches.append(patch)
        if !didTransact {
            didTransact = true
            try? writer.replaceText(block: blockID, range: 0..<0, with: "!")
        }
        depth -= 1
    }
}
