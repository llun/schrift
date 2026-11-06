import XCTest

@testable import Schrift

@MainActor
final class DocumentEngineRoundOneTests: DocumentEngineTestCase {
    private static let emptyID = "b0000000-0000-4000-8000-0000000000ee"

    func testEmptyBlockSelectionAndCompositionCreateTextThroughWriter() throws {
        let pair = try makeEmptyPair()
        defer { pair.destroy() }
        let caret = EditorPosition(blockID: Self.emptyID, offset: 0)
        let before = try YStateEncoder.encodeStateAsUpdate(pair.a)
        try pair.engineA.setSelection(EditorSelection(anchor: caret, head: caret))
        XCTAssertEqual(try pair.engineA.currentSelection(), EditorSelection(anchor: caret, head: caret))
        try pair.engineA.compositionBegan(blockID: Self.emptyID)
        XCTAssertNil(BlockIndex(doc: pair.a).entries[Self.emptyID]?.textType)
        XCTAssertEqual(try YStateEncoder.encodeStateAsUpdate(pair.a), before)
        let update = try pair.engineA.compositionCommitted(text: "😀に")
        try pair.b.applyUpdate(YUpdateDecoder.decode(update), origin: .remote)
        XCTAssertNotNil(BlockIndex(doc: pair.a).entries[Self.emptyID]?.textType)
        XCTAssertEqual(try pair.engineA.currentSelection()?.head.offset, 3)
        XCTAssertEqual(text(of: try XCTUnwrap(block(pair.surfaceA, Self.emptyID))), "😀に")
        assertConverged(pair, "empty commit")
    }

    func testEmptyElementAnchorSurvivesPeerTextCreationWithBothAffinities() throws {
        for assoc in [-1, 0] {
            let pair = try makeEmptyPair()
            defer { pair.destroy() }
            let caret = EditorPosition(blockID: Self.emptyID, offset: 0, assoc: assoc)
            try pair.engineA.setSelection(EditorSelection(anchor: caret, head: caret))
            XCTAssertEqual(try pair.engineA.currentSelection()?.head.offset, 0)
            try pair.engineA.compositionBegan(blockID: Self.emptyID, at: 0, assoc: assoc)
            try pair.a.applyUpdate(
                YUpdateDecoder.decode(pair.engineB.replaceText(block: Self.emptyID, range: 0..<0, with: "peer")),
                origin: .remote)
            XCTAssertEqual(try pair.engineA.currentSelection()?.head.offset, assoc < 0 ? 0 : 4)
            try pair.b.applyUpdate(YUpdateDecoder.decode(pair.engineA.compositionCommitted(text: "に")), origin: .remote)
            XCTAssertEqual(text(of: try XCTUnwrap(block(pair.surfaceA, Self.emptyID))), assoc < 0 ? "にpeer" : "peerに")
            XCTAssertEqual(try pair.engineA.currentSelection()?.head.offset, assoc < 0 ? 1 : 5)
            assertConverged(pair, "peer creates text, affinity \(assoc)")
        }
    }

    func testEmptyElementAnchorDoesNotRetargetAReplacementElement() throws {
        let pair = try makeEmptyPair()
        defer { pair.destroy() }
        let caret = EditorPosition(blockID: Self.emptyID, offset: 0)
        try pair.engineA.setSelection(EditorSelection(anchor: caret, head: caret))
        try pair.engineA.compositionBegan(blockID: Self.emptyID)
        try pair.a.applyUpdate(
            YUpdateDecoder.decode(pair.engineB.setBlockType(block: Self.emptyID, to: "heading")), origin: .remote)
        XCTAssertNil(try pair.engineA.currentSelection())
        XCTAssertEqual(try pair.engineA.compositionCommitted(text: "LOST"), Data([0, 0]))
        assertConverged(pair, "replaced empty element")
    }

    func testCompositionCanRestartAfterCommitOrCancelInsideApplyPatch() throws {
        for commit in [false, true] {
            let doc = try makeDoc(clientID: 1)
            defer { doc.destroy() }
            let surface = RestartingSurface(blocks: projection(doc))
            let engine = DocumentEngine(doc: doc, surface: surface)
            try engine.compositionBegan(blockID: Self.firstID, at: 6)
            var attempted = false
            var caught: Error?
            surface.onPatch = {
                guard !attempted else { return }
                attempted = true
                do {
                    if commit {
                        _ = try engine.compositionCommitted(text: "に")
                    } else {
                        try engine.compositionCancelled()
                    }
                    try engine.compositionBegan(blockID: Self.firstID, at: 0)
                } catch { caught = error }
            }
            try engine.replaceText(block: Self.thirdID, range: 0..<0, with: "trigger ")
            XCTAssertTrue(attempted)
            XCTAssertNil(caught)
            XCTAssertTrue(surface.headless.isCompositionDeferred, "an old completion must not end the new composition")
            XCTAssertEqual(surface.headless.compositionDeferrals, [true])
            surface.onPatch = nil
            if caught == nil { try engine.compositionCancelled() }
            XCTAssertEqual(surface.headless.compositionDeferrals, [true, false])
            assertSurfaceMatchesProjection(surface.headless, doc, "reentrant restart after commit=\(commit)")
        }
    }

