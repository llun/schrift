import XCTest

@testable import Schrift

final class ListFormatTests: XCTestCase {
    func testEachFormatMapsToItsBlockKindAndBack() {
        XCTAssertEqual(ListFormat.bulleted.blockKind, .bulletItem)
        XCTAssertEqual(ListFormat.numbered.blockKind, .numberedItem)
        XCTAssertEqual(ListFormat.checklist.blockKind, .checklistItem(checked: false))
        for format in ListFormat.allCases {
            XCTAssertEqual(ListFormat(blockKind: format.blockKind), format)
        }
    }

    func testACheckedChecklistItemIsStillAChecklist() {
        XCTAssertEqual(ListFormat(blockKind: .checklistItem(checked: true)), .checklist)
    }

    func testNonListKindsHaveNoListFormat() {
        for kind: BlockKind in [.paragraph, .heading(level: 1), .quote, .codeBlock(language: ""), .divider, .unknown] {
            XCTAssertNil(ListFormat(blockKind: kind))
        }
    }

    func testAMissingOrUnknownStoredDefaultFallsBackToBulleted() {
        XCTAssertEqual(ListFormat.stored(""), .bulleted)
        XCTAssertEqual(ListFormat.stored("roman"), .bulleted)
        XCTAssertEqual(ListFormat.stored("checklist"), .checklist)
        XCTAssertTrue(ListFormat.preferenceKey.hasPrefix("schrift."))
    }

    func testChoosingConvertsOtherKindsAndLeavesTheSameFormatAlone() {
        XCTAssertEqual(blockKindAfterChoosing(.numbered, current: .paragraph), .numberedItem)
        XCTAssertEqual(blockKindAfterChoosing(.checklist, current: .bulletItem), .checklistItem(checked: false))
        XCTAssertNil(blockKindAfterChoosing(.bulleted, current: .bulletItem))
        XCTAssertNil(blockKindAfterChoosing(.checklist, current: .checklistItem(checked: true)))
    }
}
