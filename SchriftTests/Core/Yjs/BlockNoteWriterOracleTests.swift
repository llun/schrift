import XCTest

@testable import Schrift

final class BlockNoteWriterOracleTests: XCTestCase {
    typealias Checkpoint = (label: String, updateBase64: String, xml: String)

    private var props: [(key: String, value: YAnyValue)] {
        [
            ("backgroundColor", .string("default")), ("textColor", .string("default")),
            ("textAlignment", .string("left")),
        ]
    }

    /// Each edit is authored against our previous edit, never against replayed web steps.
    private func check(
        _ checkpoints: [Checkpoint], identical: [Bool],
        author: (BlockNoteWriter, Int) throws -> Data
    ) throws {
        let doc = YDoc(clientID: 2, gc: false)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(try XCTUnwrap(Data(base64Encoded: checkpoints[0].updateBase64))))
        let writer = BlockNoteWriter(doc: doc)
        for index in 1..<checkpoints.count {
            let step = checkpoints[index]
            let bytes = try author(writer, index)
            XCTAssertEqual(YXMLString.fragment(doc), step.xml, step.label)
            XCTAssertNil(doc.store.pendingStructs, step.label)
            XCTAssertNil(doc.store.pendingDs, step.label)
            XCTAssertEqual(bytes == Data(base64Encoded: step.updateBase64), identical[index - 1], step.label)
            XCTAssertEqual(doc.lastTransactionOrigin, .localUser)
        }
    }

    func testTypingMarksLinkAndColor() throws {
        // First typing is exact. Later steps differ because the web inserts plain
        // text then formats it, retaining deleted redundant closers; explicit
        // insertion marks mint the opening format before the string instead.
        try check(BlockNote056TypingMarksLinkColorTests.checkpoints, identical: [true, false, false, false]) {
            w, step in
            switch step {
            case 1: return try w.replaceText(block: "p-a", range: NSRange(location: 0, length: 0), with: "Hi ")
            case 2:
                // a2: web clocks the string before bold-open; explicit marks
                // clock bold-open first. Same three structs, different origins.
                return try w.replaceText(
                    block: "p-a", range: NSRange(location: 3, length: 0), with: "there", marks: ["bold": "{}"])
            case 3:
                // a3: web inserts before the bold closer, moves that closer,
                // then deletes 2:10; explicit unmarked insertion keeps it.
                // Web clocks link's string before its opener; ours reverses it.
                return try w.transaction { _ in
                    _ = try w.replaceText(block: "p-a", range: NSRange(location: 8, length: 0), with: " ", marks: [:])
                    _ = try w.replaceText(
                        block: "p-a", range: NSRange(location: 9, length: 0), with: "link",
                        marks: ["link": #"{"href":"https://example.com/"}"#])
                }
            default:
                // a4: web similarly moves/deletes its link closer (2:18) and
                // repeats the prior 2:10 delete. Our explicit color insertion
                // keeps its closer and starts one clock earlier after a3.
                return try w.replaceText(
                    block: "p-a", range: NSRange(location: 13, length: 0), with: " red",
                    marks: ["textColor": #"{"stringValue":"red"}"#])
            }
        }
    }

    func testBoldOnAndOff() throws {
        try check(BlockNote056ToggleBoldOnOffTests.checkpoints, identical: [true, true]) { w, step in
            try w.formatRange(
                block: "p-b", range: NSRange(location: 2, length: 4), attributes: ["bold": step == 1 ? "{}" : "null"])
        }
    }

    func testSplit() throws {
        try check(BlockNote056SplitParagraphTests.checkpoints, identical: [true]) { w, _ in
            try w.splitBlock(block: "p-c", at: 5, newID: "1")
        }
    }

    func testJoin() throws {
        try check(BlockNote056MergeParagraphsTests.checkpoints, identical: [true]) { w, _ in
            try w.joinBlocks(block: "p-d-second")
        }
    }

    func testBlockTypeChanges() throws {
        // The second web checkpoint is encodeStateAsUpdate(since: vector),
        // which repeats the first step's delete set. Our transaction update
        // contains only the second step's deletes; structs are identical.
        try check(BlockNote056ChangeBlockTypesTests.checkpoints, identical: [true, false]) { w, step in
            try w.setBlockType(
                block: step == 1 ? "p-e" : "li-e", to: step == 1 ? "heading" : "checkListItem",
                props: props
                    + (step == 1 ? [("level", .int(2)), ("isToggleable", .bool(false))] : [("checked", .bool(false))]))
        }
    }

    func testMixedInlineEdit() throws {
        // Seven UTF-16 units, one atomic mention, then four units of middle text.
        try check(BlockNote056MixedInlineEditTests.checkpoints, identical: [true]) { w, _ in
            try w.replaceText(block: "p-g", range: NSRange(location: 12, length: 0), with: "!")
        }
    }
}
