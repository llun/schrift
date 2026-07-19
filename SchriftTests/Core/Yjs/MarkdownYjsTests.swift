import XCTest

@testable import Schrift

/// Tests the markdown → BlockNote block mapping (`MarkdownYjs.blockNoteBlocks`).
/// The Yjs byte encoding those blocks produce is covered by `YjsEncoderTests`,
/// and the full markdown→Yjs→markdown fidelity is validated offline against the
/// real BlockNote library.
final class MarkdownYjsTests: XCTestCase {
    private func nodes(_ markdown: String) -> [String] {
        MarkdownYjs.blockNoteBlocks(from: markdown).map(\.node)
    }
    private func firstBlock(_ markdown: String) -> BlockNoteBlock {
        MarkdownYjs.blockNoteBlocks(from: markdown)[0]
    }
    private func prop(_ block: BlockNoteBlock, _ key: String) -> YAnyValue? {
        block.props.first { $0.key == key }?.value
    }

    func testEmptyMarkdownProducesOneEmptyParagraph() {
        let blocks = MarkdownYjs.blockNoteBlocks(from: "")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].node, "paragraph")
        XCTAssertTrue(blocks[0].runs.isEmpty)
    }

    func testBlockKindsMapToBlockNoteNodes() {
        XCTAssertEqual(nodes("# H1"), ["heading"])
        XCTAssertEqual(nodes("plain"), ["paragraph"])
        XCTAssertEqual(nodes("- a\n- b"), ["bulletListItem", "bulletListItem"])
        XCTAssertEqual(nodes("1. a\n2. b"), ["numberedListItem", "numberedListItem"])
        XCTAssertEqual(nodes("- [ ] a"), ["checkListItem"])
        XCTAssertEqual(nodes("> q"), ["quote"])
        XCTAssertEqual(nodes("```\ncode\n```"), ["codeBlock"])
        XCTAssertEqual(nodes("---"), ["divider"])
        XCTAssertEqual(nodes("![alt](https://example.com/a.png)"), ["image"])
    }

    /// The bug this PR fixes: a standalone image used to fall into `.unknown` and
    /// encode as a literal-text paragraph, so a web-authored image was flattened
    /// to the raw `![…](…)` string on the first in-app save. It must now map to a
    /// real `image` leaf node carrying the url — never a paragraph of text.
    func testStandaloneImageMarkdownMapsToImageNodeNotLiteralText() {
        let markdown = "![photo](https://example.com/p.jpg)"
        XCTAssertEqual(nodes(markdown), ["image"])
        let block = firstBlock(markdown)
        XCTAssertEqual(prop(block, "url"), .string("https://example.com/p.jpg"))
        XCTAssertEqual(prop(block, "name"), .string("photo"))
        XCTAssertEqual(prop(block, "previewWidth"), .undefined)
        XCTAssertTrue(block.runs.isEmpty, "image is a leaf — it must carry no literal text runs")
    }

    /// Props are an *ordered* tuple array: their order is the order of the emitted
    /// Yjs bytes. `YjsEncoderTests.testImageBlockIsLeafWithProps` locks the byte
    /// layout for one hardcoded prop order, but nothing there constrains what
    /// `map` actually produces — reordering these would keep the golden green
    /// while every real save emitted bytes the golden never validated. Pin the
    /// order (and the absence of `textColor`) here, at the mapping.
    func testImageBlockPropOrderMatchesTheGoldenFixture() {
        let block = firstBlock("![photo](https://example.com/p.jpg)")
        XCTAssertEqual(
            block.props.map(\.key),
            ["textAlignment", "backgroundColor", "name", "url", "caption", "showPreview", "previewWidth"])
    }

    func testHeadingCarriesLevel() {
        XCTAssertEqual(prop(firstBlock("### Three"), "level"), .int(3))
        XCTAssertEqual(prop(firstBlock("###### Six"), "level"), .int(6))
    }

    func testChecklistCheckedState() {
        XCTAssertEqual(prop(firstBlock("- [ ] todo"), "checked"), .bool(false))
        XCTAssertEqual(prop(firstBlock("- [x] done"), "checked"), .bool(true))
    }

    func testCodeBlockLanguageDefaultsToText() {
        XCTAssertEqual(prop(firstBlock("```\ncode\n```"), "language"), .string("text"))
        XCTAssertEqual(prop(firstBlock("```swift\ncode\n```"), "language"), .string("swift"))
    }

    func testDividerHasNoText() {
        let block = firstBlock("---")
        XCTAssertEqual(block.node, "divider")
        XCTAssertTrue(block.runs.isEmpty)
    }

    func testInlineMarkdownBecomesStyledRuns() {
        let block = firstBlock("say **hi**")
        XCTAssertEqual(block.runs.map(\.text), ["say ", "hi"])
        XCTAssertEqual(block.runs[1].marks.map(\.key), ["bold"])
    }

    func testEncodeProducesValidYjsUpdateHeader() {
        // A v1 update begins with the number of clients (0x01 for one client).
        let data = MarkdownYjs.encode(markdown: "# Title\n\nbody", clientID: 1)
        XCTAssertEqual(data.first, 0x01)
        XCTAssertGreaterThan(data.count, 20)
    }

    func testBlockNoteBlocksFromEditorBlocksPreservesStableIDs() {
        let a = EditorBlock(kind: .paragraph, text: "Alpha")
        let b = EditorBlock(kind: .heading(level: 1), text: "Beta")
        let result = MarkdownYjs.blockNoteBlocks(from: [a, b])
        XCTAssertEqual(result.map(\.id), [a.id.uuidString.lowercased(), b.id.uuidString.lowercased()])
        XCTAssertEqual(result.map(\.node), ["paragraph", "heading"])
    }

    func testBlockNoteBlocksFromEmptyEditorBlocksFallsBackToOneParagraph() {
        let result = MarkdownYjs.blockNoteBlocks(from: [])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.node, "paragraph")
    }

    /// Calling the `[EditorBlock]` overload twice on the *same* array must
    /// yield identical ids — that stability is the whole point of Task 1
    /// (the live write path's `old` baseline has to line up across edits).
    func testBlockNoteBlocksFromEditorBlocksIsStableAcrossRepeatedCalls() {
        let blocks = [EditorBlock(kind: .paragraph, text: "Alpha"), EditorBlock(kind: .quote, text: "Beta")]
        let first = MarkdownYjs.blockNoteBlocks(from: blocks)
        let second = MarkdownYjs.blockNoteBlocks(from: blocks)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }

    /// `.unknown` blocks are the one case `map` doesn't reuse `EditorBlock.id`
    /// for (it can split one block into N literal-text paragraphs, so a single
    /// id wouldn't make sense) — it mints a fresh id per line, unchanged from
    /// the markdown-parse path. This is exactly why a document containing an
    /// `.unknown` block never qualifies as fully-modeled and so never enters
    /// the live write path — this overload's id-stability guarantee doesn't
    /// extend to it.
    func testUnknownBlockMintsFreshIDsNotTheEditorBlockID() {
        let block = EditorBlock(kind: .unknown, text: "| a | b |\n| - | - |")
        let result = MarkdownYjs.blockNoteBlocks(from: [block])
        XCTAssertEqual(result.count, 2)
        for mapped in result {
            XCTAssertNotEqual(mapped.id, block.id.uuidString.lowercased())
        }
    }

    /// The String overload is a thin wrapper (`blockNoteBlocks(from:
    /// parseEditorBlocks(markdown))`) — same markdown produces the same node
    /// shape either way. It does **not** produce the same ids as a second,
    /// independent `parseEditorBlocks` call on the same markdown: each parse
    /// mints its own fresh `EditorBlock.id`s (`EditorBlock.init`'s default
    /// `id: UUID = UUID()` is evaluated per call), so two parses of identical
    /// text never share ids. That instability is precisely the defect the
    /// `[EditorBlock]` overload exists to avoid — the live write path must
    /// feed it the editor's *actual*, already-parsed `blocks`, never a fresh
    /// re-parse of `currentMarkdown()`.
    func testStringOverloadRoutesThroughEditorBlockOverload() {
        let markdown = "Alpha\n\n# Beta"
        let blocks = parseEditorBlocks(markdown)
        let viaBlocks = MarkdownYjs.blockNoteBlocks(from: blocks)
        let viaString = MarkdownYjs.blockNoteBlocks(from: markdown)
        XCTAssertEqual(viaString.map(\.node), viaBlocks.map(\.node))
        XCTAssertNotEqual(
            viaString.map(\.id), blocks.map { $0.id.uuidString.lowercased() },
            "the String overload re-parses internally and mints its own ids, independent of any earlier parse")
    }
}
