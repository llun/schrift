import XCTest

@testable import Schrift

/// PR12a against real BlockNote 0.56 column groups (`BlockNoteColumnCaptures`,
/// `@blocknote/xl-multi-column`): every web-authored group is familiar, its
/// save shadow is the exporter's own Markdown, and the native writer's edits
/// inside a column, through an open group, produce the web's XML and Markdown.
/// The web's moves across a column boundary (PR12b) are refused before any
/// write.
final class BlockNoteColumnOracleTests: XCTestCase {
    private func doc(_ base64: String, clientID: UInt = 9) throws -> YDoc {
        let doc = YDoc(clientID: clientID, gc: false)
        try doc.applyUpdate(YUpdateDecoder.decode(try XCTUnwrap(Data(base64Encoded: base64))))
        return doc
    }

    private func group(_ doc: YDoc, _ id: String = "cl") throws -> ColumnGroup {
        let engine = DocumentEngine(doc: doc, surface: HeadlessSurface())
        defer { engine.detach() }
        return try XCTUnwrap(engine.columnGroup(id))
    }

    /// The shadow's classic spellings differ from the export's where they do
    /// at the root too (`- ` for `* `, `_x_` for `*x*`, empty paragraphs
    /// dropped where the export writes blank lines), which `draftSyncDecision`
    /// reads as no change (`syncCanonicalMarkdown`); the rest is byte for byte.
    private static let exactFixtures: Set<String> = ["table", "cellTyping"]

    private func assertShadow(
        _ doc: YDoc, _ markdown: String, _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let shadow = NativeBlockProjection.markdownShadow(doc)
        XCTAssertEqual(
            shadow.map(syncCanonicalMarkdown), syncCanonicalMarkdown(markdown), name, file: file, line: line)
        if Self.exactFixtures.contains(name) { XCTAssertEqual(shadow, markdown, name, file: file, line: line) }
    }

    /// A list restarts at each column, as the export's column frames make it.
    func testListsRestartAtEachColumn() throws {
        let fixture = try XCTUnwrap(BlockNoteColumnCaptures.fixtures.first { $0.name == "listsAcross" })
        let doc = try doc(fixture.update)
        defer { doc.destroy() }
        let shadow = try XCTUnwrap(NativeBlockProjection.markdownShadow(doc))
        XCTAssertTrue(shadow.hasPrefix("1. a\n\n1. b\n2. b2\n\n1. c\n\n1. d\n"), shadow)
        XCTAssertTrue(fixture.markdown.hasPrefix("1. a\n\n1. b\n2. b2\n\n1. c\n\n1. d\n"))
    }

    func testEveryFixtureIsAFamiliarGroupWhoseShadowIsTheExport() throws {
        for fixture in BlockNoteColumnCaptures.fixtures {
            let doc = try doc(fixture.update)
            defer { doc.destroy() }
            XCTAssertEqual(YXMLString.fragment(doc), fixture.xml, fixture.name)
            for (id, group) in ColumnGroup.groups(in: doc) {
                XCTAssertEqual(group.group.familiarity, .familiar, "\(fixture.name) \(id)")
            }
            XCTAssertFalse(ColumnGroup.groups(in: doc).isEmpty, fixture.name)
            let native = NativeBlockProjection.project(doc)
            XCTAssertTrue(native.isFullyModeled, "\(fixture.name): the native projection models the group")
            XCTAssertEqual(
                native.blocks.filter { $0.block.node == "columnList" }.map(\.depth).max(), 0,
                "\(fixture.name): the group is one root block; its blocks are not the document's")
            assertShadow(doc, fixture.markdown, fixture.name)
            // The classic projection keeps a group opaque.
            XCTAssertFalse(YBlockProjection.project(doc).isFullyModeled, fixture.name)
        }
    }

