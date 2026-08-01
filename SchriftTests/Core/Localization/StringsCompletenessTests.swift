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
        .editor_presence_count_two, .editor_presence_count_few,
    ]

    /// The English `other` form each extended key is a plural sibling of — used
    /// to check placeholder parity, since English has no dual/few counterpart.
    private static let extendedPluralOtherSibling: [L10nKey: L10nKey] = [
        .search_results_two: .search_results_other, .search_results_few: .search_results_other,
        .shared_count_two: .shared_count_other, .shared_count_few: .shared_count_other,
        .share_members_two: .share_members_other, .share_members_few: .share_members_other,
        .editor_presence_count_two: .editor_presence_count_other,
        .editor_presence_count_few: .editor_presence_count_other,
    ]

    /// The argument list a string implies — which position takes an object, an
    /// integer, a double. See `formatSpecifiers(in:)`.
    ///
    /// This used to be a *count* of `%` occurrences with the conversion
    /// character thrown away, which made the gate blind to the one mismatch that
    /// actually crashes: a table writing `%d` where English has `%@` passed,
    /// and `String(format:)` then dereferenced an integer as an object pointer.
    /// Counting also cannot tell a reordered positional translation (correct)
    /// from a reordered plain one (not).
    private func argumentList(_ s: String) -> [Int: FormatArgumentKind] {
        formatArgumentList(of: s)
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
        // Same arguments per key across languages — same positions, same kinds —
        // so String(format:) can't be handed an arg list the string won't take.
        let en = Strings_en.table
        for language in AppLanguage.allCases where language != .english {
            let table = Strings.table(for: language)
            for key in L10nKey.allCases where !Self.extendedPluralKeys.contains(key) {
                XCTAssertEqual(
                    argumentList(table[key] ?? ""), argumentList(en[key] ?? ""),
                    "\(language.code) format-argument mismatch on \(key.rawValue)")
            }
        }
    }

    func testNoStringUsesOnePositionWithTwoArgumentKinds() {
        // Independent of the English comparison, and that is the point: a
        // self-contradictory string (`"%1$d … %1$@"`) renders garbage whatever
        // it is compared against, and if the contradiction were in *English*
        // every parity test would happily agree with it.
        for language in AppLanguage.allCases {
            let table = Strings.table(for: language)
            for key in L10nKey.allCases {
                guard let string = table[key] else { continue }
                for (position, kind) in argumentList(string) {
                    XCTAssertNotEqual(
                        kind, .conflicted,
                        "\(language.code) uses argument \(position) with two kinds in \(key.rawValue): \(string)")
                }
            }
        }
    }

    func testSloveneExtendedPluralPlaceholderParity() {
        // Extended forms take the same arguments as their English `other`
        // sibling (English has no dual/few form of its own to compare against).
        let en = Strings_en.table
        let sl = Strings.table(for: .slovene)
        for (key, sibling) in Self.extendedPluralOtherSibling {
            XCTAssertEqual(
                argumentList(sl[key] ?? ""), argumentList(en[sibling] ?? ""),
                "sl format-argument mismatch on \(key.rawValue)")
        }
    }
}
