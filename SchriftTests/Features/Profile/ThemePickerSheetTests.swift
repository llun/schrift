import SwiftUI
import XCTest

@testable import Schrift

@MainActor
final class ThemePickerSheetTests: XCTestCase {
    func testSpecimenLinesAreTwoShrinkingBars() {
        XCTAssertEqual(themeSpecimenLineFractions.count, 2)
        XCTAssertTrue(themeSpecimenLineFractions.allSatisfy { $0 > 0 && $0 <= 1 })
        XCTAssertGreaterThan(themeSpecimenLineFractions[0], themeSpecimenLineFractions[1])
    }

    func testRowsStackOnlyAtAccessibilitySizes() {
        XCTAssertFalse(themePickerStacksRows(.large))
        XCTAssertFalse(themePickerStacksRows(.xxxLarge))
        XCTAssertTrue(themePickerStacksRows(.accessibility1))
        XCTAssertTrue(themePickerStacksRows(.accessibility5))
    }

    func testEveryThemeHasNameAndDescriptionKeys() {
        let loc = LocalizationStore(
            userDefaults: UserDefaults(suiteName: "ThemePickerSheetTests.\(UUID())")!)
        for theme in AppTheme.allCases {
            XCTAssertFalse(loc[themeValueKey(theme)].isEmpty)
            XCTAssertFalse(loc[themeDescriptionKey(theme)].isEmpty)
        }
        XCTAssertFalse(loc[.theme_specimen_title].isEmpty)
        XCTAssertFalse(loc[.theme_specimen_chip].isEmpty)
    }

    func testSelectingEachThemePersists() {
        let suite = "ThemePickerSheetTests.persist.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ThemeStore(userDefaults: defaults)
        for theme in AppTheme.allCases {
            store.selected = theme
            XCTAssertEqual(ThemeStore(userDefaults: defaults).selected, theme)
        }
    }
}
