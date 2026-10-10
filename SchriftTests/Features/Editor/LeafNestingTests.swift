import XCTest

@testable import Schrift

/// Images, attachments and link lines nested under a list item: the pure rules in
/// `EditorBlock.swift` (`blockNestsAsLeaf`, `nestingBase`, the normalization,
/// `leafIndentRange` and the leaf indent/outdent) and the editor intents built on them.
@MainActor
final class LeafNestingTests: XCTestCase {
    private var suiteNames: [String] = []

    private func makeViewModel(blocks: [EditorBlock]) -> EditorViewModel {
        let client = DocsAPIClient(
            baseURL: URL(string: "https://docs.example.org/api/v1.0/")!, session: MockURLProtocol.makeSession(),
            cookieProvider: { [] })
        let suiteName = "LeafNestingTests.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let draftStore = PendingDraftStore(userDefaults: UserDefaults(suiteName: suiteName)!)
        let coordinator = DocumentSaveCoordinator(client: client, draftStore: draftStore, backgroundTasks: .noop)
        let viewModel = EditorViewModel(client: client, documentID: UUID(), title: "Doc", saveCoordinator: coordinator)
        viewModel.blocks = blocks
        viewModel.mode = .blocks
        return viewModel
    }

    override func tearDown() {
        MockURLProtocol.reset()
        for suiteName in suiteNames {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        suiteNames = []
        super.tearDown()
    }

    private func item(_ text: String, _ indent: Int = 0) -> EditorBlock {
        EditorBlock(kind: .checklistItem(checked: false), text: text, indent: indent)
    }

    private func photo(_ name: String = "p", _ indent: Int = 0) -> EditorBlock {
        EditorBlock(kind: .image(alt: name, url: "https://docs.example.org/media/\(name).jpg"), indent: indent)
    }

    // MARK: - Which blocks nest

    func testImagesAttachmentsAndLinkLinesNestButOtherBlocksDoNot() {
        XCTAssertTrue(blockNestsAsLeaf(photo()))
        XCTAssertTrue(blockNestsAsLeaf(EditorBlock(kind: .attachment(name: "r", url: "https://x/r.pdf"))))
        XCTAssertTrue(blockNestsAsLeaf(EditorBlock(kind: .paragraph, text: "[r](https://x/r.pdf)")))
        XCTAssertFalse(blockNestsAsLeaf(EditorBlock(kind: .paragraph, text: "prose")))
        XCTAssertFalse(blockNestsAsLeaf(EditorBlock(kind: .paragraph, text: "[r](https://x/r.pdf) and more")))
        XCTAssertFalse(blockNestsAsLeaf(EditorBlock(kind: .paragraph, text: "[a\nb](https://x/r.pdf)")))
        XCTAssertFalse(blockNestsAsLeaf(EditorBlock(kind: .divider)))
        XCTAssertFalse(blockNestsAsLeaf(item("a")))
    }

    // MARK: - Normalization

    func testANestedLeafStaysUnderTheListItemAbove() {
        let blocks = [
            item("a"), photo("p", 1), EditorBlock(kind: .paragraph, text: "[r](https://x/r.pdf)", indent: 1),
            photo("q", 3),
        ]
        XCTAssertEqual(normalizedListIndents(blocks).map(\.indent), [0, 1, 1, 1])
    }

    func testALeafWithNoListItemAboveIsFlattened() {
        XCTAssertEqual(normalizedListIndents([photo("p", 1)]).map(\.indent), [0])
        XCTAssertEqual(
            normalizedListIndents([EditorBlock(kind: .paragraph, text: "p"), photo("q", 1)]).map(\.indent), [0, 0])
        XCTAssertEqual(
            normalizedListIndents([item("a"), EditorBlock(kind: .paragraph, text: "prose", indent: 1)]).map(\.indent),
            [0, 0], "only a link line nests; prose does not")
    }

    func testALeafHasNoChildren() {
        XCTAssertEqual(normalizedListIndents([item("a"), photo("p", 1), item("b", 2)]).map(\.indent), [0, 1, 1])
    }

    /// A document with no nested leaves normalizes exactly as before: a flat leaf
    /// after an item still ends the list's nesting.
    func testAFlatLeafStillEndsTheListsNesting() {
        XCTAssertEqual(normalizedListIndents([item("a"), photo(), item("b", 1)]).map(\.indent), [0, 0, 0])
    }

    // MARK: - Subtrees, numbering and list-item indent

    func testAListItemsSubtreeCarriesItsNestedLeaves() {
        let blocks = [item("z"), item("a"), photo("p", 1), item("b", 1), photo("q", 2), item("c")]
        XCTAssertEqual(listSubtreeEnd(of: 1, in: blocks), 5)
        XCTAssertEqual(shiftingListItem(at: 1, by: 1, in: blocks)?.map(\.indent), [0, 1, 2, 2, 3, 0])
    }

    func testAnItemCanIndentUnderTheNestedLeafAboveIt() {
        let blocks = [item("a"), photo("p", 1), item("b")]
        XCTAssertTrue(canIndentListItem(at: 2, in: blocks))
        XCTAssertEqual(shiftingListItem(at: 2, by: 1, in: blocks)?.map(\.indent), [0, 1, 1])
        XCTAssertFalse(canIndentListItem(at: 2, in: [item("a"), photo(), item("b")]), "a flat leaf is no parent")
    }

    func testANestedLeafDoesNotRestartTheNumbering() {
        let blocks = [
            EditorBlock(kind: .numberedItem, text: "one"), photo("p", 1),
            EditorBlock(kind: .numberedItem, text: "two"),
        ]
        XCTAssertEqual(numberedIndex(of: 2, in: blocks), 2)
        XCTAssertEqual(numberedIndex(of: 2, in: [blocks[0], photo(), blocks[2]]), 1, "a flat leaf still ends the run")
    }

    // MARK: - Leaf indent and outdent

    func testALeafsIndentRangeIsBoundedByTheBlocksAroundIt() {
        XCTAssertEqual(leafIndentRange(at: 1, in: [item("a"), photo()]), 0...1)
        XCTAssertEqual(leafIndentRange(at: 1, in: [EditorBlock(kind: .paragraph, text: "x"), photo()]), 0...0)
        XCTAssertEqual(leafIndentRange(at: 0, in: [photo()]), 0...0)
        // A nested sibling after it — leaf or item — pins its lower bound.
        XCTAssertEqual(leafIndentRange(at: 1, in: [item("a"), photo("p", 1), photo("q", 1)]), 1...1)
        XCTAssertEqual(leafIndentRange(at: 1, in: [item("a"), photo("p", 1), item("b", 1)]), 1...1)
        XCTAssertNil(leafIndentRange(at: 0, in: [item("a")]))
    }

    func testIndentingALeafNestsItUnderTheItemAbove() {
        let blocks = [item("a"), photo()]
        XCTAssertTrue(canIndentLeaf(at: 1, in: blocks))
        let indented = indentingLeaf(at: 1, in: blocks)
        XCTAssertEqual(indented?.map(\.indent), [0, 1])
        XCTAssertNil(indentingLeaf(at: 1, in: indented ?? []), "no deeper than one level under the item")
        XCTAssertNil(indentingLeaf(at: 0, in: blocks), "a list item is not a leaf")
    }

    func testOutdentingALeafWithNothingAfterItMovesItInPlace() {
        let blocks = [item("a"), photo("p", 1), item("c")]
        XCTAssertTrue(canOutdentLeaf(at: 1, in: blocks))
        XCTAssertEqual(outdentingLeaf(at: 1, in: blocks)?.map(\.indent), [0, 0, 0])
        XCTAssertNil(outdentingLeaf(at: 1, in: [item("a"), photo()]), "a flat leaf can't go further out")
    }

    /// Outdenting in place would strand the siblings after it; the leaf moves past
    /// its parent's subtree instead, one level out.
    func testOutdentingALeafWithSiblingsAfterItMovesItPastThem() {
        let a = item("a")
        let p = photo("p", 1)
        let b = item("b", 1)
        let c = item("c")
        let result = outdentingLeaf(at: 1, in: [a, p, b, c])
        XCTAssertEqual(result?.map(\.id), [a.id, b.id, p.id, c.id])
        XCTAssertEqual(result?.map(\.indent), [0, 1, 0, 0])
    }

    func testOutdentingADeepLeafLandsUnderItsGrandparent() {
        let blocks = [item("a"), item("b", 1), photo("p", 2), photo("q", 2), item("c", 1), item("d")]
        let result = outdentingLeaf(at: 2, in: blocks)
        XCTAssertEqual(result?.map(\.id), [0, 1, 3, 2, 4, 5].map { blocks[$0].id })
        XCTAssertEqual(result?.map(\.indent), [0, 1, 2, 1, 1, 0])
    }

    // MARK: - Editor intents

    func testIndentAndOutdentLeafDirtyTheDocument() {
        let a = item("a")
        let p = photo()
        let viewModel = makeViewModel(blocks: [a, p])

        XCTAssertTrue(viewModel.indentLeaf(blockID: p.id))
        XCTAssertEqual(viewModel.blocks.map(\.indent), [0, 1])
        XCTAssertTrue(viewModel.isDirty)
        XCTAssertEqual(viewModel.currentMarkdown(), "- [ ] a\n  ![p](https://docs.example.org/media/p.jpg)\n")

        XCTAssertFalse(viewModel.indentLeaf(blockID: p.id), "already as deep as it can go")
        XCTAssertFalse(viewModel.indentLeaf(blockID: a.id), "not a leaf")
        XCTAssertTrue(viewModel.outdentLeaf(blockID: p.id))
        XCTAssertEqual(viewModel.blocks.map(\.indent), [0, 0])
    }

    func testAMoveAmongAnItemsChildrenJoinsThem() {
        let p = photo()
        let a = item("a")
        let b = item("b", 1)
        let viewModel = makeViewModel(blocks: [p, a, b])

        viewModel.moveBlock(blockID: p.id, to: 1)

        XCTAssertEqual(viewModel.blocks.map(\.id), [a.id, p.id, b.id])
        XCTAssertEqual(viewModel.blocks.map(\.indent), [0, 1, 1])
    }

    func testAMoveKeepsAFlatLeafFlatAndANestedLeafNested() {
        let p = photo()
        let a = item("a")
        let c = EditorBlock(kind: .paragraph, text: "c")
        let viewModel = makeViewModel(blocks: [p, a, c])
        viewModel.moveBlock(blockID: p.id, to: 1)
        XCTAssertEqual(viewModel.blocks.map(\.indent), [0, 0, 0], "dropped after an item, a flat photo stays flat")

        let nested = photo("q", 1)
        let other = makeViewModel(blocks: [item("x"), nested, item("y")])
        other.moveBlock(blockID: nested.id, to: 2)
        XCTAssertEqual(other.blocks.map(\.indent), [0, 0, 1], "it keeps its level under the item it lands after")
    }

    func testARequestedIndentIsClampedToWhatThePositionAllows() {
        let a = item("a")
        let p = photo("p", 1)
        let viewModel = makeViewModel(blocks: [a, p])

        viewModel.moveBlock(blockID: p.id, to: 1, indent: 0)
        XCTAssertEqual(viewModel.blocks.map(\.indent), [0, 0])
        XCTAssertTrue(viewModel.isDirty)

        viewModel.moveBlock(blockID: p.id, to: 1, indent: 5)
        XCTAssertEqual(viewModel.blocks.map(\.indent), [0, 1])
    }

    // MARK: - Live editing

    /// The live path diffs a flat list, so nesting a leaf takes the classic save
    /// and latches the screen off the live stream, exactly as a nested item does.
    func testNestingALeafTakesTheClassicPathAndLeavesLiveEditing() {
        let a = item("a")
        let p = photo()
        let viewModel = makeViewModel(blocks: [a, p])
        let live = LeafNestingLiveWriteSpy()
        viewModel.liveWrite = live

        viewModel.toggleChecklist(blockID: a.id)
        XCTAssertEqual(live.forwardCount, 1, "a flat document still edits live")
        XCTAssertFalse(viewModel.isDirty)

        viewModel.indentLeaf(blockID: p.id)

        XCTAssertEqual(live.forwardCount, 1, "the nesting is never forwarded")
        XCTAssertTrue(viewModel.isDirty)
        XCTAssertTrue(viewModel.hasUnmodelableLocalEdit)
    }
}

@MainActor
private final class LeafNestingLiveWriteSpy: EditorLiveWriteCoordinating {
    var isHandlingLocalEditsLive: Bool { true }
    private(set) var forwardCount = 0
    func forwardLocalEdit() -> Bool {
        forwardCount += 1
        return true
    }
    func flushPendingLiveSnapshot() {}
}
