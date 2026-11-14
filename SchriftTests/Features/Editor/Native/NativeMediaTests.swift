import UIKit
import XCTest

@testable import Schrift

/// PR13a end to end on a real editor session: the slash menu's media items,
/// the inspector's prop commands and peers' media edits reaching the card.
/// The upload pipeline is `NativeMediaQueueTests` (PR13b).
@MainActor
final class NativeMediaTests: NativeEditingTestCase {
    private nonisolated static let origin = "https://example.test"

    private func seed(_ name: String) throws -> Data {
        let capture = try XCTUnwrap(BlockNoteMediaCaptures.edits.first { $0.name == name }, name)
        return try XCTUnwrap(Data(base64Encoded: capture.seed))
    }

    private func xml(_ harness: Harness) async -> String {
        await harness.session.replicaDoc { YXMLString.fragment($0) } ?? ""
    }

    private func props(_ harness: Harness, _ id: String) throws -> [ProjectedProp] {
        try XCTUnwrap(harness.session.surface.blocks.first { $0.id == id }).props
    }

    // MARK: - Slash menu and inspector commands

    /// "/image" in an empty paragraph makes it an empty image block in place
    /// (the web's `insertOrUpdateBlockForSlashMenu`), one command, and asks
    /// for its inspector.
    func testTheImageSlashItemMakesAnEmptyImageAndRequestsItsInspector() async throws {
        let harness = try await makeHarness(state: try seed("imageSlashEmpty"))
        addTeardownBlock { await harness.close() }
        XCTAssertTrue(harness.session.canType)
        setSelection(harness, NSRange(location: try location(harness.session, "q", 0), length: 0))
        for key in ["/", "i", "m"] { harness.view.insertText(key) }
        await harness.settle()
        XCTAssertNotNil(harness.input.slashMenuQuery)
        let item = try XCTUnwrap(NativeInputCoordinator.slashItems.first { $0.id == "mediaImage" })
        let applied = await harness.run { harness.input.applySlashItem(item) }
        XCTAssertTrue(applied)
        XCTAssertEqual(harness.input.requestedMedia, "q")
        XCTAssertEqual(harness.session.surface.blocks.map(\.node), ["paragraph", "image", "paragraph"])
        let capture = try XCTUnwrap(BlockNoteMediaCaptures.edits.first { $0.name == "imageSlashEmpty" })
        let written = await xml(harness)
        XCTAssertEqual(written, capture.xml)
        try await assertConsistent(harness, localCommands: 4)
    }

    /// From a paragraph with text the block goes after it; the last root
    /// block gets the web's trailing paragraph, and the caret goes there.
    func testTheFileSlashItemAfterTextAddsTheTrailingParagraph() async throws {
        let harness = try await makeHarness([paragraph("lead", "Notes"), paragraph("q", "Later")])
        addTeardownBlock { await harness.close() }
        setSelection(harness, NSRange(location: try location(harness.session, "q", 0), length: 0))
        for key in ["/", "f"] { harness.view.insertText(key) }
        await harness.settle()
        let item = try XCTUnwrap(NativeInputCoordinator.slashItems.first { $0.id == "mediaFile" })
        let applied = await harness.run { harness.input.applySlashItem(item) }
        XCTAssertTrue(applied)
        let blocks = harness.session.surface.blocks
        XCTAssertEqual(blocks.map(\.node), ["paragraph", "paragraph", "file", "paragraph"])
        XCTAssertEqual(blocks[1].runs.map(\.text).joined(), "Later", "the query went, the text stayed")
        XCTAssertEqual(harness.input.requestedMedia, blocks[2].id)
        XCTAssertTrue(blocks[3].runs.allSatisfy(\.text.isEmpty))
        XCTAssertEqual(harness.view.selectedRange.location, try location(harness.session, blocks[3].id, 0))
        try await assertConsistent(harness, localCommands: 3)
    }

    /// A nested paragraph keeps its "/query": the slash item is refused (a
    /// media block below the root has no shadow) and nothing is written.
    func testTheSlashItemIsRefusedInANestedParagraph() async throws {
        let parent = BlockNoteBlock(
            node: "bulletListItem", props: paragraph("x", "").props, runs: [InlineRun("Parent")], id: "parent",
            children: [paragraph("q", "")])
        let harness = try await makeHarness([parent, paragraph("tail", "After")])
        addTeardownBlock { await harness.close() }
        setSelection(harness, NSRange(location: try location(harness.session, "q", 0), length: 0))
        for key in ["/", "i"] { harness.view.insertText(key) }
        await harness.settle()
        let item = try XCTUnwrap(NativeInputCoordinator.slashItems.first { $0.id == "mediaImage" })
        _ = await harness.run { harness.input.applySlashItem(item) }
        await harness.settle()
        XCTAssertEqual(harness.session.surface.blocks.map(\.node), ["bulletListItem", "paragraph", "paragraph"])
        let written = await xml(harness)
        XCTAssertFalse(written.contains("<image"))
        try await assertConsistent(harness, localCommands: 2)
    }

