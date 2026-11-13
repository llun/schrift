import XCTest

@testable import Schrift

/// PR12b against real BlockNote 0.56 (`BlockNoteColumnStructureCaptures`):
/// every column-structure command, Move up/down next to and inside a group
/// and the keyboard's moves across a column's edge produce the web's XML and
/// Markdown; what the native editor does not do yet is refused before any
/// write.
final class BlockNoteColumnStructureOracleTests: XCTestCase {
    private func capture(_ name: String) throws -> BlockNoteColumnStructureCaptures.Edit {
        try XCTUnwrap(BlockNoteColumnStructureCaptures.edits.first { $0.name == name }, name)
    }

    private func doc(_ base64: String) throws -> YDoc {
        let doc = YDoc(clientID: 2, gc: false)
        try doc.applyUpdate(YUpdateDecoder.decode(try XCTUnwrap(Data(base64Encoded: base64))))
        return doc
    }

    private func command(_ engine: DocumentEngine, _ id: String, _ kind: NativeEditCommand.Kind) -> NativeEditCommand {
        NativeEditCommand(id: UUID(), baseRevision: engine.revision, blockID: id, kind: kind)
    }

    /// The web's edit `name` against the native command on `id`, with the
    /// group open (`open`) and the engine's own new ids "1", "2", ….
    private func assertWeb(
        _ name: String, _ id: String, _ kind: NativeEditCommand.Kind, open: Bool = true, file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let capture = try capture(name)
        let doc = try doc(capture.seed)
        defer { doc.destroy() }
        let engine = DocumentEngine(doc: doc, surface: HeadlessSurface())
        defer { engine.detach() }
        var next = 0
        engine.newBlockID = {
            next += 1
            return "\(next)"
        }
        if open { XCTAssertTrue(engine.openColumns("cl"), name, file: file, line: line) }
        _ = try engine.applyStructural(command(engine, id, kind), persist: { _ in })
        XCTAssertEqual(YXMLString.fragment(doc), capture.xml, name, file: file, line: line)
        XCTAssertEqual(
            NativeBlockProjection.markdownShadow(doc).map(syncCanonicalMarkdown),
            syncCanonicalMarkdown(capture.markdown),
            name, file: file, line: line)
        XCTAssertFalse(engine.nativeWriteFailed, name, file: file, line: line)
    }

    func testTheSlashMenusColumnsItemsMatchTheWeb() throws {
        // An empty paragraph becomes the group (keeping its id); one with text gets it after it;
        // in a column it goes after the group. One id is spare either way.
        try assertWeb(
            "slashTwoEmpty", "q", .insertColumns(count: 2, ids: ["x", "1", "2", "3", "4"], removing: 0..<0),
            open: false)
        try assertWeb(
            "slashThreeEmpty", "q",
            .insertColumns(count: 3, ids: ["x", "1", "2", "3", "4", "5", "6"], removing: 0..<0),
            open: false)
        try assertWeb(
            "slashTwoAfterText", "lead", .insertColumns(count: 2, ids: ["1", "2", "3", "4", "5"], removing: 0..<0),
            open: false)
        try assertWeb(
            "slashTwoInColumn", "b", .insertColumns(count: 2, ids: ["1", "2", "3", "4", "5"], removing: 0..<0))
    }

