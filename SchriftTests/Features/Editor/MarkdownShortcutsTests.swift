import XCTest
@testable import Schrift

final class MarkdownShortcutsTests: XCTestCase {
    // MARK: - Typing shortcuts

    func testHeadingShortcuts() {
        XCTAssertEqual(detectMarkdownShortcut(text: "# "), BlockShortcutMatch(kind: .heading(level: 1), remainderText: ""))
        XCTAssertEqual(detectMarkdownShortcut(text: "## Hello"), BlockShortcutMatch(kind: .heading(level: 2), remainderText: "Hello"))
        XCTAssertEqual(detectMarkdownShortcut(text: "###### deep"), BlockShortcutMatch(kind: .heading(level: 6), remainderText: "deep"))
    }

    func testHeadingShortcutRequiresSpace() {
        XCTAssertNil(detectMarkdownShortcut(text: "#Hello"))
        XCTAssertNil(detectMarkdownShortcut(text: "#"))
    }

    func testBulletShortcuts() {
        XCTAssertEqual(detectMarkdownShortcut(text: "- "), BlockShortcutMatch(kind: .bulletItem, remainderText: ""))
        XCTAssertEqual(detectMarkdownShortcut(text: "* item"), BlockShortcutMatch(kind: .bulletItem, remainderText: "item"))
    }

    func testChecklistShortcuts() {
        XCTAssertEqual(detectMarkdownShortcut(text: "[] task"), BlockShortcutMatch(kind: .checklistItem(checked: false), remainderText: "task"))
        XCTAssertEqual(detectMarkdownShortcut(text: "[ ] task"), BlockShortcutMatch(kind: .checklistItem(checked: false), remainderText: "task"))
        XCTAssertEqual(detectMarkdownShortcut(text: "[x] done"), BlockShortcutMatch(kind: .checklistItem(checked: true), remainderText: "done"))
    }

    func testNumberedShortcuts() {
        XCTAssertEqual(detectMarkdownShortcut(text: "1. "), BlockShortcutMatch(kind: .numberedItem, remainderText: ""))
        XCTAssertEqual(detectMarkdownShortcut(text: "12) go"), BlockShortcutMatch(kind: .numberedItem, remainderText: "go"))
        XCTAssertNil(detectMarkdownShortcut(text: "1.missing space"))
    }

    func testQuoteShortcut() {
        XCTAssertEqual(detectMarkdownShortcut(text: "> quoted"), BlockShortcutMatch(kind: .quote, remainderText: "quoted"))
    }

    func testShortcutMustBeAtStart() {
        XCTAssertNil(detectMarkdownShortcut(text: "text # heading"))
        XCTAssertNil(detectMarkdownShortcut(text: " - indented"))
    }

    // MARK: - Enter shortcuts

    func testEnterShortcutForCodeFence() {
        XCTAssertEqual(detectEnterShortcut(text: "```"), BlockShortcutMatch(kind: .codeBlock(language: ""), remainderText: ""))
        XCTAssertEqual(detectEnterShortcut(text: "```swift"), BlockShortcutMatch(kind: .codeBlock(language: "swift"), remainderText: ""))
    }

    func testEnterShortcutForDivider() {
        XCTAssertEqual(detectEnterShortcut(text: "---"), BlockShortcutMatch(kind: .divider, remainderText: ""))
        XCTAssertEqual(detectEnterShortcut(text: "***"), BlockShortcutMatch(kind: .divider, remainderText: ""))
    }

    func testEnterShortcutIgnoresOrdinaryText() {
        XCTAssertNil(detectEnterShortcut(text: "hello"))
        XCTAssertNil(detectEnterShortcut(text: "--"))
        XCTAssertNil(detectEnterShortcut(text: "``` with ` backtick"))
    }

    // MARK: - Inline marker wrapping

    func testWrapSelectionInMarker() {
        let result = wrapInlineMarker(text: "Hello world", range: NSRange(location: 0, length: 5), marker: "**")
        XCTAssertEqual(result.text, "**Hello** world")
        XCTAssertEqual(result.selection, NSRange(location: 2, length: 5))
    }

    func testUnwrapAlreadyWrappedSelection() {
        let result = wrapInlineMarker(text: "**Hello** world", range: NSRange(location: 2, length: 5), marker: "**")
        XCTAssertEqual(result.text, "Hello world")
        XCTAssertEqual(result.selection, NSRange(location: 0, length: 5))
    }

    func testCollapsedSelectionInsertsMarkerPair() {
        let result = wrapInlineMarker(text: "Hello", range: NSRange(location: 5, length: 0), marker: "`")
        XCTAssertEqual(result.text, "Hello``")
        XCTAssertEqual(result.selection, NSRange(location: 6, length: 0))
    }

    func testWrapClampsOutOfBoundsRange() {
        let result = wrapInlineMarker(text: "Hi", range: NSRange(location: 10, length: 5), marker: "_")
        XCTAssertEqual(result.text, "Hi__")
        XCTAssertEqual(result.selection, NSRange(location: 3, length: 0))
    }
}
