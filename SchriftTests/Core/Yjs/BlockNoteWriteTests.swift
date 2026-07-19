import XCTest

@testable import Schrift

/// The **from-empty byte-identity anchor** for the B6 local write path.
///
/// `BlockNoteWrite.applyEdit(old: [], new: blocks)` builds a whole BlockNote
/// document as local `YItem`s inside one local transaction and encodes the
/// resulting store as a v1 update. That update must be **byte-identical** to what
/// `BlockNoteYjs.encode(blocks)` — the shipping golden encoder, already pinned
/// byte-for-byte to real yjs (`YjsEncoderTests`) — produces for the same blocks
/// and client id. A match proves `YWrite` + the block-subtree builder reproduce
/// the exact document shape (item order, origins, parents, clocks) yjs itself
/// would, reusing the whole golden corpus as B6's correctness anchor.
final class BlockNoteWriteTests: XCTestCase {
    private let clientID: UInt = 42

    /// Deterministic repeating-digit BlockNote id for index `n`.
    private func U(_ n: Int) -> String { String(format: "%04x", n) + "0000-0000-4000-8000-000000000000" }

    /// The three base props every text block carries, in BlockNote order.
    private var P: [(key: String, value: YAnyValue)] {
        [
            ("backgroundColor", .string("default")), ("textColor", .string("default")),
            ("textAlignment", .string("left")),
        ]
    }

    private func para(_ runs: [InlineRun], _ id: Int) -> BlockNoteBlock {
        BlockNoteBlock(node: "paragraph", props: P, runs: runs, id: U(id))
    }

    /// The anchor assertion: from-empty apply == golden encode, byte for byte.
    private func assertFromEmptyMatchesGolden(
        _ blocks: [BlockNoteBlock], file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let doc = YDoc(clientID: clientID)
        let update = try BlockNoteWrite.applyEdit(old: [], new: blocks, to: doc)
        XCTAssertEqual(
            update, BlockNoteYjs.encode(blocks, clientID: UInt32(clientID)),
            "from-empty apply diverged from the golden encoder", file: file, line: line)
    }

    // MARK: - Step 1 anchors (brief)

    func testFromEmptyMatchesGoldenEncoder() throws {
        let blocks = [
            para([InlineRun("hello")], 0x1111), para([InlineRun("world")], 0x2222),
        ]
        let doc = YDoc(clientID: clientID)
        let update = try BlockNoteWrite.applyEdit(old: [], new: blocks, to: doc)
        XCTAssertEqual(update, BlockNoteYjs.encode(blocks, clientID: UInt32(clientID)))
    }

    func testFromEmptyBoldRunMatchesGolden() throws {
        let blocks = [
            BlockNoteBlock(
                node: "paragraph", props: P,
                runs: [InlineRun("a"), InlineRun("b", marks: [("bold", "{}")])],
                id: U(0x3333))
        ]
        let doc = YDoc(clientID: clientID)
        let update = try BlockNoteWrite.applyEdit(old: [], new: blocks, to: doc)
        XCTAssertEqual(update, BlockNoteYjs.encode(blocks, clientID: UInt32(clientID)))
    }

    // MARK: - Step 5 anchors: the full golden corpus

    func testFromEmptyEmptyParagraph() throws {
        try assertFromEmptyMatchesGolden([para([], 1)])
    }

    func testFromEmptyHeading() throws {
        let block = BlockNoteBlock(
            node: "heading", props: P + [("level", .int(2)), ("isToggleable", .bool(false))],
            runs: [InlineRun("Heading two")], id: U(1))
        try assertFromEmptyMatchesGolden([block])
    }

    func testFromEmptyBulletList() throws {
        let blocks = [
            BlockNoteBlock(node: "bulletListItem", props: P, runs: [InlineRun("one")], id: U(1)),
            BlockNoteBlock(node: "bulletListItem", props: P, runs: [InlineRun("two")], id: U(2)),
        ]
        try assertFromEmptyMatchesGolden(blocks)
    }

