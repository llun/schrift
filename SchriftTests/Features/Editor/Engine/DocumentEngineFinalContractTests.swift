import XCTest

@testable import Schrift

@MainActor
final class DocumentEngineFinalContractTests: DocumentEngineTestCase {
    func testCompositionIntentsRejectTransactionBodyAndChainedAfterTransactionHook() throws {
        for duringCleanup in [true, false] {
            for intent in ["cancel", "commit", "begin"] {
                let doc = try makeDoc(clientID: 1)
                defer { doc.destroy() }
                let surface = HeadlessSurface(blocks: projection(doc))
                weak var hookedEngine: DocumentEngine?
                var attempted = false
                func assertRejected(_ engine: DocumentEngine) throws {
                    let state = try YStateEncoder.encodeStateAsUpdate(doc)
                    let blocks = surface.blocks
                    let patches = surface.appliedPatches
                    let deferrals = surface.compositionDeferrals
                    let selection = try engine.currentSelection()
                    let transaction = doc.transaction
                    let pending = doc.transactionCleanups.count
                    let action: () throws -> Void = {
                        switch intent {
                        case "begin": try engine.compositionBegan(blockID: Self.firstID, at: 6)
                        case "commit": _ = try engine.compositionCommitted(text: "unsafe")
                        default: try engine.compositionCancelled()
                        }
                    }
                    XCTAssertThrowsError(try action()) {
                        XCTAssertEqual($0 as? DocumentEngineError, .insideTransaction)
                    }
                    XCTAssertEqual(try YStateEncoder.encodeStateAsUpdate(doc), state)
                    XCTAssertEqual(surface.blocks, blocks)
                    XCTAssertEqual(surface.appliedPatches, patches)
                    XCTAssertEqual(surface.compositionDeferrals, deferrals)
                    XCTAssertEqual(try engine.currentSelection(), selection)
                    XCTAssertTrue(doc.transaction === transaction)
                    XCTAssertEqual(doc.transactionCleanups.count, pending)
                }
                // Installed before the engine, so this runs in its chained hook
                // before record(T), reproducing the mid-observer cancel bug.
                doc.afterTransaction = { _ in
                    guard duringCleanup, !attempted, let engine = hookedEngine else { return }
                    attempted = true
                    XCTAssertNil(doc.transaction)
                    XCTAssertFalse(doc.transactionCleanups.isEmpty)
                    do { try assertRejected(engine) } catch { XCTFail("hook check failed: \(error)") }
                }
                let engine = DocumentEngine(doc: doc, surface: surface)
                hookedEngine = engine
                if intent != "begin" { try engine.compositionBegan(blockID: Self.firstID, at: 6) }
                let textType = try XCTUnwrap(BlockIndex(doc: doc).entries[Self.firstID]?.textType)
                try doc.transact(origin: .remote) { _ in
                    try textType.insert(0, "Z")
                    if !duringCleanup {
                        attempted = true
                        XCTAssertNotNil(doc.transaction)
                        try assertRejected(engine)
                    }
                }
                XCTAssertTrue(attempted)
                XCTAssertNil(doc.transaction)
                XCTAssertTrue(doc.transactionCleanups.isEmpty)
                if intent == "begin" {
                    XCTAssertFalse(surface.isCompositionDeferred)
                    try engine.compositionBegan(blockID: Self.firstID, at: 6)
                } else {
                    XCTAssertTrue(surface.isCompositionDeferred)
                    XCTAssertTrue(surface.appliedPatches.isEmpty)
                }
                try engine.compositionCancelled()
                XCTAssertEqual(surface.compositionDeferrals, [true, false])
                XCTAssertEqual(
                    text(of: surface.blocks[0]), "ZFirst paragraph.",
                    "the transaction delta must not be replayed on a rebuild")
                assertSurfaceMatchesProjection(surface, doc, "\(intent), during cleanup=\(duringCleanup)")
            }
        }
    }

    func testWholeListFreezeRejectsOtherBlockInputsUntilResetAndCompletion() throws {
        for commit in [false, true] {
            let local = try makeDoc(clientID: 1)
            defer { local.destroy() }
            let peer = try makeDoc(clientID: 2)
            defer { peer.destroy() }
            let surface = ContractSurface(blocks: projection(local))
            let peerSurface = HeadlessSurface(blocks: projection(peer))
            let engine = DocumentEngine(doc: local, surface: surface)
            let peerEngine = DocumentEngine(doc: peer, surface: peerSurface)
            try engine.compositionBegan(blockID: Self.secondID, at: 3)
            try local.applyUpdate(YUpdateDecoder.decode(peerEngine.joinBlocks(block: Self.secondID)), origin: .remote)
            try local.applyUpdate(
                YUpdateDecoder.decode(peerEngine.replaceText(block: Self.thirdID, range: 0..<0, with: "Z")),
                origin: .remote)
            XCTAssertTrue(surface.received.isEmpty, "removal makes every subsequent block patch wait for reset")
            XCTAssertEqual(text(of: surface.headless.blocks[2]), "Third paragraph.")
            let caret = EditorPosition(blockID: Self.thirdID, offset: 5)
            func assertWholeListLocked() throws {
                let actions: [() throws -> Void] = [
                    { _ = try engine.replaceText(block: Self.thirdID, range: 5..<5, with: "unsafe") },
                    { try engine.setSelection(EditorSelection(anchor: caret, head: caret)) },
                    { try engine.compositionBegan(blockID: Self.thirdID, at: 5) },
                ]
                for reject in actions {
                    let state = try YStateEncoder.encodeStateAsUpdate(local)
                    let selection = try engine.currentSelection()
                    let patches = surface.received
                    let deferrals = surface.headless.compositionDeferrals
                    XCTAssertThrowsError(try reject()) { XCTAssertEqual($0 as? DocumentEngineError, .composingBlock) }
                    XCTAssertEqual(try YStateEncoder.encodeStateAsUpdate(local), state)
                    XCTAssertEqual(try engine.currentSelection(), selection)
                    XCTAssertEqual(surface.received, patches)
                    XCTAssertEqual(surface.headless.compositionDeferrals, deferrals)
                }
            }
            try assertWholeListLocked()
            var checkedReset = false
            surface.onPatch = {
                guard !checkedReset else { return }
                checkedReset = true
                guard case .reset = surface.received.last?.changes.first else { return XCTFail("expected final reset") }
                // The queue is now nil, but the deferral-complete event has not
                // arrived. Its global lock must survive delivery of the reset.
                do { try assertWholeListLocked() } catch { XCTFail("reset callback failed: \(error)") }
            }
            if commit {
                XCTAssertEqual(try engine.compositionCommitted(text: "LOST"), Data([0, 0]))
            } else {
                try engine.compositionCancelled()
            }
            XCTAssertTrue(checkedReset)
            XCTAssertEqual(surface.headless.compositionDeferrals, [true, false])
            assertSurfaceMatchesProjection(surface.headless, local, "whole-list reset after commit=\(commit)")
            surface.onPatch = nil
            try engine.setSelection(EditorSelection(anchor: caret, head: caret))
            try engine.compositionBegan(blockID: Self.thirdID, at: 5)
            try engine.compositionCancelled()
            let update = try engine.replaceText(block: Self.thirdID, range: 5..<5, with: "allowed")
            try peer.applyUpdate(YUpdateDecoder.decode(update), origin: .remote)
            XCTAssertEqual(YXMLString.fragment(local), YXMLString.fragment(peer))
            assertSurfaceMatchesProjection(surface.headless, local, "whole-list input unlocked")
            assertSurfaceMatchesProjection(peerSurface, peer, "peer after unlock")
        }
    }

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
