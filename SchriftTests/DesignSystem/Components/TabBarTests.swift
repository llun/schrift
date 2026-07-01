import XCTest
@testable import Schrift

final class TabBarTests: XCTestCase {
    func testSelectedIconUsesFilledVariant() {
        XCTAssertEqual(tabBarIconName(baseSystemImage: "house", isSelected: true), "house.fill")
    }

    func testUnselectedIconUsesBaseVariant() {
        XCTAssertEqual(tabBarIconName(baseSystemImage: "house", isSelected: false), "house")
    }

    func testWorksWithCompoundSymbolNames() {
        XCTAssertEqual(tabBarIconName(baseSystemImage: "person.crop.circle", isSelected: true), "person.crop.circle.fill")
    }
}
