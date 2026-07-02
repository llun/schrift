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