    func testTheGroupReadsColumnsWidthsAndBlocks() throws {
        let widths = try doc(try XCTUnwrap(BlockNoteColumnCaptures.fixtures.first { $0.name == "widths" }).update)
        defer { widths.destroy() }
        let group = try group(widths)
        XCTAssertEqual(group.columns.map(\.id), ["c1", "c2", "c3"])
        XCTAssertEqual(group.columns.map(\.width), [1.5, 0.75, 0.75])
        XCTAssertEqual(group.columns.map(\.blockIDs), [["h", "q"], ["k"], ["cb"]])
        XCTAssertEqual(group.blockCount, 4)

        let two = try doc(try XCTUnwrap(BlockNoteColumnCaptures.fixtures.first { $0.name == "two" }).update)
        defer { two.destroy() }
        let engine = DocumentEngine(doc: two, surface: HeadlessSurface())
        defer { engine.detach() }
        XCTAssertTrue(engine.openColumns("cl"))
        let first = try XCTUnwrap(engine.columnBlocks("c1"))
        XCTAssertEqual(first.map(\.id), ["a", "b", "b2"])
        XCTAssertEqual(first.map(\.depth), [0, 0, 1])
        XCTAssertEqual(first.map(\.parentID), [nil, nil, "b"])
        XCTAssertEqual(try XCTUnwrap(engine.columnBlocks("c2")).map(\.id), ["c", "d"])
        engine.closeColumns("cl")
        XCTAssertNil(engine.columnBlocks("c1"))
    }

    private func command(_ engine: DocumentEngine, _ id: String, _ kind: NativeEditCommand.Kind) -> NativeEditCommand {
        NativeEditCommand(id: UUID(), baseRevision: engine.revision, blockID: id, kind: kind)
    }

    private func replace(_ engine: DocumentEngine, _ id: String, _ range: Range<Int>, _ text: String) throws {
        try engine.replaceText(
            NativeEditCommand(id: UUID(), baseRevision: engine.revision, blockID: id, range: range, replacement: text),
            persist: { _ in })
    }

    /// The native writer, addressing an open group's blocks, against the
    /// web's own edits: the same XML, and the shadow the web's Markdown.
    func testColumnEditsMatchTheWebCaptures() throws {
        func edited(_ name: String, _ body: (DocumentEngine) throws -> Void) throws {
            let capture = try XCTUnwrap(BlockNoteColumnCaptures.edits.first { $0.name == name })
            let doc = try doc(capture.seed, clientID: 2)
            defer { doc.destroy() }
            let surface = HeadlessSurface()
            let engine = DocumentEngine(doc: doc, surface: surface)
            defer { engine.detach() }
            XCTAssertTrue(engine.openColumns("cl"), name)
            try body(engine)
            XCTAssertEqual(YXMLString.fragment(doc), capture.xml, name)
            assertShadow(doc, capture.markdown, name)
            XCTAssertFalse(engine.nativeWriteFailed, name)
        }
        func apply(_ engine: DocumentEngine, _ id: String, _ kind: NativeEditCommand.Kind) throws {
            _ = try engine.applyStructural(command(engine, id, kind), persist: { _ in })
        }
        try edited("typeMiddle") { try replace($0, "a", 2..<2, "X") }
        try edited("enterSplit") { try apply($0, "a", .split(offset: 2, newID: "1")) }
        try edited("enterAtColumnEnd") { engine in
            try apply(engine, "b", .split(offset: 6, newID: "1"))
            try replace(engine, "1", 0..<0, "n")
        }
        // The column's `emptyChildEnter: "stay"`: Enter in an empty block adds one.
        try edited("enterInEmptyColumnBlock") { try apply($0, "b", .split(offset: 0, newID: "1")) }
        try edited("enterListItem") { try apply($0, "d", .split(offset: 4, newID: "1")) }
        try edited("enterEmptyListItem") { try apply($0, "d2", .split(offset: 0, newID: "1")) }
        try edited("enterEmptyNested") { try apply($0, "k", .split(offset: 0, newID: "1")) }
        try edited("backspaceJoin") { try apply($0, "b", .join) }
        try edited("tabNest") { try apply($0, "b", .indent) }
        try edited("shiftTabLastChild") { try apply($0, "k2", .outdent) }
        try edited("shiftTabOnlyChild") { try apply($0, "k", .outdent) }
        try edited("boldPart") { engine in
            try apply(
                engine, "c",
                .marks(
                    NativeMarkCommand(
                        startOffset: 0, endBlockID: "c", endOffset: 2,
                        attributes: [TextMark(key: "bold", valueJSON: "{}")])))
        }
        try edited("toHeading") { engine in
            try apply(
                engine, "c",
                .blockType(node: "heading", props: [ProjectedProp(key: "level", value: .int(2))], removing: 0..<0))
        }
        try edited("rangeDelete") { engine in
            try apply(
                engine, "a",
                .range(
                    NativeRangeCommand(startOffset: 2, endBlockID: "b", endOffset: 3, replacement: "", newBlockIDs: [])
                ))
        }
        // A table in a column: its cell through the table editor's paragraph ids.
        try edited("cellTyping") { engine in
            XCTAssertTrue(engine.openTable("tbl"))
            let ids = try XCTUnwrap(engine.tableParagraphs("tbl")).map(\.id)
            try replace(engine, ids[0], 1..<1, "Z")
        }
    }

