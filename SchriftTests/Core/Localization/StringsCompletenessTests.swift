import Foundation
import XCTest

@testable import Schrift

final class StringsCompletenessTests: XCTestCase {
    /// Count of `%@` / `%d` / `%lld` placeholders (ignoring escaped `%%`).
    private func placeholderCount(_ s: String) -> Int {
        var count = 0
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "%" {
                let next = s.index(after: i)
                guard next < s.endIndex else { break }
                if s[next] == "%" {
                    i = s.index(after: next)
                    continue
                }  // escaped %%
                count += 1
            }
            i = s.index(after: i)
        }
        return count
    }

    func testEveryLanguageHasEveryKey() {
        for language in AppLanguage.allCases {
            let table = Strings.table(for: language)
            for key in L10nKey.allCases {
                XCTAssertNotNil(table[key], "\(language.code) missing \(key.rawValue)")
                XCTAssertFalse((table[key] ?? "").isEmpty, "\(language.code) empty \(key.rawValue)")
            }
        }
    }

    func testFormatSpecifierParityWithEnglish() {
        // Same placeholder count per key across languages, so String(format:)
        // can't crash on a mismatched arg list.
        let en = Strings_en.table
        for language in AppLanguage.allCases where language != .english {
            let table = Strings.table(for: language)
            for key in L10nKey.allCases {
                XCTAssertEqual(
                    placeholderCount(table[key] ?? ""), placeholderCount(en[key] ?? ""),
                    "\(language.code) placeholder mismatch on \(key.rawValue)")
            }
        }
    }
}
