import XCTest

@testable import Schrift

final class BlockNoteWriterOracleTests: XCTestCase {
    typealias Checkpoint = (label: String, updateBase64: String, xml: String)

    private func structs(_ update: YUpdate) -> [YItemRecord] {
        update.blocks.flatMap(\.structs).compactMap { if case .item(let item) = $0 { item } else { nil } }
    }

    private func deletes(_ update: YUpdate) -> Set<[UInt]> {
        Set(update.deleteSet.flatMap { block in block.ranges.map { [block.client, $0.clock, $0.length] } })
    }

    /// The writer's update alone must carry the edit: a second replica seeded
    /// with the same checkpoint reaches the same XML from the decoded bytes.
    private func assertConverges(_ replica: YDoc, _ bytes: Data, xml: String, _ label: String) throws {
        try replica.applyUpdate(YUpdateDecoder.decode(bytes))
        XCTAssertEqual(YXMLString.fragment(replica), xml, "replica: \(label)")
        XCTAssertNil(replica.store.pendingStructs, label)
        XCTAssertNil(replica.store.pendingDs, label)
    }

    /// Each edit is authored against our previous edit, never against replayed web steps.
    /// `differs` checks the documented difference wherever the bytes are not identical.
    private func check(
        _ checkpoints: [Checkpoint], identical: [Bool],
        differs: (Int, _ web: YUpdate, _ ours: YUpdate) -> Void = { _, _, _ in },
        author: (BlockNoteWriter, Int) throws -> Data
    ) throws {
        let seed = try YUpdateDecoder.decode(try XCTUnwrap(Data(base64Encoded: checkpoints[0].updateBase64)))
        let doc = YDoc(clientID: 2, gc: false)
        let replica = YDoc(clientID: 3, gc: false)
        defer {
            doc.destroy()
            replica.destroy()
        }
        try doc.applyUpdate(seed)
        try replica.applyUpdate(seed)
        let writer = BlockNoteWriter(doc: doc)
        for index in 1..<checkpoints.count {
            let step = checkpoints[index]
            let bytes = try author(writer, index)
            XCTAssertEqual(YXMLString.fragment(doc), step.xml, step.label)
            XCTAssertNil(doc.store.pendingStructs, step.label)
            XCTAssertNil(doc.store.pendingDs, step.label)
            XCTAssertEqual(doc.lastTransactionOrigin, .localUser)
            try assertConverges(replica, bytes, xml: step.xml, step.label)
            let web = try XCTUnwrap(Data(base64Encoded: step.updateBase64))
            XCTAssertEqual(bytes == web, identical[index - 1], step.label)
            if bytes != web { differs(index, try YUpdateDecoder.decode(web), try YUpdateDecoder.decode(bytes)) }
        }
    }

