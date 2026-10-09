import Foundation
import XCTest

@testable import Schrift

final class AppLanguageTests: XCTestCase {
    func testCodesAndAutonymsAreUniqueAndEveryCodeRoundTripsThroughBestMatch() {
        let codes = AppLanguage.allCases.map(\.code)
        let autonyms = AppLanguage.allCases.map(\.autonym)
        XCTAssertEqual(Set(codes).count, codes.count)
        XCTAssertEqual(Set(autonyms).count, autonyms.count)
        XCTAssertFalse(codes.contains(""))
        XCTAssertFalse(autonyms.contains(""))
        for language in AppLanguage.allCases {
            XCTAssertEqual(AppLanguage.bestMatch(preferred: [language.code]), language, language.code)
        }
    }

    func testBestMatchPrefersExactThenScriptThenEnglish() {
        XCTAssertEqual(AppLanguage.bestMatch(preferred: ["fr-FR", "en"]), .french)
        XCTAssertEqual(AppLanguage.bestMatch(preferred: ["sl-SI", "en"]), .slovene)
        XCTAssertEqual(AppLanguage.bestMatch(preferred: ["zh-Hant-TW"]), .chineseTraditional)
        XCTAssertEqual(AppLanguage.bestMatch(preferred: ["zh-Hans-CN"]), .chineseSimplified)
        XCTAssertEqual(AppLanguage.bestMatch(preferred: ["ja"]), .english)
        XCTAssertEqual(AppLanguage.bestMatch(preferred: []), .english)
    }
}
