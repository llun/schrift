import SwiftUI
import XCTest

@testable import Schrift

final class FoldLayoutTests: XCTestCase {
    // The iPhone Duo unfolded in landscape: 951pt wide, crease down the middle.
    private let width: CGFloat = 951
    private let crease = CGRect(x: 473, y: 0, width: 6, height: 669)

    func testFindsAVerticalCreaseAndClipsItToTheView() {
        XCTAssertEqual(FoldLayout.verticalFold(in: [crease], width: width), 473...479)
        XCTAssertEqual(
            FoldLayout.verticalFold(in: [CGRect(x: -2, y: 0, width: 6, height: 600)], width: width), 0...4)
    }

    func testIgnoresHorizontalCreasesAndOnesOutsideTheView() {
        XCTAssertNil(FoldLayout.verticalFold(in: [CGRect(x: 0, y: 330, width: 669, height: 6)], width: 669))
        XCTAssertNil(FoldLayout.verticalFold(in: [crease.offsetBy(dx: 600, dy: 0)], width: width))
        XCTAssertNil(FoldLayout.verticalFold(in: [], width: width))
    }

    func testSidebarEndsAtTheCrease() {
        XCTAssertEqual(FoldLayout.sidebarWidth(fold: 473...479, width: width), 473)
    }

    func testSidebarKeepsTheSystemWidthWhenTheCreaseHugsAnEdge() {
        XCTAssertNil(FoldLayout.sidebarWidth(fold: 200...206, width: width))
        XCTAssertNil(FoldLayout.sidebarWidth(fold: 700...706, width: width))
    }

    func testClearanceMovesContentToTheWiderSide() {
        XCTAssertEqual(
            FoldLayout.clearance(fold: 473...479, width: width),
            EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 478))
        XCTAssertEqual(
            FoldLayout.clearance(fold: 300...306, width: width),
            EdgeInsets(top: 0, leading: 306, bottom: 0, trailing: 0))
    }
}
