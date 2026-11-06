import XCTest

@testable import Schrift

@MainActor
final class DocumentEngineFinalContractTests: DocumentEngineTestCase {
    func testFrozenBlockRejectsSelectionAndEveryIntentWithoutSideEffects() throws {
        let pair = try makePair()
        defer { pair.destroy() }
        let caret = EditorPosition(blockID: Self.secondID, offset: 3)
        try pair.engineA.setSelection(EditorSelection(anchor: caret, head: caret))
        try pair.engineA.compositionBegan(blockID: Self.secondID)
        try pair.a.applyUpdate(
            YUpdateDecoder.decode(pair.engineB.replaceText(block: Self.secondID, range: 0..<0, with: "ZZ")),
            origin: .remote)
        XCTAssertEqual(try pair.engineA.currentSelection()?.head.offset, 5, "queries use the live replica")
        XCTAssertFalse(text(of: pair.surfaceA.blocks[1]).hasPrefix("ZZ"))
        try assertBlockedInputs(pair.engineA, doc: pair.a, surface: pair.surfaceA)

        let independent = EditorPosition(blockID: Self.firstID, offset: 0)
        try pair.engineA.setSelection(EditorSelection(anchor: independent, head: independent))
        try pair.engineA.setSelection(nil)
        let update = try pair.engineA.replaceText(block: Self.firstID, range: 0..<0, with: "allowed ")
        try pair.b.applyUpdate(YUpdateDecoder.decode(update), origin: .remote)
        try pair.engineA.compositionCancelled()
        XCTAssertEqual(YXMLString.fragment(pair.a), YXMLString.fragment(pair.b))
        assertSurfaceMatchesProjection(pair.surfaceA, pair.a, "unfrozen after cancel")
        assertSurfaceMatchesProjection(pair.surfaceB, pair.b, "peer after independent edit")
        try pair.engineA.setSelection(EditorSelection(anchor: caret, head: caret))
        let after = try pair.engineA.replaceText(block: Self.secondID, range: 0..<0, with: "unlocked ")
        try pair.b.applyUpdate(YUpdateDecoder.decode(after), origin: .remote)
        assertSurfaceMatchesProjection(pair.surfaceA, pair.a, "input allowed after rebuild")
        assertSurfaceMatchesProjection(pair.surfaceB, pair.b, "peer after unlock")
    }

    func testPendingRebuildRejectsInputsAndExplicitRestartButAllowsRelativeRestart() throws {
        for commit in [false, true] {
            let doc = try makeDoc(clientID: 1)
            defer { doc.destroy() }
            let surface = ContractSurface(blocks: projection(doc))
            let engine = DocumentEngine(doc: doc, surface: surface)
            let caret = EditorPosition(blockID: Self.secondID, offset: 3)
            try engine.setSelection(EditorSelection(anchor: caret, head: caret))
            try engine.compositionBegan(blockID: Self.secondID)
            try doc.transact(origin: .remote) { _ in
                try XCTUnwrap(BlockIndex(doc: doc).entries[Self.secondID]?.textType).insert(0, "ZZ")
            }
            var attempted = false
            surface.onPatch = {
                guard !attempted else { return }
                attempted = true
                do {
                    if commit {
                        _ = try engine.compositionCommitted(text: "に")
                    } else {
                        try engine.compositionCancelled()
                    }
                    // Logical composition is nil; its only catch-up patch has
                    // not reached this surface yet. All these offsets are unsafe.
                    try self.assertBlockedInputs(engine, doc: doc, surface: surface.headless)
                    let state = try YStateEncoder.encodeStateAsUpdate(doc)
                    let deferrals = surface.headless.compositionDeferrals
                    XCTAssertThrowsError(try engine.compositionBegan(blockID: Self.secondID, at: 7)) {
                        XCTAssertEqual($0 as? DocumentEngineError, .composingBlock)
                    }
                    XCTAssertEqual(try YStateEncoder.encodeStateAsUpdate(doc), state)
                    XCTAssertEqual(surface.headless.compositionDeferrals, deferrals)
                    try engine.compositionBegan(blockID: Self.secondID)
                } catch { XCTFail("pending-rebuild callback failed: \(error)") }
            }
            try engine.replaceText(block: Self.firstID, range: 0..<0, with: "trigger ")
            XCTAssertTrue(attempted)
            XCTAssertTrue(surface.headless.isCompositionDeferred)
            XCTAssertEqual(surface.headless.compositionDeferrals, [true])
            surface.onPatch = nil
            try engine.compositionCommitted(text: "語")
            XCTAssertEqual(try engine.currentSelection()?.head.offset, commit ? 7 : 6)
            XCTAssertEqual(
                text(of: surface.headless.blocks[1]),
                commit
                    ? "ZZSecに語ond paragraph has bold words inside it." : "ZZSec語ond paragraph has bold words inside it."
            )
            XCTAssertEqual(surface.headless.compositionDeferrals, [true, false])
            assertSurfaceMatchesProjection(surface.headless, doc, "relative restart after commit=\(commit)")
        }
    }

