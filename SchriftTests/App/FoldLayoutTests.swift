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
        // Wholly off the leading edge: an unguarded clip would build the invalid range 0...-4 and trap.
        XCTAssertNil(FoldLayout.verticalFold(in: [CGRect(x: -10, y: 0, width: 6, height: 600)], width: width))
        XCTAssertNil(FoldLayout.verticalFold(in: [CGRect(x: -6, y: 0, width: 6, height: 600)], width: width))
    }

    func testClipsACreaseRunningPastTheTrailingEdge() {
        XCTAssertEqual(
            FoldLayout.verticalFold(in: [CGRect(x: 949, y: 0, width: 6, height: 600)], width: width), 949...951)
    }

    func testSkipsRegionsThatAreNotVerticalCreases() {
        let horizontal = CGRect(x: 0, y: 330, width: 951, height: 6)
        XCTAssertEqual(FoldLayout.verticalFold(in: [horizontal, crease], width: width), 473...479)
    }

    func testClearanceMovesContentToTheWiderSide() {
        XCTAssertEqual(
            FoldLayout.clearance(fold: 473...479, width: width),
            EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 478))
        XCTAssertEqual(
            FoldLayout.clearance(fold: 300...306, width: width),
            EdgeInsets(top: 0, leading: 306, bottom: 0, trailing: 0))
        // A dead-centre crease keeps content on the leading side.
        XCTAssertEqual(
            FoldLayout.clearance(fold: 472.5...478.5, width: width),
            EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 478.5))
    }
}
