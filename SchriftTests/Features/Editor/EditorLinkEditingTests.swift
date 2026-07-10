import XCTest

@testable import Schrift

@MainActor
final class EditorLinkEditingTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!

    private var cacheDirectory: URL!
    private var childrenSuiteName: String!
    private var draftSuiteName: String!

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorLinkEditingTests-\(UUID().uuidString)", isDirectory: true)
        childrenSuiteName = "EditorLinkEditingTests.children.\(UUID().uuidString)"
        draftSuiteName = "EditorLinkEditingTests.drafts.\(UUID().uuidString)"
    }

    override func tearDown() {
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: cacheDirectory)
        UserDefaults(suiteName: childrenSuiteName)?.removePersistentDomain(forName: childrenSuiteName)
        UserDefaults(suiteName: draftSuiteName)?.removePersistentDomain(forName: draftSuiteName)
        super.tearDown()
    }

    /// Loads content so `hasLoadedContent` is true — `canEditLink` guards on it,
    /// exactly as the photo entry points do — then enters block editing.
    private func makeEditingViewModel(content: String) async -> EditorViewModel {
        MockURLProtocol.stubHandler = { _ in
            let body = """
                {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "\(content)", \
                "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
                """
            return .init(statusCode: 200, headers: [:], body: Data(body.utf8), error: nil)
        }
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let draftStore = PendingDraftStore(userDefaults: UserDefaults(suiteName: draftSuiteName)!)
        let contentCache = DocumentContentCacheStore(directory: cacheDirectory)
        let childrenCache = DocumentChildrenCacheStore(userDefaults: UserDefaults(suiteName: childrenSuiteName)!)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: draftStore, contentCache: contentCache, backgroundTasks: .noop)
        let viewModel = EditorViewModel(
            client: client, documentID: documentID, title: "Doc", saveCoordinator: coordinator,
            contentCache: contentCache, childrenCache: childrenCache)
        await viewModel.load()
        viewModel.startEditing()
        return viewModel
    }

    private func focusFirstBlock(_ viewModel: EditorViewModel, selection: NSRange) {
        viewModel.focusedBlockID = viewModel.blocks[0].id
        viewModel.selection = selection
    }

    private func firstLink(_ viewModel: EditorViewModel) throws -> InlineLinkSpan {
        try XCTUnwrap(InlineMarkdown.layout(of: viewModel.blocks[0].text).links.first)
    }

    // MARK: - canEditLink

    func testLinkEditingNeedsAFocusedBlock() async {
        let viewModel = await makeEditingViewModel(content: "Body text.")
        XCTAssertFalse(viewModel.canEditLink)
        focusFirstBlock(viewModel, selection: NSRange(location: 0, length: 0))
        XCTAssertTrue(viewModel.canEditLink)
    }

    /// A code block's text is literal, so a link written into it would render as
    /// `[a](b)` and save as `[a](b)`. Don't offer.
    func testLinkEditingIsUnavailableInACodeBlock() async {
        let viewModel = await makeEditingViewModel(content: "Body text.")
        viewModel.blocks = [EditorBlock(kind: .codeBlock(language: "swift"), text: "let x = 1")]
        focusFirstBlock(viewModel, selection: NSRange(location: 0, length: 0))
        XCTAssertFalse(viewModel.canEditLink)
    }

    func testLinkEditingIsUnavailableInMarkdownSourceMode() async {
        let viewModel = await makeEditingViewModel(content: "Body text.")
        viewModel.setMode(.markdown)
        // `setMode` also clears the focus, so restore it: the mode itself is what
        // must disable the button.
        focusFirstBlock(viewModel, selection: NSRange(location: 0, length: 0))
        XCTAssertFalse(viewModel.canEditLink)
    }

    // MARK: - Creating

    func testTheSelectionBecomesTheLabel() async {
        let viewModel = await makeEditingViewModel(content: "Read the docs now.")
        focusFirstBlock(viewModel, selection: NSRange(location: 9, length: 4))

        viewModel.beginLinkEditing()

        XCTAssertEqual(viewModel.linkEditor?.label, "docs")
        XCTAssertNil(viewModel.linkEditor?.span)
        XCTAssertTrue(viewModel.commitLinkEditing(label: "docs", url: "https://x.dev/"))
        XCTAssertEqual(viewModel.blocks[0].text, "Read the [docs](https://x.dev/) now.")
        XCTAssertNil(viewModel.linkEditor)
        XCTAssertTrue(viewModel.isDirty)
    }

    func testAnEmptyLabelFallsBackToTheAddress() async {
        let viewModel = await makeEditingViewModel(content: "Body")
        focusFirstBlock(viewModel, selection: NSRange(location: 4, length: 0))
        viewModel.beginLinkEditing()

        XCTAssertTrue(viewModel.commitLinkEditing(label: "   ", url: "x.dev/a"))
        XCTAssertEqual(viewModel.blocks[0].text, "Body[https://x.dev/a](https://x.dev/a)")
    }

    func testTheCaretLandsAfterTheNewLink() async {
        let viewModel = await makeEditingViewModel(content: "Body")
        focusFirstBlock(viewModel, selection: NSRange(location: 4, length: 0))
        viewModel.beginLinkEditing()
        viewModel.commitLinkEditing(label: "a", url: "https://x.dev/")

        XCTAssertEqual(viewModel.cursorRequest?.blockID, viewModel.blocks[0].id)
        XCTAssertEqual(viewModel.cursorRequest?.offset, (viewModel.blocks[0].text as NSString).length)
    }

    // MARK: - Rejecting

    /// The sheet stays open, the block is untouched, and nothing is marked dirty.
    func testAnUnsafeAddressIsRejectedWithoutTouchingTheBlock() async {
        let viewModel = await makeEditingViewModel(content: "Body")
        focusFirstBlock(viewModel, selection: NSRange(location: 4, length: 0))
        viewModel.beginLinkEditing()

        for unsafe in ["javascript:alert", "https://x.dev/a(1)", "  ", "https://x.dev/a b"] {
            XCTAssertFalse(viewModel.commitLinkEditing(label: "a", url: unsafe), unsafe)
            XCTAssertEqual(viewModel.blocks[0].text, "Body", unsafe)
            XCTAssertNotNil(viewModel.linkEditor, unsafe)
            XCTAssertFalse(viewModel.isDirty, unsafe)
        }
    }

    // MARK: - Editing an existing link

    func testTappingALinkPrefillsTheSheetFromIt() async throws {
        let viewModel = await makeEditingViewModel(content: "See [docs](https://x.dev/) now")
        let span = try firstLink(viewModel)

        viewModel.beginLinkEditing(blockID: viewModel.blocks[0].id, span: span)

        XCTAssertEqual(viewModel.linkEditor?.label, "docs")
        XCTAssertEqual(viewModel.linkEditor?.url, "https://x.dev/")
        XCTAssertEqual(viewModel.linkEditor?.span, span)
    }

    func testTheLinkButtonRetargetsTheLinkUnderTheCaret() async {
        let viewModel = await makeEditingViewModel(content: "See [docs](https://x.dev/) now")
        focusFirstBlock(viewModel, selection: NSRange(location: 6, length: 0))

        viewModel.beginLinkEditing()

        XCTAssertNotNil(viewModel.linkEditor?.span)
        XCTAssertTrue(viewModel.commitLinkEditing(label: "guide", url: "https://y.dev/"))
        XCTAssertEqual(viewModel.blocks[0].text, "See [guide](https://y.dev/) now")
    }

    /// The sheet is asynchronous; a revalidation can install new content behind
    /// it. A stale span must not splice a link into unrelated words.
    func testCommittingAgainstAChangedBlockIsAbandoned() async throws {
        let viewModel = await makeEditingViewModel(content: "See [docs](https://x.dev/) now")
        let span = try firstLink(viewModel)
        viewModel.beginLinkEditing(blockID: viewModel.blocks[0].id, span: span)

        viewModel.blocks[0].text = "Something else entirely"

        XCTAssertFalse(viewModel.commitLinkEditing(label: "guide", url: "https://y.dev/"))
        XCTAssertEqual(viewModel.blocks[0].text, "Something else entirely")
        XCTAssertNil(viewModel.linkEditor)
    }

    // MARK: - Removing

    func testRemovingALinkKeepsItsLabel() async throws {
        let viewModel = await makeEditingViewModel(content: "See [docs](https://x.dev/) now")
        let span = try firstLink(viewModel)

        viewModel.removeLink(blockID: viewModel.blocks[0].id, span: span)

        XCTAssertEqual(viewModel.blocks[0].text, "See docs now")
        XCTAssertTrue(viewModel.isDirty)
    }

    func testRemovingAStaleLinkIsANoOp() async throws {
        let viewModel = await makeEditingViewModel(content: "See [docs](https://x.dev/) now")
        let span = try firstLink(viewModel)
        viewModel.blocks[0].text = "Something else entirely"

        viewModel.removeLink(blockID: viewModel.blocks[0].id, span: span)

        XCTAssertEqual(viewModel.blocks[0].text, "Something else entirely")
    }

    // MARK: - What reaches the save

    /// The block's text *is* the markdown the full-overwrite save writes, so an
    /// authored link must survive serialization and re-parse unchanged.
    func testAnAuthoredLinkSurvivesTheSaveRoundTrip() async throws {
        let viewModel = await makeEditingViewModel(content: "Read the docs now.")
        focusFirstBlock(viewModel, selection: NSRange(location: 9, length: 4))
        viewModel.beginLinkEditing()
        viewModel.commitLinkEditing(label: "docs", url: "x.dev/a")

        let markdown = viewModel.currentMarkdown()
        XCTAssertEqual(markdown, "Read the [docs](https://x.dev/a) now.\n")
        let reparsed = try XCTUnwrap(InlineMarkdown.layout(of: parseEditorBlocks(markdown)[0].text).links.first)
        XCTAssertEqual(reparsed.url, "https://x.dev/a")
        XCTAssertEqual(reparsed.label, "docs")
    }

    /// Bold's markers are now drawn at zero width, so a user selecting a bold
    /// word sees no asterisks. Applying an inline marker must never quietly
    /// remove the ones that are there — and the italic it adds must reach the
    /// save, which is the whole point of the flanking rule.
    func testApplyingItalicToABoldWordKeepsTheBoldAndSavesTheItalic() async {
        let viewModel = await makeEditingViewModel(content: "a **word** b")
        // "word" is the visible text; its source range inside "**word**".
        focusFirstBlock(viewModel, selection: NSRange(location: 4, length: 4))

        viewModel.applyInlineMarker("_")

        XCTAssertEqual(viewModel.blocks[0].text, "a **_word_** b")
        let runs = InlineMarkdown.parse(viewModel.blocks[0].text)
        XCTAssertEqual(runs.map(\.text), ["a ", "word", " b"], "the underscores are syntax, not content")
        XCTAssertEqual(runs[1].marks.map(\.key), ["bold", "italic"], "both marks must reach the encoder")
    }
}
