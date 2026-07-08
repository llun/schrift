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
}
