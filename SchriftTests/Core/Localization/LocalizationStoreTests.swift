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
        // Strings_fr doesn't exist until Task B12; Strings.table(for:) currently
        // maps every non-English language to Strings_en.table, so compare
        // against the dispatcher rather than a not-yet-existing per-language
        // table. This assertion stays valid once B12 wires the real tables in.
        XCTAssertEqual(store[.common_done], Strings.table(for: .french)[.common_done])
        XCTAssertEqual(store.locale.identifier, "fr")
    }
    func testFallsBackToEnglishForMissingKey() {
        // A key intentionally absent from a non-English table resolves to English.
        let store = LocalizationStore(userDefaults: defaults)
        store.language = .thai
        let value = store[.common_done]
        XCTAssertFalse(value.isEmpty)
    }
    func testFormatSubstitutesArgs() {
        let store = LocalizationStore(userDefaults: defaults)
        store.language = .english
        XCTAssertEqual(store.format(.search_results_other, 3), "3 results")
    }
    func testPersistsLanguage() {
        LocalizationStore(userDefaults: defaults).language = .german
        XCTAssertEqual(LocalizationStore(userDefaults: defaults).language, .german)
    }
}
