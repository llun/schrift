import XCTest

@testable import Schrift

/// Tests for `YBlockProjection.project` — the structural walk that projects a
/// live Yjs replica back into BlockNote blocks (B5, the read side of the live
/// document bridge, C1). Fidelity classification here covers structure only
/// (node vocabulary, props presence/values, marks vocabulary, nesting); a
/// later task (B5 Task 4) may further downgrade a block to opaque when no
/// markdown spelling round-trips.
final class YBlockProjectionTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a replica from markdown via the same pipeline a save uses
    /// (`MarkdownYjs.encode` → `YUpdateDecoder.decode` → `YDoc.applyUpdate`),
    /// then projects it. The projection is computed *before* `destroy()` — the
    /// projected value holds no reference into the replica's item graph, but
    /// destroying first would tear down the graph the walk is still reading.
    private func projectedDoc(fromMarkdown md: String) throws -> ProjectedDocument {
        let doc = YDoc(clientID: 99)
        try doc.applyUpdate(try YUpdateDecoder.decode(MarkdownYjs.encode(markdown: md, clientID: 1)))
        let projected = YBlockProjection.project(doc)
        doc.destroy()
        return projected
    }

    /// Builds a replica directly from hand-crafted `BlockNoteBlock`s — used to
    /// reach shapes `MarkdownYjs` itself can never produce (unknown node names,
    /// extra/foreign props, unknown marks), since `BlockNoteYjs.encode` emits
    /// whatever it is given.
    private func projectedDoc(fromBlocks blocks: [BlockNoteBlock]) throws -> ProjectedDocument {
        let doc = YDoc(clientID: 99)
        try doc.applyUpdate(try YUpdateDecoder.decode(BlockNoteYjs.encode(blocks, clientID: 1)))
        let projected = YBlockProjection.project(doc)
        doc.destroy()
        return projected
    }

    private let baseProps: [(key: String, value: YAnyValue)] = [
        ("backgroundColor", .string("default")),
        ("textColor", .string("default")),
        ("textAlignment", .string("left")),
    ]

    // MARK: - Test 1: every modeled block kind round-trips

    func testProjectsEveryModeledBlockKindRoundTrip() throws {
        let markdown = """
            # Title

            Body **bold** _it_ ~~st~~ `co` [l](https://x.example/)

            - b

            1. n

            - [x] done

            > q

            ```swift
            let x = 1
            ```

            ---

            ![a](https://x.example/i.png)

            """
        let doc = try projectedDoc(fromMarkdown: markdown)

        let expectedNodes = [
            "heading", "paragraph", "bulletListItem", "numberedListItem", "checkListItem", "quote", "codeBlock",
            "divider", "image",
        ]
        XCTAssertEqual(doc.blocks.map(\.node), expectedNodes)
        XCTAssertEqual(doc.blocks.count, expectedNodes.count)

        for block in doc.blocks {
            XCTAssertEqual(block.fidelity, .modeled, "\(block.node) expected .modeled, got \(block.fidelity)")
        }
        XCTAssertTrue(doc.isFullyRenderable)
        XCTAssertTrue(doc.isFullyModeled)

        for block in doc.blocks {
            XCTAssertFalse(block.id.isEmpty, "\(block.node) block has an empty id")
            XCTAssertEqual(block.id, block.id.lowercased(), "\(block.node) block id is not lowercase")
            XCTAssertNotNil(UUID(uuidString: block.id), "\(block.node) block id is not a UUID: \(block.id)")
        }

        let paragraph = doc.blocks[1]
        XCTAssertEqual(
            paragraph.runs,
            InlineMarkdown.parse("Body **bold** _it_ ~~st~~ `co` [l](https://x.example/)"))
    }

    // MARK: - Test 2: empty replica / empty document

    func testEmptyReplicaProjectsEmptyRenderable() throws {
        let freshDoc = YDoc(clientID: 99)
        let freshProjection = YBlockProjection.project(freshDoc)
        freshDoc.destroy()
        XCTAssertEqual(freshProjection.blocks, [])
        XCTAssertTrue(freshProjection.isFullyRenderable)
        XCTAssertTrue(freshProjection.isFullyModeled)

        let emptyDocProjection = try projectedDoc(fromMarkdown: "")
        XCTAssertEqual(emptyDocProjection.blocks.count, 1)
        let paragraph = emptyDocProjection.blocks[0]
        XCTAssertEqual(paragraph.node, "paragraph")
        XCTAssertEqual(paragraph.runs, [])
        XCTAssertEqual(paragraph.fidelity, .modeled)
        XCTAssertTrue(emptyDocProjection.isFullyRenderable)
        XCTAssertTrue(emptyDocProjection.isFullyModeled)
    }

    // MARK: - Test 3: fidelity classification on hand-crafted shapes

    // Note: nested-blockGroup opacity and other shapes the public
    // `BlockNoteYjs.encode` can never produce (it always emits exactly one
    // element child per container) are deferred to a later task with oracle
    // fixtures — only reachable shapes are asserted here.

    func testHeadingToggleableTrueIsOpaque() throws {
        let props = baseProps + [("level", .int(1)), ("isToggleable", .bool(true))]
        let block = BlockNoteBlock(node: "heading", props: props, runs: [], id: "x")
        let doc = try projectedDoc(fromBlocks: [block])
        XCTAssertEqual(doc.blocks.count, 1)
        XCTAssertTrue(doc.blocks[0].fidelity.isOpaque, "expected opaque, got \(doc.blocks[0].fidelity)")
        XCTAssertEqual(doc.blocks[0].id, "x")
        XCTAssertFalse(doc.isFullyRenderable)
    }

    func testUnknownNodeIsOpaque() throws {
        let block = BlockNoteBlock(node: "fancyTable", props: [], runs: [], id: "x")
        let doc = try projectedDoc(fromBlocks: [block])
        XCTAssertEqual(doc.blocks.count, 1)
        guard case .opaque(let reason) = doc.blocks[0].fidelity else {
            XCTFail("expected .opaque, got \(doc.blocks[0].fidelity)")
            return
        }
        XCTAssertEqual(reason, "unknownNode:fancyTable")
        XCTAssertEqual(doc.blocks[0].id, "x")
        XCTAssertFalse(doc.isFullyRenderable)
    }

    func testUnknownPropKeyIsLossy() throws {
        let props = baseProps + [("sparkle", .bool(true))]
        let block = BlockNoteBlock(node: "paragraph", props: props, runs: [], id: "x")
        let doc = try projectedDoc(fromBlocks: [block])
        guard case .lossy(let reasons) = doc.blocks[0].fidelity else {
            XCTFail("expected .lossy, got \(doc.blocks[0].fidelity)")
            return
        }
        XCTAssertEqual(reasons, ["unknownProp:sparkle"])
        XCTAssertTrue(doc.isFullyRenderable)
        XCTAssertFalse(doc.isFullyModeled)
    }

    func testUnknownMarkIsLossyAndDropped() throws {
        let run = InlineRun("hi", marks: [(key: "underline", valueJSON: "{}")])
        let block = BlockNoteBlock(node: "paragraph", props: baseProps, runs: [run], id: "x")
        let doc = try projectedDoc(fromBlocks: [block])
        guard case .lossy(let reasons) = doc.blocks[0].fidelity else {
            XCTFail("expected .lossy, got \(doc.blocks[0].fidelity)")
            return
        }
        XCTAssertEqual(reasons, ["unknownMark:underline"])
        XCTAssertEqual(doc.blocks[0].runs, [InlineRun("hi")])
    }

    func testColoredTextIsLossy() throws {
        let props: [(key: String, value: YAnyValue)] = [
            ("backgroundColor", .string("default")),
            ("textColor", .string("red")),
            ("textAlignment", .string("left")),
        ]
        let block = BlockNoteBlock(node: "paragraph", props: props, runs: [], id: "x")
        let doc = try projectedDoc(fromBlocks: [block])
        guard case .lossy(let reasons) = doc.blocks[0].fidelity else {
            XCTFail("expected .lossy, got \(doc.blocks[0].fidelity)")
            return
        }
        XCTAssertEqual(reasons, ["prop:textColor"])
    }

    func testNumberedStartIsLossy() throws {
        let props = baseProps + [("start", .int(3))]
        let block = BlockNoteBlock(node: "numberedListItem", props: props, runs: [], id: "x")
        let doc = try projectedDoc(fromBlocks: [block])
        guard case .lossy(let reasons) = doc.blocks[0].fidelity else {
            XCTFail("expected .lossy, got \(doc.blocks[0].fidelity)")
            return
        }
        XCTAssertEqual(reasons, ["prop:start"])
    }

    // MARK: - Test 4 (deletions): deferred

    // `testDeletedBlocksAreSkipped` needs a second update that deletes a
    // container item. There is no vehicle to produce that from a single
    // `MarkdownYjs.encode` call, and hand-building a delete-set frame by hand
    // (rather than from an oracle capture) risks pinning behavior nobody
    // verified against real yjs. Deferred to a later task with oracle
    // fixtures, per the task brief.

    // MARK: - Test 5: inline format fold reproduces InlineMarkdown.parse

    func testFormatFoldReproducesParseRuns() throws {
        // The golden inline cases from InlineLayoutTests's
        // testParseProducesExactlyTheRuns... group, covering bold, the
        // italic+bold+code combo, strike, and a nested link+bold combo.
        let cases = [
            "See [docs](https://example.com) now",
            "Some *italic* and **bold** and `code` here.",
            "~~gone~~ text",
            "Hello **world**",
            "[**b**](u)",
        ]
        for line in cases {
            let doc = try projectedDoc(fromMarkdown: line)
            XCTAssertEqual(doc.blocks.count, 1, "line: \(line)")
            XCTAssertEqual(doc.blocks[0].runs, InlineMarkdown.parse(line), "line: \(line)")
            XCTAssertEqual(doc.blocks[0].fidelity, .modeled, "line: \(line)")
        }
    }
}
