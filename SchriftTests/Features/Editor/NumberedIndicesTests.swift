import XCTest

@testable import Schrift

final class NumberedIndicesTests: XCTestCase {
    /// The one-pass numbering is only a speed-up; it must agree with the per-row scan on
    /// every shape, so enumerate every sequence over a small alphabet that covers each
    /// rule (same-level run, deeper items skipped, nested leaves skipped, breaks).
    func testOnePassNumberingEqualsPerRowScanForEverySmallShape() {
        let alphabet: [EditorBlock] = [
            EditorBlock(kind: .numberedItem, text: "n0", indent: 0),
            EditorBlock(kind: .numberedItem, text: "n1", indent: 1),
            EditorBlock(kind: .numberedItem, text: "n2", indent: 2),
            EditorBlock(kind: .bulletItem, text: "b0", indent: 0),
            EditorBlock(kind: .checklistItem(checked: false), text: "c1", indent: 1),
            EditorBlock(kind: .image(alt: "a", url: "https://example.com/a.png"), indent: 1),
            EditorBlock(kind: .paragraph, text: "[f](https://example.com/f)", indent: 2),
            EditorBlock(kind: .paragraph, text: "prose", indent: 0),
        ]
        let length = 5
        var sequence = [Int](repeating: 0, count: length)
        var checked = 0
        while true {
            let blocks = sequence.map { alphabet[$0] }
            let expected = blocks.indices.map { numberedIndex(of: $0, in: blocks) }
            XCTAssertEqual(numberedIndices(in: blocks), expected, "shape \(sequence)")
            checked += 1
            var position = length - 1
            while position >= 0, sequence[position] == alphabet.count - 1 {
                sequence[position] = 0
                position -= 1
            }
            if position < 0 { break }
            sequence[position] += 1
        }
        XCTAssertEqual(checked, Int(pow(Double(alphabet.count), Double(length))))
    }

    func testEmptyDocumentHasNoNumbers() {
        XCTAssertEqual(numberedIndices(in: []), [])
    }

    func testLongListNumbersContinuouslyAcrossASubList() {
        var blocks: [EditorBlock] = []
        for item in 0..<200 {
            blocks.append(EditorBlock(kind: .numberedItem, text: "\(item)", indent: 0))
            if item % 3 == 0 { blocks.append(EditorBlock(kind: .numberedItem, text: "sub", indent: 1)) }
        }
        let numbers = numberedIndices(in: blocks)
        let topLevel = blocks.indices.filter { blocks[$0].indent == 0 }.map { numbers[$0] }
        XCTAssertEqual(topLevel, Array(1...200))
    }
}
