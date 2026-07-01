import XCTest
@testable import DocsIOS

final class MarkdownBlockTests: XCTestCase {
    func testParsesParagraph() {
        XCTAssertEqual(parseMarkdownBlocks("Hello world"), [.paragraph(text: "Hello world")])
    }

    func testParsesHeadingLevels() {
        XCTAssertEqual(parseMarkdownBlocks("# Title"), [.heading(level: 1, text: "Title")])
        XCTAssertEqual(parseMarkdownBlocks("## Subtitle"), [.heading(level: 2, text: "Subtitle")])
        XCTAssertEqual(parseMarkdownBlocks("###### Deep"), [.heading(level: 6, text: "Deep")])
    }

    func testHeadingRequiresSpaceAfterHashes() {
        XCTAssertEqual(parseMarkdownBlocks("#NoSpace"), [.paragraph(text: "#NoSpace")])
    }

    func testParsesBulletItemsWithDashOrAsterisk() {
        XCTAssertEqual(parseMarkdownBlocks("- Item one"), [.bulletItem(text: "Item one")])
        XCTAssertEqual(parseMarkdownBlocks("* Item two"), [.bulletItem(text: "Item two")])
    }

    func testParsesUncheckedChecklistItem() {
        XCTAssertEqual(parseMarkdownBlocks("- [ ] Task"), [.checklistItem(checked: false, text: "Task")])
    }

    func testParsesCheckedChecklistItemLowercaseAndUppercase() {
        XCTAssertEqual(parseMarkdownBlocks("- [x] Done"), [.checklistItem(checked: true, text: "Done")])
        XCTAssertEqual(parseMarkdownBlocks("- [X] Done"), [.checklistItem(checked: true, text: "Done")])
    }

    func testChecklistIsDistinguishedFromPlainBullet() {
        let blocks = parseMarkdownBlocks("- [ ] Task\n- Not a checklist item")
        XCTAssertEqual(blocks, [.checklistItem(checked: false, text: "Task"), .bulletItem(text: "Not a checklist item")])
    }

    func testParsesQuote() {
        XCTAssertEqual(parseMarkdownBlocks("> Quoted text"), [.quote(text: "Quoted text")])
    }

    func testParsesMultipleBlocksInOrder() {
        let markdown = """
        # Heading

        A paragraph.

        - Bullet one
        - [ ] Checklist item
        > A quote
        """
        XCTAssertEqual(parseMarkdownBlocks(markdown), [
            .heading(level: 1, text: "Heading"),
            .paragraph(text: "A paragraph."),
            .bulletItem(text: "Bullet one"),
            .checklistItem(checked: false, text: "Checklist item"),
            .quote(text: "A quote"),
        ])
    }

    func testEmptyLinesAreSkipped() {
        XCTAssertEqual(parseMarkdownBlocks("\n\nHello\n\n\nWorld\n"), [.paragraph(text: "Hello"), .paragraph(text: "World")])
    }

    func testEmptyStringProducesNoBlocks() {
        XCTAssertEqual(parseMarkdownBlocks(""), [])
    }
}
