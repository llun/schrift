import XCTest

@testable import Schrift

@MainActor
final class DocumentEngineCompositionTests: DocumentEngineTestCase {
    func testCommitWritesOneLocalTransactionAndOneRebuild() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        var origins: [YTransactionOrigin?] = []
        doc.afterTransaction = { origins.append($0.origin) }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        let caret = EditorPosition(blockID: Self.firstID, offset: 6)
        try engine.setSelection(EditorSelection(anchor: caret, head: caret))
        try engine.compositionBegan(blockID: Self.firstID)
        XCTAssertTrue(surface.isCompositionDeferred)
        XCTAssertTrue(surface.appliedPatches.isEmpty)
        let update = try engine.compositionCommitted(text: "日本")

        XCTAssertNotEqual(update, Data([0, 0]))
        XCTAssertEqual(origins, [.localUser])
        XCTAssertEqual(text(of: surface.blocks[0]), "First 日本paragraph.")
        XCTAssertEqual(try engine.currentSelection()?.head.offset, 8)
        assertSingleRebuild(surface, origin: .localUser)
        XCTAssertEqual(surface.compositionDeferrals, [true, false])
        assertSurfaceMatchesProjection(surface, doc, "commit")
    }

    func testPeerTypingBeforeCaretDuringComposition() throws {
        try concurrentComposition(
            range: 0..<0, replacement: "A ", expectedAnchor: 8, expectedText: "A First にparagraph.")
    }

    func testPeerTypingAfterCaretDuringComposition() throws {
        try concurrentComposition(
            range: 10..<10, replacement: "!", expectedAnchor: 6, expectedText: "First にpara!graph.")
    }

    func testPeerTypingOverCaretDuringComposition() throws {
        // Left affinity names the deleted space. Its surviving boundary is
        // before the peer's replacement, not after that newly inserted text.
        try concurrentComposition(range: 4..<9, replacement: "X", expectedAnchor: 4, expectedText: "FirsにXagraph.")
    }

    func testEndOfTextAnchorStaysBeforePeerAppendAndCommitUsesUTF16() throws {
        let pair = try makePair()
        defer { pair.destroy() }
        let (local, peer, surface, peerSurface, engine, peerEngine) =
            (pair.a, pair.b, pair.surfaceA, pair.surfaceB, pair.engineA, pair.engineB)
        try engine.compositionBegan(blockID: Self.firstID, at: 16)
        try local.applyUpdate(
            YUpdateDecoder.decode(peerEngine.replaceText(block: Self.firstID, range: 16..<16, with: "!")),
            origin: .remote)
        try peer.applyUpdate(YUpdateDecoder.decode(engine.compositionCommitted(text: "😀に")), origin: .remote)
        XCTAssertEqual(text(of: surface.blocks[0]), "First paragraph.😀に!")
        XCTAssertEqual(try engine.currentSelection()?.head.offset, 19)
        assertSingleRebuild(surface, origin: .localUser)
        XCTAssertEqual(YXMLString.fragment(local), YXMLString.fragment(peer))
        assertSurfaceMatchesProjection(surface, local, "end-of-text composition")
        assertSurfaceMatchesProjection(peerSurface, peer, "peer end-of-text composition")
    }

    func testNonAddressableBlockDropsWriteAndRebuildsWithoutRetargeting() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        try engine.compositionBegan(blockID: Self.firstID, at: 6)
        let element = try XCTUnwrap(BlockIndex(doc: doc).entries[Self.firstID]?.element)
        try doc.transact { tx in
            try YWrite.insertAfter(tx, into: element, after: element.start, [.type(YType(typeRef: .xmlText))])
        }
        XCTAssertTrue(surface.appliedPatches.isEmpty, "other-origin changes are deferred too")
        let state = try YStateEncoder.encodeStateAsUpdate(doc)
        XCTAssertEqual(try engine.compositionCommitted(text: "LOST"), Data([0, 0]))
        XCTAssertEqual(try YStateEncoder.encodeStateAsUpdate(doc), state)
        assertSingleRebuild(surface, origin: .other)
        assertSurfaceMatchesProjection(surface, doc, "non-addressable composition")
    }

    func testSeveralHeldPeerTransactionsBecomeExactlyOneRebuild() throws {
        let pair = try makePair()
        defer { pair.destroy() }
        let (local, peer, surface, peerSurface, engine, peerEngine) =
            (pair.a, pair.b, pair.surfaceA, pair.surfaceB, pair.engineA, pair.engineB)
        try engine.compositionBegan(blockID: Self.firstID, at: 6)
        let updates = [
            try peerEngine.replaceText(block: Self.firstID, range: 0..<0, with: "A"),
            try peerEngine.replaceText(block: Self.firstID, range: 17..<17, with: "!"),
            try peerEngine.formatRange(
                block: Self.firstID, range: 0..<1, marks: [TextMark(key: "bold", valueJSON: "{}")]),
        ]
        for update in updates {
            try local.applyUpdate(YUpdateDecoder.decode(update), origin: .remote)
            XCTAssertTrue(surface.appliedPatches.isEmpty)
            assertSurfaceMatchesProjection(peerSurface, peer, "peer transactions")
        }
        try peer.applyUpdate(YUpdateDecoder.decode(engine.compositionCommitted(text: "に")), origin: .remote)
        XCTAssertEqual(text(of: surface.blocks[0]), "AFirst にparagraph.!")
        assertSingleRebuild(surface, origin: .localUser)
        XCTAssertEqual(YXMLString.fragment(local), YXMLString.fragment(peer))
        assertSurfaceMatchesProjection(surface, local, "held peer transactions committed")
        assertSurfaceMatchesProjection(peerSurface, peer, "peer received commit")
    }

    func testResetHoldsSubsequentIndependentDeltasUntilCancel() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        try engine.compositionBegan(blockID: Self.firstID, at: 6)
        let container = try XCTUnwrap(BlockIndex(doc: doc).entries[Self.firstID]?.container)
        try doc.transact(origin: .remote) { tx in
            try YWrite.mapSet(tx, on: container, key: "id", .any([.string("renamed")]))
        }
        try engine.replaceText(block: Self.thirdID, range: 0..<0, with: "later ")
        XCTAssertTrue(surface.appliedPatches.isEmpty)
        try engine.compositionCancelled()
        XCTAssertEqual(surface.appliedPatches.count, 1)
        guard case .reset = surface.appliedPatches[0].changes.first else { return XCTFail("expected reset") }
        XCTAssertEqual(surface.blocks[0].id, "renamed")
        XCTAssertTrue(text(of: surface.blocks[2]).hasPrefix("later "))
        assertSurfaceMatchesProjection(surface, doc, "reset plus subsequent delta")
    }

    func testReentrantCancelRebuildsBeforeClearingDeferral() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let surface = CompositionCallbackSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        try engine.compositionBegan(blockID: Self.firstID, at: 6)
        try engine.replaceText(block: Self.firstID, range: 0..<0, with: "held ")
        surface.onPatch = {
            if surface.headless.appliedPatches.count == 1 {
                try? engine.compositionCancelled()
            } else {
                XCTAssertTrue(surface.headless.isCompositionDeferred, "rebuild must arrive before deferral ends")
            }
        }
        try engine.replaceText(block: Self.thirdID, range: 0..<0, with: "visible ")
        XCTAssertEqual(surface.maximumDepth, 1)
        XCTAssertEqual(surface.headless.appliedPatches.count, 2)
        XCTAssertEqual(surface.headless.compositionDeferrals, [true, false])
        assertSurfaceMatchesProjection(surface.headless, doc, "reentrant cancel")
    }

    func testDestroyDuringCompositionClearsDeferralAndDropsHeldPatches() throws {
        let doc = try makeDoc(clientID: 1)
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        try engine.compositionBegan(blockID: Self.firstID, at: 6)
        try engine.replaceText(block: Self.firstID, range: 0..<0, with: "held ")
        let displayed = surface.blocks
        doc.destroy()
        XCTAssertTrue(engine.isDetached)
        XCTAssertEqual(surface.blocks, displayed)
        XCTAssertTrue(surface.appliedPatches.isEmpty)
        XCTAssertEqual(surface.compositionDeferrals, [true, false])
        XCTAssertThrowsError(try engine.compositionCommitted(text: "LOST")) {
            XCTAssertEqual($0 as? DocumentEngineError, .detached)
        }
        // A destroyed replica has no projection to compare; teardown preserves
        // the last display instead of synthesizing a patch from a destroyed doc.
    }

    func testCancelRebuildsOnceWithoutWritingAndOtherBlocksKeepUpdating() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        try engine.compositionBegan(blockID: Self.firstID, at: 6)
        try doc.transact(origin: .remote) { _ in
            let index = BlockIndex(doc: doc)
            try XCTUnwrap(index.entries[Self.firstID]?.textType).insert(0, "A ")
            try XCTUnwrap(index.entries[Self.secondID]?.textType).insert(0, "B ")
        }
        XCTAssertEqual(text(of: surface.blocks[0]), "First paragraph.")
        XCTAssertTrue(text(of: surface.blocks[1]).hasPrefix("B "))
        XCTAssertEqual(surface.appliedPatches.count, 1)
        let before = try YStateEncoder.encodeStateAsUpdate(doc)
        try engine.compositionCancelled()
        XCTAssertEqual(try YStateEncoder.encodeStateAsUpdate(doc), before)
        XCTAssertEqual(surface.appliedPatches.count, 2)
        guard case .replaceBlock(let id, _) = surface.appliedPatches[1].changes.first else {
            return XCTFail("expected rebuild")
        }
        XCTAssertEqual(id, Self.firstID)
        XCTAssertFalse(surface.isCompositionDeferred)
        assertSurfaceMatchesProjection(surface, doc, "cancel")
    }

    func testPeerDeletingComposingBlockDropsCommitAndResets() throws {
        let pair = try makePair()
        defer { pair.destroy() }
        let (local, peer, surface, peerSurface, engine, peerEngine) =
            (pair.a, pair.b, pair.surfaceA, pair.surfaceB, pair.engineA, pair.engineB)
        try engine.compositionBegan(blockID: Self.secondID, at: 6)
        let update = try peerEngine.joinBlocks(block: Self.secondID)
        try local.applyUpdate(YUpdateDecoder.decode(update), origin: .remote)
        XCTAssertTrue(
            surface.appliedPatches.isEmpty, "list changes involving the composing block are held together")
        XCTAssertEqual(try engine.compositionCommitted(text: "LOST"), Data([0, 0]))
        XCTAssertEqual(surface.appliedPatches.count, 1)
        guard case .reset = surface.appliedPatches[0].changes.first else { return XCTFail("expected reset") }
        XCTAssertEqual(YXMLString.fragment(local), YXMLString.fragment(peer))
        assertSurfaceMatchesProjection(surface, local, "deleted composition")
        assertSurfaceMatchesProjection(peerSurface, peer, "peer deletion")
    }

    func testPeerReplacingTextTypeDropsCommitDespiteSameBlockID() throws {
        let pair = try makePair()
        defer { pair.destroy() }
        let (local, peer, surface, peerSurface, engine, peerEngine) =
            (pair.a, pair.b, pair.surfaceA, pair.surfaceB, pair.engineA, pair.engineB)
        try engine.compositionBegan(blockID: Self.firstID, at: 6)
        try local.applyUpdate(
            YUpdateDecoder.decode(peerEngine.setBlockType(block: Self.firstID, to: "heading")), origin: .remote)
        XCTAssertTrue(surface.appliedPatches.isEmpty)
        XCTAssertEqual(try engine.compositionCommitted(text: "LOST"), Data([0, 0]))
        assertSingleRebuild(surface, origin: .other)
        XCTAssertEqual(YXMLString.fragment(local), YXMLString.fragment(peer))
        assertSurfaceMatchesProjection(surface, local, "replaced composition text")
        assertSurfaceMatchesProjection(peerSurface, peer, "peer type change")
    }

    func testDetachDropsHeldChangesAndAllNewIntentsThrow() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        try engine.compositionBegan(blockID: Self.firstID, at: 6)
        try engine.replaceText(block: Self.firstID, range: 0..<0, with: "X")
        engine.detach()
        XCTAssertTrue(surface.appliedPatches.isEmpty)
        XCTAssertEqual(surface.compositionDeferrals, [true, false])
        let position = EditorPosition(blockID: Self.firstID, offset: 0)
        for intent in [
            { try engine.compositionBegan(blockID: Self.firstID, at: 0) },
            { _ = try engine.compositionCommitted(text: "x") },
            { try engine.compositionCancelled() },
            { try engine.setSelection(EditorSelection(anchor: position, head: position)) },
            { _ = try engine.currentSelection() },
        ] {
            XCTAssertThrowsError(try intent()) { XCTAssertEqual($0 as? DocumentEngineError, .detached) }
        }
        // Detached surfaces deliberately keep their last display. A new attachment
        // starts from the replica's current projection, with no stale queue replay.
        let replacementSurface = HeadlessSurface(blocks: projection(doc))
        let replacementEngine = DocumentEngine(doc: doc, surface: replacementSurface)
        try replacementEngine.replaceText(block: Self.firstID, range: 0..<0, with: "Y")
        assertSurfaceMatchesProjection(replacementSurface, doc, "reattach after detach")
    }

    func testInvalidCompositionTransitionsDoNotChangeReplicaOrSurface() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        func assertRejected(_ expected: DocumentEngineError, _ action: () throws -> Void) throws {
            let before = try YStateEncoder.encodeStateAsUpdate(doc)
            let deferrals = surface.compositionDeferrals
            let patches = surface.appliedPatches
            XCTAssertThrowsError(try action()) { XCTAssertEqual($0 as? DocumentEngineError, expected) }
            XCTAssertEqual(try YStateEncoder.encodeStateAsUpdate(doc), before)
            XCTAssertEqual(surface.compositionDeferrals, deferrals)
            XCTAssertEqual(surface.appliedPatches, patches)
        }
        try assertRejected(.compositionNotActive) { _ = try engine.compositionCommitted(text: "x") }
        try assertRejected(.compositionNotActive) { try engine.compositionCancelled() }
        try assertRejected(.invalidPosition) { try engine.compositionBegan(blockID: Self.firstID) }
        try assertRejected(.invalidPosition) { try engine.compositionBegan(blockID: Self.firstID, at: -1) }
        try engine.compositionBegan(blockID: Self.firstID, at: 6)
        try assertRejected(.compositionAlreadyActive) { try engine.compositionBegan(blockID: Self.secondID, at: 0) }
        try engine.compositionCancelled()
        assertSingleRebuild(surface, origin: .other)
        assertSurfaceMatchesProjection(surface, doc, "invalid transitions")
    }

    private func concurrentComposition(
        range: Range<Int>, replacement: String, expectedAnchor: Int, expectedText: String
    ) throws {
        let pair = try makePair()
        defer { pair.destroy() }
        let (local, peer, surface, peerSurface, engine, peerEngine) =
            (pair.a, pair.b, pair.surfaceA, pair.surfaceB, pair.engineA, pair.engineB)
        let caret = EditorPosition(blockID: Self.firstID, offset: 6)
        try engine.setSelection(EditorSelection(anchor: caret, head: caret))
        try engine.compositionBegan(blockID: Self.firstID)
        try local.applyUpdate(
            YUpdateDecoder.decode(peerEngine.replaceText(block: Self.firstID, range: range, with: replacement)),
            origin: .remote)
        XCTAssertEqual(try engine.currentSelection()?.head.offset, expectedAnchor)
        XCTAssertTrue(surface.appliedPatches.isEmpty)
        XCTAssertEqual(text(of: surface.blocks[0]), "First paragraph.")
        assertSurfaceMatchesProjection(peerSurface, peer, "peer edit while local composition held")

        let update = try engine.compositionCommitted(text: "に")
        try peer.applyUpdate(YUpdateDecoder.decode(update), origin: .remote)
        XCTAssertEqual(try engine.currentSelection()?.head.offset, expectedAnchor + 1)
        XCTAssertEqual(text(of: surface.blocks[0]), expectedText)
        assertSingleRebuild(surface, origin: .localUser)
        XCTAssertEqual(YXMLString.fragment(local), YXMLString.fragment(peer))
        assertSurfaceMatchesProjection(surface, local, "concurrent composition committed")
        assertSurfaceMatchesProjection(peerSurface, peer, "peer received composition")
    }

    private func assertSingleRebuild(
        _ surface: HeadlessSurface, origin: BlockPatchOrigin, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(surface.appliedPatches.count, 1, file: file, line: line)
        XCTAssertEqual(surface.appliedPatches.first?.origin, origin, file: file, line: line)
        XCTAssertEqual(surface.appliedPatches.first?.changes.count, 1, file: file, line: line)
        guard case .replaceBlock = surface.appliedPatches.first?.changes.first else {
            return XCTFail("expected exactly one rebuild", file: file, line: line)
        }
    }
}

private final class CompositionCallbackSurface: EditorSurface {
    let headless: HeadlessSurface
    var onPatch: (() -> Void)?
    private var depth = 0
    private(set) var maximumDepth = 0

    init(blocks: [BlockSnapshot]) { headless = HeadlessSurface(blocks: blocks) }

    func applyPatch(_ patch: BlockPatch) {
        depth += 1
        maximumDepth = max(maximumDepth, depth)
        headless.applyPatch(patch)
        onPatch?()
        depth -= 1
    }

    func setCompositionDeferred(_ deferred: Bool) { headless.setCompositionDeferred(deferred) }
}
