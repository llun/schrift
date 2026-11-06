import XCTest

@testable import Schrift

/// Plan §6's concurrent second editor: two replicas from one seed, an engine
/// each, concurrent intents, updates exchanged between them. The assertions
/// are convergence (identical XML) and that each surface equals its own
/// replica's projection — never a guess at which side "wins".
@MainActor
final class DocumentEngineConcurrencyTests: DocumentEngineTestCase {
    /// Exchanges both independently authored updates and asserts convergence.
    private func exchange(_ pair: Pair, _ updateA: Data, _ updateB: Data, _ label: String) throws {
        try pair.a.applyUpdate(try YUpdateDecoder.decode(updateB), origin: .remote)
        try pair.b.applyUpdate(try YUpdateDecoder.decode(updateA), origin: .remote)
        XCTAssertEqual(YXMLString.fragment(pair.a), YXMLString.fragment(pair.b), label)
        assertSurfaceMatchesProjection(pair.surfaceA, pair.a, "\(label): A")
        assertSurfaceMatchesProjection(pair.surfaceB, pair.b, "\(label): B")
    }

    func testTypingWithAMarkToggledAtAFormatBoundary() throws {
        let pair = try makePair()
        defer { pair.destroy() }

        // A bolds the boundary between the plain prefix and the bold run and
        // types there; B types plain text at the same offset.
        let updateA = try pair.engineA.formatRange(
            block: Self.secondID, range: 21..<25, marks: [TextMark(key: "bold", valueJSON: "{}")])
        let updateB = try pair.engineB.replaceText(block: Self.secondID, range: 23..<23, with: "Z")

        try exchange(pair, updateA, updateB, "mark at a boundary")
        XCTAssertEqual(
            text(of: try XCTUnwrap(block(pair.surfaceA, Self.secondID))),
            text(of: try XCTUnwrap(block(pair.surfaceB, Self.secondID))))
    }

    func testTypingDuringAPeersTypeChange() throws {
        let pair = try makePair()
        defer { pair.destroy() }

        let updateA = try pair.engineA.setBlockType(block: Self.thirdID, to: "heading", props: [("level", .int(3))])
        let updateB = try pair.engineB.replaceText(block: Self.thirdID, range: 5..<5, with: "!")

        try exchange(pair, updateA, updateB, "typing during a type change")
        // Parity with the replica, not a guess: whatever the CRDT holds is what
        // the surface must show.
        XCTAssertEqual(block(pair.surfaceA, Self.thirdID)?.node, block(pair.surfaceB, Self.thirdID)?.node)
        XCTAssertEqual(
            text(of: try XCTUnwrap(block(pair.surfaceA, Self.thirdID))),
            text(of: try XCTUnwrap(block(pair.surfaceB, Self.thirdID))))
    }

    func testDeletionAcrossAFormatBoundary() throws {
        let pair = try makePair()
        defer { pair.destroy() }

        let updateA = try pair.engineA.replaceText(block: Self.secondID, range: 26..<36, with: "")
        let updateB = try pair.engineB.replaceText(block: Self.secondID, range: 20..<24, with: "")

        try exchange(pair, updateA, updateB, "deletion across a boundary")
        XCTAssertEqual(
            text(of: try XCTUnwrap(block(pair.surfaceA, Self.secondID))),
            text(of: try XCTUnwrap(block(pair.surfaceB, Self.secondID))))
    }

    func testRemoteFormattingProducesACleanupPatch() throws {
        let pair = try makePair()
        defer { pair.destroy() }

        // A formats a range B already has bold inside, so the remote transaction
        // arms the B4 cleanup on B.
        let updateA = try pair.engineA.formatRange(
            block: Self.secondID, range: 0..<30, marks: [TextMark(key: "bold", valueJSON: "{}")])
        try pair.b.applyUpdate(try YUpdateDecoder.decode(updateA), origin: .remote)

        XCTAssertEqual(pair.b.lastTransactionOrigin, nil, "the cleanup transaction must have run on B")
        assertSurfaceMatchesProjection(pair.surfaceB, pair.b, "B after the remote format")
        XCTAssertFalse(pair.surfaceB.appliedPatches.isEmpty)
        XCTAssertEqual(YXMLString.fragment(pair.a), YXMLString.fragment(pair.b))
    }

    func testConcurrentSplitsConverge() throws {
        let pair = try makePair()
        defer { pair.destroy() }

        let updateA = try pair.engineA.splitBlock(
            block: Self.firstID, at: 6, newID: "b0000000-0000-4000-8000-0000000000aa")
        let updateB = try pair.engineB.splitBlock(
            block: Self.thirdID, at: 5, newID: "b0000000-0000-4000-8000-0000000000bb")

        try exchange(pair, updateA, updateB, "concurrent splits")
        XCTAssertEqual(pair.surfaceA.blocks.count, 5)
        XCTAssertEqual(pair.surfaceA.blocks.map(\.id), pair.surfaceB.blocks.map(\.id))
    }
}