    func testColumnCommandsMatchTheWeb() throws {
        try assertWeb("addColumnRight", "cl", .columns(.add(index: 1, columnID: "nc", paragraphID: "np")))
        try assertWeb("addColumnLeft", "cl", .columns(.add(index: 0, columnID: "nc", paragraphID: "np")))
        try assertWeb("addColumnEnd", "cl", .columns(.add(index: 2, columnID: "nc", paragraphID: "np")))
        // Widths averaging outside 0.99...1.01 are normalised first, as JS divides them.
        try assertWeb("addColumnUneven", "cl", .columns(.add(index: 3, columnID: "nc", paragraphID: "np")))
        try assertWeb("removeColumnOfThree", "cl", .columns(.remove(index: 1)))
        // A group left with one column dissolves into its blocks.
        try assertWeb("removeColumnOfTwo", "cl", .columns(.remove(index: 1)))
        try assertWeb("removeFirstColumnOfTwo", "cl", .columns(.remove(index: 0)))
        try assertWeb("moveColumnRight", "cl", .columns(.move(from: 0, to: 1)))
        try assertWeb("moveColumnLeft", "cl", .columns(.move(from: 2, to: 1)))
        try assertWeb("resizeWider", "cl", .columns(.resize(left: 0, leftWidth: 1.25, rightWidth: 0.75)))
        try assertWeb("resizeOdd", "cl", .columns(.resize(left: 0, leftWidth: 1.1, rightWidth: 0.9)))
        // Closed, a group's structure still takes commands (from the document's card).
        try assertWeb("removeColumnOfThree", "cl", .columns(.remove(index: 1)), open: false)
    }

    func testMovesNextToAndInsideAGroupMatchTheWeb() throws {
        try assertWeb("moveDownIntoGroup", "lead", .moveDown)
        try assertWeb("moveUpIntoGroup", "tail", .moveUp)
        try assertWeb("moveDownIntoGroup", "lead", .moveDown, open: false)
        try assertWeb("moveUpFromColumnTop", "c", .moveUp)
        try assertWeb("moveDownFromColumnEnd", "b", .moveDown)
        try assertWeb("moveUpFromFirstColumnTop", "a", .moveUp)
        try assertWeb("moveDownFromLastColumnEnd", "d", .moveDown)
        // A column the move empties keeps one empty paragraph, as ProseMirror refills it.
        try assertWeb("moveUpOnlyBlockOfColumn", "c", .moveUp)
    }

    func testKeyboardMovesAcrossAColumnsEdgeMatchTheWeb() throws {
        try assertWeb("backspaceSecondColumnStart", "c", .join)
        try assertWeb("backspaceFirstColumnStart", "a", .join)
        try assertWeb("backspaceAfterGroup", "tail", .join)
        try assertWeb("backspaceAfterGroup", "tail", .join, open: false)
        try assertWeb("backspaceEmptiesColumn", "c", .join)
        try assertWeb("backspaceEmptiesFirstColumn", "a", .join)
        try assertWeb("backspaceEmptyFirstBlockInColumn", "c", .join)
        try assertWeb(
            "deleteBeforeGroup", "lead",
            .range(
                NativeRangeCommand(startOffset: 6, endBlockID: "cl", endOffset: 0, replacement: "", newBlockIDs: [])),
            open: false)
        // The column's "stay": Enter in an empty last block adds one.
        try assertWeb("enterEmptyLastInColumn", "b", .split(offset: 0, newID: "1"))
    }

    func testDeletingAGroupMatchesTheWeb() throws {
        try assertWeb("deleteGroup", "cl", .deleteBlock, open: false)
    }

    /// Delete at a column's end pulls the next column's first block in on
    /// the web; the column surface holds only its own column, so natively it
    /// is refused before any write (a known limit).
    func testDeleteAtAColumnsEndIsRefused() throws {
        let capture = try capture("deleteAtColumnEnd")
        let doc = try doc(capture.seed)
        defer { doc.destroy() }
        let engine = DocumentEngine(doc: doc, surface: HeadlessSurface())
        defer { engine.detach() }
        XCTAssertTrue(engine.openColumns("cl"))
        let before = YXMLString.fragment(doc)
        let range = NativeEditCommand.Kind.range(
            NativeRangeCommand(startOffset: 6, endBlockID: "c", endOffset: 0, replacement: "", newBlockIDs: []))
        XCTAssertFalse(engine.canApplyStructural(command(engine, "b", range)))
        XCTAssertEqual(YXMLString.fragment(doc), before)
    }

