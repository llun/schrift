import Foundation
import XCTest

@testable import Schrift

final class AppLanguageTests: XCTestCase {
    func testCodesAndAutonyms() {
        XCTAssertEqual(AppLanguage.thai.code, "th")
        XCTAssertEqual(AppLanguage.thai.autonym, "ไทย")
        XCTAssertEqual(AppLanguage.chineseSimplified.code, "zh-Hans")
        XCTAssertEqual(AppLanguage.chineseTraditional.code, "zh-Hant")
        XCTAssertEqual(AppLanguage.allCases.count, 10)
    }
    func testBestMatchPrefersExactThenScriptThenEnglish() {
        XCTAssertEqual(AppLanguage.bestMatch(preferred: ["fr-FR", "en"]), .french)
        XCTAssertEqual(AppLanguage.bestMatch(preferred: ["zh-Hant-TW"]), .chineseTraditional)
        XCTAssertEqual(AppLanguage.bestMatch(preferred: ["zh-Hans-CN"]), .chineseSimplified)
        XCTAssertEqual(AppLanguage.bestMatch(preferred: ["ja"]), .english)
        XCTAssertEqual(AppLanguage.bestMatch(preferred: []), .english)
    }
}
