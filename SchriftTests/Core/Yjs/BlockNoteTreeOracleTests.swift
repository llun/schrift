import XCTest

@testable import Schrift

/// `BlockNoteTreeCommands` against real BlockNote 0.56.0 + yjs 13.6.33
/// captures: `f-sink-bullet` (Tab, prosemirror-schema-list `sinkListItem`)
/// and `enter-empty-nested` (Enter on an empty nested block, `liftListItem`).
/// Each is checked on the writer's replica, on a second replica fed only the
/// update, and through the native engine's own command path. The rest pins
/// `liftToOuterList`'s sibling and child rules, for which no capture exists.
@MainActor
final class BlockNoteTreeOracleTests: XCTestCase {
    private static let props = #"backgroundColor="default" textAlignment="left" textColor="default""#

    private func seed(_ base64: String) throws -> YUpdate {
        try YUpdateDecoder.decode(try XCTUnwrap(Data(base64Encoded: base64)))
    }

    private func assertOracle(
        seed base64: String, xml: String, file: StaticString = #filePath, line: UInt = #line,
        _ author: (BlockNoteWriter) throws -> Data
    ) throws {
        let doc = YDoc(clientID: 2, gc: false)
        let replica = YDoc(clientID: 3, gc: false)
        defer {
            doc.destroy()
            replica.destroy()
        }
        try doc.applyUpdate(try seed(base64))
        try replica.applyUpdate(try seed(base64))
        let update = try author(BlockNoteWriter(doc: doc))
        XCTAssertEqual(YXMLString.fragment(doc), xml, file: file, line: line)
        try replica.applyUpdate(YUpdateDecoder.decode(update))
        XCTAssertEqual(YXMLString.fragment(replica), xml, file: file, line: line)
        XCTAssertNil(replica.store.pendingStructs, file: file, line: line)
        XCTAssertNil(replica.store.pendingDs, file: file, line: line)
    }

    /// The engine's command (validation, then the writer) on a native session.
    private func assertEngineOracle(
        seed base64: String, xml: String, blockID: String, kind: NativeEditCommand.Kind,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let state = try XCTUnwrap(Data(base64Encoded: base64))
        let session = try NativeEditorSession(state: state)
        defer { session.close() }
        var updates: [Data] = []
        try session.engine.applyStructural(
            NativeEditCommand(id: UUID(), baseRevision: 0, blockID: blockID, kind: kind)
        ) { updates.append($0) }
        XCTAssertEqual(updates.count, 1, file: file, line: line)
        let replica = YDoc(clientID: 9, gc: false)
        defer { replica.destroy() }
        try replica.applyUpdate(YUpdateDecoder.decode(state))
        try replica.applyUpdate(YUpdateDecoder.decode(try XCTUnwrap(updates.first)))
        XCTAssertEqual(YXMLString.fragment(replica), xml, file: file, line: line)
        XCTAssertEqual(
            session.surface.blocks, NativeBlockProjection.project(replica).blocks.map(BlockSnapshot.init),
            file: file, line: line)
    }

    func testSinkMatchesTheSinkBulletCapture() throws {
        let checkpoints = BlockNote056SinkBulletTests.checkpoints
        try assertOracle(seed: checkpoints[0].updateBase64, xml: checkpoints[1].xml) {
            try $0.sinkListItem(block: "li-f-second")
        }
        try assertEngineOracle(
            seed: checkpoints[0].updateBase64, xml: checkpoints[1].xml, blockID: "li-f-second", kind: .indent)
    }

    func testLiftMatchesTheEnterEmptyNestedCapture() throws {
        let capture = try XCTUnwrap(BlockNoteWriterCaptures.captures["enter-empty-nested"])
        let base64 = try XCTUnwrap(BlockNoteWriterCaptures.seeds[capture.seed])
        try assertOracle(seed: base64, xml: capture.xml) { try $0.liftListItem(block: "kid") }
        // Return in the empty nested paragraph and Shift-Tab write the same tree.
        try assertEngineOracle(
            seed: base64, xml: capture.xml, blockID: "kid", kind: .split(offset: 0, newID: "unused"))
        try assertEngineOracle(seed: base64, xml: capture.xml, blockID: "kid", kind: .outdent)
    }

    // MARK: - liftToOuterList without a capture

    private func doc(_ blocks: [BlockNoteBlock]) throws -> YDoc {
        let doc = YDoc(clientID: 2, gc: false)
        try doc.applyUpdate(YUpdateDecoder.decode(BlockNoteYjs.encode(blocks, clientID: 1)))
        return doc
    }

    private func block(_ id: String, _ children: [BlockNoteBlock] = []) -> BlockNoteBlock {
        BlockNoteBlock(
            node: "paragraph",
            props: [
                ("backgroundColor", .string("default")), ("textColor", .string("default")),
                ("textAlignment", .string("left")),
            ], runs: [InlineRun(id)], id: id, children: children)
    }

