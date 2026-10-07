import XCTest

@testable import Schrift

final class FormattingBarFormatTests: XCTestCase {
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
        XCTAssertEqual(blockKindAfterChoosing(ListFormat.numbered, current: .paragraph), .numberedItem)
        XCTAssertEqual(
            blockKindAfterChoosing(ListFormat.checklist, current: .bulletItem), .checklistItem(checked: false))
        XCTAssertNil(blockKindAfterChoosing(ListFormat.bulleted, current: .bulletItem))
        XCTAssertNil(blockKindAfterChoosing(ListFormat.checklist, current: .checklistItem(checked: true)))
    }

    func testTappingTogglesOnTheListKindNotTheExactState() {
        XCTAssertEqual(blockKindAfterTapping(ListFormat.checklist, current: .paragraph), .checklistItem(checked: false))
        XCTAssertEqual(blockKindAfterTapping(ListFormat.checklist, current: .checklistItem(checked: true)), .paragraph)
        XCTAssertEqual(blockKindAfterTapping(ListFormat.checklist, current: .checklistItem(checked: false)), .paragraph)
        XCTAssertEqual(blockKindAfterTapping(ListFormat.bulleted, current: .bulletItem), .paragraph)
        XCTAssertEqual(blockKindAfterTapping(ListFormat.numbered, current: .bulletItem), .numberedItem)
        XCTAssertEqual(blockKindAfterTapping(ListFormat.bulleted, current: .quote), .bulletItem)
    }

    // MARK: - Quote format

    func testQuoteFormatsMapToTheirKindsAndACodeBlockMatchesAnyLanguage() {
        XCTAssertEqual(QuoteFormat.quote.blockKind, .quote)
        XCTAssertEqual(QuoteFormat.code.blockKind, .codeBlock(language: ""))
        XCTAssertEqual(QuoteFormat(blockKind: .codeBlock(language: "swift")), .code)
        XCTAssertNil(QuoteFormat(blockKind: .bulletItem))
        XCTAssertNil(QuoteFormat(blockKind: .paragraph))
        XCTAssertNil(QuoteFormat(blockKind: .heading(level: 1)))
        XCTAssertNil(QuoteFormat(blockKind: .checklistItem(checked: false)))
        XCTAssertEqual(QuoteFormat.stored("nope"), .quote)
        XCTAssertNotEqual(QuoteFormat.preferenceKey, ListFormat.preferenceKey)
    }

    func testQuoteTapTogglesAndPickKeepsTheCodeLanguage() {
        XCTAssertEqual(blockKindAfterTapping(QuoteFormat.code, current: .codeBlock(language: "swift")), .paragraph)
        XCTAssertEqual(blockKindAfterTapping(QuoteFormat.code, current: .quote), .codeBlock(language: ""))
        XCTAssertNil(blockKindAfterChoosing(QuoteFormat.code, current: .codeBlock(language: "swift")))
        XCTAssertEqual(blockKindAfterChoosing(QuoteFormat.quote, current: .codeBlock(language: "swift")), .quote)
    }
}
