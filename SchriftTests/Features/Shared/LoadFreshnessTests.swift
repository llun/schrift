import XCTest

@testable import Schrift

final class LoadFreshnessTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testNothingIsFreshBeforeASuccess() {
        XCTAssertFalse(LoadFreshness<Int>().isFresh(token: 0, at: start))
    }

    func testFreshInsideTheWindowAndStaleAtItsEdge() {
        var freshness = LoadFreshness<Int>(window: 30)
        freshness.noteSuccess(token: 1, at: start)

        XCTAssertTrue(freshness.isFresh(token: 1, at: start.addingTimeInterval(29)))
        XCTAssertFalse(freshness.isFresh(token: 1, at: start.addingTimeInterval(30)))
    }

    func testADifferentTokenIsNeverFresh() {
        var freshness = LoadFreshness<Int>(window: 30)
        freshness.noteSuccess(token: 1, at: start)

        XCTAssertFalse(freshness.isFresh(token: 2, at: start.addingTimeInterval(1)))
    }

    func testAClockThatWentBackwardsIsNotFresh() {
        var freshness = LoadFreshness<Int>(window: 30)
        freshness.noteSuccess(token: 1, at: start)

        XCTAssertFalse(freshness.isFresh(token: 1, at: start.addingTimeInterval(-5)))
    }
}
