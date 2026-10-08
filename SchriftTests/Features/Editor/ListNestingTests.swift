import XCTest

@testable import Schrift

/// Nested list items: the pure nesting rules in `EditorBlock.swift` and the
/// editor's indent, outdent, Return and backspace behaviour built on them.
@MainActor
final class ListNestingTests: XCTestCase {
    private func makeViewModel(blocks: [EditorBlock]) -> EditorViewModel {
        let client = DocsAPIClient(
            baseURL: URL(string: "https://docs.example.org/api/v1.0/")!, session: MockURLProtocol.makeSession(),
            cookieProvider: { [] })
        let suiteName = "ListNestingTests.\(UUID().uuidString)"
        let draftStore = PendingDraftStore(userDefaults: UserDefaults(suiteName: suiteName)!)
        let coordinator = DocumentSaveCoordinator(client: client, draftStore: draftStore, backgroundTasks: .noop)
        let viewModel = EditorViewModel(client: client, documentID: UUID(), title: "Doc", saveCoordinator: coordinator)
        viewModel.blocks = blocks
        viewModel.mode = .blocks
        return viewModel
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func bullet(_ text: String, _ indent: Int = 0) -> EditorBlock {
        EditorBlock(kind: .bulletItem, text: text, indent: indent)
    }

    // MARK: - Normalization

    func testNormalizationClampsEachItemToOneLevelBelowTheItemAbove() {
        let blocks = [
            bullet("a", 3),
            bullet("b", 5),
            bullet("c", 1),
            EditorBlock(kind: .paragraph, text: "p", indent: 2),
            bullet("d", 2),
        ]
        XCTAssertEqual(normalizedListIndents(blocks).map(\.indent), [0, 1, 1, 0, 0])
    }

    func testNormalizationNeverExceedsTheMaximum() {
        let blocks = (0...(maxListIndent + 2)).map { bullet("\($0)", $0) }
        XCTAssertEqual(normalizedListIndents(blocks).last?.indent, maxListIndent)
    }

    // MARK: - Indent and outdent rules

    func testTheFirstItemOfAListCannotBeIndented() {
        let blocks = [EditorBlock(kind: .paragraph, text: "p"), bullet("a"), bullet("b")]
        XCTAssertFalse(canIndentListItem(at: 0, in: blocks))
        XCTAssertFalse(canIndentListItem(at: 1, in: blocks))
        XCTAssertTrue(canIndentListItem(at: 2, in: blocks))
    }

    func testAnItemCanGoAtMostOneLevelDeeperThanTheItemAbove() {
        let blocks = [bullet("a"), bullet("b", 1)]
        XCTAssertFalse(canIndentListItem(at: 1, in: blocks))
        XCTAssertTrue(canOutdentListItem(at: 1, in: blocks))
        XCTAssertFalse(canOutdentListItem(at: 0, in: blocks))
    }

    func testChildrenMoveWithTheirItem() {
        let blocks = [bullet("a"), bullet("b"), bullet("b.1", 1), bullet("b.1.1", 2), bullet("c")]
        XCTAssertEqual(shiftingListItem(at: 1, by: 1, in: blocks)?.map(\.indent), [0, 1, 2, 3, 0])
        let indented = [bullet("a"), bullet("b", 1), bullet("b.1", 2), bullet("c")]
        XCTAssertEqual(shiftingListItem(at: 1, by: -1, in: indented)?.map(\.indent), [0, 0, 1, 0])
    }

    /// Outdenting an item makes its later siblings its children, as BlockNote
    /// does: an item never jumps over the siblings below it.
    func testOutdentingAnItemAdoptsItsLaterSiblings() {
        let blocks = [bullet("a"), bullet("b", 1), bullet("c", 1)]
        XCTAssertEqual(shiftingListItem(at: 1, by: -1, in: blocks)?.map(\.indent), [0, 0, 1])
    }

    func testAShiftThatIsNotAllowedReturnsNil() {
        let blocks = [bullet("a"), EditorBlock(kind: .paragraph, text: "p")]
        XCTAssertNil(shiftingListItem(at: 0, by: 1, in: blocks))
        XCTAssertNil(shiftingListItem(at: 0, by: -1, in: blocks))
        XCTAssertNil(shiftingListItem(at: 1, by: 1, in: blocks))
    }

    // MARK: - Editor intents

    func testIndentAndOutdentMoveTheItemAndDirtyTheDocument() {
        let a = bullet("a")
        let b = bullet("b")
        let viewModel = makeViewModel(blocks: [a, b])

        XCTAssertTrue(viewModel.indentListItem(blockID: b.id))
        XCTAssertEqual(viewModel.blocks.map(\.indent), [0, 1])
        XCTAssertTrue(viewModel.isDirty)
        XCTAssertEqual(viewModel.currentMarkdown(), "- a\n  - b\n")

        XCTAssertTrue(viewModel.outdentListItem(blockID: b.id))
        XCTAssertEqual(viewModel.blocks.map(\.indent), [0, 0])
    }

    /// Tab is consumed on every list item, even one that can't move, so it
    /// never types a tab character into a list; anywhere else it falls through.
    func testTheTabKeyIsHandledOnListItemsOnly() {
        let a = bullet("a")
        let paragraph = EditorBlock(kind: .paragraph, text: "p")
        let viewModel = makeViewModel(blocks: [a, paragraph])

        XCTAssertTrue(viewModel.indentListItem(blockID: a.id), "the first item can't move, but Tab is still handled")
        XCTAssertEqual(viewModel.blocks.map(\.indent), [0, 0])
        XCTAssertFalse(viewModel.isDirty, "a move that didn't happen is not an edit")
        XCTAssertFalse(viewModel.indentListItem(blockID: paragraph.id))
        XCTAssertFalse(viewModel.outdentListItem(blockID: paragraph.id))
    }

    func testTheFormattingBarStateFollowsTheFocusedItem() {
        let a = bullet("a")
        let b = bullet("b", 1)
        let paragraph = EditorBlock(kind: .paragraph, text: "p")
        let viewModel = makeViewModel(blocks: [a, b, paragraph])

        viewModel.focusedBlockID = a.id
        XCTAssertTrue(viewModel.focusedBlockIsListItem)
        XCTAssertFalse(viewModel.canIndentFocusedBlock)
        XCTAssertFalse(viewModel.canOutdentFocusedBlock)

        viewModel.focusedBlockID = b.id
        XCTAssertFalse(viewModel.canIndentFocusedBlock)
        XCTAssertTrue(viewModel.canOutdentFocusedBlock)

        viewModel.focusedBlockID = paragraph.id
        XCTAssertFalse(viewModel.focusedBlockIsListItem)
    }

    func testReturnKeepsTheItemsLevel() {
        let a = bullet("a")
        let b = bullet("b", 1)
        let viewModel = makeViewModel(blocks: [a, b])

        viewModel.splitBlock(blockID: b.id, at: 1)

        XCTAssertEqual(viewModel.blocks.map(\.indent), [0, 1, 1])
        XCTAssertEqual(viewModel.blocks[2].kind, .bulletItem)
    }

    func testReturnOnAnEmptyNestedItemStepsOutOneLevel() {
        let a = bullet("a")
        let b = bullet("b", 1)
        let empty = bullet("", 2)
        let viewModel = makeViewModel(blocks: [a, b, empty])

        viewModel.splitBlock(blockID: empty.id, at: 0)
        XCTAssertEqual(viewModel.blocks.map(\.indent), [0, 1, 1])
        XCTAssertEqual(viewModel.blocks[2].kind, .bulletItem)

        viewModel.splitBlock(blockID: empty.id, at: 0)
        XCTAssertEqual(viewModel.blocks.map(\.indent), [0, 1, 0])

        // At the top level, Return on an empty item leaves the list as before.
        viewModel.splitBlock(blockID: empty.id, at: 0)
        XCTAssertEqual(viewModel.blocks[2].kind, .paragraph)
        XCTAssertEqual(viewModel.blocks.count, 3)
    }

    func testBackspaceAtTheStartOfANestedItemOutdentsInsteadOfDeleting() {
        let a = bullet("a")
        let b = bullet("b", 1)
        let viewModel = makeViewModel(blocks: [a, b])

        viewModel.mergeBlockWithPrevious(blockID: b.id)

        XCTAssertEqual(viewModel.blocks.map(\.text), ["a", "b"])
        XCTAssertEqual(viewModel.blocks.map(\.indent), [0, 0])
        XCTAssertEqual(viewModel.blocks[1].kind, .bulletItem)
    }

    /// Converting a parent out of the list leaves no item nested under nothing:
    /// its children are taken up by what now precedes them.
    func testConvertingAParentToAParagraphReparentsItsChildren() {
        let a = bullet("a")
        let b = bullet("b", 1)
        let c = bullet("c", 2)
        let viewModel = makeViewModel(blocks: [a, b, c])

        viewModel.convertBlock(blockID: a.id, to: .paragraph)

        XCTAssertEqual(viewModel.blocks.map(\.indent), [0, 0, 1])
    }

    func testANewListItemInsertedAfterANestedOneJoinsItsLevel() {
        let a = bullet("a")
        let b = bullet("b", 1)
        let viewModel = makeViewModel(blocks: [a, b])

        viewModel.insertBlock(after: b.id, kind: .bulletItem)

        XCTAssertEqual(viewModel.blocks.map(\.indent), [0, 1, 1])
    }

    // MARK: - Live editing

    /// `BlockNoteWrite` diffs a flat block list, so a nested list must take the
    /// classic save and keep the screen off the live stream from then on.
    func testANestedListTakesTheClassicPathAndLeavesLiveEditing() {
        let a = bullet("a")
        let b = bullet("b")
        let viewModel = makeViewModel(blocks: [a, b])
        let live = NestingLiveWriteSpy()
        viewModel.liveWrite = live

        viewModel.updateText(blockID: a.id, text: "a!")
        XCTAssertEqual(live.forwardCount, 1, "a flat list still edits live")
        XCTAssertFalse(viewModel.isDirty)

        viewModel.indentListItem(blockID: b.id)

        XCTAssertEqual(live.forwardCount, 1, "the indent is never forwarded")
        XCTAssertTrue(viewModel.isDirty)
        XCTAssertTrue(viewModel.hasUnmodelableLocalEdit)
        XCTAssertFalse(viewModel.canEngageLiveEditing)
    }
}

@MainActor
private final class NestingLiveWriteSpy: EditorLiveWriteCoordinating {
    var isHandlingLocalEditsLive: Bool { true }
    private(set) var forwardCount = 0
    func forwardLocalEdit() -> Bool {
        forwardCount += 1
        return true
    }
    func flushPendingLiveSnapshot() {}
}