    func testMidSurrogateCapturesAreRejectedWithoutSideEffects() throws {
        let blocks = [
            BlockNoteBlock(node: "paragraph", props: Self.paragraphProps, runs: [InlineRun("A😀B")], id: Self.firstID)
        ]
        let doc = try makeDoc(blocks, clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        let valid = EditorPosition(blockID: Self.firstID, offset: 3)
        try engine.setSelection(EditorSelection(anchor: valid, head: valid))
        let invalid = EditorPosition(blockID: Self.firstID, offset: 2)
        let before = try YStateEncoder.encodeStateAsUpdate(doc)
        for reject in [
            { try engine.setSelection(EditorSelection(anchor: invalid, head: valid)) },
            { try engine.setSelection(EditorSelection(anchor: valid, head: invalid)) },
            { try engine.compositionBegan(blockID: Self.firstID, at: 2) },
        ] {
            XCTAssertThrowsError(try reject()) { XCTAssertEqual($0 as? DocumentEngineError, .invalidPosition) }
            XCTAssertEqual(try engine.currentSelection(), EditorSelection(anchor: valid, head: valid))
            XCTAssertEqual(try YStateEncoder.encodeStateAsUpdate(doc), before)
            XCTAssertEqual(surface.compositionDeferrals, [])
            XCTAssertEqual(surface.appliedPatches, [])
        }
        try engine.compositionBegan(blockID: Self.firstID, at: 3)
        try engine.compositionCommitted(text: "に")
        XCTAssertEqual(text(of: surface.blocks[0]), "A😀にB")
        XCTAssertEqual(try engine.currentSelection()?.head.offset, 4)
        assertSurfaceMatchesProjection(surface, doc, "surrogate boundary")
    }

    func testPostCommitCaretIsCapturedBeforeObserverEdits() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let firstText = try XCTUnwrap(BlockIndex(doc: doc).entries[Self.firstID]?.textType)
        var edited = false
        doc.afterTransaction = { transaction in
            guard transaction.origin == .localUser, !edited else { return }
            edited = true
            do { try doc.transact { _ in try firstText.insert(0, "prefix ") } } catch {
                XCTFail("observer edit failed: \(error)")
            }
        }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        try engine.compositionBegan(blockID: Self.firstID, at: 6)
        try engine.compositionCommitted(text: "😀")
        XCTAssertTrue(edited)
        XCTAssertEqual(text(of: surface.blocks[0]), "prefix First 😀paragraph.")
        XCTAssertEqual(try engine.currentSelection()?.head.offset, 15)
        assertSurfaceMatchesProjection(surface, doc, "post-commit observer caret")
    }

    func testExplicitRightAffinityFollowsPeerAppend() throws {
        let pair = try makePair()
        defer { pair.destroy() }
        try pair.engineA.compositionBegan(blockID: Self.firstID, at: 16, assoc: 0)
        try pair.a.applyUpdate(
            YUpdateDecoder.decode(pair.engineB.replaceText(block: Self.firstID, range: 16..<16, with: "!")),
            origin: .remote)
        try pair.b.applyUpdate(YUpdateDecoder.decode(pair.engineA.compositionCommitted(text: "に")), origin: .remote)
        XCTAssertEqual(text(of: pair.surfaceA.blocks[0]), "First paragraph.!に")
        XCTAssertEqual(try pair.engineA.currentSelection()?.head.offset, 18)
        assertConverged(pair, "right affinity")
    }

    func testEmptyCommitDoesNotWriteAndRebuildsDeferredChanges() throws {
        let pair = try makePair()
        defer { pair.destroy() }
        try pair.engineA.compositionBegan(blockID: Self.firstID, at: 6)
        try pair.a.applyUpdate(
            YUpdateDecoder.decode(pair.engineB.replaceText(block: Self.firstID, range: 0..<0, with: "A ")),
            origin: .remote)
        let before = try YStateEncoder.encodeStateAsUpdate(pair.a)
        XCTAssertEqual(try pair.engineA.compositionCommitted(text: ""), Data([0, 0]))
        XCTAssertEqual(try YStateEncoder.encodeStateAsUpdate(pair.a), before)
        XCTAssertEqual(try pair.engineA.currentSelection()?.head.offset, 8)
        XCTAssertEqual(pair.surfaceA.appliedPatches.count, 1)
        XCTAssertEqual(pair.surfaceA.compositionDeferrals, [true, false])
        assertConverged(pair, "empty commit")
    }

