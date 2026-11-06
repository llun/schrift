import XCTest

@testable import Schrift

@MainActor
final class DocumentEngineSelectionTests: DocumentEngineTestCase {
    func testPeerInsertBeforeAndAfterCaretRemapsBothEndpoints() throws {
        let local = try makeDoc(clientID: 1)
        defer { local.destroy() }
        let peer = try makeDoc(clientID: 2)
        defer { peer.destroy() }
        let surface = HeadlessSurface(blocks: projection(local))
        let peerSurface = HeadlessSurface(blocks: projection(peer))
        let engine = DocumentEngine(doc: local, surface: surface)
        let peerEngine = DocumentEngine(doc: peer, surface: peerSurface)
        try engine.setSelection(selection(anchor: 6, head: 10))

        try local.applyUpdate(
            YUpdateDecoder.decode(peerEngine.replaceText(block: Self.firstID, range: 0..<0, with: "A ")),
            origin: .remote)
        XCTAssertEqual(try engine.currentSelection(), selection(anchor: 8, head: 12))
        assertSurfaceMatchesProjection(surface, local, "insert before selection")
        assertSurfaceMatchesProjection(peerSurface, peer, "peer insert before selection")

        try local.applyUpdate(
            YUpdateDecoder.decode(peerEngine.replaceText(block: Self.firstID, range: 15..<15, with: "!")),
            origin: .remote)
        XCTAssertEqual(try engine.currentSelection(), selection(anchor: 8, head: 12))
        assertSurfaceMatchesProjection(surface, local, "insert after selection")
        assertSurfaceMatchesProjection(peerSurface, peer, "peer insert after selection")
        XCTAssertEqual(YXMLString.fragment(local), YXMLString.fragment(peer))
    }

    func testAffinityAtCaretAndEndOfText() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        try engine.setSelection(
            EditorSelection(
                anchor: EditorPosition(blockID: Self.firstID, offset: 6, assoc: -1),
                head: EditorPosition(blockID: Self.firstID, offset: 6, assoc: 0)))
        try doc.transact(origin: .remote) { _ in
            try XCTUnwrap(BlockIndex(doc: doc).entries[Self.firstID]?.textType).insert(6, "X")
        }
        XCTAssertEqual(
            try engine.currentSelection(),
            EditorSelection(
                anchor: EditorPosition(blockID: Self.firstID, offset: 6, assoc: -1),
                head: EditorPosition(blockID: Self.firstID, offset: 7, assoc: 0)))
        assertSurfaceMatchesProjection(surface, doc, "affinity at insertion")

        try engine.setSelection(
            EditorSelection(
                anchor: EditorPosition(blockID: Self.firstID, offset: 17, assoc: -1),
                head: EditorPosition(blockID: Self.firstID, offset: 17, assoc: 0)))
        try engine.replaceText(block: Self.firstID, range: 17..<17, with: "!")
        XCTAssertEqual(
            try engine.currentSelection(),
            EditorSelection(
                anchor: EditorPosition(blockID: Self.firstID, offset: 17, assoc: -1),
                head: EditorPosition(blockID: Self.firstID, offset: 18, assoc: 0)))
        assertSurfaceMatchesProjection(surface, doc, "affinity at end")
    }

    func testDeletedCaretTextCollapsesToSurvivingBoundary() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        try engine.setSelection(selection(anchor: 6, head: 8))
        try doc.transact(origin: .remote) { _ in
            try XCTUnwrap(BlockIndex(doc: doc).entries[Self.firstID]?.textType).delete(4, 6)
        }
        XCTAssertEqual(try engine.currentSelection(), selection(anchor: 4, head: 4))
        assertSurfaceMatchesProjection(surface, doc, "deleted selection text")
    }

    func testCrossBlockBackwardSelectionUsesUTF16AndCanBeCleared() throws {
        let blocks =
            [BlockNoteBlock(node: "paragraph", props: Self.paragraphProps, runs: [InlineRun("A😀B")], id: Self.firstID)]
            + Array(Self.seedBlocks().dropFirst())
        let doc = try makeDoc(blocks, clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        let original = EditorSelection(
            anchor: EditorPosition(blockID: Self.secondID, offset: 3),
            head: EditorPosition(blockID: Self.firstID, offset: 3))
        try engine.setSelection(original)
        try engine.replaceText(block: Self.firstID, range: 0..<0, with: "😀")
        XCTAssertEqual(
            try engine.currentSelection(),
            EditorSelection(anchor: original.anchor, head: EditorPosition(blockID: Self.firstID, offset: 5)))
        try engine.setSelection(nil)
        XCTAssertNil(try engine.currentSelection())
        assertSurfaceMatchesProjection(surface, doc, "UTF-16 backward selection")
    }

    func testInvalidSelectionIsRejectedWithoutReplacingPreviousCapture() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        try engine.setSelection(selection(anchor: 2, head: 4))
        XCTAssertThrowsError(try engine.setSelection(selection(anchor: -1, head: 4)))
        XCTAssertThrowsError(try engine.setSelection(selection(anchor: 2, head: 999)))
        XCTAssertEqual(try engine.currentSelection(), selection(anchor: 2, head: 4))
        try engine.setBlockType(block: Self.firstID, to: "heading")
        XCTAssertNil(try engine.currentSelection(), "a replaced text type must not resolve into its replacement")
        assertSurfaceMatchesProjection(surface, doc, "invalidated text identity")
    }

    private func selection(anchor: Int, head: Int) -> EditorSelection {
        EditorSelection(
            anchor: EditorPosition(blockID: Self.firstID, offset: anchor),
            head: EditorPosition(blockID: Self.firstID, offset: head))
    }
}
