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

    func testMediaDirectlyUnderACompletedItemIsHiddenWithIt() {
        let blocks = parseEditorBlocks(
            """
            - [x] Done

            ![](https://docs.llun.dev/media/one.jpg)

            ![](https://docs.llun.dev/media/two.jpg)

            - [ ] Open

            ![](https://docs.llun.dev/media/three.jpg)
            """)
        XCTAssertEqual(blocks.count, 5)
        let filtered = ChecklistReadingPresentation(blocks: blocks, hidingCompleted: true)
        XCTAssertEqual(filtered.rows.map(\.sourceIndex), [3, 4])
        XCTAssertEqual(filtered.hiddenCount, 1, "The notice counts completed items, not the media hidden with them")
        XCTAssertEqual(
            ChecklistReadingPresentation(blocks: blocks, hidingCompleted: false).rows.map(\.sourceIndex),
            Array(blocks.indices))
    }

    func testAttachmentUnderACompletedItemIsHiddenWithIt() {
        let blocks = [
            EditorBlock(kind: .checklistItem(checked: true), text: "Done"),
            EditorBlock(kind: .attachment(name: "a.pdf", url: "https://docs.llun.dev/media/a.pdf"), text: ""),
            EditorBlock(kind: .checklistItem(checked: false), text: "Open"),
        ]
        let filtered = ChecklistReadingPresentation(blocks: blocks, hidingCompleted: true)
        XCTAssertEqual(filtered.rows.map(\.sourceIndex), [2])
    }

    func testOnlyTheMediaRunIsHiddenNotWhatFollowsIt() {
        let blocks = parseEditorBlocks(
            """
            - [x] Done

            ![](https://docs.llun.dev/media/one.jpg)

            A paragraph about something else

            ![](https://docs.llun.dev/media/two.jpg)
            """)
        XCTAssertEqual(blocks.count, 4)
        XCTAssertEqual(
            ChecklistReadingPresentation(blocks: blocks, hidingCompleted: true).rows.map(\.sourceIndex), [2, 3])
    }

    func testMediaUnderAnOpenItemOrWithNoItemAboveStaysVisible() {
        let blocks = parseEditorBlocks(
            """
            ![](https://docs.llun.dev/media/zero.jpg)

            - [ ] Open

            ![](https://docs.llun.dev/media/one.jpg)
            """)
        XCTAssertEqual(
            ChecklistReadingPresentation(blocks: blocks, hidingCompleted: true).rows.map(\.sourceIndex), [0, 1, 2])
    }

    func testAQueuedPhotoUnderACompletedItemStaysVisibleForItsActions() {
        let placeholder = "schrift-attachment://11111111-1111-4111-8111-111111111111"
        let blocks = [
            EditorBlock(kind: .checklistItem(checked: true), text: "Done"),
            EditorBlock(kind: .image(alt: "", url: placeholder), text: ""),
        ]
        XCTAssertNotNil(pendingAttachmentID(fromPlaceholderURL: placeholder))
        XCTAssertEqual(
            ChecklistReadingPresentation(blocks: blocks, hidingCompleted: true).rows.map(\.sourceIndex), [1])
    }

    /// A completed item's nested items are part of it: they hide with it rather
    /// than drawing indented under whichever item precedes it. Siblings at its
    /// level and above stay, and the count is still completed items only.
    func testACompletedItemHidesItsNestedItems() {
        let blocks = [
            EditorBlock(kind: .checklistItem(checked: false), text: "open"),
            EditorBlock(kind: .checklistItem(checked: true), text: "done", indent: 1),
            EditorBlock(kind: .checklistItem(checked: false), text: "sub-open", indent: 2),
            EditorBlock(kind: .checklistItem(checked: true), text: "sub-done", indent: 2),
            EditorBlock(kind: .checklistItem(checked: false), text: "sibling", indent: 1),
            EditorBlock(kind: .checklistItem(checked: false), text: "next"),
        ]
        let filtered = ChecklistReadingPresentation(blocks: blocks, hidingCompleted: true)
        XCTAssertEqual(filtered.rows.map(\.sourceIndex), [0, 4, 5])
        XCTAssertEqual(filtered.hiddenCount, 2)
        XCTAssertEqual(
            ChecklistReadingPresentation(blocks: blocks, hidingCompleted: false).rows.map(\.sourceIndex),
            Array(blocks.indices))
    }

    // MARK: - Nested leaves

    private func photo(_ name: String, _ indent: Int = 0) -> EditorBlock {
        EditorBlock(kind: .image(alt: name, url: "https://docs.llun.dev/media/\(name).jpg"), indent: indent)
    }

    /// A photo or file nested under a completed item is part of it, like a nested
    /// item, and hides with it. The count stays completed items only.
    func testACompletedItemHidesTheLeavesNestedUnderIt() {
        let blocks = [
            EditorBlock(kind: .checklistItem(checked: true), text: "done"),
            photo("one", 1),
            EditorBlock(kind: .attachment(name: "a.pdf", url: "https://docs.llun.dev/media/a.pdf"), indent: 1),
            EditorBlock(kind: .paragraph, text: "[site](https://example.com)", indent: 1),
            EditorBlock(kind: .checklistItem(checked: false), text: "open"),
        ]
        let filtered = ChecklistReadingPresentation(blocks: blocks, hidingCompleted: true)
        XCTAssertEqual(filtered.rows.map(\.sourceIndex), [4])
        XCTAssertEqual(filtered.hiddenCount, 1)
    }

    /// A queued photo keeps its Retry/Remove card reachable even inside a hidden
    /// subtree — and the subtree goes on hiding around it.
    func testAQueuedPhotoInsideAHiddenSubtreeStaysVisible() {
        let placeholder = "schrift-attachment://11111111-1111-4111-8111-111111111111"
        let blocks = [
            EditorBlock(kind: .checklistItem(checked: true), text: "done"),
            photo("one", 1),
            EditorBlock(kind: .image(alt: "", url: placeholder), indent: 1),
            photo("two", 1),
            EditorBlock(kind: .checklistItem(checked: true), text: "sub-done", indent: 1),
            EditorBlock(kind: .checklistItem(checked: false), text: "open"),
        ]
        let filtered = ChecklistReadingPresentation(blocks: blocks, hidingCompleted: true)
        XCTAssertEqual(filtered.rows.map(\.sourceIndex), [2, 5])
        XCTAssertEqual(filtered.hiddenCount, 2)
    }

    /// A nested leaf after a hidden nested item is that item's *sibling*, under an
    /// open parent, and stays. Flat media after it is still read as the item's own
    /// — the server's export flattens a nested photo to exactly that shape.
    func testOnlyFlatMediaAfterAHiddenItemIsHiddenWithIt() {
        let blocks = [
            EditorBlock(kind: .checklistItem(checked: false), text: "open"),
            EditorBlock(kind: .checklistItem(checked: true), text: "done", indent: 1),
            photo("sibling", 1),
            EditorBlock(kind: .checklistItem(checked: true), text: "done too", indent: 1),
            photo("flat"),
            EditorBlock(kind: .checklistItem(checked: false), text: "next"),
        ]
        XCTAssertEqual(
            ChecklistReadingPresentation(blocks: blocks, hidingCompleted: true).rows.map(\.sourceIndex), [0, 2, 5])
    }
}
