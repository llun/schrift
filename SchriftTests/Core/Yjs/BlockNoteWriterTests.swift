import XCTest

@testable import Schrift

final class BlockNoteWriterTests: XCTestCase {
    private func seeded(_ checkpoints: [(label: String, updateBase64: String, xml: String)]) throws -> YDoc {
        let doc = YDoc(clientID: 2, gc: false)
        try doc.applyUpdate(YUpdateDecoder.decode(try XCTUnwrap(Data(base64Encoded: checkpoints[0].updateBase64))))
        return doc
    }

    func testClampsHugeRangesWithoutNewlinePadding() throws {
        let doc = try seeded(BlockNote056SplitParagraphTests.checkpoints)
        defer { doc.destroy() }
        let w = BlockNoteWriter(doc: doc)
        try w.formatRange(block: "p-c", range: NSRange(location: 5, length: Int.max), attributes: ["bold": "{}"])
        XCTAssertTrue(YXMLString.fragment(doc).contains("Hello<bold>World</bold>"))
        try w.formatRange(
            block: "p-c", range: NSRange(location: Int.max, length: Int.max), attributes: ["italic": "{}"])
        try w.replaceText(block: "p-c", range: NSRange(location: Int.max, length: Int.max), with: "!")
        XCTAssertTrue(YXMLString.fragment(doc).contains("World!</bold>"))
        try w.replaceText(block: "p-c", range: NSRange(location: 5, length: Int.max), with: "?")
        XCTAssertFalse(YXMLString.fragment(doc).contains("\n"))
        XCTAssertTrue(YXMLString.fragment(doc).contains("Hello"))
    }

    func testMissingBlockThrowsTypedErrorWithoutMutation() throws {
        let doc = YDoc(clientID: 2, gc: false)
        defer { doc.destroy() }
        do {
            try BlockNoteWriter(doc: doc).replaceText(
                block: "missing", range: NSRange(location: 0, length: 0), with: "x")
            XCTFail("Expected missing target")
        } catch BlockNoteWriter.Error.missingBlock(let id) {
            XCTAssertEqual(id, "missing")
        }
        XCTAssertTrue(doc.share.isEmpty)
    }

    func testFirstBlockJoinThrowsWithoutMutation() throws {
        let doc = try seeded(BlockNote056SplitParagraphTests.checkpoints)
        defer { doc.destroy() }
        let before = YXMLString.fragment(doc)
        do {
            try BlockNoteWriter(doc: doc).joinBlocks(block: "p-c")
            XCTFail("Expected no previous block")
        } catch BlockNoteWriter.Error.noPreviousBlock(let id) {
            XCTAssertEqual(id, "p-c")
        }
        XCTAssertEqual(YXMLString.fragment(doc), before)
    }

    func testSplitAtZeroAndEndPreservesVisibleContentAndIDs() throws {
        for offset in [0, 10] {
            let doc = try seeded(BlockNote056SplitParagraphTests.checkpoints)
            defer { doc.destroy() }
            let w = BlockNoteWriter(doc: doc)
            try w.splitBlock(block: "p-c", at: offset, newID: "11111111-1111-4111-8111-111111111111")
            let blocks = YBlockProjection.project(doc).blocks
            XCTAssertEqual(blocks.count, 2)
            XCTAssertEqual(blocks[0].runs.map(\.text).joined(), offset == 0 ? "" : "HelloWorld")
            XCTAssertEqual(blocks[1].runs.map(\.text).joined(), offset == 0 ? "HelloWorld" : "")
            XCTAssertEqual(blocks[0].id, "p-c")
            XCTAssertEqual(blocks[1].id, "11111111-1111-4111-8111-111111111111")
            try w.joinBlocks(block: "11111111-1111-4111-8111-111111111111")
            XCTAssertEqual(YXMLString.fragment(doc), BlockNote056SplitParagraphTests.checkpoints[0].xml)
        }
    }

    func testReplaceAcrossInlineNodeAndInsertBetweenTwoInlineNodes() throws {
        let doc = try seeded(BlockNote056MixedInlineEditTests.checkpoints)
        defer { doc.destroy() }
        let w = BlockNoteWriter(doc: doc)
        // Replace the mention and the following middle text, leaving two nodes
        // adjacent. An insertion there must mint an XmlText between them.
        try w.replaceText(block: "p-g", range: NSRange(location: 8, length: 8), with: "")
        try w.replaceText(block: "p-g", range: NSRange(location: 8, length: 0), with: "between")
        let xml = YXMLString.fragment(doc)
        XCTAssertTrue(xml.contains("</usermentioninline>between<interlinkinglinkinline"))
        XCTAssertTrue(xml.contains("<math>x^2</math> after"))
        // Cross a text/node boundary and replace the mention atomically.
        try w.replaceText(block: "p-g", range: NSRange(location: 6, length: 3), with: "!")
        XCTAssertFalse(YXMLString.fragment(doc).contains("usermentioninline"))
        XCTAssertTrue(YXMLString.fragment(doc).contains("Before!etween"))
    }

