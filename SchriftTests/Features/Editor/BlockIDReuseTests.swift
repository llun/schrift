import XCTest

@testable import Schrift

/// `reusingBlockIDs(from:into:)` — what lets `EditorViewModel.install(...)` swap in a
/// revalidated body without re-identifying the blocks nothing changed.
final class BlockIDReuseTests: XCTestCase {
    private func paragraphs(_ texts: [String]) -> [EditorBlock] {
        texts.map { EditorBlock(kind: .paragraph, text: $0) }
    }

    private func assertUniqueIDs(_ blocks: [EditorBlock], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Set(blocks.map(\.id)).count, blocks.count, "ids must stay unique", file: file, line: line)
    }

    func testUnchangedDocumentKeepsEveryIDAndEqualsTheOldBlocks() {
        let old = paragraphs(["a", "b", "c"])
        let result = reusingBlockIDs(from: old, into: paragraphs(["a", "b", "c"]))

        XCTAssertEqual(result, old, "identical content comes back equal, ids included, so install can skip assigning")
    }

    func testInsertionInTheMiddleKeepsEveryOtherID() {
        let old = paragraphs(["a", "b", "c"])
        let new = paragraphs(["a", "inserted", "b", "c"])
        let result = reusingBlockIDs(from: old, into: new)

        XCTAssertEqual(result.map(\.text), ["a", "inserted", "b", "c"])
        XCTAssertEqual([result[0].id, result[2].id, result[3].id], old.map(\.id))
        XCTAssertEqual(result[1].id, new[1].id, "the inserted block keeps its fresh id")
        assertUniqueIDs(result)
    }

    func testRemovalKeepsTheSurvivorsIDs() {
        let old = paragraphs(["a", "b", "c"])
        let result = reusingBlockIDs(from: old, into: paragraphs(["a", "c"]))

        XCTAssertEqual(result.map(\.id), [old[0].id, old[2].id])
    }

    /// The conservative choice: an edited block is a different block as far as identity goes,
    /// so a surviving native text view is never handed text that changed under it.
    func testEditedBlockGetsAFreshIDWhileItsNeighboursKeepTheirs() {
        let old = paragraphs(["a", "b", "c"])
        let new = paragraphs(["a", "b edited", "c"])
        let result = reusingBlockIDs(from: old, into: new)

        XCTAssertEqual(result.map(\.text), ["a", "b edited", "c"])
        XCTAssertEqual(result[0].id, old[0].id)
        XCTAssertEqual(result[2].id, old[2].id)
        XCTAssertFalse(old.map(\.id).contains(result[1].id), "no positional reuse for changed content")
        assertUniqueIDs(result)
    }

    func testKindAndIndentAreContent() {
        let old = [
            EditorBlock(kind: .bulletItem, text: "x"),
            EditorBlock(kind: .bulletItem, text: "y", indent: 1),
        ]
        let new = [
            EditorBlock(kind: .numberedItem, text: "x"),
            EditorBlock(kind: .bulletItem, text: "y", indent: 0),
        ]
        let result = reusingBlockIDs(from: old, into: new)

        XCTAssertTrue(Set(result.map(\.id)).isDisjoint(with: old.map(\.id)))
        XCTAssertEqual(result.map(\.kind), new.map(\.kind))
        XCTAssertEqual(result.map(\.indent), [0, 0])
    }

    func testDuplicateContentReusesEachOldIDAtMostOnce() {
        let old = paragraphs(["same", "same"])
        let result = reusingBlockIDs(from: old, into: paragraphs(["same", "same", "same"]))

        XCTAssertEqual(result.count, 3)
        assertUniqueIDs(result)
        XCTAssertEqual(Set(result.map(\.id)).intersection(old.map(\.id)).count, 2)
    }

    func testReorderKeepsTheLongestUnchangedRunAndUniqueIDs() {
        let old = paragraphs(["a", "b", "c", "d"])
        let result = reusingBlockIDs(from: old, into: paragraphs(["d", "a", "b", "c"]))

        XCTAssertEqual(result.map(\.text), ["d", "a", "b", "c"])
        XCTAssertEqual(Array(result[1...].map(\.id)), Array(old[0..<3].map(\.id)))
        XCTAssertNotEqual(result[0].id, old[3].id, "a moved block is re-identified")
        assertUniqueIDs(result)
    }

    /// Defensive: whatever ids the caller's `new` carries, the result never names one twice.
    func testUnmatchedBlockCollidingWithAReusedIDIsReminted() {
        let old = paragraphs(["a", "b"])
        let new = [
            EditorBlock(kind: .paragraph, text: "a"),
            EditorBlock(id: old[0].id, kind: .paragraph, text: "z"),
        ]
        let result = reusingBlockIDs(from: old, into: new)

        XCTAssertEqual(result[0].id, old[0].id)
        assertUniqueIDs(result)
    }

    func testEmptySidesReturnTheNewBlocksUnchanged() {
        let new = paragraphs(["a"])
        XCTAssertEqual(reusingBlockIDs(from: [], into: new), new)
        XCTAssertEqual(reusingBlockIDs(from: paragraphs(["a"]), into: []), [])
    }
}
