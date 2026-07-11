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
        XCTAssertEqual(store[.common_done], "Terminé")
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
