import XCTest

@testable import Schrift

/// Patch building is O(touched blocks), not O(document): a keystroke projects
/// no block at all, and a structural change projects only the blocks it
/// inserted or rebuilt.
@MainActor
final class DocumentEnginePatchCostTests: DocumentEngineTestCase {
    private func makeLargeDoc(blocks count: Int) throws -> YDoc {
        let blocks = (0..<count).map { index in
            BlockNoteBlock(
                node: "paragraph", props: Self.paragraphProps,
                runs: [InlineRun("Paragraph number \(index) with some text in it.")],
                id: String(format: "b0000000-0000-4000-8000-%012d", index))
        }
        return try makeDoc(blocks, clientID: 1)
    }

    func testTypingProjectsNoBlock() throws {
        let doc = try makeLargeDoc(blocks: 60)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        let before = engine.projectedBlockCount

        try engine.replaceText(block: "b0000000-0000-4000-8000-000000000030", range: 5..<5, with: "X")

        XCTAssertEqual(engine.projectedBlockCount, before, "a keystroke must not project a block")
        XCTAssertLessThanOrEqual(engine.visitedTypeCount, 2, "one XmlText, at most one more type")
        assertSurfaceMatchesProjection(surface, doc, "after typing in a 60-block document")
    }

    func testSplitProjectsOnlyTheNewBlock() throws {
        let doc = try makeLargeDoc(blocks: 60)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        let before = engine.projectedBlockCount

        try engine.splitBlock(
            block: "b0000000-0000-4000-8000-000000000030", at: 5,
            newID: "b0000000-0000-4000-8000-0000000000aa")

        XCTAssertEqual(engine.projectedBlockCount - before, 1, "only the inserted block is projected")
        assertSurfaceMatchesProjection(surface, doc, "after the split")
    }

    func testTypeChangeProjectsOnlyThatBlock() throws {
        let doc = try makeLargeDoc(blocks: 60)
        defer { doc.destroy() }
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        let before = engine.projectedBlockCount

        try engine.setBlockType(
            block: "b0000000-0000-4000-8000-000000000030", to: "heading", props: [("level", .int(2))])

        XCTAssertEqual(engine.projectedBlockCount - before, 1)
        assertSurfaceMatchesProjection(surface, doc, "after the type change")
    }
}
