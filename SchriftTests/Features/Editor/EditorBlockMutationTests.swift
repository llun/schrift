import XCTest
@testable import Schrift

@MainActor
final class EditorBlockMutationTests: XCTestCase {
    private func makeViewModel(blocks: [EditorBlock]) -> EditorViewModel {
        let client = DocsAPIClient(baseURL: URL(string: "https://docs.example.org/api/v1.0/")!, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let suiteName = "EditorBlockMutationTests.\(UUID().uuidString)"
        let draftStore = PendingDraftStore(userDefaults: UserDefaults(suiteName: suiteName)!)
        let coordinator = DocumentSaveCoordinator(client: client, draftStore: draftStore, backgroundTasks: .noop)
        let viewModel = EditorViewModel(client: client, documentID: UUID(), title: "Doc", saveCoordinator: coordinator)
        viewModel.blocks = blocks
        viewModel.mode = .blocks
        return viewModel
    }

    // MARK: - Splitting

    func testSplitInMiddleKeepsHeadAndMovesTail() {
        let block = EditorBlock(kind: .paragraph, text: "HelloWorld")
        let viewModel = makeViewModel(blocks: [block])

        viewModel.splitBlock(blockID: block.id, at: 5)

        XCTAssertEqual(viewModel.blocks.map(\.text), ["Hello", "World"])
        XCTAssertEqual(viewModel.blocks.map(\.kind), [.paragraph, .paragraph])
        XCTAssertEqual(viewModel.focusedBlockID, viewModel.blocks[1].id)
        XCTAssertEqual(viewModel.cursorRequest?.blockID, viewModel.blocks[1].id)
        XCTAssertEqual(viewModel.cursorRequest?.offset, 0)
        XCTAssertTrue(viewModel.isDirty)
    }

    func testSplitAtEndOfBulletContinuesTheList() {
        let block = EditorBlock(kind: .bulletItem, text: "Item")
        let viewModel = makeViewModel(blocks: [block])

        viewModel.splitBlock(blockID: block.id, at: 4)

        XCTAssertEqual(viewModel.blocks.map(\.kind), [.bulletItem, .bulletItem])
        XCTAssertEqual(viewModel.blocks.map(\.text), ["Item", ""])
    }

    func testSplitCheckedChecklistItemContinuesUnchecked() {
        let block = EditorBlock(kind: .checklistItem(checked: true), text: "Done")
        let viewModel = makeViewModel(blocks: [block])

        viewModel.splitBlock(blockID: block.id, at: 4)

        XCTAssertEqual(viewModel.blocks.map(\.kind), [.checklistItem(checked: true), .checklistItem(checked: false)])
    }

    func testSplitHeadingProducesParagraphTail() {
        let block = EditorBlock(kind: .heading(level: 2), text: "Title")
        let viewModel = makeViewModel(blocks: [block])

        viewModel.splitBlock(blockID: block.id, at: 5)

        XCTAssertEqual(viewModel.blocks.map(\.kind), [.heading(level: 2), .paragraph])
    }

    func testEnterOnEmptyListItemEscapesToParagraph() {
        let block = EditorBlock(kind: .bulletItem, text: "")
        let viewModel = makeViewModel(blocks: [block])

        viewModel.splitBlock(blockID: block.id, at: 0)

        XCTAssertEqual(viewModel.blocks.count, 1)
        XCTAssertEqual(viewModel.blocks[0].kind, .paragraph)
    }

    // MARK: - Merging

    func testBackspaceMergesParagraphIntoPrevious() {
        let first = EditorBlock(kind: .paragraph, text: "Hello")
        let second = EditorBlock(kind: .paragraph, text: "World")
        let viewModel = makeViewModel(blocks: [first, second])

        viewModel.mergeBlockWithPrevious(blockID: second.id)

        XCTAssertEqual(viewModel.blocks.map(\.text), ["HelloWorld"])
        XCTAssertEqual(viewModel.focusedBlockID, first.id)
        XCTAssertEqual(viewModel.cursorRequest?.offset, 5)
    }

    func testBackspaceOnStyledBlockConvertsToParagraphFirst() {
        let first = EditorBlock(kind: .paragraph, text: "Hello")
        let second = EditorBlock(kind: .bulletItem, text: "Item")
        let viewModel = makeViewModel(blocks: [first, second])

        viewModel.mergeBlockWithPrevious(blockID: second.id)

        XCTAssertEqual(viewModel.blocks.count, 2)
        XCTAssertEqual(viewModel.blocks[1].kind, .paragraph)
        XCTAssertEqual(viewModel.blocks[1].text, "Item")
    }

    func testBackspaceAfterDividerDeletesTheDivider() {
        let divider = EditorBlock(kind: .divider)
        let paragraph = EditorBlock(kind: .paragraph, text: "Text")
        let viewModel = makeViewModel(blocks: [divider, paragraph])

        viewModel.mergeBlockWithPrevious(blockID: paragraph.id)

        XCTAssertEqual(viewModel.blocks.map(\.kind), [.paragraph])
        XCTAssertEqual(viewModel.blocks[0].text, "Text")
    }

    func testBackspaceIntoCodeBlockAppendsTextAsNewLine() {
        let code = EditorBlock(kind: .codeBlock(language: ""), text: "line1")
        let paragraph = EditorBlock(kind: .paragraph, text: "tail")
        let viewModel = makeViewModel(blocks: [code, paragraph])

        viewModel.mergeBlockWithPrevious(blockID: paragraph.id)

        XCTAssertEqual(viewModel.blocks.count, 1)
        XCTAssertEqual(viewModel.blocks[0].text, "line1\ntail")
        XCTAssertEqual(viewModel.cursorRequest?.offset, 5)
    }

    func testBackspaceEmptyParagraphIntoCodeBlockJustRemovesIt() {
        let code = EditorBlock(kind: .codeBlock(language: ""), text: "line1")
        let paragraph = EditorBlock(kind: .paragraph, text: "")
        let viewModel = makeViewModel(blocks: [code, paragraph])

        viewModel.mergeBlockWithPrevious(blockID: paragraph.id)

        XCTAssertEqual(viewModel.blocks.count, 1)
        XCTAssertEqual(viewModel.blocks[0].text, "line1")
    }

    func testBackspaceOnFirstParagraphIsANoOp() {
        let block = EditorBlock(kind: .paragraph, text: "Hello")
        let viewModel = makeViewModel(blocks: [block])

        viewModel.mergeBlockWithPrevious(blockID: block.id)

        XCTAssertEqual(viewModel.blocks.map(\.text), ["Hello"])
        XCTAssertFalse(viewModel.isDirty)
    }

    // MARK: - Conversions and insertion

    func testToggleChecklistFlipsCheckedState() {
        let block = EditorBlock(kind: .checklistItem(checked: false), text: "Task")
        let viewModel = makeViewModel(blocks: [block])

        viewModel.toggleChecklist(blockID: block.id)

        XCTAssertEqual(viewModel.blocks[0].kind, .checklistItem(checked: true))
    }

    func testConvertBlockChangesKind() {
        let block = EditorBlock(kind: .paragraph, text: "Text")
        let viewModel = makeViewModel(blocks: [block])

        viewModel.convertBlock(blockID: block.id, to: .heading(level: 1))

        XCTAssertEqual(viewModel.blocks[0].kind, .heading(level: 1))
        XCTAssertEqual(viewModel.blocks[0].text, "Text")
    }

    func testConvertBlockToSameKindTogglesBackToParagraph() {
        let block = EditorBlock(kind: .bulletItem, text: "Item")
        let viewModel = makeViewModel(blocks: [block])

        viewModel.convertBlock(blockID: block.id, to: .bulletItem)

        XCTAssertEqual(viewModel.blocks[0].kind, .paragraph)
    }

    func testConvertToDividerClearsText() {
        let block = EditorBlock(kind: .paragraph, text: "Text")
        let viewModel = makeViewModel(blocks: [block])

        viewModel.convertBlock(blockID: block.id, to: .divider)

        XCTAssertEqual(viewModel.blocks[0].kind, .divider)
        XCTAssertEqual(viewModel.blocks[0].text, "")
    }

    func testInsertBlockAfterFocusesNewBlock() {
        let block = EditorBlock(kind: .paragraph, text: "First")
        let viewModel = makeViewModel(blocks: [block])

        viewModel.insertBlock(after: block.id, kind: .bulletItem)

        XCTAssertEqual(viewModel.blocks.count, 2)
        XCTAssertEqual(viewModel.blocks[1].kind, .bulletItem)
        XCTAssertEqual(viewModel.focusedBlockID, viewModel.blocks[1].id)
    }

    func testAppendParagraphAtEndReusesTrailingEmptyParagraph() {
        let trailing = EditorBlock(kind: .paragraph, text: "")
        let viewModel = makeViewModel(blocks: [EditorBlock(kind: .paragraph, text: "Body"), trailing])

        viewModel.appendParagraphAtEnd()

        XCTAssertEqual(viewModel.blocks.count, 2)
        XCTAssertEqual(viewModel.focusedBlockID, trailing.id)
    }

    func testAppendParagraphAtEndAddsWhenLastBlockHasContent() {
        let viewModel = makeViewModel(blocks: [EditorBlock(kind: .paragraph, text: "Body")])

        viewModel.appendParagraphAtEnd()

        XCTAssertEqual(viewModel.blocks.count, 2)
        XCTAssertEqual(viewModel.blocks[1].kind, .paragraph)
    }

    func testUpdateTextAndTitleMarkDirty() {
        let block = EditorBlock(kind: .paragraph, text: "Old")
        let viewModel = makeViewModel(blocks: [block])

        viewModel.updateText(blockID: block.id, text: "New")
        XCTAssertTrue(viewModel.isDirty)
        XCTAssertEqual(viewModel.blocks[0].text, "New")

        viewModel.updateTitle("Renamed")
        XCTAssertEqual(viewModel.title, "Renamed")
    }

    // MARK: - Shortcuts and slash menu wiring

    func testTypingMarkdownPrefixConvertsParagraph() {
        let block = EditorBlock(kind: .paragraph, text: "")
        let viewModel = makeViewModel(blocks: [block])
        viewModel.focusedBlockID = block.id

        viewModel.updateText(blockID: block.id, text: "# ")

        XCTAssertEqual(viewModel.blocks[0].kind, .heading(level: 1))
        XCTAssertEqual(viewModel.blocks[0].text, "")
    }

    func testShortcutDoesNotFireInsideNonParagraphBlocks() {
        let block = EditorBlock(kind: .quote, text: "")
        let viewModel = makeViewModel(blocks: [block])

        viewModel.updateText(blockID: block.id, text: "- ")

        XCTAssertEqual(viewModel.blocks[0].kind, .quote)
        XCTAssertEqual(viewModel.blocks[0].text, "- ")
    }

    func testEnterOnFenceTextConvertsToCodeBlock() {
        let block = EditorBlock(kind: .paragraph, text: "```swift")
        let viewModel = makeViewModel(blocks: [block])

        viewModel.splitBlock(blockID: block.id, at: 8)

        XCTAssertEqual(viewModel.blocks.count, 1)
        XCTAssertEqual(viewModel.blocks[0].kind, .codeBlock(language: "swift"))
        XCTAssertEqual(viewModel.blocks[0].text, "")
    }

    func testEnterOnDividerTextConvertsAndAddsParagraph() {
        let block = EditorBlock(kind: .paragraph, text: "---")
        let viewModel = makeViewModel(blocks: [block])

        viewModel.splitBlock(blockID: block.id, at: 3)

        XCTAssertEqual(viewModel.blocks.map(\.kind), [.divider, .paragraph])
        XCTAssertEqual(viewModel.focusedBlockID, viewModel.blocks[1].id)
    }

    func testSlashTypingOpensQueryAndSelectionAppliesKind() {
        let block = EditorBlock(kind: .paragraph, text: "")
        let viewModel = makeViewModel(blocks: [block])
        viewModel.focusedBlockID = block.id

        viewModel.updateText(blockID: block.id, text: "/head")
        XCTAssertEqual(viewModel.slashQueryText, "head")

        viewModel.applySlashSelection(allSlashMenuItems.first { $0.id == "heading2" }!)

        XCTAssertEqual(viewModel.blocks[0].kind, .heading(level: 2))
        XCTAssertEqual(viewModel.blocks[0].text, "")
        XCTAssertNil(viewModel.slashQueryText)
    }

    func testSlashQueryClearsWhenSlashRemoved() {
        let block = EditorBlock(kind: .paragraph, text: "")
        let viewModel = makeViewModel(blocks: [block])
        viewModel.focusedBlockID = block.id

        viewModel.updateText(blockID: block.id, text: "/")
        XCTAssertEqual(viewModel.slashQueryText, "")

        viewModel.updateText(blockID: block.id, text: "")
        XCTAssertNil(viewModel.slashQueryText)
    }

    // MARK: - Formatting actions

    func testApplyInlineMarkerWrapsSelectionInFocusedBlock() {
        let block = EditorBlock(kind: .paragraph, text: "Hello world")
        let viewModel = makeViewModel(blocks: [block])
        viewModel.focusedBlockID = block.id
        viewModel.selection = NSRange(location: 0, length: 5)

        viewModel.applyInlineMarker("**")

        XCTAssertEqual(viewModel.blocks[0].text, "**Hello** world")
        XCTAssertEqual(viewModel.cursorRequest?.offset, 2)
        XCTAssertEqual(viewModel.cursorRequest?.length, 5)
    }

    func testApplyInlineMarkerIgnoresCodeBlocks() {
        let block = EditorBlock(kind: .codeBlock(language: ""), text: "let x = 1")
        let viewModel = makeViewModel(blocks: [block])
        viewModel.focusedBlockID = block.id

        viewModel.applyInlineMarker("**")

        XCTAssertEqual(viewModel.blocks[0].text, "let x = 1")
    }

    func testInsertAtCursorInMarkdownMode() {
        let viewModel = makeViewModel(blocks: [])
        viewModel.mode = .markdown
        viewModel.rawMarkdown = "Hello"
        viewModel.selection = NSRange(location: 5, length: 0)

        viewModel.insertAtCursor("\n- ")

        XCTAssertEqual(viewModel.rawMarkdown, "Hello\n- ")
        XCTAssertEqual(viewModel.selection, NSRange(location: 8, length: 0))
    }

    func testInsertDividerBelowFocusedAddsTrailingParagraph() {
        let block = EditorBlock(kind: .paragraph, text: "Body")
        let viewModel = makeViewModel(blocks: [block])
        viewModel.focusedBlockID = block.id

        viewModel.insertDividerBelowFocused()

        XCTAssertEqual(viewModel.blocks.map(\.kind), [.paragraph, .divider, .paragraph])
        XCTAssertEqual(viewModel.focusedBlockID, viewModel.blocks[2].id)
    }

    func testStartEditingOnEmptyDocumentSeedsAParagraph() {
        let viewModel = makeViewModel(blocks: [])
        viewModel.mode = .reading

        viewModel.startEditing()

        XCTAssertEqual(viewModel.mode, .blocks)
        XCTAssertEqual(viewModel.blocks.count, 1)
        XCTAssertEqual(viewModel.blocks[0].kind, .paragraph)
        XCTAssertEqual(viewModel.focusedBlockID, viewModel.blocks[0].id)
    }
}
