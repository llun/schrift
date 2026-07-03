import XCTest

@testable import Schrift

final class MarkdownParserTests: XCTestCase {
    private func assertParses(
        _ markdown: String,
        _ expected: [EditorBlock],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let parsed = parseEditorBlocks(markdown)
        XCTAssertTrue(
            blocksContentEqual(parsed, expected),
            "Parsed \(parsed.map { "\($0.kind): \"\($0.text)\"" }) but expected \(expected.map { "\($0.kind): \"\($0.text)\"" })",
            file: file,
            line: line
        )
    }

    // MARK: - Ported from the original line-based parser

    func testParsesParagraph() {
        assertParses("Hello world", [EditorBlock(kind: .paragraph, text: "Hello world")])
    }

    func testParsesHeadingLevels() {
        assertParses("# Title", [EditorBlock(kind: .heading(level: 1), text: "Title")])
        assertParses("## Subtitle", [EditorBlock(kind: .heading(level: 2), text: "Subtitle")])
        assertParses("###### Deep", [EditorBlock(kind: .heading(level: 6), text: "Deep")])
    }

    func testHeadingRequiresSpaceAfterHashes() {
        assertParses("#NoSpace", [EditorBlock(kind: .paragraph, text: "#NoSpace")])
    }

    func testParsesBulletItemsWithDashOrAsterisk() {
        assertParses("- Item one", [EditorBlock(kind: .bulletItem, text: "Item one")])
        assertParses("* Item two", [EditorBlock(kind: .bulletItem, text: "Item two")])
    }

    func testParsesUncheckedChecklistItem() {
        assertParses("- [ ] Task", [EditorBlock(kind: .checklistItem(checked: false), text: "Task")])
    }

    func testParsesCheckedChecklistItemLowercaseAndUppercase() {
        assertParses("- [x] Done", [EditorBlock(kind: .checklistItem(checked: true), text: "Done")])
        assertParses("- [X] Done", [EditorBlock(kind: .checklistItem(checked: true), text: "Done")])
    }

    func testChecklistIsDistinguishedFromPlainBullet() {
        assertParses(
            "- [ ] Task\n- Not a checklist item",
            [
                EditorBlock(kind: .checklistItem(checked: false), text: "Task"),
                EditorBlock(kind: .bulletItem, text: "Not a checklist item"),
            ])
    }

    func testParsesQuote() {
        assertParses("> Quoted text", [EditorBlock(kind: .quote, text: "Quoted text")])
    }

    func testQuotePreservesLeadingWhitespaceBeyondTheMarkerSpace() {
        // ">     code" is indented code inside a blockquote — the marker eats
        // exactly one space; the rest is significant content.
        assertParses(">     let x = 1", [EditorBlock(kind: .quote, text: "    let x = 1")])
        XCTAssertTrue(
            blocksContentEqual(
                parseEditorBlocks(serializeMarkdown([EditorBlock(kind: .quote, text: "  indented")])),
                [EditorBlock(kind: .quote, text: "  indented")]
            ))
    }

    func testParsesMultipleBlocksInOrder() {
        let markdown = """
            # Heading

            A paragraph.

            - Bullet one
            - [ ] Checklist item
            > A quote
            """
        assertParses(
            markdown,
            [
                EditorBlock(kind: .heading(level: 1), text: "Heading"),
                EditorBlock(kind: .paragraph, text: "A paragraph."),
                EditorBlock(kind: .bulletItem, text: "Bullet one"),
                EditorBlock(kind: .checklistItem(checked: false), text: "Checklist item"),
                EditorBlock(kind: .quote, text: "A quote"),
            ])
    }

    func testEmptyLinesAreSkipped() {
        assertParses(
            "\n\nHello\n\n\nWorld\n",
            [
                EditorBlock(kind: .paragraph, text: "Hello"),
                EditorBlock(kind: .paragraph, text: "World"),
            ])
    }

    func testEmptyStringProducesNoBlocks() {
        assertParses("", [])
    }

    // MARK: - Ordered lists

    func testParsesNumberedItemsWithDotOrParenMarkers() {
        assertParses("1. First", [EditorBlock(kind: .numberedItem, text: "First")])
        assertParses("2) Second", [EditorBlock(kind: .numberedItem, text: "Second")])
        assertParses("42. Forty-second", [EditorBlock(kind: .numberedItem, text: "Forty-second")])
    }

    func testNumberedItemRequiresSpaceAfterMarker() {
        assertParses("1.First", [EditorBlock(kind: .paragraph, text: "1.First")])
    }

    // MARK: - Code fences

    func testParsesCodeFenceWithLanguage() {
        assertParses(
            "```swift\nlet answer = 42\n```",
            [
                EditorBlock(kind: .codeBlock(language: "swift"), text: "let answer = 42")
            ])
    }

    func testParsesCodeFenceWithoutLanguage() {
        assertParses(
            "```\nplain code\n```",
            [
                EditorBlock(kind: .codeBlock(language: ""), text: "plain code")
            ])
    }

    func testCodeFencePreservesBlankLinesAndIndentation() {
        assertParses(
            "```\nline one\n\n    indented\n```",
            [
                EditorBlock(kind: .codeBlock(language: ""), text: "line one\n\n    indented")
            ])
    }

    func testUnclosedCodeFenceKeepsRemainingContent() {
        assertParses(
            "```\nno closing fence\nstill code",
            [
                EditorBlock(kind: .codeBlock(language: ""), text: "no closing fence\nstill code")
            ])
    }

    func testLongerFenceContainsTripleBacktickContent() {
        assertParses(
            "````\n```\ninner fence\n```\n````",
            [
                EditorBlock(kind: .codeBlock(language: ""), text: "```\ninner fence\n```")
            ])
    }

    // MARK: - Dividers

    func testParsesDividers() {
        assertParses("---", [EditorBlock(kind: .divider)])
        assertParses("***", [EditorBlock(kind: .divider)])
        assertParses("___", [EditorBlock(kind: .divider)])
        assertParses("-----", [EditorBlock(kind: .divider)])
    }

    func testTwoDashesAreNotADivider() {
        assertParses("--", [EditorBlock(kind: .paragraph, text: "--")])
    }

    // MARK: - Unknown passthrough

    func testIndentedListLineIsPreservedVerbatimAsUnknown() {
        assertParses("  - nested item", [EditorBlock(kind: .unknown, text: "  - nested item")])
    }

    func testTableLinesGroupIntoOneUnknownBlock() {
        let table = "| Name | Role |\n| --- | --- |\n| Ana | Dev |"
        assertParses(table, [EditorBlock(kind: .unknown, text: table)])
    }

    func testImageLineBecomesUnknown() {
        assertParses(
            "![diagram](https://example.com/d.png)",
            [
                EditorBlock(kind: .unknown, text: "![diagram](https://example.com/d.png)")
            ])
    }

    func testHTMLLineBecomesUnknown() {
        assertParses("<div>widget</div>", [EditorBlock(kind: .unknown, text: "<div>widget</div>")])
    }

    func testMultiLineParagraphRunBecomesOneUnknownBlock() {
        assertParses("line one\nline two", [EditorBlock(kind: .unknown, text: "line one\nline two")])
    }

    func testUnknownRunEndsAtClassifiedLine() {
        assertParses(
            "  indented\n- bullet",
            [
                EditorBlock(kind: .unknown, text: "  indented"),
                EditorBlock(kind: .bulletItem, text: "bullet"),
            ])
    }

    func testNestedListUnderBulletIsPreserved() {
        assertParses(
            "- top\n  - nested\n  - nested two",
            [
                EditorBlock(kind: .bulletItem, text: "top"),
                EditorBlock(kind: .unknown, text: "  - nested\n  - nested two"),
            ])
    }

    func testCRLFLineEndingsParseLikeLF() {
        assertParses(
            "# Title\r\n\r\nBody text.",
            [
                EditorBlock(kind: .heading(level: 1), text: "Title"),
                EditorBlock(kind: .paragraph, text: "Body text."),
            ])
        // CRLF must not split a multi-line run apart with phantom blank lines.
        assertParses("line one\r\nline two", [EditorBlock(kind: .unknown, text: "line one\nline two")])
        XCTAssertTrue(markdownSurvivesRoundTrip("- item one\r\n- item two\r\n"))
    }

    // MARK: - Round-trip survival gate

    func testRealisticDocumentSurvivesRoundTrip() {
        let markdown = """
            # Project kickoff

            Welcome to the team documentation.

            - First item
            - Second item

            1. Step one
            2. Step two

            - [ ] Draft the spec
            - [x] Review the design

            > Remember to sync with the web team.

            ```swift
            let answer = 42
            ```

            | Name | Role |
            | --- | --- |
            | Ana | Dev |

            ![diagram](https://example.com/d.png)

            ---

            Done.
            """
        XCTAssertTrue(markdownSurvivesRoundTrip(markdown))
    }

    func testLoneOpeningFenceFailsRoundTripGate() {
        // An unclosed fence gains a closing fence line on serialize.
        XCTAssertFalse(markdownSurvivesRoundTrip("```"))
    }
}