    /// The web moves a block across a column boundary (into the previous
    /// column, out of the group, the block after the group into its last
    /// column) or does nothing; natively each is refused before any write
    /// (PR12b ports the moves).
    func testBoundaryCommandsAreRefusedBeforeAnyWrite() throws {
        let capture = try XCTUnwrap(BlockNoteColumnCaptures.edits.first { $0.name == "typeMiddle" })
        let doc = try doc(capture.seed, clientID: 2)
        defer { doc.destroy() }
        let engine = DocumentEngine(doc: doc, surface: HeadlessSurface())
        defer { engine.detach() }
        XCTAssertTrue(engine.openColumns("cl"))
        let before = YXMLString.fragment(doc)
        // The moves across a column's edge are PR12b's (`BlockNoteColumnStructureOracleTests`).
        let refused: [(String, NativeEditCommand.Kind)] = [
            // Shift-Tab at a column's top: the web does nothing either.
            ("b", .outdent),
            // A range or a mark change never crosses into another column or the document.
            (
                "b",
                .range(
                    NativeRangeCommand(startOffset: 0, endBlockID: "c", endOffset: 1, replacement: "", newBlockIDs: []))
            ),
            (
                "lead",
                .range(
                    NativeRangeCommand(startOffset: 0, endBlockID: "a", endOffset: 1, replacement: "", newBlockIDs: []))
            ),
            (
                "b",
                .marks(
                    NativeMarkCommand(
                        startOffset: 0, endBlockID: "c", endOffset: 2,
                        attributes: [TextMark(key: "bold", valueJSON: "{}")]))
            ),
            // Nothing nests under a group.
            ("cl", .indent),
        ]
        for (id, kind) in refused {
            XCTAssertFalse(engine.canApplyStructural(command(engine, id, kind)), "\(id) \(kind)")
            XCTAssertThrowsError(
                try engine.applyStructural(command(engine, id, kind), persist: { _ in }), "\(id) \(kind)")
        }
        XCTAssertEqual(YXMLString.fragment(doc), before, "nothing was written")
        XCTAssertFalse(engine.nativeWriteFailed)
        // A column's last block stays: deleting the only block of a column is refused.
        let single = try XCTUnwrap(BlockNoteColumnCaptures.edits.first { $0.name == "enterEmptyListItem" })
        let other = try self.doc(single.seed, clientID: 2)
        defer { other.destroy() }
        let second = DocumentEngine(doc: other, surface: HeadlessSurface())
        defer { second.detach() }
        XCTAssertTrue(second.openColumns("cl"))
        XCTAssertFalse(second.canApplyStructural(command(second, "a", .deleteBlock)))
        XCTAssertTrue(second.canApplyStructural(command(second, "d2", .deleteBlock)), "a column of two may lose one")
    }

