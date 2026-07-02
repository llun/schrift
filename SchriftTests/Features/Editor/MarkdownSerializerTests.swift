import XCTest
@testable import Schrift

final class MarkdownSerializerTests: XCTestCase {
    func testSerializesHeadings() {
        XCTAssertEqual(serializeMarkdown([EditorBlock(kind: .heading(level: 1), text: "Title")]), "# Title\n")
        XCTAssertEqual(serializeMarkdown([EditorBlock(kind: .heading(level: 3), text: "Deep")]), "### Deep\n")
    }

    func testSerializesParagraph() {
        XCTAssertEqual(serializeMarkdown([EditorBlock(kind: .paragraph, text: "Hello")]), "Hello\n")
    }

    func testSerializesChecklistItems() {
        XCTAssertEqual(serializeMarkdown([
            EditorBlock(kind: .checklistItem(checked: false), text: "Todo"),
            EditorBlock(kind: .checklistItem(checked: true), text: "Done"),
        ]), "- [ ] Todo\n- [x] Done\n")
    }

    func testSerializesQuoteBlocksSeparatedByBlankLines() {
        XCTAssertEqual(serializeMarkdown([
            EditorBlock(kind: .quote, text: "First"),
            EditorBlock(kind: .quote, text: "Second"),
        ]), "> First\n\n> Second\n")
    }

    func testAdjacentListItemsJoinTightly() {
        XCTAssertEqual(serializeMarkdown([
            EditorBlock(kind: .bulletItem, text: "One"),
            EditorBlock(kind: .bulletItem, text: "Two"),
        ]), "- One\n- Two\n")
    }

    func testParagraphsAreSeparatedByBlankLine() {
        XCTAssertEqual(serializeMarkdown([
            EditorBlock(kind: .paragraph, text: "One"),
            EditorBlock(kind: .paragraph, text: "Two"),
        ]), "One\n\nTwo\n")
    }

    func testNumberedItemsAreRenumberedByPosition() {
        XCTAssertEqual(serializeMarkdown([
            EditorBlock(kind: .numberedItem, text: "First"),
            EditorBlock(kind: .numberedItem, text: "Second"),
            EditorBlock(kind: .numberedItem, text: "Third"),
        ]), "1. First\n2. Second\n3. Third\n")
    }

    func testNumberedRunsRestartAfterInterruption() {
        XCTAssertEqual(serializeMarkdown([
            EditorBlock(kind: .numberedItem, text: "One"),
            EditorBlock(kind: .paragraph, text: "Break"),
            EditorBlock(kind: .numberedItem, text: "Restarts"),
        ]), "1. One\n\nBreak\n\n1. Restarts\n")
    }

    func testSerializesCodeBlockWithLanguage() {
        XCTAssertEqual(
            serializeMarkdown([EditorBlock(kind: .codeBlock(language: "swift"), text: "let x = 1")]),
            "```swift\nlet x = 1\n```\n"
        )
    }

    func testCodeBlockContainingFenceUsesLongerFence() {
        XCTAssertEqual(
            serializeMarkdown([EditorBlock(kind: .codeBlock(language: ""), text: "```\ninner\n```")]),
            "````\n```\ninner\n```\n````\n"
        )
    }

    func testSerializesEmptyCodeBlock() {
        XCTAssertEqual(
            serializeMarkdown([EditorBlock(kind: .codeBlock(language: ""), text: "")]),
            "```\n```\n"
        )
    }

    func testSerializesDivider() {
        XCTAssertEqual(serializeMarkdown([EditorBlock(kind: .divider)]), "---\n")
    }

    func testUnknownBlockIsEmittedVerbatim() {
        let table = "| a | b |\n| - | - |"
        XCTAssertEqual(serializeMarkdown([EditorBlock(kind: .unknown, text: table)]), table + "\n")
    }

    func testEmptyParagraphsAreDropped() {
        XCTAssertEqual(serializeMarkdown([
            EditorBlock(kind: .paragraph, text: "One"),
            EditorBlock(kind: .paragraph, text: ""),
            EditorBlock(kind: .paragraph, text: "Two"),
        ]), "One\n\nTwo\n")
    }

    func testEmptyBlocksProduceEmptyString() {
        XCTAssertEqual(serializeMarkdown([]), "")
        XCTAssertEqual(serializeMarkdown([EditorBlock(kind: .paragraph, text: "")]), "")
    }

    func testNumberedIndexCountsContiguousRun() {
        let blocks = [
            EditorBlock(kind: .numberedItem, text: "a"),
            EditorBlock(kind: .numberedItem, text: "b"),
            EditorBlock(kind: .paragraph, text: "break"),
            EditorBlock(kind: .numberedItem, text: "c"),
        ]
        XCTAssertEqual(numberedIndex(of: 0, in: blocks), 1)
        XCTAssertEqual(numberedIndex(of: 1, in: blocks), 2)
        XCTAssertEqual(numberedIndex(of: 3, in: blocks), 1)
    }
}
