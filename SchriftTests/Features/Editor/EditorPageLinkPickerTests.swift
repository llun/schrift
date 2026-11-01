import XCTest

@testable import Schrift

/// The `[[` page picker wired to the editor: which documents it offers (from this device's
/// caches only), how it opens and closes with the caret, and what picking one writes.
@MainActor
final class EditorPageLinkPickerTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let serverOrigin = "https://docs.example.org"
    private let documentID = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!
    private let ownerID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    private var cacheDirectory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorPageLinkPickerTests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "EditorPageLinkPickerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: cacheDirectory)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func document(_ title: String, id: UUID = UUID(), updatedAt: TimeInterval = 0) -> Document {
        Document(
            id: id, title: title, excerpt: nil, abilities: DocumentAbilities(), linkReach: .restricted,
            linkRole: .reader, isFavorite: false, depth: 1, numchild: 0, path: "0001",
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: updatedAt),
            userRole: .owner, creator: nil)
    }

    /// Every store isolated in one suite — the list and children caches the picker reads, and
    /// the create/delete stores whose records it must skip.
    private func makeEditingViewModel(
        content: String = "Body", serverOrigin: String? = nil, recents: [Document] = [],
        children: [Document] = []
    ) async -> (viewModel: EditorViewModel, coordinator: DocumentSaveCoordinator) {
        MockURLProtocol.stubHandler = { _ in
            let body = """
                {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "\(content)", \
                "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
                """
            return .init(statusCode: 200, headers: [:], body: Data(body.utf8), error: nil)
        }
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let contentCache = DocumentContentCacheStore(directory: cacheDirectory)
        let listCache = DocumentCacheStore(userDefaults: defaults)
        let childrenCache = DocumentChildrenCacheStore(userDefaults: defaults)
        listCache.saveRecentDocuments(recents)
        if !children.isEmpty { childrenCache.save(children, for: UUID()) }
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: PendingDraftStore(userDefaults: defaults), contentCache: contentCache,
            createStore: PendingDocumentCreateStore(userDefaults: defaults),
            deleteStore: PendingDocumentDeleteStore(userDefaults: defaults),
            listCache: listCache, childrenCache: childrenCache,
            serverOrigin: self.serverOrigin, backgroundTasks: .noop)
        let viewModel = EditorViewModel(
            client: client, documentID: documentID, title: "Doc", saveCoordinator: coordinator,
            serverOrigin: serverOrigin ?? self.serverOrigin, contentCache: contentCache,
            childrenCache: childrenCache, listCache: listCache)
        await viewModel.load()
        viewModel.startEditing()
        viewModel.focusedBlockID = viewModel.blocks[0].id
        return (viewModel, coordinator)
    }

    /// What a keystroke does: the text view publishes the buffer, then the caret.
    private func typeText(_ text: String, caret: Int? = nil, in viewModel: EditorViewModel) {
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: text)
        viewModel.selection = NSRange(location: caret ?? (text as NSString).length, length: 0)
    }

    // MARK: - Opening and the candidates

    func testTypingTwoBracketsOpensThePickerWithCachedDocuments() async {
        let notes = document("Release notes", updatedAt: 2)
        let roadmap = document("Roadmap", updatedAt: 1)
        let (viewModel, _) = await makeEditingViewModel(recents: [notes], children: [roadmap])
        XCTAssertNil(viewModel.pageLinkPicker)

        typeText("See [[", in: viewModel)

        XCTAssertEqual(viewModel.pageLinkPicker?.matches.map(\.id), [notes.id, roadmap.id])
        XCTAssertEqual(viewModel.pageLinkPicker?.highlightedIndex, 0)
    }

    func testTheQueryFiltersTheRows() async {
        let notes = document("Release notes")
        let roadmap = document("Roadmap")
        let (viewModel, _) = await makeEditingViewModel(recents: [notes, roadmap])

        typeText("See [[road", in: viewModel)

        XCTAssertEqual(viewModel.pageLinkPicker?.query, "road")
        XCTAssertEqual(viewModel.pageLinkPicker?.matches.map(\.id), [roadmap.id])
    }

    func testSubpagesAreOfferedAndTheCurrentDocumentIsNot() async {
        let subpage = document("Meeting notes")
        let (viewModel, _) = await makeEditingViewModel(recents: [document("Doc itself", id: documentID)])
        viewModel.subpages = [subpage]

        typeText("[[", in: viewModel)

        XCTAssertEqual(viewModel.pageLinkPicker?.matches.map(\.id), [subpage.id])
    }

    /// A pending create's id is re-keyed when it syncs, so a link to it would dangle; a
    /// document queued for deletion is on its way out.
    func testLocalAndPendingDeleteDocumentsAreNotOffered() async {
        let (viewModel, coordinator) = await makeEditingViewModel()
        let local = coordinator.createLocalDocument(title: "Local page", parentID: nil, ownerUserID: ownerID)
        let doomed = document("Doomed page")
        coordinator.recordPendingDelete(documentID: doomed.id, ownerUserID: ownerID)
        let kept = document("Kept page")
        viewModel.subpages = [local, doomed, kept]

        typeText("[[page", in: viewModel)

        XCTAssertEqual(viewModel.pageLinkPicker?.matches.map(\.id), [kept.id])
    }

    func testNoMatchesShowsTheEmptyStateUntilASpaceIsTyped() async {
        let (viewModel, _) = await makeEditingViewModel(recents: [document("Roadmap")])

        typeText("[[zzz", in: viewModel)
        XCTAssertEqual(viewModel.pageLinkPicker?.matches, [])

        typeText("[[zzz ", in: viewModel)
        XCTAssertNil(viewModel.pageLinkPicker, "a space after no match means literal brackets")
    }

    func testASpaceInAMatchingQueryKeepsThePickerOpen() async {
        let plan = document("Project plan")
        let (viewModel, _) = await makeEditingViewModel(recents: [plan])

        typeText("[[project pl", in: viewModel)

        XCTAssertEqual(viewModel.pageLinkPicker?.matches.map(\.id), [plan.id])
    }

    // MARK: - Closing with the caret

    func testBackspacingPastTheBracketsClosesThePicker() async {
        let (viewModel, _) = await makeEditingViewModel(recents: [document("Roadmap")])
        typeText("[[", in: viewModel)
        XCTAssertNotNil(viewModel.pageLinkPicker)

        typeText("[", in: viewModel)

        XCTAssertNil(viewModel.pageLinkPicker)
    }

    func testMovingTheCaretOutOfTheQueryClosesThePicker() async {
        let (viewModel, _) = await makeEditingViewModel(recents: [document("Roadmap")])
        typeText("Hi [[ro", in: viewModel)
        XCTAssertNotNil(viewModel.pageLinkPicker)

        viewModel.selection = NSRange(location: 1, length: 0)
        XCTAssertNil(viewModel.pageLinkPicker)
        viewModel.selection = NSRange(location: 3, length: 4)
        XCTAssertNil(viewModel.pageLinkPicker, "a ranged selection")
    }

    func testLeavingTheBlockClosesThePicker() async {
        let (viewModel, _) = await makeEditingViewModel(recents: [document("Roadmap")])
        typeText("[[", in: viewModel)

        viewModel.focusedBlockID = nil

        XCTAssertNil(viewModel.pageLinkPicker)
    }

    func testTheSlashMenuAndCodeBlocksNeverShowThePicker() async {
        let (viewModel, _) = await makeEditingViewModel(recents: [document("Roadmap")])
        typeText("/[[", in: viewModel)
        XCTAssertNotNil(viewModel.slashQueryText)
        XCTAssertNil(viewModel.pageLinkPicker)

        viewModel.blocks[0].kind = .codeBlock(language: "")
        typeText("x [[", in: viewModel)
        XCTAssertNil(viewModel.pageLinkPicker, "a code block's text is literal")
    }

    func testWithoutAServerOriginThereIsNoPicker() async {
        let (viewModel, _) = await makeEditingViewModel(serverOrigin: "", recents: [document("Roadmap")])
        typeText("[[", in: viewModel)
        XCTAssertNil(viewModel.pageLinkPicker)
    }

    // MARK: - Picking

    func testPickingReplacesTheQueryWithAPageChipLink() async throws {
        let id = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let roadmap = document("Roadmap", id: id)
        let (viewModel, _) = await makeEditingViewModel(recents: [roadmap])
        typeText("See [[road", in: viewModel)

        viewModel.selectPageLink(roadmap)

        let link = "[Roadmap](https://docs.example.org/docs/22222222-2222-4222-8222-222222222222/)"
        XCTAssertEqual(viewModel.blocks[0].text, "See " + link)
        let caret = 4 + (link as NSString).length
        XCTAssertEqual(viewModel.selection, NSRange(location: caret, length: 0))
        XCTAssertEqual(viewModel.cursorRequest?.offset, caret)
        XCTAssertNil(viewModel.pageLinkPicker)
        let span = try XCTUnwrap(InlineMarkdown.layout(of: viewModel.blocks[0].text).links.first)
        XCTAssertTrue(isDocumentLink(href: span.url, serverHost: "docs.example.org"), "drawn as a page chip")
        XCTAssertTrue(viewModel.isDirty)
    }

    func testReturnPicksTheHighlightedRow() async {
        let first = document("Alpha", updatedAt: 2)
        let second = document("Alpine", updatedAt: 1)
        let (viewModel, _) = await makeEditingViewModel(recents: [first, second])
        let blockID = viewModel.blocks[0].id
        typeText("[[al", in: viewModel)

        viewModel.handlePageLinkPickerKey(.down)
        XCTAssertEqual(viewModel.pageLinkPicker?.highlightedIndex, 1)
        XCTAssertTrue(viewModel.commitHighlightedPageLink(in: blockID))

        XCTAssertTrue(viewModel.blocks[0].text.hasPrefix("[Alpine]("))
        XCTAssertEqual(viewModel.blocks.count, 1, "Return did not split the block")
    }

    func testReturnFallsThroughWithNothingToPick() async {
        let (viewModel, _) = await makeEditingViewModel(recents: [document("Roadmap")])
        let blockID = viewModel.blocks[0].id

        typeText("plain", in: viewModel)
        XCTAssertFalse(viewModel.commitHighlightedPageLink(in: blockID))
        typeText("[[zzz", in: viewModel)
        XCTAssertFalse(viewModel.commitHighlightedPageLink(in: blockID), "the empty state has no row")
        XCTAssertEqual(viewModel.blocks[0].text, "[[zzz")
    }

    func testArrowKeysWrapAndANewQueryResetsTheHighlight() async {
        let (viewModel, _) = await makeEditingViewModel(recents: [
            document("Alpha", updatedAt: 3), document("Alpine", updatedAt: 2), document("Altitude", updatedAt: 1),
        ])
        typeText("[[al", in: viewModel)

        viewModel.handlePageLinkPickerKey(.up)
        XCTAssertEqual(viewModel.pageLinkPicker?.highlightedIndex, 2)
        viewModel.handlePageLinkPickerKey(.down)
        XCTAssertEqual(viewModel.pageLinkPicker?.highlightedIndex, 0)
        viewModel.handlePageLinkPickerKey(.down)
        XCTAssertEqual(viewModel.pageLinkPicker?.highlightedIndex, 1)

        typeText("[[alp", in: viewModel)
        XCTAssertEqual(viewModel.pageLinkPicker?.highlightedIndex, 0)
    }

    func testTheKeyCommandsAreClaimedOnlyWhileThePickerIsUp() async {
        let (viewModel, _) = await makeEditingViewModel(recents: [document("Roadmap")])
        let blockID = viewModel.blocks[0].id
        XCTAssertFalse(viewModel.isPageLinkPickerActive(in: blockID))

        typeText("[[", in: viewModel)

        XCTAssertTrue(viewModel.isPageLinkPickerActive(in: blockID))
        XCTAssertFalse(viewModel.isPageLinkPickerActive(in: UUID()))
    }

    // MARK: - Escape

    func testEscapeDismissesThisSearchUntilItsBracketsAreRetyped() async {
        let (viewModel, _) = await makeEditingViewModel(recents: [document("Roadmap")])
        typeText("[[ro", in: viewModel)

        viewModel.handlePageLinkPickerKey(.escape)
        XCTAssertNil(viewModel.pageLinkPicker)
        typeText("[[roa", in: viewModel)
        XCTAssertNil(viewModel.pageLinkPicker, "still the dismissed search")

        typeText("[", in: viewModel)
        typeText("[[", in: viewModel)
        XCTAssertNotNil(viewModel.pageLinkPicker, "fresh brackets at the same place open it again")
    }

    func testEscapeLeavesALaterSearchAlone() async {
        let (viewModel, _) = await makeEditingViewModel(recents: [document("Roadmap")])
        typeText("[[x", in: viewModel)
        viewModel.handlePageLinkPickerKey(.escape)

        typeText("[[x]] and [[", in: viewModel)

        XCTAssertNotNil(viewModel.pageLinkPicker)
    }
}
