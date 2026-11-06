import XCTest

@testable import Schrift

/// The final review pass: mark order the event delta cannot see, delivery
/// after detach, release without detach, and per-block changes for ids the
/// same patch removed.
@MainActor
final class DocumentEngineFinalPassTests: DocumentEngineTestCase {
    private func paragraph(_ runs: [InlineRun], id: String = firstID) -> BlockNoteBlock {
        BlockNoteBlock(node: "paragraph", props: Self.paragraphProps, runs: runs, id: id)
    }

    // MARK: - 1. Mark order on retained text

    func testInsertingWithFewerMarksKeepsTheSuffixOrder() throws {
        let doc = try makeDoc(
            [paragraph([InlineRun("abcdef", marks: [("bold", "{}"), ("italic", "{}")])])], clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)

        try engine.replaceText(
            block: Self.firstID, range: 3..<3, with: "X", marks: [TextMark(key: "italic", valueJSON: "{}")])

        assertSurfaceMatchesProjection(surface, doc, "after an italic-only insert inside bold+italic")
    }

    // MARK: - 2. Nothing is delivered after a mid-flush detach

    private final class DetachingSurface: EditorSurface {
        var onFirst: (() -> Void)?
        private(set) var received: [BlockPatch] = []
        func applyPatch(_ patch: BlockPatch) {
            received.append(patch)
            if received.count == 1 { onFirst?() }
        }
    }

    func testDetachingFromApplyPatchDropsTheRestOfTheFlush() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let index = BlockIndex(doc: doc)
        let firstText = try XCTUnwrap(index.entries[Self.firstID]?.textType)
        let thirdText = try XCTUnwrap(index.entries[Self.thirdID]?.textType)
        // A hook installed before the engine opens a second transaction from
        // the first one's observer phase (as the format cleanup does), so one
        // flush carries two patches.
        var nested = false
        doc.afterTransaction = { _ in
            guard !nested else { return }
            nested = true
            try? doc.transact { _ in try thirdText.insert(0, "Z") }
        }
        let surface = DetachingSurface()
        let engine = DocumentEngine(doc: doc, surface: surface)
        surface.onFirst = { engine.detach() }

        try doc.transact { _ in try firstText.insert(0, "A") }

        XCTAssertEqual(surface.received.count, 1, "the second buffered patch must not reach a detached surface")
    }

    // MARK: - 3. Releasing the engine detaches it

    func testReleasingTheEngineClearsItsHooks() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let first = HeadlessSurface(blocks: projection(doc))
        var engine: DocumentEngine? = DocumentEngine(doc: doc, surface: first)
        XCTAssertNotNil(engine)
        engine = nil

        XCTAssertNil(doc.afterAllTransactions)
        XCTAssertNil(doc.onDestroy)
        XCTAssertNil(doc.afterTransaction)

        // A second editor on the same lingering replica attaches cleanly.
        let second = HeadlessSurface(blocks: projection(doc))
        let reopened = DocumentEngine(doc: doc, surface: second)
        try reopened.replaceText(block: Self.firstID, range: 0..<0, with: "X")
        assertSurfaceMatchesProjection(second, doc, "after reopening on the lingering replica")
        XCTAssertTrue(first.appliedPatches.isEmpty)
    }

    // MARK: - 4. No per-block change for a removed id

    func testReorderWithAnEditSendsNoChangeForRemovedIDs() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        let index = BlockIndex(doc: doc)
        let group = try XCTUnwrap(index.rootGroupType())
        let first = try XCTUnwrap(index.entries[Self.firstID])
        let third = try XCTUnwrap(index.entries[Self.thirdID])
        let secondText = try XCTUnwrap(index.entries[Self.secondID]?.textType)

        // Move the first block to the end (delete + re-create under its id)
        // and edit the second block, in one transaction.
        try doc.transact { tx in
            first.containerItem.delete(tx)
            let container = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            _ = try YWrite.insertAfter(tx, into: group, after: third.containerItem, [.type(container)])
            try YWrite.mapSet(tx, on: container, key: "id", .any([.string(Self.firstID)]))
            let element = YType(typeRef: .xmlElement(nodeName: "paragraph"))
            _ = try YWrite.insertAfter(tx, into: container, after: nil, [.type(element)])
            let text = YType(typeRef: .xmlText)
            _ = try YWrite.insertAfter(tx, into: element, after: nil, [.type(text)])
            try text.insert(0, "Moved.")
            try secondText.insert(0, "S")
        }

        let patch = try XCTUnwrap(surface.appliedPatches.last)
        var removed: Set<String> = []
        for change in patch.changes {
            switch change {
            case .remove(let ids): removed.formUnion(ids)
            case .text(let id, _), .props(let id, _), .replaceBlock(let id, _):
                XCTAssertFalse(removed.contains(id), "a per-block change addresses removed id \(id): \(patch.changes)")
            default: break
            }
        }
        XCTAssertFalse(removed.isEmpty, "the move must be a remove + insert, got \(patch.changes)")
        _ = engine
        assertSurfaceMatchesProjection(surface, doc, "after a move plus an edit")
    }
}
