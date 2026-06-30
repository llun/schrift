import XCTest
@testable import DocsIOS

final class DocsRadiusTests: XCTestCase {
    func testRadiusScaleMatchesSpec() {
        XCTAssertEqual(DocsRadius.xs, 2)
        XCTAssertEqual(DocsRadius.sm, 4)
        XCTAssertEqual(DocsRadius.md, 8)
        XCTAssertEqual(DocsRadius.lg, 12)
        XCTAssertEqual(DocsRadius.xl, 16)
        XCTAssertEqual(DocsRadius.xl2, 24)
        XCTAssertEqual(DocsRadius.pill, 999)
    }
}
