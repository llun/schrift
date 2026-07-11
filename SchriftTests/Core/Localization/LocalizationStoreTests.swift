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
    func testResolvesAKeyForANonEnglishLanguage() {
        // A real key resolves to a non-empty string in a non-English language.
        // (The subscript's `?? Strings_en.table[key]` fallback can't be reached
        // via a real key — StringsCompletenessTests forbids any key being absent
        // from a table — so this exercises resolution, not the fallback branch.)
        let store = LocalizationStore(userDefaults: defaults)
        store.language = .thai
        let value = store[.common_close]
        XCTAssertFalse(value.isEmpty)
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
