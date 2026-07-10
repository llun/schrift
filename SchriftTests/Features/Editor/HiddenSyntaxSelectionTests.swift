import XCTest

@testable import Schrift

final class HiddenSyntaxSelectionTests: XCTestCase {

    /// "see [docs](https://x.dev/) now" — hidden runs are `[` at 4 and
    /// `](https://x.dev/)` at 9..<26.
    private let source = "see [docs](https://x.dev/) now"
    private var hidden: [NSRange] { InlineMarkdown.layout(of: source).syntax }

    func testFixtureHasTheHiddenRunsTheOtherTestsAssume() {
        XCTAssertEqual(hidden, [NSRange(location: 4, length: 1), NSRange(location: 9, length: 17)])
    }

    // MARK: - Caret snapping

    func testCaretOutsideAnyHiddenRunIsUntouched() {
        for offset in [0, 4, 5, 9, 26, 29] {
            let snapped = snappedSelection(NSRange(location: offset, length: 0), hidden: hidden)
            XCTAssertEqual(snapped, NSRange(location: offset, length: 0), "at \(offset)")
        }
    }

    func testCaretJustInsideAHiddenRunSnapsBackToItsStart() {
        // Offset 10 is one past `]` — nearer the label's end than the link's.
        let snapped = snappedSelection(NSRange(location: 10, length: 0), hidden: hidden)
        XCTAssertEqual(snapped, NSRange(location: 9, length: 0))
    }

    func testCaretNearTheEndOfAHiddenRunSnapsForwardPastIt() {
        let snapped = snappedSelection(NSRange(location: 25, length: 0), hidden: hidden)
        XCTAssertEqual(snapped, NSRange(location: 26, length: 0))
    }

    /// The hidden run 9..<26 has midpoint 17.5; offsets 17 and 18 straddle it.
    func testAnExactTieSnapsForward() {
        // Equidistant from both ends of a run of even length: 9..<25 would tie at 17.
        let evenRun = [NSRange(location: 9, length: 16)]
        let snapped = snappedSelection(NSRange(location: 17, length: 0), hidden: evenRun)
        XCTAssertEqual(snapped, NSRange(location: 25, length: 0))
    }

    func testNoHiddenRunsLeavesTheSelectionAlone() {
        let selection = NSRange(location: 3, length: 4)
        XCTAssertEqual(snappedSelection(selection, hidden: []), selection)
    }

    // MARK: - Selection expansion

    func testASelectionEndingInsideALinksLabelIsUntouched() {
        // "see [do" — the end lands inside the label, which is visible.
        XCTAssertEqual(
            snappedSelection(NSRange(location: 0, length: 7), hidden: hidden),
            NSRange(location: 0, length: 7))
    }

    func testASelectionThatWouldBisectAHiddenRunExpandsOutward() {
        // Start inside `](https://…`, end in " now".
        let snapped = snappedSelection(NSRange(location: 15, length: 12), hidden: hidden)
        XCTAssertEqual(snapped, NSRange(location: 9, length: 18))
    }

    func testASelectionEndingMidURLExpandsToCoverTheWholeLink() {
        let snapped = snappedSelection(NSRange(location: 0, length: 15), hidden: hidden)
        XCTAssertEqual(snapped, NSRange(location: 0, length: 26))
        XCTAssertEqual((source as NSString).substring(with: snapped), "see [docs](https://x.dev/)")
    }

    // MARK: - Backspace

    func testBackspaceBehindVisibleTextIsUntouched() {
        XCTAssertEqual(caretBeforeBackspace(from: 3, hidden: hidden), 3)
        // Caret at the label's end: the character behind it is the visible "s".
        XCTAssertEqual(caretBeforeBackspace(from: 9, hidden: hidden), 9)
    }

    func testBackspaceAfterALinkDeletesTheLabelsLastLetterNotTheClosingParen() {
        // Caret at 26, just past `)`. Skipping the hidden run puts it at 9, so the
        // delete that follows removes the "s" of "docs".
        XCTAssertEqual(caretBeforeBackspace(from: 26, hidden: hidden), 9)
    }

    func testBackspaceAtTheStartOfALabelSkipsTheHiddenOpeningBracket() {
        // Caret at 5 (start of the label); behind it is the hidden `[` at 4, so
        // the delete that follows removes the space before the link.
        XCTAssertEqual(caretBeforeBackspace(from: 5, hidden: hidden), 4)
    }

    func testBackspaceAtOffsetZeroIsUntouched() {
        XCTAssertEqual(caretBeforeBackspace(from: 0, hidden: hidden), 0)
    }

    /// A link at the very start of a block: skipping its leading `[` lands on 0,
    /// which is what makes backspace there merge with the previous block.
    func testBackspaceThroughALeadingHiddenRunReachesZero() {
        let leading = InlineMarkdown.layout(of: "[a](b) tail").syntax
        XCTAssertEqual(caretBeforeBackspace(from: 1, hidden: leading), 0)
    }

    /// `caretBeforeBackspace` must not depend on the hidden runs being maximal,
    /// even though `InlineMarkdown` always produces them that way.
    func testBackspaceSkipsAChainOfAdjacentHiddenRuns() {
        let adjacent = [NSRange(location: 2, length: 2), NSRange(location: 4, length: 2)]
        XCTAssertEqual(caretBeforeBackspace(from: 6, hidden: adjacent), 2)
    }

    /// The whole point of the design: hiding characters never removes them.
    func testHiddenRunsAndVisibleSpansStillCoverTheEntireSource() {
        let layout = InlineMarkdown.layout(of: source)
        let covered = (layout.spans.map(\.range) + layout.syntax).reduce(0) { $0 + $1.length }
        XCTAssertEqual(covered, (source as NSString).length)
    }
}
