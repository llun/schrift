import XCTest

@testable import Schrift

final class SubpageRowTests: XCTestCase {
    func testLabelOrdersTitleThenPendingDeleteThenSummaryThenChildCount() {
        let label = subpageRowAccessibilityLabel(
            title: "Meeting notes", summary: "Highlights", childCount: 3, pendingDelete: true,
            pendingDeleteLabel: "Will be deleted")
        XCTAssertEqual(label, "Meeting notes, Will be deleted, Highlights, 3")
    }

    func testTitleAloneIsTheWholeLabelWhenNothingElseApplies() {
        XCTAssertEqual(subpageRowAccessibilityLabel(title: "Plan", summary: nil, childCount: 0), "Plan")
    }

    func testEmptySummaryAndZeroChildrenAreOmitted() {
        XCTAssertEqual(subpageRowAccessibilityLabel(title: "Plan", summary: "", childCount: 0), "Plan")
    }

    func testPendingDeleteWithoutALocalizedPhraseAddsNothing() {
        XCTAssertEqual(
            subpageRowAccessibilityLabel(title: "Plan", summary: nil, childCount: 0, pendingDelete: true),
            "Plan")
    }

    func testPendingDeletePhraseIsIgnoredWhenTheRowIsNotPendingDelete() {
        XCTAssertEqual(
            subpageRowAccessibilityLabel(
                title: "Plan", summary: nil, childCount: 0, pendingDelete: false,
                pendingDeleteLabel: "Will be deleted"),
            "Plan")
    }

    func testChildCountAppearsAfterTheSummary() {
        XCTAssertEqual(subpageRowAccessibilityLabel(title: "Plan", summary: "Q3", childCount: 2), "Plan, Q3, 2")
        XCTAssertEqual(subpageRowAccessibilityLabel(title: "Plan", summary: nil, childCount: 2), "Plan, 2")
    }
}
