import XCTest
@testable import Schrift

final class HexColorComponentsTests: XCTestCase {
    func testBlackProducesZeroComponents() {
        let components = hexColorComponents(0x000000)
        XCTAssertEqual(components.red, 0.0, accuracy: 0.0001)
        XCTAssertEqual(components.green, 0.0, accuracy: 0.0001)
        XCTAssertEqual(components.blue, 0.0, accuracy: 0.0001)
    }

    func testWhiteProducesFullComponents() {
        let components = hexColorComponents(0xFFFFFF)
        XCTAssertEqual(components.red, 1.0, accuracy: 0.0001)
        XCTAssertEqual(components.green, 1.0, accuracy: 0.0001)
        XCTAssertEqual(components.blue, 1.0, accuracy: 0.0001)
    }

    func testMixedHexProducesExpectedComponents() {
        let components = hexColorComponents(0xFF8000)
        XCTAssertEqual(components.red, 1.0, accuracy: 0.0001)
        XCTAssertEqual(components.green, 0.5020, accuracy: 0.0001)
        XCTAssertEqual(components.blue, 0.0, accuracy: 0.0001)
    }

    func testBrandFillHexProducesExpectedComponents() {
        let components = hexColorComponents(0x5E5CD0)
        XCTAssertEqual(components.red, 0.3686, accuracy: 0.0001)
        XCTAssertEqual(components.green, 0.3608, accuracy: 0.0001)
        XCTAssertEqual(components.blue, 0.8157, accuracy: 0.0001)
    }
}
