import XCTest

@testable import Schrift

final class MarkdownShortcutsTests: XCTestCase {
    // MARK: - Typing shortcuts

    func testHeadingShortcuts() {
        XCTAssertEqual(
            detectMarkdownShortcut(text: "# "), BlockShortcutMatch(kind: .heading(level: 1), remainderText: ""))
        XCTAssertEqual(
            detectMarkdownShortcut(text: "## Hello"),
            BlockShortcutMatch(kind: .heading(level: 2), remainderText: "Hello"))
        XCTAssertEqual(
            detectMarkdownShortcut(text: "###### deep"),
            BlockShortcutMatch(kind: .heading(level: 6), remainderText: "deep"))
    }

    func testHeadingShortcutRequiresSpace() {
        XCTAssertNil(detectMarkdownShortcut(text: "#Hello"))
        XCTAssertNil(detectMarkdownShortcut(text: "#"))
    }

    func testBulletShortcuts() {
        XCTAssertEqual(detectMarkdownShortcut(text: "- "), BlockShortcutMatch(kind: .bulletItem, remainderText: ""))
        XCTAssertEqual(
            detectMarkdownShortcut(text: "* item"), BlockShortcutMatch(kind: .bulletItem, remainderText: "item"))
    }

    func testChecklistShortcuts() {
        XCTAssertEqual(
            detectMarkdownShortcut(text: "[] task"),
            BlockShortcutMatch(kind: .checklistItem(checked: false), remainderText: "task"))
        XCTAssertEqual(
            detectMarkdownShortcut(text: "[ ] task"),
            BlockShortcutMatch(kind: .checklistItem(checked: false), remainderText: "task"))
        XCTAssertEqual(
            detectMarkdownShortcut(text: "[x] done"),
            BlockShortcutMatch(kind: .checklistItem(checked: true), remainderText: "done"))
    }

    func testNumberedShortcuts() {
        XCTAssertEqual(detectMarkdownShortcut(text: "1. "), BlockShortcutMatch(kind: .numberedItem, remainderText: ""))
        XCTAssertEqual(
            detectMarkdownShortcut(text: "12) go"), BlockShortcutMatch(kind: .numberedItem, remainderText: "go"))
        XCTAssertNil(detectMarkdownShortcut(text: "1.missing space"))
    }

    func testQuoteShortcut() {
        XCTAssertEqual(
            detectMarkdownShortcut(text: "> quoted"), BlockShortcutMatch(kind: .quote, remainderText: "quoted"))
    }

    func testShortcutMustBeAtStart() {
        XCTAssertNil(detectMarkdownShortcut(text: "text # heading"))
        XCTAssertNil(detectMarkdownShortcut(text: " - indented"))
    }

    // MARK: - Enter shortcuts

    func testEnterShortcutForCodeFence() {
        XCTAssertEqual(
            detectEnterShortcut(text: "```"), BlockShortcutMatch(kind: .codeBlock(language: ""), remainderText: ""))
        XCTAssertEqual(
            detectEnterShortcut(text: "```swift"),
            BlockShortcutMatch(kind: .codeBlock(language: "swift"), remainderText: ""))
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

    // MARK: - Why the Italic button still emits `_`

    /// `wrapInlineMarker` decides wrap-vs-unwrap from the **single character** on
    /// each side of the selection. A `*` applied to a selected bold word finds a
    /// `*` on both sides and takes the unwrap branch, silently downgrading bold to
    /// italic — and the block editor now draws those asterisks at zero width, so
    /// nothing warns the user.
    ///
    /// This is why the Italic button emits `_` (which the save parser then drops)
    /// rather than the `*` it reads. Whoever fixes that must fix this first: the
    /// unwrap branch needs to require a delimiter run of exactly the marker's
    /// length, and `***x***` — what wrapping bold in `*` produces — must parse as
    /// bold+italic rather than bold(`*x`) + literal(`*`).
    func testASingleAsteriskAroundABoldWordUnwrapsTheBold() {
        let result = wrapInlineMarker(text: "**word**", range: NSRange(location: 2, length: 4), marker: "*")
        XCTAssertEqual(result.text, "*word*", "the bold is destroyed — see the doc comment")
    }

    func testAnUnderscoreAroundABoldWordNestsInsteadOfUnwrapping() {
        let result = wrapInlineMarker(text: "**word**", range: NSRange(location: 2, length: 4), marker: "_")
        XCTAssertEqual(result.text, "**_word_**")
        XCTAssertEqual(InlineMarkdown.parse(result.text).first?.marks.map(\.key), ["bold"])
    }
}
