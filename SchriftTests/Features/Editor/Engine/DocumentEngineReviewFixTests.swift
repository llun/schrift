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

    private func rootGroup(_ doc: YDoc) throws -> YType {
        let root = try XCTUnwrap(doc.share[BlockNoteYjs.fragmentField])
        var item = root.start
        while let current = item {
            defer { item = current.right }
            if case .type(let type) = current.content, type.typeRef == .xmlElement(nodeName: "blockGroup") {
                return type
            }
        }
        throw XCTSkip("no root group")
    }

    // MARK: - 1. Nested text escalates to the top-level block

    func testNestedBlockTextChangeReplacesTheTopLevelBlock() throws {
        let doc = try makeDoc(nestedSeed(), clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)

        try engine.replaceText(block: Self.childID, range: 0..<0, with: "X")

        let patch = try XCTUnwrap(surface.appliedPatches.last)
        XCTAssertTrue(
            patch.changes.contains {
                if case .replaceBlock(let id, _) = $0 { return id == Self.parentID } else { return false }
            },
            "a nested text change must rebuild the top-level block, got \(patch.changes)")
        XCTAssertFalse(
            patch.changes.contains {
                if case .text(let id, _) = $0 { return id == Self.parentID } else { return false }
            },
            "nested offsets must never be emitted as the parent's text")
        assertSurfaceMatchesProjection(surface, doc, "after the nested text change")
    }

    // MARK: - 2. A nested group change is not a top-level insert

    func testNestedGroupChangeDoesNotEmitAPhantomInsert() throws {
        let doc = try makeDoc(nestedSeed(), clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)

        try engine.splitBlock(block: Self.childID, at: 3, newID: Self.splitID)

        let patch = try XCTUnwrap(surface.appliedPatches.last)
        XCTAssertFalse(
            patch.changes.contains { if case .insert = $0 { return true } else { return false } },
            "a nested group must not produce a top-level insert, got \(patch.changes)")
        XCTAssertEqual(surface.blocks.count, 1)
        assertSurfaceMatchesProjection(surface, doc, "after the nested split")
    }

    // MARK: - 3. A move reorders the surface

    func testAReorderInTheRootGroupEmitsRemoveAndInsert() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let group = try rootGroup(doc)
        // The index remembers the replica as [second, third, first]; the replica
        // is [first, second, third]. A membership-neutral group change must be
        // read as a reorder, not as "nothing changed".
        var index = BlockIndex(doc: doc)
        index.setGroupOrder(group, [Self.secondID, Self.thirdID, Self.firstID])
        var builder = PatchBuilder(doc: doc, index: index)

        var patch = BlockPatch()
        try doc.transact { tx in
            let bare = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            let item = try YWrite.insertAfter(tx, into: group, after: nil, [.type(bare)])
            item?.delete(tx)
            patch = builder.build(tx)
        }

        XCTAssertTrue(patch.changes.contains { if case .remove = $0 { return true } else { return false } })
        let inserted = patch.changes.compactMap { change -> [BlockSnapshot]? in
            if case .insert(_, let blocks) = change { return blocks } else { return nil }
        }.flatMap { $0 }
        XCTAssertEqual(inserted.map(\.id), [Self.firstID, Self.secondID, Self.thirdID])
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
