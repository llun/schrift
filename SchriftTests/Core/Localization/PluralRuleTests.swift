import XCTest

@testable import Schrift

final class PluralRuleTests: XCTestCase {
    func testEnglishOneVsOther() {
        XCTAssertEqual(pluralCategory(1, language: .english), .one)
        XCTAssertEqual(pluralCategory(2, language: .english), .other)
        XCTAssertEqual(pluralCategory(0, language: .english), .other)
    }
    func testChineseAndThaiAreOtherOnly() {
        XCTAssertEqual(pluralCategory(1, language: .chineseSimplified), .other)
        XCTAssertEqual(pluralCategory(1, language: .chineseTraditional), .other)
        XCTAssertEqual(pluralCategory(1, language: .thai), .other)
    }
    func testSloveneUsesFullCLDRSet() {
        // CLDR `sl`: one = i%100==1, two = i%100==2, few = i%100==3..4, else other.
        XCTAssertEqual(pluralCategory(1, language: .slovene), .one)
        XCTAssertEqual(pluralCategory(101, language: .slovene), .one)
        XCTAssertEqual(pluralCategory(2, language: .slovene), .two)
        XCTAssertEqual(pluralCategory(102, language: .slovene), .two)
        XCTAssertEqual(pluralCategory(3, language: .slovene), .few)
        XCTAssertEqual(pluralCategory(4, language: .slovene), .few)
        XCTAssertEqual(pluralCategory(104, language: .slovene), .few)
        XCTAssertEqual(pluralCategory(5, language: .slovene), .other)
        XCTAssertEqual(pluralCategory(0, language: .slovene), .other)
        XCTAssertEqual(pluralCategory(11, language: .slovene), .other)
        XCTAssertEqual(pluralCategory(100, language: .slovene), .other)
    }
}
