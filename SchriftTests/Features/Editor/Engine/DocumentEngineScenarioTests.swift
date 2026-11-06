import XCTest

@testable import Schrift

/// The C2 scenarios, rebuilt so they assert what they claim: after every step
/// the surface's block list equals the replica's projection, and the patch that
/// produced it is the one the engine emitted.
@MainActor
final class DocumentEngineScenarioTests: DocumentEngineTestCase {
    func testTypingProducesATextPatchAndTheSurfaceConverges() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)

        try engine.replaceText(block: Self.firstID, range: 5..<5, with: "X")

        assertSurfaceMatchesProjection(surface, doc, "after typing")
        XCTAssertEqual(text(of: try XCTUnwrap(block(surface, Self.firstID))), "FirstX paragraph.")
        let patch = try XCTUnwrap(surface.appliedPatches.last)
        guard case .text(let id, let deltas) = try XCTUnwrap(patch.changes.first) else {
            return XCTFail("expected a text change, got \(patch.changes)")
        }
        XCTAssertEqual(id, Self.firstID)
        XCTAssertEqual(deltas, [TextDelta(range: 5..<5, replacement: "X", marks: [])])
    }

    func testTypingInsideABoldRunCarriesTheMark() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)

        // "Second paragraph has bold words inside it." — offset 25 is inside "bold words".
        try engine.replaceText(block: Self.secondID, range: 25..<25, with: "X")

        assertSurfaceMatchesProjection(surface, doc, "after typing in bold")
        let runs = try XCTUnwrap(block(surface, Self.secondID)).runs
        XCTAssertTrue(runs.contains { $0.text.contains("X") && $0.marks.contains { $0.key == "bold" } })
    }

    func testDeletingAcrossAFormatBoundaryConverges() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)

        // 26..<36 starts inside the bold run and ends in plain text.
        try engine.replaceText(block: Self.secondID, range: 26..<36, with: "")

        assertSurfaceMatchesProjection(surface, doc, "after the boundary delete")
        XCTAssertEqual(text(of: try XCTUnwrap(block(surface, Self.secondID))), "Second paragraph has bold de it.")
    }

    func testRemoteInsertWhileEditingConverges() throws {
        let local = try makeDoc(clientID: 1)
        let remote = try makeDoc(clientID: 2)
        defer {
            local.destroy()
            remote.destroy()
        }
        let localSurface = HeadlessSurface(blocks: projection(local))
        let remoteSurface = HeadlessSurface(blocks: projection(remote))
        let localEngine = DocumentEngine(doc: local, surface: localSurface)
        _ = localEngine
        let remoteEngine = DocumentEngine(doc: remote, surface: remoteSurface)

        let update = try remoteEngine.replaceText(block: Self.firstID, range: 0..<0, with: "A ")
        try local.applyUpdate(try YUpdateDecoder.decode(update), origin: .remote)

        assertSurfaceMatchesProjection(localSurface, local, "local after the remote insert")
        assertSurfaceMatchesProjection(remoteSurface, remote, "remote after its own insert")
        XCTAssertEqual(text(of: try XCTUnwrap(block(localSurface, Self.firstID))), "A First paragraph.")
        XCTAssertEqual(YXMLString.fragment(local), YXMLString.fragment(remote))
    }

    func testRemoteSplitInsertsABlockAndShrinksTheSource() throws {
        let local = try makeDoc(clientID: 1)
        let remote = try makeDoc(clientID: 2)
        defer {
            local.destroy()
            remote.destroy()
        }
        let localSurface = HeadlessSurface(blocks: projection(local))
        let remoteSurface = HeadlessSurface(blocks: projection(remote))
        let localEngine = DocumentEngine(doc: local, surface: localSurface)
        _ = localEngine
        let remoteEngine = DocumentEngine(doc: remote, surface: remoteSurface)

        let update = try remoteEngine.splitBlock(
            block: Self.firstID, at: 6, newID: "b0000000-0000-4000-8000-0000000000aa")
        try local.applyUpdate(try YUpdateDecoder.decode(update), origin: .remote)

        assertSurfaceMatchesProjection(localSurface, local, "local after the remote split")
        assertSurfaceMatchesProjection(remoteSurface, remote, "remote after its own split")
        XCTAssertEqual(localSurface.blocks.count, 4)
        XCTAssertEqual(localSurface.blocks.map(\.id)[1], "b0000000-0000-4000-8000-0000000000aa")
        XCTAssertEqual(text(of: localSurface.blocks[0]), "First ")
        XCTAssertEqual(text(of: localSurface.blocks[1]), "paragraph.")
    }

    func testRemoteJoinRemovesABlockAndGrowsTheTarget() throws {
        let local = try makeDoc(clientID: 1)
        let remote = try makeDoc(clientID: 2)
        defer {
            local.destroy()
            remote.destroy()
        }
        let localSurface = HeadlessSurface(blocks: projection(local))
        let remoteSurface = HeadlessSurface(blocks: projection(remote))
        let localEngine = DocumentEngine(doc: local, surface: localSurface)
        _ = localEngine
        let remoteEngine = DocumentEngine(doc: remote, surface: remoteSurface)

        let update = try remoteEngine.joinBlocks(block: Self.secondID)
        try local.applyUpdate(try YUpdateDecoder.decode(update), origin: .remote)

        assertSurfaceMatchesProjection(localSurface, local, "local after the remote join")
        assertSurfaceMatchesProjection(remoteSurface, remote, "remote after its own join")
        XCTAssertEqual(localSurface.blocks.count, 2)
        XCTAssertEqual(
            text(of: localSurface.blocks[0]), "First paragraph.Second paragraph has bold words inside it.")
    }

    func testRemoteFormatChangeConvergesAndTheCleanupLeavesNoDrift() throws {
        let local = try makeDoc(clientID: 1)
        let remote = try makeDoc(clientID: 2)
        defer {
            local.destroy()
            remote.destroy()
        }
        let localSurface = HeadlessSurface(blocks: projection(local))
        let remoteSurface = HeadlessSurface(blocks: projection(remote))
        let localEngine = DocumentEngine(doc: local, surface: localSurface)
        _ = localEngine
        let remoteEngine = DocumentEngine(doc: remote, surface: remoteSurface)

        let update = try remoteEngine.formatRange(
            block: Self.thirdID, range: 0..<5, marks: [TextMark(key: "bold", valueJSON: "{}")])
        try local.applyUpdate(try YUpdateDecoder.decode(update), origin: .remote)

        assertSurfaceMatchesProjection(localSurface, local, "local after the remote format")
        assertSurfaceMatchesProjection(remoteSurface, remote, "remote after its own format")
        XCTAssertEqual(local.lastTransactionOrigin, nil, "the remote format must have run the B4 cleanup")
        let runs = try XCTUnwrap(block(localSurface, Self.thirdID)).runs
        XCTAssertEqual(runs.first?.text, "Third")
        XCTAssertEqual(runs.first?.marks.map(\.key), ["bold"])
        XCTAssertFalse(localSurface.appliedPatches.isEmpty)
    }

    func testRemoteTypeChangeReplacesTheBlock() throws {
        let local = try makeDoc(clientID: 1)
        let remote = try makeDoc(clientID: 2)
        defer {
            local.destroy()
            remote.destroy()
        }
        let localSurface = HeadlessSurface(blocks: projection(local))
        let remoteSurface = HeadlessSurface(blocks: projection(remote))
        let localEngine = DocumentEngine(doc: local, surface: localSurface)
        _ = localEngine
        let remoteEngine = DocumentEngine(doc: remote, surface: remoteSurface)

        let update = try remoteEngine.setBlockType(block: Self.thirdID, to: "heading", props: [("level", .int(2))])
        try local.applyUpdate(try YUpdateDecoder.decode(update), origin: .remote)

        assertSurfaceMatchesProjection(localSurface, local, "local after the remote type change")
        assertSurfaceMatchesProjection(remoteSurface, remote, "remote after its own type change")
        XCTAssertEqual(block(localSurface, Self.thirdID)?.node, "heading")
        XCTAssertTrue(
            localSurface.appliedPatches.contains { patch in
                patch.changes.contains { if case .replaceBlock(Self.thirdID, _) = $0 { true } else { false } }
            })
    }

    func testPropChangeProducesAPropsPatch() throws {
        let doc = try makeDoc(clientID: 1)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)

        try engine.setBlockType(block: Self.thirdID, to: "paragraph", props: [("textAlignment", .string("center"))])

        assertSurfaceMatchesProjection(surface, doc, "after the prop change")
        let patch = try XCTUnwrap(surface.appliedPatches.last)
        guard case .props(let id, let props) = try XCTUnwrap(patch.changes.first) else {
            return XCTFail("expected a props change, got \(patch.changes)")
        }
        XCTAssertEqual(id, Self.thirdID)
        XCTAssertEqual(props.first { $0.key == "textAlignment" }?.value, .string("center"))
    }
}
