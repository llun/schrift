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
}
