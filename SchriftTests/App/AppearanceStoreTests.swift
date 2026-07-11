import SwiftUI
import XCTest

@testable import Schrift

@MainActor
final class AppearanceStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    override func setUp() {
        defaults = UserDefaults(suiteName: #function)
        defaults.removePersistentDomain(forName: #function)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: #function)
        defaults = nil
    }

    func testDefaultsToSystem() {
        XCTAssertEqual(AppearanceStore(userDefaults: defaults).selected, .system)
        XCTAssertNil(AppAppearance.system.colorScheme)
        XCTAssertEqual(AppAppearance.dark.colorScheme, .dark)
    }
    func testPersistsSelection() {
        let store = AppearanceStore(userDefaults: defaults)
        store.selected = .dark
        XCTAssertEqual(AppearanceStore(userDefaults: defaults).selected, .dark)
    }
}
