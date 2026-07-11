import XCTest

@testable import Schrift

final class AppearancePickerTests: XCTestCase {
    func testOptionsOrderAndIcons() {
        XCTAssertEqual(appearanceOptions(), [.light, .dark, .system])
        XCTAssertEqual(AppAppearance.light.iconName, "sun.max")
        XCTAssertEqual(AppAppearance.dark.iconName, "moon")
        XCTAssertEqual(AppAppearance.system.iconName, "circle.lefthalf.filled")
    }

    func testValueKeyMapping() {
        XCTAssertEqual(appearanceValueKey(.system), .appearance_system)
        XCTAssertEqual(appearanceValueKey(.light), .appearance_light)
        XCTAssertEqual(appearanceValueKey(.dark), .appearance_dark)
    }
}