    func testSplitAndJoinPreserveMarkedRunsAndInlineNodes() throws {
        let doc = try seeded(BlockNote056MixedInlineEditTests.checkpoints)
        defer { doc.destroy() }
        let w = BlockNoteWriter(doc: doc)
        try w.formatRange(block: "p-g", range: NSRange(location: 8, length: 8), attributes: ["bold": "{}"])
        let before = YXMLString.fragment(doc)
        try w.splitBlock(block: "p-g", at: 8, newID: "11111111-1111-4111-8111-111111111111")
        try w.joinBlocks(block: "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(YXMLString.fragment(doc), before)
        XCTAssertNil(doc.store.pendingStructs)
        XCTAssertNil(doc.store.pendingDs)
    }

    func testNilMarksInheritAndExplicitEmptyMarksClear() throws {
        let doc = try seeded(BlockNote056SplitParagraphTests.checkpoints)
        defer { doc.destroy() }
        let w = BlockNoteWriter(doc: doc)
        try w.formatRange(block: "p-c", range: NSRange(location: 0, length: 5), attributes: ["bold": "{}"])
        try w.replaceText(block: "p-c", range: NSRange(location: 3, length: 0), with: "!")
        XCTAssertTrue(YXMLString.fragment(doc).contains("<bold>Hel!lo</bold>World"))
        try w.replaceText(block: "p-c", range: NSRange(location: 4, length: 0), with: "?", marks: [:])
        XCTAssertTrue(YXMLString.fragment(doc).contains("<bold>Hel!</bold>?<bold>lo</bold>World"))
    }

    func testFormatAcrossInlineNodesClampsEachTextPortion() throws {
        let doc = try seeded(BlockNote056MixedInlineEditTests.checkpoints)
        defer { doc.destroy() }
        try BlockNoteWriter(doc: doc).formatRange(
            block: "p-g", range: NSRange(location: 6, length: Int.max), attributes: ["italic": "{}"])
        let xml = YXMLString.fragment(doc)
        XCTAssertTrue(xml.contains("Before<italic> </italic><usermentioninline"))
        XCTAssertTrue(xml.contains("</usermentioninline><italic> middle </italic>"))
        XCTAssertTrue(xml.contains("<math>x^2</math><italic> after</italic>"))
        XCTAssertFalse(xml.contains("\n"))
    }

    func testUTF16RangeEditsOnlySelectedCodeUnits() throws {
        let doc = try seeded(BlockNote056SplitParagraphTests.checkpoints)
        defer { doc.destroy() }
        let w = BlockNoteWriter(doc: doc)
        try w.replaceText(block: "p-c", range: NSRange(location: 0, length: 10), with: "a😀b")
        try w.replaceText(block: "p-c", range: NSRange(location: 1, length: 2), with: "x")
        XCTAssertTrue(YXMLString.fragment(doc).contains(">axb</paragraph>"))
    }

    func testDuplicateSplitIDThrowsBeforeTruncating() throws {
        let doc = try seeded(BlockNote056SplitParagraphTests.checkpoints)
        defer { doc.destroy() }
        do {
            try BlockNoteWriter(doc: doc).splitBlock(block: "p-c", at: 3, newID: "p-c")
            XCTFail("Expected duplicate id")
        } catch BlockNoteWriter.Error.duplicateID(let id) {
            XCTAssertEqual(id, "p-c")
        }
        XCTAssertEqual(YXMLString.fragment(doc), BlockNote056SplitParagraphTests.checkpoints[0].xml)
    }

    func testMalformedInlineThrowsBeforeMutation() throws {
        let doc = try seeded(BlockNote056SplitParagraphTests.checkpoints)
        defer { doc.destroy() }
        let root = try XCTUnwrap(doc.share["document-store"])
        guard case .type(let group)? = root.start?.content,
            case .type(let container)? = group.start?.content,
            case .type(let paragraph)? = container.start?.content
        else { return XCTFail("seed shape") }
        try doc.transact { tx in
            try YWrite.insertAfter(
                tx, into: paragraph, after: paragraph.start, [.type(YType(typeRef: .xmlElement(nodeName: "unknown")))])
        }
        let before = YXMLString.fragment(doc)
        do {
            try BlockNoteWriter(doc: doc).replaceText(block: "p-c", range: NSRange(location: 0, length: 1), with: "x")
            XCTFail("Expected malformed inline")
        } catch BlockNoteWriter.Error.malformedBlock(let id) {
            XCTAssertEqual(id, "p-c")
        }
        XCTAssertEqual(YXMLString.fragment(doc), before)
    }
}