    private func xml(_ id: String, _ children: String = "") -> String {
        #"<blockcontainer id="\#(id)"><paragraph \#(Self.props)>\#(id)</paragraph>\#(children)</blockcontainer>"#
    }

    /// The following siblings become the lifted block's last children, after
    /// its own; the siblings before it stay with the parent.
    func testLiftTakesTheFollowingSiblingsAfterItsOwnChildren() throws {
        let doc = try doc([block("p", [block("a"), block("b", [block("b1")]), block("c")]), block("t")])
        defer { doc.destroy() }
        try BlockNoteWriter(doc: doc).liftListItem(block: "b")
        XCTAssertEqual(
            YXMLString.fragment(doc),
            "<blockgroup>" + xml("p", "<blockgroup>" + xml("a") + "</blockgroup>")
                + xml("b", "<blockgroup>" + xml("b1") + xml("c") + "</blockgroup>") + xml("t") + "</blockgroup>")
    }

    /// Sinking under a sibling that already has children appends to them.
    func testSinkAppendsToTheSiblingsChildren() throws {
        let doc = try doc([block("a", [block("a1")]), block("b", [block("b1")])])
        defer { doc.destroy() }
        try BlockNoteWriter(doc: doc).sinkListItem(block: "b")
        XCTAssertEqual(
            YXMLString.fragment(doc),
            "<blockgroup>"
                + xml(
                    "a",
                    "<blockgroup>" + xml("a1") + xml("b", "<blockgroup>" + xml("b1") + "</blockgroup>")
                        + "</blockgroup>") + "</blockgroup>")
    }

    /// `mergeIntoParent` (no capture exists for a nested-source Backspace):
    /// the content joins the parent's end and the block's children take its
    /// place; a sole child without children takes the group with it.
    /// A sole child whose own nested group is empty leaves no empty group
    /// behind in its parent (review round 1).
    func testMergeIntoParentRemovesAGroupLeftEmptyByAChildWithAnEmptyGroup() throws {
        let doc = try doc([block("q", [block("only")])])
        defer { doc.destroy() }
        let writer = BlockNoteWriter(doc: doc)
        let only = try writer.find("only")
        try writer.transaction { tx in
            try YWrite.insertAfter(
                tx, into: only.container, after: only.elementItem,
                [.type(YType(typeRef: .xmlElement(nodeName: "blockGroup")))])
        }
        try writer.mergeIntoParent(block: "only")
        XCTAssertEqual(
            YXMLString.fragment(doc),
            #"<blockgroup><blockcontainer id="q"><paragraph \#(Self.props)>qonly</paragraph></blockcontainer></blockgroup>"#
        )
    }

    func testMergeIntoParentPromotesChildrenAndRemovesAnEmptiedGroup() throws {
        let doc = try doc([block("p", [block("a", [block("a1")]), block("b")])])
        defer { doc.destroy() }
        let writer = BlockNoteWriter(doc: doc)
        try writer.mergeIntoParent(block: "a")
        let merged = #"<blockcontainer id="p"><paragraph \#(Self.props)>pa</paragraph>"#
        XCTAssertEqual(
            YXMLString.fragment(doc),
            "<blockgroup>" + merged + "<blockgroup>" + xml("a1") + xml("b")
                + "</blockgroup></blockcontainer></blockgroup>")
        XCTAssertThrowsError(try writer.mergeIntoParent(block: "b")) {
            XCTAssertEqual($0 as? BlockNoteWriter.Error, .noPreviousBlock("b"), "not a first child")
        }
        let sole = try self.doc([block("q", [block("only")])])
        defer { sole.destroy() }
        try BlockNoteWriter(doc: sole).mergeIntoParent(block: "only")
        XCTAssertEqual(
            YXMLString.fragment(sole),
            #"<blockgroup><blockcontainer id="q"><paragraph \#(Self.props)>qonly</paragraph></blockcontainer></blockgroup>"#
        )
    }

    func testTheFirstBlockAndARootBlockAreRefusedBeforeAnyWrite() throws {
        let doc = try doc([block("a"), block("b")])
        defer { doc.destroy() }
        let writer = BlockNoteWriter(doc: doc)
        let before = YXMLString.fragment(doc)
        XCTAssertThrowsError(try writer.sinkListItem(block: "a")) {
            XCTAssertEqual($0 as? BlockNoteWriter.Error, .noPreviousBlock("a"))
        }
        XCTAssertThrowsError(try writer.liftListItem(block: "b")) {
            XCTAssertEqual($0 as? BlockNoteWriter.Error, .unsupportedBlockType("paragraph"))
        }
        XCTAssertEqual(YXMLString.fragment(doc), before)
    }
}
