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
        XCTAssertEqual(
            tabBarIconName(baseSystemImage: "person.crop.circle", isSelected: true), "person.crop.circle.fill")
    }

    func testSelectedIconFallsBackToBaseWhenNoFilledVariantExists() {
        // `magnifyingglass` (the Search tab) has no `.fill` variant in SF
        // Symbols, so requesting `magnifyingglass.fill` renders an empty image
        // and the icon disappears when the tab is selected. The helper must
        // fall back to the base symbol instead.
        XCTAssertEqual(tabBarIconName(baseSystemImage: "magnifyingglass", isSelected: true), "magnifyingglass")
    }

    func testUnselectedIconWithoutFilledVariantUsesBaseVariant() {
        XCTAssertEqual(tabBarIconName(baseSystemImage: "magnifyingglass", isSelected: false), "magnifyingglass")
    }
}
