import XCTest

@testable import Schrift

final class MarkdownRoundTripTests: XCTestCase {
    /// Any block array the editor can produce (no empty paragraphs) must
    /// survive serialize → parse unchanged.
    private func assertBlocksFixedPoint(
        _ blocks: [EditorBlock],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let reparsed = parseEditorBlocks(serializeMarkdown(blocks))
        XCTAssertTrue(
            blocksContentEqual(reparsed, blocks),
            "Round trip produced \(reparsed.map { "\($0.kind): \"\($0.text)\"" }) from \(blocks.map { "\($0.kind): \"\($0.text)\"" })",
            file: file,
            line: line
        )
    }

    func testEveryKindSurvivesRoundTrip() {
        assertBlocksFixedPoint([
            EditorBlock(kind: .heading(level: 1), text: "Title"),
            EditorBlock(kind: .heading(level: 6), text: "Small"),
            EditorBlock(kind: .paragraph, text: "Some **bold** text."),
            EditorBlock(kind: .bulletItem, text: "Bullet"),
            EditorBlock(kind: .numberedItem, text: "Numbered"),
            EditorBlock(kind: .checklistItem(checked: false), text: "Todo"),
            EditorBlock(kind: .checklistItem(checked: true), text: "Done"),
            EditorBlock(kind: .quote, text: "Quote"),
            EditorBlock(kind: .codeBlock(language: "swift"), text: "let x = 1\nlet y = 2"),
            EditorBlock(kind: .divider),
            EditorBlock(kind: .unknown, text: "| a | b |\n| - | - |"),
            EditorBlock(kind: .paragraph, text: "The end."),
        ])
    }

    func testAdjacentListRunsSurvive() {
        assertBlocksFixedPoint([
            EditorBlock(kind: .bulletItem, text: "one"),
            EditorBlock(kind: .checklistItem(checked: true), text: "two"),
            EditorBlock(kind: .numberedItem, text: "three"),
            EditorBlock(kind: .numberedItem, text: "four"),
        ])
    }

    func testAdjacentQuotesSurvive() {
        assertBlocksFixedPoint([
            EditorBlock(kind: .quote, text: "first"),
            EditorBlock(kind: .quote, text: "second"),
        ])
    }

    func testCodeBlockContainingFenceSurvives() {
        assertBlocksFixedPoint([
            EditorBlock(kind: .codeBlock(language: ""), text: "```\ninner\n```")
        ])
    }

    func testCodeBlockWithBlankLinesSurvives() {
        assertBlocksFixedPoint([
            EditorBlock(kind: .codeBlock(language: "python"), text: "a = 1\n\nb = 2")
        ])
    }

    func testEmptyTextedBlocksSurvive() {
        assertBlocksFixedPoint([
            EditorBlock(kind: .heading(level: 2), text: ""),
            EditorBlock(kind: .bulletItem, text: ""),
            EditorBlock(kind: .checklistItem(checked: false), text: ""),
            EditorBlock(kind: .quote, text: ""),
            EditorBlock(kind: .codeBlock(language: ""), text: ""),
        ])
    }

    func testDividerBetweenParagraphsSurvives() {
        assertBlocksFixedPoint([
            EditorBlock(kind: .paragraph, text: "above"),
            EditorBlock(kind: .divider),
            EditorBlock(kind: .paragraph, text: "below"),
        ])
    }

    // MARK: - Canonicalization fixed point on arbitrary input

    private let corpus: [String] = [
        "# Title\n\nBody text.\n",
        "* star bullet\n* another\n",
        "3. starts at three\n7) other marker\n",
        ">tight quote\n",
        "#  Extra   spaces  \n",
        "| a | b |\n| - | - |\n| 1 | 2 |\n",
        "Nested:\n- top\n  - inner\n    - deeper\n",
        "![img](x.png)\n\n<hr>\n",
        "```js\nconsole.log('hi')\n```\n",
        "Line one\nline two\nline three\n",
        "*****\n",
        "- [X] Upper checked\n",
    ]

    func testCorpusReachesCanonicalFixedPointAfterOnePass() {
        for markdown in corpus {
            let once = serializeMarkdown(parseEditorBlocks(markdown))
            let twice = serializeMarkdown(parseEditorBlocks(once))
            XCTAssertEqual(once, twice, "Not canonical after one pass for: \(markdown)")
        }
    }

    func testCorpusSurvivesRoundTrip() {
        for markdown in corpus {
            XCTAssertTrue(markdownSurvivesRoundTrip(markdown), "Content lost for: \(markdown)")
        }
    }
}
