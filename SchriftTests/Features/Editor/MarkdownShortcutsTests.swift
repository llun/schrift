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

    // MARK: - A marker never eats a longer delimiter run

    /// The unwrap branch requires the delimiter run hugging the selection to be
    /// **exactly** the marker's length. Before that, a `*` applied to a selected
    /// bold word found a `*` on each side, unwrapped, and silently downgraded bold
    /// to italic — invisibly, since the block editor draws markdown syntax at zero
    /// width. It now wraps instead.
    ///
    /// The result `***word***` is not something this scanner parses as bold+italic
    /// (it reads bold(`*word`) + literal(`*`)), but nothing emits `*`: the Italic
    /// button emits `_`. The rule that matters is that no formatting is destroyed.
    func testASingleAsteriskAroundABoldWordWrapsRatherThanEatingTheBold() {
        let result = wrapInlineMarker(text: "**word**", range: NSRange(location: 2, length: 4), marker: "*")
        XCTAssertEqual(result.text, "***word***")
    }

    /// The same destruction was reachable from the shipping toolbar — Italic on a
    /// hand-typed `__word__` used to unwrap to `_word_`. It now wraps. The result
    /// is literal (a `_` run of three is not a delimiter), which loses no text.
    func testItalicOnAHandTypedStrongWordWrapsRatherThanEatingIt() {
        let result = wrapInlineMarker(text: "__word__", range: NSRange(location: 2, length: 4), marker: "_")
        XCTAssertEqual(result.text, "___word___")
        XCTAssertEqual(InlineMarkdown.parse(result.text), [InlineRun("___word___")])
    }

    /// Italic on a bold word nests, and — now that the scanner honors CommonMark's
    /// flanking rule — the italic actually survives the save.
    func testAnUnderscoreAroundABoldWordNestsAndBothMarksSurvive() {
        let result = wrapInlineMarker(text: "**word**", range: NSRange(location: 2, length: 4), marker: "_")
        XCTAssertEqual(result.text, "**_word_**")
        XCTAssertEqual(InlineMarkdown.parse(result.text).first?.marks.map(\.key), ["bold", "italic"])
    }

    /// Toggling italic back off unwraps the lone `_` run it added, leaving the bold.
    func testUnderscoreUnwrapsTheItalicItAddedAndLeavesTheBold() {
        let result = wrapInlineMarker(text: "**_word_**", range: NSRange(location: 3, length: 4), marker: "_")
        XCTAssertEqual(result.text, "**word**")
        XCTAssertEqual(InlineMarkdown.parse(result.text).first?.marks.map(\.key), ["bold"])
    }

    /// The exact-length rule must hold for the multi-character markers too, not
    /// just `*`/`_`. Bold (`**`) is a shipping toolbar button, so a selection
    /// already hugged by a longer `*` run — `***word***` — must wrap, not unwrap
    /// down to `*word*` and destroy the run.
    func testBoldMarkerOnATripleAsteriskRunWrapsRatherThanEatingIt() {
        let result = wrapInlineMarker(text: "***word***", range: NSRange(location: 3, length: 4), marker: "**")
        XCTAssertEqual(result.text, "*****word*****")
    }

    /// A `**` run of exactly the marker's length still unwraps — the guard tightens
    /// the unwrap branch, it does not disable it.
    func testBoldMarkerOnAnExactDoubleAsteriskRunStillUnwraps() {
        let result = wrapInlineMarker(text: "**word**", range: NSRange(location: 2, length: 4), marker: "**")
        XCTAssertEqual(result.text, "word")
    }

    /// The rule is marker-agnostic: a single backtick hugged by a double-backtick
    /// run wraps rather than unwrapping and eating the extra backticks.
    func testCodeMarkerOnADoubleBacktickRunWrapsRatherThanEatingIt() {
        let result = wrapInlineMarker(text: "``code``", range: NSRange(location: 2, length: 4), marker: "`")
        XCTAssertEqual(result.text, "```code```")
    }
}