    func testJoinRejectsADeferredDestinationEvenWhenSourceIsNotComposing() throws {
        let pair = try makePair()
        defer { pair.destroy() }
        try pair.engineA.compositionBegan(blockID: Self.firstID, at: 3)
        let state = try YStateEncoder.encodeStateAsUpdate(pair.a)
        XCTAssertThrowsError(try pair.engineA.joinBlocks(block: Self.secondID)) {
            XCTAssertEqual($0 as? DocumentEngineError, .composingBlock)
        }
        XCTAssertEqual(try YStateEncoder.encodeStateAsUpdate(pair.a), state)
        XCTAssertEqual(pair.surfaceA.compositionDeferrals, [true])
        try pair.engineA.compositionCancelled()
        assertSurfaceMatchesProjection(pair.surfaceA, pair.a, "join rejected")
        assertSurfaceMatchesProjection(pair.surfaceB, pair.b, "untouched peer")
    }

    func testOptimisticSurfaceAlwaysAppliesCommitRebuildAndSubsequentPeerDeltas() throws {
        let local = try makeDoc(clientID: 1)
        defer { local.destroy() }
        let peer = try makeDoc(clientID: 2)
        defer { peer.destroy() }
        let surface = ContractSurface(blocks: projection(local), skipsLocalUser: true)
        let peerSurface = HeadlessSurface(blocks: projection(peer))
        let engine = DocumentEngine(doc: local, surface: surface)
        let peerEngine = DocumentEngine(doc: peer, surface: peerSurface)
        try engine.compositionBegan(blockID: Self.firstID, at: 6)
        try local.applyUpdate(
            YUpdateDecoder.decode(peerEngine.replaceText(block: Self.firstID, range: 0..<0, with: "ZZ")),
            origin: .remote)
        // Marked text changes the frozen display synchronously; the surface
        // therefore skips local-user patches, including a wrongly tagged rebuild.
        surface.headless.applyPatch(
            BlockPatch(
                [.text(blockID: Self.firstID, deltas: [TextDelta(range: 6..<6, replacement: "に")])], origin: .localUser)
        )
        try peer.applyUpdate(YUpdateDecoder.decode(engine.compositionCommitted(text: "に")), origin: .remote)
        XCTAssertEqual(surface.received.map(\.origin), [.other])
        assertSurfaceMatchesProjection(surface.headless, local, "optimistic commit rebuild")
        assertSurfaceMatchesProjection(peerSurface, peer, "peer received committed text")
        XCTAssertEqual(YXMLString.fragment(local), YXMLString.fragment(peer))
        try local.applyUpdate(
            YUpdateDecoder.decode(peerEngine.replaceText(block: Self.firstID, range: 4..<5, with: "!")), origin: .remote
        )
        assertSurfaceMatchesProjection(surface.headless, local, "peer delta after rebuild")
        assertSurfaceMatchesProjection(peerSurface, peer, "peer after subsequent delta")
    }

    private func assertBlockedInputs(_ engine: DocumentEngine, doc: YDoc, surface: HeadlessSurface) throws {
        let blocked = EditorPosition(blockID: Self.secondID, offset: 4)
        let other = EditorPosition(blockID: Self.firstID, offset: 0)
        let actions: [() throws -> Void] = [
            { try engine.setSelection(EditorSelection(anchor: blocked, head: other)) },
            { try engine.setSelection(EditorSelection(anchor: other, head: blocked)) },
            { _ = try engine.replaceText(block: Self.secondID, range: 4..<4, with: "unsafe") },
            {
                _ = try engine.formatRange(
                    block: Self.secondID, range: 0..<1, marks: [TextMark(key: "bold", valueJSON: "{}")])
            },
            { _ = try engine.splitBlock(block: Self.secondID, at: 4, newID: "b0000000-0000-4000-8000-0000000000ff") },
            { _ = try engine.joinBlocks(block: Self.secondID) },
            { _ = try engine.joinBlocks(block: Self.thirdID) },
            { _ = try engine.setBlockType(block: Self.secondID, to: "heading") },
        ]
        for reject in actions {
            let state = try YStateEncoder.encodeStateAsUpdate(doc)
            let selection = try engine.currentSelection()
            let patches = surface.appliedPatches
            let deferrals = surface.compositionDeferrals
            XCTAssertThrowsError(try reject()) { XCTAssertEqual($0 as? DocumentEngineError, .composingBlock) }
            XCTAssertEqual(try YStateEncoder.encodeStateAsUpdate(doc), state)
            XCTAssertEqual(try engine.currentSelection(), selection)
            XCTAssertEqual(surface.appliedPatches, patches)
            XCTAssertEqual(surface.compositionDeferrals, deferrals)
        }
    }
}

private final class ContractSurface: EditorSurface {
    let headless: HeadlessSurface
    let skipsLocalUser: Bool
    var onPatch: (() -> Void)?
    private(set) var received: [BlockPatch] = []

    init(blocks: [BlockSnapshot], skipsLocalUser: Bool = false) {
        headless = HeadlessSurface(blocks: blocks)
        self.skipsLocalUser = skipsLocalUser
    }

    func applyPatch(_ patch: BlockPatch) {
        received.append(patch)
        if !skipsLocalUser || patch.origin != .localUser { headless.applyPatch(patch) }
        onPatch?()
    }

    func setCompositionDeferred(_ deferred: Bool) { headless.setCompositionDeferred(deferred) }
}
