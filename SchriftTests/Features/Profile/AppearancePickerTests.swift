import XCTest

@testable import Schrift

final class AppearancePickerTests: XCTestCase {
    func testOptionsOrderAndIcons() {
        XCTAssertEqual(appearanceOptions(), [.light, .dark, .system])
        XCTAssertEqual(AppAppearance.light.icon, .light_mode)
        XCTAssertEqual(AppAppearance.dark.icon, .dark_mode)
        XCTAssertEqual(AppAppearance.system.icon, .contrast)
    }

    func testValueKeyMapping() {
        XCTAssertEqual(appearanceValueKey(.system), .appearance_system)
        XCTAssertEqual(appearanceValueKey(.light), .appearance_light)
        XCTAssertEqual(appearanceValueKey(.dark), .appearance_dark)
    }
}
