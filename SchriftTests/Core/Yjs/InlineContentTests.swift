import XCTest

@testable import Schrift

final class InlineContentTests: XCTestCase {
    func testPlainTextIsOneStringPiece() {
        XCTAssertEqual(InlineContent.pieces(for: [InlineRun("hello")]), [.string("hello")])
    }

    func testBoldRunOpensAndClosesTheMark() {
        let runs = [InlineRun("a"), InlineRun("b", marks: [("bold", "{}")]), InlineRun("c")]
        XCTAssertEqual(
            InlineContent.pieces(for: runs),
            [
                .string("a"), .format(key: "bold", valueJSON: "{}"), .string("b"),
                .format(key: "bold", valueJSON: "null"), .string("c"),
            ])
    }

    func testTrailingMarkIsClosedAfterLastRun() {
        let runs = [InlineRun("x", marks: [("italic", "{}")])]
        XCTAssertEqual(
            InlineContent.pieces(for: runs),
            [
                .format(key: "italic", valueJSON: "{}"), .string("x"),
                .format(key: "italic", valueJSON: "null"),
            ])
    }

    func testMarkCarriesAcrossAdjacentRunsWithoutReopening() {
        let runs = [InlineRun("a", marks: [("bold", "{}")]), InlineRun("b", marks: [("bold", "{}")])]
        XCTAssertEqual(
            InlineContent.pieces(for: runs),
            [
                .format(key: "bold", valueJSON: "{}"), .string("a"), .string("b"),
                .format(key: "bold", valueJSON: "null"),
            ])
    }
}