    /// Two columns sharing an id are unfamiliar: nothing could tell their
    /// surfaces apart.
    func testDuplicateColumnIdsAreUnfamiliar() throws {
        let fixture = try XCTUnwrap(BlockNoteColumnCaptures.fixtures.first { $0.name == "two" })
        let doc = try doc(fixture.update, clientID: 3)
        defer { doc.destroy() }
        XCTAssertTrue(try group(doc).isFamiliar)
        let root = try XCTUnwrap(doc.share[BlockNoteYjs.fragmentField])
        guard case .type(let rootGroup)? = YBlockProjection.children(of: root, includeFormats: false).first?.content,
            case .type(let list) = YBlockProjection.children(of: rootGroup, includeFormats: false)[1].content
        else { return XCTFail("no group") }
        let columns = ColumnGroup.columnTypes(of: list)
        try doc.transact { tx in try YWrite.mapSet(tx, on: columns[1], key: "id", .any([.string("c1")])) }
        XCTAssertEqual(try group(doc).familiarity, .unfamiliar("duplicate column id"))
        XCTAssertNil(NativeBlockProjection.markdownShadow(doc), "the document is read-only")
    }

    /// Closed, a group's blocks address nothing; its text is preserved.
    func testAClosedGroupsBlocksAreNotTargets() throws {
        let capture = try XCTUnwrap(BlockNoteColumnCaptures.edits.first { $0.name == "typeMiddle" })
        let doc = try doc(capture.seed, clientID: 2)
        defer { doc.destroy() }
        let engine = DocumentEngine(doc: doc, surface: HeadlessSurface())
        defer { engine.detach() }
        let before = YXMLString.fragment(doc)
        XCTAssertThrowsError(try replace(engine, "a", 0..<0, "x"))
        XCTAssertFalse(engine.canApplyStructural(command(engine, "a", .split(offset: 1, newID: "n"))))
        // The document's own blocks type around the group.
        try replace(engine, "tail", 5..<5, "!")
        XCTAssertNotEqual(YXMLString.fragment(doc), before)
        XCTAssertTrue(
            YXMLString.fragment(doc).contains(
                "<blockcontainer id=\"a\"><paragraph backgroundColor=\"default\" textAlignment=\"left\" textColor=\"default\">Left</paragraph>"
            ))
    }

    /// The real test document (`.review/state.bin`, git-ignored) when present:
    /// its web group (one column holds a captioned image) is preserved and,
    /// since PR13a, modeled; the document's interlink, math and diagram keep
    /// it without a shadow.
    func testTheRealCaptureGroupIsPreserved() throws {
        let review = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".review")
        guard let state = try? Data(contentsOf: review.appendingPathComponent("state.bin")) else {
            throw XCTSkip("no .review capture")
        }
        let doc = YDoc(clientID: 9, gc: false)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(state))
        let groups = ColumnGroup.groups(in: doc)
        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.values.first)
        XCTAssertEqual(group.group.columns.count, 2)
        XCTAssertEqual(group.blocks.map { $0.map(\.node) }, [["paragraph"], ["paragraph", "image"]])
        let native = NativeBlockProjection.project(doc)
        let card = try XCTUnwrap(native.blocks.first { $0.block.node == "columnList" })
        XCTAssertEqual(card.block.fidelity, .modeled)
        XCTAssertNil(NativeBlockProjection.markdownShadow(doc))
        // The index is canonical: the document's other blocks are addressable.
        let engine = DocumentEngine(doc: doc, surface: HeadlessSurface())
        defer { engine.detach() }
        XCTAssertNotNil(engine.columnGroup(group.group.id))
    }
}
