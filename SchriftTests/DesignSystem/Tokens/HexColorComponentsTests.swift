import XCTest

@testable import Schrift

final class HexColorComponentsTests: XCTestCase {
    func testSplitsHexIntoUnitRangeChannels() {
        let cases: [(hex: UInt32, red: Double, green: Double, blue: Double)] = [
            (0x000000, 0, 0, 0),
            (0xFFFFFF, 1, 1, 1),
            (0xFF8000, 1, 0.5020, 0),
            (0x0000FF, 0, 0, 1),
        ]
        for testCase in cases {
            let components = hexColorComponents(testCase.hex)
            XCTAssertEqual(components.red, testCase.red, accuracy: 0.0001, "\(testCase.hex)")
            XCTAssertEqual(components.green, testCase.green, accuracy: 0.0001, "\(testCase.hex)")
            XCTAssertEqual(components.blue, testCase.blue, accuracy: 0.0001, "\(testCase.hex)")
        }
    }
}