    func testFromEmptyNumberedList() throws {
        let blocks = [
            BlockNoteBlock(
                node: "numberedListItem", props: P + [("start", .null)], runs: [InlineRun("first")], id: U(1)),
            BlockNoteBlock(
                node: "numberedListItem", props: P + [("start", .null)], runs: [InlineRun("second")], id: U(2)),
        ]
        try assertFromEmptyMatchesGolden(blocks)
    }

    func testFromEmptyCheckList() throws {
        let blocks = [
            BlockNoteBlock(
                node: "checkListItem", props: P + [("checked", .bool(false))], runs: [InlineRun("todo")], id: U(1)),
            BlockNoteBlock(
                node: "checkListItem", props: P + [("checked", .bool(true))], runs: [InlineRun("done")], id: U(2)),
        ]
        try assertFromEmptyMatchesGolden(blocks)
    }

    func testFromEmptyQuote() throws {
        let block = BlockNoteBlock(
            node: "quote", props: [("backgroundColor", .string("default")), ("textColor", .string("default"))],
            runs: [InlineRun("quoted")], id: U(1))
        try assertFromEmptyMatchesGolden([block])
    }

    func testFromEmptyCodeBlock() throws {
        let block = BlockNoteBlock(
            node: "codeBlock", props: [("language", .string("swift"))], runs: [InlineRun("let x = 1")], id: U(1))
        try assertFromEmptyMatchesGolden([block])
    }

    /// A leaf (`divider`) with no text child and no props, between two paragraphs.
    func testFromEmptyDividerLeaf() throws {
        let blocks = [
            para([InlineRun("above")], 1),
            BlockNoteBlock(node: "divider", props: [], runs: [], id: U(2)),
            para([InlineRun("below")], 3),
        ]
        try assertFromEmptyMatchesGolden(blocks)
    }

    /// A leaf (`image`) with no text child that still carries props, incl. an
    /// `.undefined` `previewWidth`.
    func testFromEmptyImageLeafWithProps() throws {
        let block = BlockNoteBlock(
            node: "image",
            props: [
                ("textAlignment", .string("left")),
                ("backgroundColor", .string("default")),
                ("name", .string("photo.jpg")),
                (
                    "url",
                    .string(
                        "https://docs.example.test/media/11111111-1111-4111-8111-111111111111/attachments/22222222-2222-4222-8222-222222222222.jpg"
                    )
                ),
                ("caption", .string("")),
                ("showPreview", .bool(true)),
                ("previewWidth", .undefined),
            ],
            runs: [], id: U(1))
        try assertFromEmptyMatchesGolden([block])
    }

    func testFromEmptyLinkMark() throws {
        let runs = [
            InlineRun("See "), InlineRun("docs", marks: [("link", "{\"href\":\"https://example.com\"}")]),
            InlineRun(" now"),
        ]
        try assertFromEmptyMatchesGolden([para(runs, 1)])
    }

    func testFromEmptyMultipleInlineMarks() throws {
        let runs = [
            InlineRun("Some "), InlineRun("italic", marks: [("italic", "{}")]), InlineRun(" and "),
            InlineRun("bold", marks: [("bold", "{}")]), InlineRun(" and "), InlineRun("code", marks: [("code", "{}")]),
            InlineRun(" here."),
        ]
        try assertFromEmptyMatchesGolden([para(runs, 1)])
    }

    func testFromEmptyStrikeLeadingMark() throws {
        let runs = [InlineRun("gone", marks: [("strike", "{}")]), InlineRun(" text")]
        try assertFromEmptyMatchesGolden([para(runs, 1)])
    }

    func testFromEmptyUnicodeUsesUtf16LengthAndUtf8Bytes() throws {
        try assertFromEmptyMatchesGolden([para([InlineRun("café 😀 end")], 1)])
    }

    /// A mixed multi-block document threaded through the real markdown pipeline —
    /// exercises the block classifier + inline scanner the shipping save path uses.
    func testFromEmptyMarkdownPipelineDocument() throws {
        let markdown = """
            # Title

            A paragraph with **bold** and *italic* and a [link](https://example.com).

            - one
            - two

            > a quote

            ```swift
            let x = 1
            ```
            """
        let blocks = MarkdownYjs.blockNoteBlocks(from: markdown)
        try assertFromEmptyMatchesGolden(blocks)
    }
}