    /// Commands that would break the group, or a group's own moves that would
    /// nest it, are refused before any write.
    func testInvalidStructureIsRefused() throws {
        let capture = try capture("addColumnRight")
        let doc = try doc(capture.seed)
        defer { doc.destroy() }
        let engine = DocumentEngine(doc: doc, surface: HeadlessSurface())
        defer { engine.detach() }
        XCTAssertTrue(engine.openColumns("cl"))
        let before = YXMLString.fragment(doc)
        let refused: [(String, NativeEditCommand.Kind)] = [
            ("cl", .columns(.add(index: 3, columnID: "nc", paragraphID: "np"))),
            ("cl", .columns(.add(index: 1, columnID: "a", paragraphID: "np"))),  // an id in use
            ("cl", .columns(.add(index: 1, columnID: "c2", paragraphID: "np"))),  // a column's id
            ("cl", .columns(.add(index: 1, columnID: "nc", paragraphID: "nc"))),
            ("cl", .columns(.remove(index: 2))),
            ("cl", .columns(.move(from: 0, to: 0))),
            ("cl", .columns(.move(from: 0, to: 2))),
            ("cl", .columns(.resize(left: 0, leftWidth: 1.6, rightWidth: 0.4))),  // below the minimum
            ("cl", .columns(.resize(left: 1, leftWidth: 1, rightWidth: 1))),
            ("cl", .columns(.resize(left: 0, leftWidth: .infinity, rightWidth: 1))),
            ("lead", .columns(.remove(index: 0))),  // not a group
            ("b", .insertColumns(count: 4, ids: Array("123456789".map(String.init)), removing: 0..<0)),
            ("b", .insertColumns(count: 2, ids: ["1", "2", "3", "4"], removing: 0..<0)),  // no spare id
        ]
        for (id, kind) in refused {
            XCTAssertFalse(engine.canApplyStructural(command(engine, id, kind)), "\(id) \(kind)")
        }
        XCTAssertEqual(YXMLString.fragment(doc), before, "nothing was written")
    }

    /// The group as a whole (PR12b): it moves among plain root blocks, is
    /// duplicated with fresh ids for itself, its columns and its blocks, and
    /// its lossless copy pastes as a group at the root (never in a column).
    func testAGroupMovesDuplicatesAndCopiesWhole() throws {
        let capture = try capture("addColumnRight")
        let doc = try doc(capture.seed)
        defer { doc.destroy() }
        let engine = DocumentEngine(doc: doc, surface: HeadlessSurface())
        defer { engine.detach() }
        var next = 0
        engine.newBlockID = {
            next += 1
            return "n\(next)"
        }
        _ = try engine.applyStructural(command(engine, "cl", .moveUp), persist: { _ in })
        XCTAssertTrue(
            YXMLString.fragment(doc).hasPrefix("<blockgroup><columnlist id=\"cl\">"), YXMLString.fragment(doc))
        _ = try engine.applyStructural(command(engine, "cl", .duplicate(newIDs: [])), persist: { _ in })
        let xml = YXMLString.fragment(doc)
        XCTAssertTrue(
            xml.contains("<columnlist id=\"n1\"><column id=\"n2\" width=\"1\"><blockcontainer id=\"n3\">"), xml)
        XCTAssertNotNil(NativeBlockProjection.markdownShadow(doc), "both groups are spelled")
        XCTAssertEqual(ColumnGroup.groups(in: doc).count, 2)
        // Copy and paste after the last block: a third group at the root.
        let payload = try XCTUnwrap(engine.subtreePayload(["cl"]))
        _ = try engine.applyStructural(command(engine, "tail", .insertSubtrees(payload: payload)), persist: { _ in })
        XCTAssertEqual(ColumnGroup.groups(in: doc).count, 3)
        // Never into a column.
        XCTAssertTrue(engine.openColumns("cl"))
        XCTAssertFalse(engine.canApplyStructural(command(engine, "a", .insertSubtrees(payload: payload))))
        // Moving a group next to another group is refused (it would nest).
        XCTAssertFalse(engine.canApplyStructural(command(engine, "n1", .moveUp)))
    }
}