    func testTypingMarksLinkAndColor() throws {
        // First typing is exact. Later steps differ because the web inserts plain
        // text then formats it, retaining deleted redundant closers; explicit
        // insertion marks mint the opening format before the string instead.
        try check(
            BlockNote056TypingMarksLinkColorTests.checkpoints, identical: [true, false, false, false],
            differs: { step, web, ours in
                let webContents = structs(web).map { String(describing: $0.content) }.sorted()
                let ourContents = structs(ours).map { String(describing: $0.content) }.sorted()
                switch step {
                case 2:
                    // Same three structs (bold open, "there", bold close), clocked in a different order.
                    XCTAssertEqual(ourContents, webContents)
                    XCTAssertEqual(ourContents.count, 3)
                    XCTAssertNotEqual(structs(ours).map(\.content), structs(web).map(\.content))
                    XCTAssertTrue(web.deleteSet.isEmpty && ours.deleteSet.isEmpty)
                case 3:
                    // The web replaces its bold closer (five structs and a delete); we keep it (four, no delete).
                    XCTAssertEqual([structs(web).count, structs(ours).count], [5, 4])
                    XCTAssertFalse(web.deleteSet.isEmpty)
                    XCTAssertTrue(ours.deleteSet.isEmpty)
                default:
                    // Likewise for the link closer: four web structs and deletes, three of ours and none.
                    XCTAssertEqual([structs(web).count, structs(ours).count], [4, 3])
                    XCTAssertFalse(web.deleteSet.isEmpty)
                    XCTAssertTrue(ours.deleteSet.isEmpty)
                }
            }
        ) { w, step in
            switch step {
            case 1: return try w.replaceText(block: "p-a", range: NSRange(location: 0, length: 0), with: "Hi ")
            case 2:
                return try w.replaceText(
                    block: "p-a", range: NSRange(location: 3, length: 0), with: "there", marks: ["bold": "{}"])
            case 3:
                return try w.transaction { _ in
                    _ = try w.replaceText(block: "p-a", range: NSRange(location: 8, length: 0), with: " ", marks: [:])
                    _ = try w.replaceText(
                        block: "p-a", range: NSRange(location: 9, length: 0), with: "link",
                        marks: ["link": #"{"href":"https://example.com/"}"#])
                }
            default:
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
        try check(
            BlockNote056ChangeBlockTypesTests.checkpoints, identical: [true, false],
            differs: { _, web, ours in
                XCTAssertEqual(ours.blocks, web.blocks)
                XCTAssertTrue(deletes(ours).isSubset(of: deletes(web)))
                XCTAssertFalse(deletes(ours).isEmpty)
                XCTAssertNotEqual(deletes(ours), deletes(web))
            }
        ) { w, step in
            // The same partial props BlockNote's `updateBlock` received.
            try w.setBlockType(
                block: step == 1 ? "p-e" : "li-e", to: step == 1 ? "heading" : "checkListItem",
                props: step == 1 ? [("level", .int(2))] : [("checked", .bool(false))])
        }
    }

    func testMixedInlineEdit() throws {
        // Seven UTF-16 units, one atomic mention, then four units of middle text.
        try check(BlockNote056MixedInlineEditTests.checkpoints, identical: [true]) { w, _ in
            try w.replaceText(block: "p-g", range: NSRange(location: 12, length: 0), with: "!")
        }
    }

    func testCodeBlockFormattingIsANoOpAndStaysPlainAfterConversion() throws {
        try check(BlockNoteWriterCaptures.codeBlockFormat, identical: [true, true]) { writer, step in
            if step == 1 {
                return try writer.formatRange(
                    block: "c", range: NSRange(location: 0, length: 2), attributes: ["bold": "{}", "italic": "{}"])
            }
            return try writer.setBlockType(block: "c", to: "paragraph")
        }
    }

    func testCodeBlockTypingDropsMarksAndStaysPlainAfterConversion() throws {
        // BlockNote's insertContent with explicit marks and insertText with
        // stored marks produced identical plain-text updates in the node capture.
        try check(BlockNoteWriterCaptures.codeBlockTyping, identical: [true, true]) { writer, step in
            if step == 1 {
                return try writer.replaceText(
                    block: "c", range: NSRange(location: 1, length: 0), with: "b",
                    marks: ["bold": "{}", "italic": "{}"])
            }
            return try writer.setBlockType(block: "c", to: "paragraph")
        }
    }

    // MARK: - BlockNote-captured block intents (BlockNoteWriterCaptures)

    /// Authors one intent on the capture's seed and expects BlockNote's XML
    /// (or `expected`), on the writer's replica and on a second replica fed
    /// only the decoded update.
    private func replay(
        _ name: String, expected: String? = nil, file: StaticString = #filePath, line: UInt = #line,
        _ author: (BlockNoteWriter) throws -> Data
    ) throws {
        let capture = try XCTUnwrap(BlockNoteWriterCaptures.captures[name], name)
        let base64 = try XCTUnwrap(BlockNoteWriterCaptures.seeds[capture.seed], name)
        let seed = try YUpdateDecoder.decode(try XCTUnwrap(Data(base64Encoded: base64)))
        let doc = YDoc(clientID: 2, gc: false)
        let replica = YDoc(clientID: 3, gc: false)
        defer {
            doc.destroy()
            replica.destroy()
        }
        try doc.applyUpdate(seed)
        try replica.applyUpdate(seed)
        let bytes = try author(BlockNoteWriter(doc: doc))
        let xml = expected ?? capture.xml
        XCTAssertEqual(YXMLString.fragment(doc), xml, name, file: file, line: line)
        try assertConverges(replica, bytes, xml: xml, name)
    }

    /// Expects `error` and an untouched replica (BlockNote refuses or does something else).
    private func refuse(
        _ name: String, _ error: BlockNoteWriter.Error, file: StaticString = #filePath, line: UInt = #line,
        _ author: (BlockNoteWriter) throws -> Data
    ) throws {
        let capture = try XCTUnwrap(BlockNoteWriterCaptures.captures[name], name)
        let base64 = try XCTUnwrap(BlockNoteWriterCaptures.seeds[capture.seed], name)
        let doc = YDoc(clientID: 2, gc: false)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(try XCTUnwrap(Data(base64Encoded: base64))))
        let before = YXMLString.fragment(doc)
        do {
            _ = try author(BlockNoteWriter(doc: doc))
            XCTFail("Expected \(error): \(name)", file: file, line: line)
        } catch let thrown as BlockNoteWriter.Error {
            XCTAssertEqual(thrown, error, name, file: file, line: line)
        }
        XCTAssertEqual(YXMLString.fragment(doc), before, name, file: file, line: line)
    }

    func testSetBlockTypeToCodeBlockKeepsOnlyPlainText() throws {
        // `updateBlock` keeps ProseMirror's textContent: marks drop, a mention
        // or interlink contributes nothing, inline math keeps its source.
        for name in ["p-mixed-to-code", "p-marked-to-code", "p-empty-to-code", "styled-to-code"] {
            let id = ["p-mixed-to-code": "p-g", "p-marked-to-code": "p-m", "p-empty-to-code": "p-z"][name] ?? "p-p"
            try replay(name) { try $0.setBlockType(block: id, to: "codeBlock") }
        }
    }

    func testSetBlockTypeBetweenInlineTypesKeepsInlineNodes() throws {
        try replay("code-to-p") { try $0.setBlockType(block: "c-1", to: "paragraph") }
        try replay("p-mixed-to-heading") {
            try $0.setBlockType(block: "p-g", to: "heading", props: [("level", .int(3))])
        }
        try replay("p-mixed-to-check") {
            try $0.setBlockType(block: "p-g", to: "checkListItem", props: [("checked", .bool(true))])
        }
    }

    func testSetBlockTypeKeepsCompatibleProps() throws {
        try replay("styled-to-heading") {
            try $0.setBlockType(block: "p-p", to: "heading", props: [("level", .int(2))])
        }
        // textAlignment survives; level is not a numbered-list prop; start takes its default.
        try replay("heading-to-numbered") { try $0.setBlockType(block: "h-2", to: "numberedListItem") }
    }

    func testSetBlockTypePreservesContainerIDAndNestedGroup() throws {
        try replay("nested-to-heading") { writer in
            let root = try XCTUnwrap(writer.doc.share["document-store"])
            guard case .type(let group)? = root.start?.content, let containerItem = group.start,
                case .type(let container) = containerItem.content, let nestedItem = container.start?.right
            else { throw BlockNoteWriter.Error.malformedBlock("seed shape") }
            let idItem = container.map["id"]
            let bytes = try writer.setBlockType(block: "p-k", to: "heading", props: [("level", .int(1))])
            XCTAssertFalse(containerItem.deleted)
            XCTAssertFalse(nestedItem.deleted)
            XCTAssertTrue(container.map["id"] === idItem)
            return bytes
        }
    }

    func testJoinIntoPreviousBlocksLastDescendant() throws {
        try replay("join-into-nested") { try $0.joinBlocks(block: "second") }
        try replay("join-into-deep") { try $0.joinBlocks(block: "second") }
    }

    func testJoinLiftsSourceChildrenIntoItsPlace() throws {
        try replay("join-nested-source") { try $0.joinBlocks(block: "second") }
        try replay("join-nested-both") { try $0.joinBlocks(block: "second") }
    }

    func testJoinIntoEmptyPreviousBlock() throws {
        // Same type and props: the empty block goes and the joined block keeps its id and children.
        try replay("join-into-empty") { try $0.joinBlocks(block: "full") }
        try replay("join-into-empty-with-kids") { try $0.joinBlocks(block: "full") }
        try replay("join-into-empty-nested") { try $0.joinBlocks(block: "second") }
        // Different type or props: the text takes the empty block's type, props and id.
        try replay("join-into-empty-styled") { try $0.joinBlocks(block: "full") }
        try replay("join-into-empty-heading") { try $0.joinBlocks(block: "full") }
    }

    func testJoinCopiesInlineNodes() throws {
        try replay("join-mixed") { try $0.joinBlocks(block: "p-g") }
    }

    func testJoinRefusesCodeBlocks() throws {
        try refuse("join-into-code", .unsupportedBlockType("codeBlock")) { try $0.joinBlocks(block: "after") }
    }

    func testSplitMovesNestedChildrenToNewBlock() throws {
        try replay("split-nested") { try $0.splitBlock(block: "p-n", at: 5, newID: "1") }
        try replay("split-nested-end") { try $0.splitBlock(block: "p-n", at: 10, newID: "1") }
    }

    func testSplitNewBlockTypeAndDefaultProps() throws {
        // Lists make another list item; everything else makes a paragraph. Never the old props.
        try replay("split-styled") { try $0.splitBlock(block: "p-s", at: 5, newID: "1") }
        try replay("split-heading") { try $0.splitBlock(block: "h-1", at: 5, newID: "1") }
        try replay("split-bullet-styled") { try $0.splitBlock(block: "b-1", at: 5, newID: "1") }
        try replay("split-check") { try $0.splitBlock(block: "k-1", at: 5, newID: "1") }
        try replay("split-numbered") { try $0.splitBlock(block: "n-1", at: 5, newID: "1") }
        try replay("split-mixed") { try $0.splitBlock(block: "p-g", at: 9, newID: "1") }
        try replay("split-empty") { try $0.splitBlock(block: "p-e0", at: 0, newID: "1") }
    }

    func testSplitAtStartInsertsEmptyBlockAbove() throws {
        try replay("split-at-start") { try $0.splitBlock(block: "p-t", at: 0, newID: "1") }
        try replay("split-check-at-start") { try $0.splitBlock(block: "k-2", at: 0, newID: "1") }
    }

    func testSplitInsideSurrogatePairSnapsToCodePoint() throws {
        // BlockNote splits "a😀b" between the surrogates and writes U+FFFD into
        // both halves (the capture's XML); the writer snaps back to the pair's start.
        let paragraph = #"<paragraph backgroundColor="default" textAlignment="left" textColor="default">"#
        try replay(
            "split-surrogate",
            expected: #"<blockgroup><blockcontainer id="p-u">"# + paragraph + #"a</paragraph></blockcontainer>"#
                + #"<blockcontainer id="1">"# + paragraph + "😀b</paragraph></blockcontainer></blockgroup>"
        ) { try $0.splitBlock(block: "p-u", at: 2, newID: "1") }
    }

    func testSplitRefusesCodeBlockWhereEnterIsALineBreak() throws {
        try refuse("split-code", .unsupportedBlockType("codeBlock")) {
            try $0.splitBlock(block: "c-2", at: 1, newID: "1")
        }
    }

    func testUnsupportedExistingBlockIsNotMalformed() throws {
        try refuse("divider-seed", .unsupportedBlockType("divider")) {
            try $0.replaceText(block: "d", range: NSRange(location: 0, length: 0), with: "x")
        }
        try refuse("divider-seed", .unsupportedBlockType("divider")) { try $0.joinBlocks(block: "b") }
        try refuse("divider-seed", .duplicateID("d")) { try $0.splitBlock(block: "a", at: 1, newID: "d") }
    }

    func testSetBlockTypeRejectsUnsupportedTarget() throws {
        try refuse("divider-seed", .unsupportedBlockType("divider")) {
            try $0.setBlockType(block: "a", to: "divider")
        }
    }

    func testSameTypeChangesOnlyChangedPropsLikeBlockNote() throws {
        // BlockNote's `updateBlock` bytes: one attribute struct and a one-clock
        // delete of the overwritten value (none at all when nothing changes).
        let cases: [(String, String, [(key: String, value: YAnyValue)], String)] = [
            ("check-toggle", "k-3", [("checked", .bool(true))], "AQECAKgBCwF4AQEBCwE="),
            ("heading-level", "h-3", [("level", .int(2))], "AQECAKgBCwF9AgEBAQsB"),
            ("p-same-type-color", "p-q", [("textColor", .string("green"))], "AQECAKgBBgF3BWdyZWVuAQEBBgE="),
            ("p-same-type", "p-q", [], "AAA="),
        ]
        for (name, id, props, web) in cases {
            let type = ["check-toggle": "checkListItem", "heading-level": "heading"][name] ?? "paragraph"
            try replay(name) { writer in
                let bytes = try writer.setBlockType(block: id, to: type, props: props)
                XCTAssertEqual(bytes.base64EncodedString(), web, name)
                return bytes
            }
        }
    }

    func testSameTypeToggleKeepsConcurrentTyping() throws {
        let capture = try XCTUnwrap(BlockNoteWriterCaptures.captures["check-toggle"])
        let seed = try YUpdateDecoder.decode(
            try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(BlockNoteWriterCaptures.seeds[capture.seed]))))
        let a = YDoc(clientID: 2, gc: false)
        let b = YDoc(clientID: 3, gc: false)
        defer {
            a.destroy()
            b.destroy()
        }
        try a.applyUpdate(seed)
        try b.applyUpdate(seed)
        let toggle = try BlockNoteWriter(doc: a).setBlockType(
            block: "k-3", to: "checkListItem", props: [("checked", .bool(true))])
        let typing = try BlockNoteWriter(doc: b).replaceText(
            block: "k-3", range: NSRange(location: 4, length: 0), with: " done")
        try a.applyUpdate(YUpdateDecoder.decode(typing))
        try b.applyUpdate(YUpdateDecoder.decode(toggle))
        let merged =
            #"<blockgroup><blockcontainer id="k-3"><checklistitem backgroundColor="default" checked="true" "#
            + #"textAlignment="left" textColor="default">Task done</checklistitem></blockcontainer></blockgroup>"#
        XCTAssertEqual(YXMLString.fragment(a), merged)
        XCTAssertEqual(YXMLString.fragment(b), merged)
    }

    func testHardBreakIsOneAtomicUnit() throws {
        // BlockNote stores Shift+Enter as an empty `hardBreak` element: one
        // position, no text (so a code block drops it), kept by split and join.
        try replay("hb-type") { try $0.replaceText(block: "hb", range: NSRange(location: 2, length: 0), with: "Z") }
        try replay("hb-delete") { try $0.replaceText(block: "hb", range: NSRange(location: 1, length: 1), with: "") }
        try replay("hb-split-after") { try $0.splitBlock(block: "hb", at: 2, newID: "1") }
        try replay("hb-split-before") { try $0.splitBlock(block: "hb", at: 1, newID: "1") }
        try replay("hb-join-into") { try $0.joinBlocks(block: "second") }
        try replay("hb-join-source") { try $0.joinBlocks(block: "second") }
        try replay("hb-to-code") { try $0.setBlockType(block: "hb", to: "codeBlock") }
        try replay("hb-to-heading") { try $0.setBlockType(block: "hb", to: "heading", props: [("level", .int(2))]) }
    }
}