    /// Each inspector change is one command; the card's preview follows it,
    /// and an unchanged value writes nothing.
    func testInspectorPropsAreOneCommandEachAndTheCardFollows() async throws {
        let harness = try await makeHarness(state: try seed("imageSetCaption"))
        addTeardownBlock { await harness.close() }
        let caption = ProjectedProp(key: "caption", value: .string("A harbour at dawn"))
        let applied = await harness.run { harness.input.setMediaProps("mx", [caption]) }
        XCTAssertTrue(applied)
        let card = try XCTUnwrap(harness.session.surface.blocks.first { $0.id == "mx" })
        guard case .image(_, let alt, _)? = card.preview else { return XCTFail("\(String(describing: card.preview))") }
        XCTAssertEqual(alt, "A harbour at dawn")
        let width = ProjectedProp(key: "previewWidth", value: .int(320))
        _ = await harness.run { harness.input.setMediaProps("mx", [width]) }
        XCTAssertEqual(MediaBlock.number(try props(harness, "mx").last { $0.key == "previewWidth" }?.value), 320)
        // Unchanged: nothing posted, nothing journaled.
        XCTAssertTrue(harness.input.setMediaProps("mx", [width]))
        _ = await harness.run { harness.input.deleteMedia("mx") }
        XCTAssertNil(harness.session.surface.blocks.first { $0.id == "mx" })
        try await assertConsistent(harness, localCommands: 3)
    }

