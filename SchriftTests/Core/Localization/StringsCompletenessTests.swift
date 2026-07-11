import Foundation
import XCTest

@testable import Schrift

final class StringsCompletenessTests: XCTestCase {
    /// Dual/few plural forms that only Slovene resolves (see PluralRule). Every
    /// other language never reaches these keys, so its table legitimately omits
    /// them; `plural(_:one:other:two:few:)` falls back to `other`.
    private static let extendedPluralKeys: Set<L10nKey> = [
        .search_results_two, .search_results_few,
        .shared_count_two, .shared_count_few,
        .share_members_two, .share_members_few,
    ]

    /// The English `other` form each extended key is a plural sibling of — used
    /// to check placeholder parity, since English has no dual/few counterpart.
    private static let extendedPluralOtherSibling: [L10nKey: L10nKey] = [
        .search_results_two: .search_results_other, .search_results_few: .search_results_other,
        .shared_count_two: .shared_count_other, .shared_count_few: .shared_count_other,
        .share_members_two: .share_members_other, .share_members_few: .share_members_other,
    ]

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

    func testEveryLanguageHasEveryBaseKey() {
        // Every language defines every non-extended key (extended dual/few forms
        // are Slovene-only; see `testSloveneDefinesExtendedPluralForms`).
        for language in AppLanguage.allCases {
            let table = Strings.table(for: language)
            for key in L10nKey.allCases where !Self.extendedPluralKeys.contains(key) {
                XCTAssertNotNil(table[key], "\(language.code) missing \(key.rawValue)")
                XCTAssertFalse((table[key] ?? "").isEmpty, "\(language.code) empty \(key.rawValue)")
            }
        }
    }

    func testSloveneDefinesExtendedPluralForms() {
        // Slovene is the one language whose plural rules produce two/few, so it
        // must define those forms; ship them or dual/few silently fall back to other.
        let table = Strings.table(for: .slovene)
        for key in Self.extendedPluralKeys {
            XCTAssertNotNil(table[key], "sl missing \(key.rawValue)")
            XCTAssertFalse((table[key] ?? "").isEmpty, "sl empty \(key.rawValue)")
        }
    }

    func testNonSloveneTablesOmitExtendedPluralForms() {
        // Guards the invariant the completeness split relies on: only Slovene
        // carries dual/few forms, so no other language can resolve one.
        for language in AppLanguage.allCases where language != .slovene {
            let table = Strings.table(for: language)
            for key in Self.extendedPluralKeys {
                XCTAssertNil(table[key], "\(language.code) unexpectedly defines \(key.rawValue)")
            }
        }
    }

    func testFormatSpecifierParityWithEnglish() {
        // Same placeholder count per key across languages, so String(format:)
        // can't crash on a mismatched arg list.
        let en = Strings_en.table
        for language in AppLanguage.allCases where language != .english {
            let table = Strings.table(for: language)
            for key in L10nKey.allCases where !Self.extendedPluralKeys.contains(key) {
                XCTAssertEqual(
                    placeholderCount(table[key] ?? ""), placeholderCount(en[key] ?? ""),
                    "\(language.code) placeholder mismatch on \(key.rawValue)")
            }
        }
    }

    func testSloveneExtendedPluralPlaceholderParity() {
        // Extended forms carry the same placeholders as their English `other`
        // sibling (English has no dual/few form of its own to compare against).
        let en = Strings_en.table
        let sl = Strings.table(for: .slovene)
        for (key, sibling) in Self.extendedPluralOtherSibling {
            XCTAssertEqual(
                placeholderCount(sl[key] ?? ""), placeholderCount(en[sibling] ?? ""),
                "sl placeholder mismatch on \(key.rawValue)")
        }
    }
}
