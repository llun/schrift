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
        XCTAssertEqual(
            serializeMarkdown([
                EditorBlock(kind: .checklistItem(checked: false), text: "Todo"),
                EditorBlock(kind: .checklistItem(checked: true), text: "Done"),
            ]), "- [ ] Todo\n- [x] Done\n")
    }

    func testAdjacentQuoteLinesJoinTightly() {
        // "> a\n> b" is one blockquote in the source; re-serializing with a
        // blank line would split it into two.
        XCTAssertEqual(
            serializeMarkdown([
                EditorBlock(kind: .quote, text: "First"),
                EditorBlock(kind: .quote, text: "Second"),
            ]), "> First\n> Second\n")
    }

    func testIndentedUnknownStaysTightlyBoundToListItems() {
        // A nested list parses as [bullet, unknown]; a blank line between them
        // would turn the tight list loose on every save.
        XCTAssertEqual(
            serializeMarkdown([
                EditorBlock(kind: .bulletItem, text: "top"),
                EditorBlock(kind: .unknown, text: "  - inner\n    - deeper"),
            ]), "- top\n  - inner\n    - deeper\n")
    }

    func testNonIndentedUnknownIsSeparatedByBlankLine() {
        XCTAssertEqual(
            serializeMarkdown([
                EditorBlock(kind: .bulletItem, text: "item"),
                EditorBlock(kind: .unknown, text: "| a | b |"),
            ]), "- item\n\n| a | b |\n")
    }

    func testAdjacentListItemsJoinTightly() {
        XCTAssertEqual(
            serializeMarkdown([
                EditorBlock(kind: .bulletItem, text: "One"),
                EditorBlock(kind: .bulletItem, text: "Two"),
            ]), "- One\n- Two\n")
    }

    func testParagraphsAreSeparatedByBlankLine() {
        XCTAssertEqual(
            serializeMarkdown([
                EditorBlock(kind: .paragraph, text: "One"),
                EditorBlock(kind: .paragraph, text: "Two"),
            ]), "One\n\nTwo\n")
    }

    func testNumberedItemsAreRenumberedByPosition() {
        XCTAssertEqual(
            serializeMarkdown([
                EditorBlock(kind: .numberedItem, text: "First"),
                EditorBlock(kind: .numberedItem, text: "Second"),
                EditorBlock(kind: .numberedItem, text: "Third"),
            ]), "1. First\n2. Second\n3. Third\n")
    }

    func testNumberedRunsRestartAfterInterruption() {
        XCTAssertEqual(
            serializeMarkdown([
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

    func testSerializesImageBlock() {
        XCTAssertEqual(
            serializeMarkdown([EditorBlock(kind: .image(alt: "diagram", url: "https://example.com/d.png"))]),
            "![diagram](https://example.com/d.png)\n")
    }

    func testUnknownBlockIsEmittedVerbatim() {
        let table = "| a | b |\n| - | - |"
        XCTAssertEqual(serializeMarkdown([EditorBlock(kind: .unknown, text: table)]), table + "\n")
    }

    func testEmptyParagraphsAreDropped() {
        XCTAssertEqual(
            serializeMarkdown([
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

    // MARK: - Nested list items

    /// The same columns the web editor's markdown export uses: two under a
    /// bullet or checklist item, three under `1. `, four under `10. `.
    func testNestedItemsAreIndentedToTheirParentsContentColumn() {
        let blocks = [
            EditorBlock(kind: .bulletItem, text: "A"),
            EditorBlock(kind: .bulletItem, text: "B", indent: 1),
            EditorBlock(kind: .checklistItem(checked: false), text: "C", indent: 2),
            EditorBlock(kind: .bulletItem, text: "D", indent: 3),
            EditorBlock(kind: .numberedItem, text: "N", indent: 1),
            EditorBlock(kind: .numberedItem, text: "M", indent: 2),
            EditorBlock(kind: .bulletItem, text: "E"),
        ]
        XCTAssertEqual(
            serializeMarkdown(blocks), "- A\n  - B\n    - [ ] C\n      - D\n  1. N\n     1. M\n- E\n")
    }

    func testAChildOfATwoDigitItemIsIndentedFourColumns() {
        var blocks = (1...10).map { EditorBlock(kind: .numberedItem, text: "n\($0)") }
        blocks.append(EditorBlock(kind: .bulletItem, text: "child", indent: 1))
        XCTAssertTrue(serializeMarkdown(blocks).hasSuffix("10. n10\n    - child\n"))
    }

    func testSerializedNestingParsesBackToTheSameIndents() {
        let blocks = [
            EditorBlock(kind: .numberedItem, text: "one"),
            EditorBlock(kind: .checklistItem(checked: true), text: "two", indent: 1),
            EditorBlock(kind: .bulletItem, text: "three", indent: 2),
            EditorBlock(kind: .numberedItem, text: "four", indent: 1),
            EditorBlock(kind: .paragraph, text: "after"),
        ]
        XCTAssertTrue(blocksContentEqual(parseEditorBlocks(serializeMarkdown(blocks)), blocks))
    }

    /// An indent the position can't hold is written as what normalization makes
    /// of it — never as an indented line under prose, which would read back as
    /// verbatim text.
    func testAnUnsupportedIndentIsNormalizedBeforeWriting() {
        XCTAssertEqual(
            serializeMarkdown([
                EditorBlock(kind: .paragraph, text: "p"),
                EditorBlock(kind: .bulletItem, text: "a", indent: 2),
                EditorBlock(kind: .bulletItem, text: "b", indent: 3),
            ]), "p\n\n- a\n  - b\n")
    }

    func testNumberingRestartsPerLevelAndContinuesAcrossASubList() {
        let blocks = [
            EditorBlock(kind: .numberedItem, text: "a"),
            EditorBlock(kind: .numberedItem, text: "a.1", indent: 1),
            EditorBlock(kind: .numberedItem, text: "a.2", indent: 1),
            EditorBlock(kind: .bulletItem, text: "a.2.x", indent: 2),
            EditorBlock(kind: .numberedItem, text: "b"),
            EditorBlock(kind: .bulletItem, text: "b.x", indent: 1),
            EditorBlock(kind: .numberedItem, text: "b.1", indent: 1),
        ]
        XCTAssertEqual(blocks.indices.map { numberedIndex(of: $0, in: blocks) }, [1, 1, 2, 1, 2, 1, 1])
    }
}
