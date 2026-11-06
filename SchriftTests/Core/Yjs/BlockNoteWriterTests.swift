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
            let newID = "11111111-1111-4111-8111-111111111111"
            try w.splitBlock(block: "p-c", at: offset, newID: newID)
            let blocks = YBlockProjection.project(doc).blocks
            XCTAssertEqual(blocks.count, 2)
            // At offset 0 BlockNote inserts the empty block above, so the text keeps its id.
            XCTAssertEqual(blocks.map(\.id), offset == 0 ? [newID, "p-c"] : ["p-c", newID])
            XCTAssertEqual(
                blocks.map { $0.runs.map(\.text).joined() }, offset == 0 ? ["", "HelloWorld"] : ["HelloWorld", ""])
            try w.joinBlocks(block: offset == 0 ? "p-c" : newID)
            XCTAssertEqual(YXMLString.fragment(doc), BlockNote056SplitParagraphTests.checkpoints[0].xml)
        }
    }

    func testReplaceAcrossInlineNodeAndInsertBetweenTwoInlineNodes() throws {
        let doc = try seeded(BlockNote056MixedInlineEditTests.checkpoints)
        defer { doc.destroy() }
        let w = BlockNoteWriter(doc: doc)
        // Delete " middle " (units 8..<16, after the mention at 7), leaving the
        // mention and the interlink adjacent. An insertion there must mint an
        // XmlText between them.
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

    private func encoded(_ blocks: [BlockNoteBlock]) throws -> YDoc {
        let doc = YDoc(clientID: 2, gc: false)
        try doc.applyUpdate(YUpdateDecoder.decode(BlockNoteYjs.encode(blocks, clientID: 1)))
        return doc
    }

    private func paragraph(_ id: String, _ text: String) -> BlockNoteBlock {
        BlockNoteBlock(
            node: "paragraph",
            props: [
                ("backgroundColor", .string("default")), ("textColor", .string("default")),
                ("textAlignment", .string("left")),
            ], runs: [InlineRun(text)], id: id)
    }

    private func assertThrows(
        _ error: BlockNoteWriter.Error, in doc: YDoc, line: UInt = #line, _ body: (BlockNoteWriter) throws -> Void
    ) {
        let before = YXMLString.fragment(doc)
        do {
            try body(BlockNoteWriter(doc: doc))
            XCTFail("Expected \(error)", line: line)
        } catch let thrown as BlockNoteWriter.Error {
            XCTAssertEqual(thrown, error, line: line)
        } catch {
            XCTFail("Unexpected \(error)", line: line)
        }
        XCTAssertEqual(YXMLString.fragment(doc), before, line: line)
    }

    func testDuplicateBlockIDsAnywhereInTheTreeThrow() throws {
        var parent = paragraph("parent", "a")
        parent.children = [paragraph("same", "b")]
        let doc = try encoded([parent, paragraph("same", "c")])
        defer { doc.destroy() }
        assertThrows(.duplicateID("same"), in: doc) {
            try $0.replaceText(block: "same", range: NSRange(location: 0, length: 0), with: "x")
        }
        assertThrows(.duplicateID("same"), in: doc) { try $0.joinBlocks(block: "same") }
        XCTAssertNoThrow(
            try BlockNoteWriter(doc: doc).formatRange(
                block: "parent", range: NSRange(location: 0, length: 1), attributes: ["bold": "{}"]))
    }

    func testCanonicallyEquivalentIDDoesNotMatchAnyIntent() throws {
        for (existing, requested) in [("e\u{301}", "\u{E9}"), ("\u{E9}", "e\u{301}")] {
            let doc = try encoded([paragraph(existing, "abc")])
            defer { doc.destroy() }
            assertThrows(.missingBlock(requested), in: doc) {
                try $0.replaceText(block: requested, range: NSRange(location: 0, length: 1), with: "x")
            }
            assertThrows(.missingBlock(requested), in: doc) {
                try $0.formatRange(block: requested, range: NSRange(location: 0, length: 1), attributes: ["bold": "{}"])
            }
            assertThrows(.missingBlock(requested), in: doc) {
                try $0.splitBlock(block: requested, at: 1, newID: "new")
            }
            assertThrows(.missingBlock(requested), in: doc) { try $0.joinBlocks(block: requested) }
            assertThrows(.missingBlock(requested), in: doc) { try $0.setBlockType(block: requested, to: "heading") }
        }
    }

    func testBothIDNormalizationFormsCanBeEditedWithoutFalseDuplicate() throws {
        let doc = try encoded([paragraph("e\u{301}", "a"), paragraph("\u{E9}", "b")])
        defer { doc.destroy() }
        let writer = BlockNoteWriter(doc: doc)
        try writer.replaceText(block: "e\u{301}", range: NSRange(location: 1, length: 0), with: "1")
        try writer.replaceText(block: "\u{E9}", range: NSRange(location: 1, length: 0), with: "2")
        let blocks = YBlockProjection.project(doc).blocks
        XCTAssertEqual(blocks.map { Array($0.id.utf16) }, [Array("e\u{301}".utf16), Array("\u{E9}".utf16)])
        XCTAssertEqual(blocks.map { $0.runs.map(\.text).joined() }, ["a1", "b2"])
    }

    func testSplitNewIDMayUseOtherNormalizationForm() throws {
        for (existing, newID) in [("e\u{301}", "\u{E9}"), ("\u{E9}", "e\u{301}")] {
            let doc = try encoded([paragraph(existing, "ab")])
            defer { doc.destroy() }
            try BlockNoteWriter(doc: doc).splitBlock(block: existing, at: 1, newID: newID)
            let blocks = YBlockProjection.project(doc).blocks
            XCTAssertEqual(blocks.map { Array($0.id.utf16) }, [Array(existing.utf16), Array(newID.utf16)])
            XCTAssertEqual(blocks.map { $0.runs.map(\.text).joined() }, ["a", "b"])
        }
    }

    func testToggleHeadingSplitIsUnsupported() throws {
        let doc = try encoded([
            BlockNoteBlock(
                node: "heading",
                props: [
                    ("backgroundColor", .string("default")), ("textColor", .string("default")),
                    ("textAlignment", .string("left")), ("level", .int(1)), ("isToggleable", .bool(true)),
                ], runs: [InlineRun("Toggle")], id: "t")
        ])
        defer { doc.destroy() }
        assertThrows(.unsupportedBlockType("heading"), in: doc) { try $0.splitBlock(block: "t", at: 3, newID: "1") }
    }

    func testUnknownTargetTypeThrowsBeforeLookup() throws {
        let doc = YDoc(clientID: 2, gc: false)
        defer { doc.destroy() }
        assertThrows(.unsupportedBlockType("table"), in: doc) { try $0.setBlockType(block: "missing", to: "table") }
    }

    /// Each guard in `resolve`: the shapes a well-formed BlockNote container never has.
    func testResolveRejectsMalformedContainers() throws {
        let shapes: [(String, (YTransaction, YType) throws -> Void)] = [
            (
                "third child",
                { tx, container in
                    try YWrite.insertAfter(
                        tx, into: container, after: container.start,
                        [
                            .type(YType(typeRef: .xmlElement(nodeName: "blockGroup"))),
                            .type(YType(typeRef: .xmlElement(nodeName: "blockGroup"))),
                        ])
                }
            ),
            (
                "second child is not a group",
                { tx, container in
                    try YWrite.insertAfter(
                        tx, into: container, after: container.start,
                        [.type(YType(typeRef: .xmlElement(nodeName: "paragraph")))])
                }
            ),
            (
                "first child is text",
                { tx, container in
                    try YWrite.insertAfter(tx, into: container, after: nil, [.type(YType(typeRef: .xmlText))])
                }
            ),
            ("no content", { tx, container in container.start?.delete(tx) }),
        ]
        for (label, mutate) in shapes {
            let doc = try seeded(BlockNote056SplitParagraphTests.checkpoints)
            defer { doc.destroy() }
            let root = try XCTUnwrap(doc.share["document-store"])
            guard case .type(let group)? = root.start?.content, case .type(let container)? = group.start?.content
            else { return XCTFail("seed shape") }
            try doc.transact { tx in try mutate(tx, container) }
            let before = YXMLString.fragment(doc)
            do {
                try BlockNoteWriter(doc: doc).replaceText(
                    block: "p-c", range: NSRange(location: 0, length: 0), with: "x")
                XCTFail("Expected malformed block: \(label)")
            } catch BlockNoteWriter.Error.malformedBlock(let id) {
                XCTAssertEqual(id, "p-c", label)
            }
            XCTAssertEqual(YXMLString.fragment(doc), before, label)
        }
    }

    func testRangesAndCaretsNeverSplitASurrogatePair() throws {
        // yjs splices a pair it is asked to cut and writes U+FFFD into both
        // halves; the writer grows a range to the whole character and moves a
        // caret back to the character's start.
        let cases: [(String, (BlockNoteWriter) throws -> Void, String)] = [
            (
                "delete leading half",
                { try $0.replaceText(block: "p-c", range: NSRange(location: 1, length: 1), with: "") }, ">ab<"
            ),
            (
                "delete trailing half",
                { try $0.replaceText(block: "p-c", range: NSRange(location: 2, length: 1), with: "") }, ">ab<"
            ),
            (
                "caret inside", { try $0.replaceText(block: "p-c", range: NSRange(location: 2, length: 0), with: "x") },
                ">ax😀b<"
            ),
            (
                "bold trailing half",
                {
                    try $0.formatRange(block: "p-c", range: NSRange(location: 2, length: 1), attributes: ["bold": "{}"])
                }, ">a<bold>😀</bold>b<"
            ),
        ]
        for (label, edit, expected) in cases {
            let doc = try seeded(BlockNote056SplitParagraphTests.checkpoints)
            defer { doc.destroy() }
            let w = BlockNoteWriter(doc: doc)
            try w.replaceText(block: "p-c", range: NSRange(location: 0, length: 10), with: "a😀b")
            try edit(w)
            let xml = YXMLString.fragment(doc)
            XCTAssertTrue(xml.contains(expected), "\(label): \(xml)")
            XCTAssertFalse(xml.contains("\u{FFFD}"), label)
        }
    }
}
