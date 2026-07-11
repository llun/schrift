import SwiftUI
import XCTest

@testable import Schrift

@MainActor
final class AppearanceStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    override func setUp() {
        suiteName = "AppearanceStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func testDefaultsToSystem() {
        XCTAssertEqual(AppearanceStore(userDefaults: defaults).selected, .system)
        XCTAssertNil(AppAppearance.system.colorScheme)
        XCTAssertEqual(AppAppearance.light.colorScheme, .light)
        XCTAssertEqual(AppAppearance.dark.colorScheme, .dark)
    }

    func testIcons() {
        XCTAssertEqual(AppAppearance.system.icon, .contrast)
        XCTAssertEqual(AppAppearance.light.icon, .light_mode)
        XCTAssertEqual(AppAppearance.dark.icon, .dark_mode)
    }
    func testPersistsSelection() {
        let store = AppearanceStore(userDefaults: defaults)
        store.selected = .dark
        XCTAssertEqual(AppearanceStore(userDefaults: defaults).selected, .dark)
    }
}