    /// A peer's caption change reaches the card (the surface re-reads a
    /// block's snapshot, preview included, on a `.props` patch).
    func testAPeersMediaPropChangeRefreshesTheCard() async throws {
        let state = try seed("imageSetCaption")
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }
        let peer = YDoc(clientID: 77, gc: true)
        defer { peer.destroy() }
        try peer.applyUpdate(YUpdateDecoder.decode(state))
        let before = YStateEncoder.encodeStateVector(peer)
        let engine = DocumentEngine(doc: peer, surface: HeadlessSurface())
        _ = try engine.applyStructural(
            NativeEditCommand(
                id: UUID(), baseRevision: engine.revision, blockID: "mx",
                kind: .mediaProps([ProjectedProp(key: "caption", value: .string("From a peer"))])), persist: { _ in })
        engine.detach()
        let vector = try YUpdateDecoder.decodeStateVector(before)
        let update = try YStateEncoder.encodeStateAsUpdate(
            peer, since: Dictionary(vector.map { ($0.client, $0.clock) }, uniquingKeysWith: { $1 }))
        try await harness.session.integrateServerState(update)
        await harness.settle()
        let card = try XCTUnwrap(harness.session.surface.blocks.first { $0.id == "mx" })
        guard case .image(_, let alt, _)? = card.preview else { return XCTFail("\(String(describing: card.preview))") }
        XCTAssertEqual(alt, "From a peer")
        try await assertConsistent(harness, localCommands: 0)
    }

    // MARK: - PR13b.2 Step 3: Batch media insertion

    /// `.insertMediaBatch(..., .replaceOrAfter)` replaces an empty middle
    /// paragraph with item 0, inserts remaining items after it, places the caret
    /// on the next editable block, and leaves `requestedMedia` unset.
    func testInsertMediaBatchReplacesEmptyParagraphAndDoesNotRequestInspector() async throws {
        let harness = try await makeHarness([
            paragraph("lead", "Before"),
            paragraph("q", ""),
            paragraph("tail", "After"),
        ])
        addTeardownBlock { await harness.close() }

        var delivered: [String]?
        let posted = await harness.run {
            harness.input.insertMediaBatch(
                nodes: ["image", "video", "pdf"], at: "q", placement: .replaceOrAfter
            ) { ids in
                delivered = ids
            }
        }
        XCTAssertTrue(posted)
        let blocks = harness.session.surface.blocks
        XCTAssertEqual(blocks.map(\.node), ["paragraph", "image", "video", "pdf", "paragraph"])
        XCTAssertNil(harness.input.requestedMedia)
        let ids = try XCTUnwrap(delivered)
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(ids[0], "q")
        XCTAssertEqual(Array(blocks[1...3].map(\.id)), ids)
        XCTAssertEqual(harness.view.selectedRange.location, try location(harness.session, "tail", 5))
        try await assertConsistent(harness, localCommands: 1)
    }

    /// Non-paragraph and last-block placements: `.before`, `.after` (with one
    /// trailing root paragraph), and non-replacing `.replaceOrAfter` over text.
    func testInsertMediaBatchBeforeAfterNonParagraphAndTrailing() async throws {
        let harness = try await makeHarness([
            paragraph("lead", "Keep me"),
            BlockNoteBlock(node: "divider", props: [], runs: [], id: "div", children: []),
        ])
        addTeardownBlock { await harness.close() }

        // 1. `.replaceOrAfter` over non-empty "lead" keeps "lead" and inserts after it;
        // only contentless "div" follows, so one trailing root paragraph is appended.
        var firstBatch: [String]?
        let ok1 = await harness.run {
            harness.input.insertMediaBatch(nodes: ["image", "file"], at: "lead", placement: .replaceOrAfter) {
                firstBatch = $0
            }
        }
        XCTAssertTrue(ok1)
        let batch1 = try XCTUnwrap(firstBatch)
        XCTAssertEqual(batch1.count, 2)
        XCTAssertFalse(batch1.contains("lead"))
        XCTAssertEqual(
            harness.session.surface.blocks.map(\.node), ["paragraph", "image", "file", "divider", "paragraph"])
        XCTAssertEqual(harness.session.surface.blocks[0].runs.map(\.text).joined(), "Keep me")

        // 2. `.before` non-paragraph "div" inserts before "div" without modifying "div" or adding another paragraph.
        var secondBatch: [String]?
        let ok2 = await harness.run {
            harness.input.insertMediaBatch(nodes: ["audio"], at: "div", placement: .before) {
                secondBatch = $0
            }
        }
        XCTAssertTrue(ok2)
        XCTAssertEqual(secondBatch?.count, 1)
        XCTAssertEqual(
            harness.session.surface.blocks.map(\.node),
            ["paragraph", "image", "file", "audio", "divider", "paragraph"])

        // 3. `.after` the last textless block in another harness appends one trailing paragraph and focuses it at offset 0.
        let tailHarness = try await makeHarness([
            BlockNoteBlock(node: "divider", props: [], runs: [], id: "divLast", children: [])
        ])
        addTeardownBlock { await tailHarness.close() }
        var thirdBatch: [String]?
        let ok3 = await tailHarness.run {
            tailHarness.input.insertMediaBatch(nodes: ["video"], at: "divLast", placement: .after) {
                thirdBatch = $0
            }
        }
        XCTAssertTrue(ok3)
        XCTAssertEqual(thirdBatch?.count, 1)
        let blocks = tailHarness.session.surface.blocks
        XCTAssertEqual(blocks.map(\.node), ["divider", "video", "paragraph"])
        let trailing = try XCTUnwrap(blocks.last)
        XCTAssertEqual(tailHarness.view.selectedRange.location, try location(tailHarness.session, trailing.id, 0))
        XCTAssertNil(tailHarness.input.requestedMedia)
        try await assertConsistent(harness, localCommands: 2)
        try await assertConsistent(tailHarness, localCommands: 1)
    }

    /// Targeting a nested block (`depth > 0`) walks up to its enclosing
    /// depth-0 block and inserts the batch at root without nesting media.
    func testInsertMediaBatchFromNestedBlockWalksUpToDepthZero() async throws {
        let deep = paragraph("grandchild", "")
        let child = BlockNoteBlock(
            node: "bulletListItem", props: paragraph("x", "").props, runs: [InlineRun("Child")], id: "child",
            children: [deep])
        let parent = BlockNoteBlock(
            node: "bulletListItem", props: paragraph("x", "").props, runs: [InlineRun("Parent")], id: "parent",
            children: [child])
        let harness = try await makeHarness([parent])
        addTeardownBlock { await harness.close() }

        var inserted: [String]?
        let ok = await harness.run {
            harness.input.insertMediaBatch(nodes: ["image", "video"], at: "grandchild", placement: .replaceOrAfter) {
                inserted = $0
            }
        }
        XCTAssertTrue(ok)
        let ids = try XCTUnwrap(inserted)
        XCTAssertEqual(ids.count, 2)
        XCTAssertFalse(ids.contains("grandchild"))
        XCTAssertFalse(ids.contains("parent"))
        let blocks = harness.session.surface.blocks
        // Top-level blocks: parent, child, grandchild (depth 0, 1, 2), then two depth-0 media blocks + trailing paragraph.
        XCTAssertEqual(
            blocks.map(\.node), ["bulletListItem", "bulletListItem", "paragraph", "image", "video", "paragraph"])
        XCTAssertEqual(blocks[3].id, ids[0])
        XCTAssertEqual(blocks[4].id, ids[1])
        let written = await xml(harness)
        XCTAssertTrue(written.contains(#"<blockcontainer id="\#(ids[0])">"#))
        XCTAssertTrue(written.contains(#"<blockcontainer id="\#(ids[1])">"#))
        try await assertConsistent(harness, localCommands: 1)
    }
}
