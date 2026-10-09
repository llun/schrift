import Foundation
import XCTest

@testable import Schrift

@MainActor
final class LocalizationStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "LocalizationStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testResolvesCurrentLanguage() {
        let store = LocalizationStore(userDefaults: defaults)
        store.language = .french
        // French is wired as of B12. Pinned literal (not a re-derived dispatcher call)
        // so this stays a real content check.
        XCTAssertEqual(store[.common_close], "Fermer")
        XCTAssertEqual(store.locale.identifier, "fr")
    }
    /// A key a language table omits resolves to English; one absent from English too resolves to its raw
    /// key, so a missing translation never renders as an empty string.
    func testAMissingKeyFallsBackToEnglishThenToItsRawKey() throws {
        let store = LocalizationStore(userDefaults: defaults)
        store.language = .thai
        try XCTSkipIf(Strings.table(for: .thai)[.theme_white] != nil, "theme copy is now translated")
        XCTAssertEqual(store[.theme_white], Strings_en.table[.theme_white])
        XCTAssertNotEqual(store[.theme_white], L10nKey.theme_white.rawValue)

        XCTAssertNil(Strings_en.table[.search_results_two])
        XCTAssertEqual(store[.search_results_two], L10nKey.search_results_two.rawValue)
    }
    func testFormatSubstitutesArgs() {
        let store = LocalizationStore(userDefaults: defaults)
        store.language = .english
        XCTAssertEqual(store.format(.search_results_other, 3), "3 results")
    }
    func testSlovenePluralSelectsDualAndFewForms() {
        let store = LocalizationStore(userDefaults: defaults)
        store.language = .slovene
        func results(_ n: Int) -> String {
            store.plural(
                n, one: .search_results_one, other: .search_results_other,
                two: .search_results_two, few: .search_results_few)
        }
        XCTAssertEqual(results(1), "1 rezultat")  // one
        XCTAssertEqual(results(2), "2 rezultata")  // two (dual)
        XCTAssertEqual(results(3), "3 rezultati")  // few
        XCTAssertEqual(results(5), "5 rezultatov")  // other
    }
    func testPluralFallsBackToOtherWhenDualFewOmitted() {
        // A caller that passes only one/other still works in Slovene — the
        // missing dual/few forms resolve to `other`.
        let store = LocalizationStore(userDefaults: defaults)
        store.language = .slovene
        XCTAssertEqual(
            store.plural(2, one: .search_results_one, other: .search_results_other),
            "2 rezultatov")
    }
    func testPersistsLanguage() {
        LocalizationStore(userDefaults: defaults).language = .german
        XCTAssertEqual(LocalizationStore(userDefaults: defaults).language, .german)
    }
}
