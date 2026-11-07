import XCTest

@testable import Schrift

final class ProjectionRangeIndexTests: XCTestCase {
    func testUTF16AndStructuralSeparatorBoundaries() throws {
        let blocks = [
            BlockSnapshot(id: "a", node: "paragraph", props: [], runs: [InlineRun("😀e\u{301}")]),
            BlockSnapshot(id: "empty", node: "paragraph", props: [], runs: []),
            BlockSnapshot(id: "b", node: "paragraph", props: [], runs: [InlineRun("tail")]),
        ]
        let index = ProjectionRangeIndex(blocks: blocks)
        XCTAssertEqual(index.entry(for: "a")?.textRange, NSRange(location: 0, length: 4))
        XCTAssertEqual(index.entry(for: "a")?.separatorRange, NSRange(location: 4, length: 1))
        XCTAssertEqual(index.entry(atUTF16: 4)?.blockID, "a")
        XCTAssertEqual(index.entry(atUTF16: 5)?.blockID, "empty")
        XCTAssertEqual(index.entry(atUTF16: 6)?.blockID, "b")
        XCTAssertEqual(index.documentRange(blockID: "b", textRange: 1..<3), NSRange(location: 7, length: 2))
        XCTAssertNil(index.documentRange(blockID: "a", textRange: 4..<5))
        XCTAssertNil(index.entry(atUTF16: -1))
        XCTAssertNil(index.entry(atUTF16: index.length))
    }

    func testDuplicateAndMissingIDsRemainVisibleButCannotBeAddressed() {
        let blocks = ["duplicate", "", "duplicate"].map {
            BlockSnapshot(id: $0, node: "paragraph", props: [], runs: [InlineRun("x")])
        }
        let index = ProjectionRangeIndex(blocks: blocks)
        XCTAssertEqual(index.entries.count, 3)
        XCTAssertEqual(index.length, 6)
        XCTAssertNil(index.entry(for: "duplicate"))
        XCTAssertNil(index.entry(for: ""))
    }

    func testPlaceholderRangesCoverTheDisplayedLabel() {
        let block = BlockSnapshot(id: "object", node: "table", props: [], runs: [])
        let index = ProjectionRangeIndex(blocks: [block])
        XCTAssertEqual(index.length, AttributedDocumentProjection.displayText(for: block).utf16.count + 1)
        XCTAssertEqual(ProjectionRangeIndex().length, 0)
    }
}
