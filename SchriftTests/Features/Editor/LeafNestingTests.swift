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

    // MARK: - Editing a nested link line

    private let linkURL = "https://x/r.pdf"

    private func link(_ text: String? = nil, _ indent: Int = 1) -> EditorBlock {
        EditorBlock(kind: .paragraph, text: text ?? "[r](\(linkURL))", indent: indent)
    }

    /// Whatever the editor holds must read back as the same blocks: nothing lost, nothing
    /// nested that the markdown cannot spell. (An empty paragraph serializes to nothing, so
    /// it is left out of the comparison.)
    private func assertRoundTrips(_ viewModel: EditorViewModel, file: StaticString = #filePath, line: UInt = #line) {
        let markdown = viewModel.currentMarkdown()
        let written = viewModel.blocks.filter { $0.kind != .paragraph || !$0.text.isEmpty }
        XCTAssertTrue(
            blocksContentEqual(parseEditorBlocks(markdown), written),
            "\(markdown.debugDescription) vs \(viewModel.blocks.map { "\($0.kind)@\($0.indent)" })",
            file: file, line: line)
    }

    func testDetachingMovesOnlyTheListedUnnestableBlocksPastTheirNestedRun() {
        let a = item("a")
        let first = link("prose", 1)
        let second = link("", 1)
        let p = photo("p", 1)
        let b = item("b")
        let blocks = [a, first, second, p, b]

        let result = detachingUnnestableBlocks([first.id, second.id], in: blocks)
        XCTAssertEqual(result.map(\.id), [a.id, p.id, first.id, second.id, b.id], "moved together, in order")
        XCTAssertEqual(result.map(\.indent), [0, 1, 0, 0, 0])

        XCTAssertEqual(
            detachingUnnestableBlocks([first.id], in: [a, link(nil, 1), p]).map(\.indent), [0, 1, 1],
            "an unlisted block is not touched")
        let stillALink = link(nil, 1)
        XCTAssertEqual(
            detachingUnnestableBlocks([stillALink.id], in: [a, stillALink, p]).map(\.id), [a.id, stillALink.id, p.id],
            "a link line still nests")
    }

    func testAnEditThatKeepsALinkLineKeepsItsLevel() {
        let r = link()
        let p = photo("p", 1)
        let viewModel = makeViewModel(blocks: [item("a"), r, p, item("b")])

        viewModel.updateText(blockID: r.id, text: "[report](\(linkURL))")

        XCTAssertEqual(viewModel.blocks.map(\.id)[1], r.id)
        XCTAssertEqual(viewModel.blocks.map(\.indent), [0, 1, 1, 0])
        XCTAssertTrue(viewModel.isDirty)
        assertRoundTrips(viewModel)
    }

    /// Typing past the link makes the line prose, which cannot nest. It steps out past the
    /// photo nested after it instead of ending the list above the photo and flattening it.
    func testAnEditThatBreaksTheLinkStepsOutWithoutOrphaningItsSiblings() {
        let a = item("a")
        let r = link()
        let p = photo("p", 1)
        let b = item("b")
        let viewModel = makeViewModel(blocks: [a, r, p, b])

        viewModel.updateText(blockID: r.id, text: "[r](\(linkURL)) and more")

        XCTAssertEqual(viewModel.blocks.map(\.id), [a.id, p.id, r.id, b.id])
        XCTAssertEqual(viewModel.blocks.map(\.indent), [0, 1, 0, 0], "the photo is still under its item")
        XCTAssertEqual(viewModel.blocks[2].text, "[r](\(linkURL)) and more")
        assertRoundTrips(viewModel)
    }

    func testReturnAtTheEndOfANestedLinkLineKeepsItAndItsSiblingsNested() {
        let a = item("a")
        let r = link()
        let p = photo("p", 1)
        let b = item("b")
        let viewModel = makeViewModel(blocks: [a, r, p, b])

        viewModel.splitBlock(blockID: r.id, at: (r.text as NSString).length)

        XCTAssertEqual(viewModel.blocks.count, 5)
        XCTAssertEqual(viewModel.blocks.map(\.id).prefix(3), [a.id, r.id, p.id])
        XCTAssertEqual(viewModel.blocks.map(\.indent), [0, 1, 1, 0, 0])
        XCTAssertEqual(viewModel.blocks[3].kind, .paragraph)
        XCTAssertEqual(viewModel.blocks[3].text, "", "the new line lands past the nested run")
        XCTAssertEqual(viewModel.focusedBlockID, viewModel.blocks[3].id)
        assertRoundTrips(viewModel)
    }

    func testReturnAtTheStartOfANestedLinkLineKeepsTheLinkNested() {
        let a = item("a")
        let r = link()
        let p = photo("p", 1)
        let viewModel = makeViewModel(blocks: [a, r, p, item("b")])

        viewModel.splitBlock(blockID: r.id, at: 0)

        XCTAssertEqual(viewModel.blocks.map(\.text), ["a", "[r](\(linkURL))", "", "", "b"])
        XCTAssertEqual(viewModel.blocks.map(\.indent), [0, 1, 1, 0, 0])
        XCTAssertEqual(viewModel.blocks[2].id, p.id)
        XCTAssertEqual(viewModel.focusedBlockID, viewModel.blocks[1].id, "the caret stays on the link")
        assertRoundTrips(viewModel)
    }

    /// Return inside the link cuts it into two pieces of prose: both step out together, in
    /// order, and every character survives.
    func testReturnInsideANestedLinkLineLosesNothingAndOrphansNothing() {
        let a = item("a")
        let r = link()
        let p = photo("p", 1)
        let viewModel = makeViewModel(blocks: [a, r, p, item("b")])

        viewModel.splitBlock(blockID: r.id, at: 3)

        XCTAssertEqual(viewModel.blocks.map(\.text), ["a", "", "[r]", "(\(linkURL))", "b"])
        XCTAssertEqual(viewModel.blocks.map(\.indent), [0, 1, 0, 0, 0])
        XCTAssertEqual(viewModel.blocks[1].id, p.id, "the photo keeps its item")
        assertRoundTrips(viewModel)
    }

    /// Backspace undoes structure before it deletes anything: a nested link line steps out a
    /// level — past the siblings it would otherwise orphan — rather than merging into its item.
    func testBackspaceAtTheStartOfANestedLinkLineOutdentsIt() {
        let a = item("a")
        let r = link()
        let p = photo("p", 1)
        let viewModel = makeViewModel(blocks: [a, r, p])

        viewModel.mergeBlockWithPrevious(blockID: r.id)

        XCTAssertEqual(viewModel.blocks.map(\.id), [a.id, p.id, r.id])
        XCTAssertEqual(viewModel.blocks.map(\.indent), [0, 1, 0])
        XCTAssertEqual(viewModel.blocks.map(\.text), ["a", "", "[r](\(linkURL))"])
    }

    func testConvertingANestedLinkLineToAHeadingStepsItOut() {
        let a = item("a")
        let r = link()
        let p = photo("p", 1)
        let viewModel = makeViewModel(blocks: [a, r, p])

        viewModel.convertBlock(blockID: r.id, to: .heading(level: 2))

        XCTAssertEqual(viewModel.blocks.map(\.id), [a.id, p.id, r.id])
        XCTAssertEqual(viewModel.blocks.map(\.indent), [0, 1, 0])
        assertRoundTrips(viewModel)
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
