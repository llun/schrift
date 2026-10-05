import XCTest

@testable import Schrift

final class ChecklistReadingPresentationTests: XCTestCase {
    func testOnlyCompletedChecklistBlocksAreHiddenWithoutChangingSourceOrderOrContent() {
        let blocks = parseEditorBlocks(
            """
            # Plan

            - [x] Finished **task**
            - [ ] Next task

            1. First
            2. Second

            ~~Completed-looking prose~~

            ```md
            - [x] Literal task
            ```

            | Preserve | table |
            | --- | --- |
            | one | two |
            """)
        let original = blocks
        let markdown = serializeMarkdown(blocks)
        // Unknown multiline blocks mint fresh fallback paragraph IDs in the existing
        // encoder. Their verbatim preservation is asserted above/below; compare bytes
        // for modeled blocks, whose BlockNote IDs are the source EditorBlock IDs.
        let modeled = blocks.filter { $0.kind != .unknown }
        let encoded = BlockNoteYjs.encode(MarkdownYjs.blockNoteBlocks(from: modeled), clientID: 42)
        let filtered = ChecklistReadingPresentation(blocks: blocks, hidingCompleted: true)
        XCTAssertEqual(filtered.hiddenCount, 1)
        XCTAssertEqual(filtered.rows.map(\.sourceIndex), blocks.indices.filter { $0 != 1 })
        XCTAssertEqual(filtered.rows.map(\.block), blocks.enumerated().filter { $0.offset != 1 }.map(\.element))
        XCTAssertEqual(blocks, original)
        XCTAssertEqual(serializeMarkdown(blocks), markdown)
        XCTAssertEqual(
            BlockNoteYjs.encode(MarkdownYjs.blockNoteBlocks(from: blocks.filter { $0.kind != .unknown }), clientID: 42),
            encoded)
        XCTAssertEqual(ChecklistReadingPresentation(blocks: blocks, hidingCompleted: false).rows.map(\.block), original)
    }

    func testAllCompletedIsHiddenRatherThanAnEmptyDocumentAndCanBeRevealed() {
        let blocks = parseEditorBlocks("- [x] One\n- [x] Two")
        let filtered = ChecklistReadingPresentation(blocks: blocks, hidingCompleted: true)
        XCTAssertTrue(filtered.hasChecklistItems)
        XCTAssertTrue(filtered.rows.isEmpty)
        XCTAssertEqual(filtered.hiddenCount, 2)
        XCTAssertEqual(ChecklistReadingPresentation(blocks: blocks, hidingCompleted: false).rows.map(\.block), blocks)
        XCTAssertFalse(ChecklistReadingPresentation(blocks: [], hidingCompleted: true).hasChecklistItems)
    }

    func testProjectionRecomputesForNewCheckedStatesInsertionsAndRemoval() {
        var blocks = parseEditorBlocks("- [x] One\n- [ ] Two")
        let firstID = blocks[0].id
        blocks[0].kind = .checklistItem(checked: false)
        blocks[1].kind = .checklistItem(checked: true)
        blocks.append(EditorBlock(kind: .checklistItem(checked: false), text: "Three"))
        XCTAssertEqual(
            ChecklistReadingPresentation(blocks: blocks, hidingCompleted: true).rows.map(\.id),
            [firstID, blocks[2].id])
        blocks.removeFirst()
        XCTAssertEqual(
            ChecklistReadingPresentation(blocks: blocks, hidingCompleted: true).rows.map(\.id), [blocks[1].id])
    }
}