    func testWriterThrowEndsCompositionAndRebuildsWithoutSwallowingError() throws {
        let pair = try makePair()
        defer { pair.destroy() }
        try pair.engineA.compositionBegan(blockID: Self.firstID, at: 6)
        let other = try XCTUnwrap(BlockIndex(doc: pair.a).entries[Self.thirdID]?.container)
        try pair.a.transact { tx in
            try YWrite.insertAfter(tx, into: other, after: other.start, [.string(Array("broken".utf16))])
        }
        // The composing block is addressable, but find() refuses the malformed
        // sibling it must traverse. This reaches the writer-throws commit branch.
        let before = try YStateEncoder.encodeStateAsUpdate(pair.a)
        let patches = pair.surfaceA.appliedPatches.count
        XCTAssertThrowsError(try pair.engineA.compositionCommitted(text: "LOST")) {
            XCTAssertEqual($0 as? BlockNoteWriter.Error, .malformedBlock(Self.firstID))
        }
        XCTAssertEqual(try YStateEncoder.encodeStateAsUpdate(pair.a), before)
        XCTAssertEqual(pair.surfaceA.appliedPatches.count, patches + 1)
        XCTAssertEqual(pair.surfaceA.compositionDeferrals, [true, false])
        assertSurfaceMatchesProjection(pair.surfaceA, pair.a, "writer failure")
        assertSurfaceMatchesProjection(pair.surfaceB, pair.b, "untouched peer")
    }

    func testCommitBeforeConcurrentPeerInsertBeforeCaret() throws {
        try commitBeforeDelivery(range: 0..<0, replacement: "A ", expectedText: "A First にparagraph.", expectedCaret: 9)
    }

    func testCommitBeforeConcurrentPeerInsertAfterCaret() throws {
        try commitBeforeDelivery(range: 10..<10, replacement: "!", expectedText: "First にpara!graph.", expectedCaret: 7)
    }

    func testCommitBeforeConcurrentPeerReplacementOverCaret() throws {
        try commitBeforeDelivery(range: 4..<9, replacement: "X", expectedText: "FirsにXagraph.", expectedCaret: 5)
    }

    private func commitBeforeDelivery(range: Range<Int>, replacement: String, expectedText: String, expectedCaret: Int)
        throws
    {
        for toAFirst in [true, false] {
            let pair = try makePair()
            defer { pair.destroy() }
            try pair.engineA.compositionBegan(blockID: Self.firstID, at: 6)
            let peerUpdate = try pair.engineB.replaceText(block: Self.firstID, range: range, with: replacement)
            let commitUpdate = try pair.engineA.compositionCommitted(text: "に")
            XCTAssertEqual(try pair.engineA.currentSelection()?.head.offset, 7)
            assertSurfaceMatchesProjection(pair.surfaceA, pair.a, "commit before peer delivery")
            assertSurfaceMatchesProjection(pair.surfaceB, pair.b, "peer before commit delivery")
            if toAFirst {
                try pair.a.applyUpdate(YUpdateDecoder.decode(peerUpdate), origin: .remote)
                try pair.b.applyUpdate(YUpdateDecoder.decode(commitUpdate), origin: .remote)
            } else {
                try pair.b.applyUpdate(YUpdateDecoder.decode(commitUpdate), origin: .remote)
                try pair.a.applyUpdate(YUpdateDecoder.decode(peerUpdate), origin: .remote)
            }
            XCTAssertEqual(text(of: pair.surfaceA.blocks[0]), expectedText)
            XCTAssertEqual(try pair.engineA.currentSelection()?.head.offset, expectedCaret)
            assertConverged(pair, "commit first, deliver to A first=\(toAFirst)")
        }
    }

    private func makeEmptyPair() throws -> Pair {
        let pair = try makePair()
        do {
            let update = try pair.engineA.splitBlock(block: Self.firstID, at: 16, newID: Self.emptyID)
            try pair.b.applyUpdate(YUpdateDecoder.decode(update), origin: .remote)
            XCTAssertNil(BlockIndex(doc: pair.a).entries[Self.emptyID]?.textType)
            assertConverged(pair, "empty fixture")
            return pair
        } catch {
            pair.destroy()
            throw error
        }
    }

    private func assertConverged(_ pair: Pair, _ label: String) {
        XCTAssertEqual(YXMLString.fragment(pair.a), YXMLString.fragment(pair.b), label)
        assertSurfaceMatchesProjection(pair.surfaceA, pair.a, "\(label): A")
        assertSurfaceMatchesProjection(pair.surfaceB, pair.b, "\(label): B")
    }
}

private final class RestartingSurface: EditorSurface {
    let headless: HeadlessSurface
    var onPatch: (() -> Void)?
    init(blocks: [BlockSnapshot]) { headless = HeadlessSurface(blocks: blocks) }
    func applyPatch(_ patch: BlockPatch) {
        headless.applyPatch(patch)
        onPatch?()
    }
    func setCompositionDeferred(_ deferred: Bool) { headless.setCompositionDeferred(deferred) }
}
