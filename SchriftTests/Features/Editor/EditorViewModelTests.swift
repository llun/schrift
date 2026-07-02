import XCTest
@testable import Schrift

@MainActor
final class EditorViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!

    override func tearDown() {
        MockURLProtocol.stubHandler = nil
        MockURLProtocol.lastRequest = nil
        super.tearDown()
    }

    private func makeEnvironment(
        title: String = "Untitled document",
        autosaveInterval: Duration = .seconds(10)
    ) -> (viewModel: EditorViewModel, coordinator: DocumentSaveCoordinator, draftStore: PendingDraftStore) {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let suiteName = "EditorViewModelTests.\(UUID().uuidString)"
        let draftStore = PendingDraftStore(userDefaults: UserDefaults(suiteName: suiteName)!)
        let coordinator = DocumentSaveCoordinator(client: client, draftStore: draftStore, backgroundTasks: .noop)
        let viewModel = EditorViewModel(
            client: client,
            documentID: documentID,
            title: title,
            saveCoordinator: coordinator,
            autosaveInterval: autosaveInterval
        )
        return (viewModel, coordinator, draftStore)
    }

    private func formattedBody(content: String?) -> Data {
        let contentJSON = content.map { "\"\($0)\"" } ?? "null"
        return Data("""
        {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": \(contentJSON), "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
        """.utf8)
    }

    private func stubLoad(content: String?, log: RequestRecorder? = nil) {
        let body = formattedBody(content: content)
        MockURLProtocol.stubHandler = { request in
            log?.record(request)
            return .init(statusCode: 200, headers: [:], body: body, error: nil)
        }
    }

    /// A save is a content PATCH (base64 Yjs) followed by a title PATCH; each
    /// save is counted by its single content PATCH.
    private func savesInFlight(_ log: RequestRecorder) -> Int {
        log.count(ofMethod: "PATCH", urlContaining: "/content/")
    }

    private func stubLoadAndSavePipeline(content: String?, log: RequestRecorder, contentStatus: Int = 204) {
        let body = formattedBody(content: content)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            switch request.httpMethod {
            case "GET" where url.contains("formatted-content"):
                return .init(statusCode: 200, headers: [:], body: body, error: nil)
            case "PATCH" where url.hasSuffix("/content/"):
                return .init(statusCode: contentStatus, headers: [:], body: Data(), error: nil)
            case "PATCH":
                return .init(statusCode: 200, headers: [:], body: Data(), error: nil) // title
            default:
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
            }
        }
    }

    // MARK: - Loading

    func testLoadParsesMarkdownContentIntoBlocks() async {
        let (viewModel, _, _) = makeEnvironment()
        stubLoad(content: "# Heading\\n\\nA paragraph.")

        await viewModel.load()

        XCTAssertTrue(blocksContentEqual(viewModel.blocks, [
            EditorBlock(kind: .heading(level: 1), text: "Heading"),
            EditorBlock(kind: .paragraph, text: "A paragraph."),
        ]))
        XCTAssertEqual(viewModel.title, "Doc")
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.openInMarkdownMode)
    }

    func testLoadWithNullContentProducesNoBlocks() async {
        let (viewModel, _, _) = makeEnvironment()
        stubLoad(content: nil)

        await viewModel.load()

        XCTAssertTrue(viewModel.blocks.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testLoadKeepsOriginalTitleWhenServerTitleIsNull() async {
        let (viewModel, _, _) = makeEnvironment(title: "Original Title")
        let body = Data("""
        {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": null, "content": "Text", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
        """.utf8)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }

        await viewModel.load()

        XCTAssertEqual(viewModel.title, "Original Title")
    }

    func testLoadFailureSetsErrorMessage() async {
        let (viewModel, _, _) = makeEnvironment()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.load()

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertTrue(viewModel.blocks.isEmpty)
    }

    func testLoadPrefersStoredDraftNewerThanServer() async {
        let (viewModel, _, draftStore) = makeEnvironment()
        stubLoad(content: "Server content")
        draftStore.save(PendingDraft(documentID: documentID, title: "Draft Title", markdown: "Draft content", updatedAt: Date()))

        await viewModel.load()

        XCTAssertEqual(viewModel.rawMarkdown, "Draft content")
        XCTAssertEqual(viewModel.title, "Draft Title")
        XCTAssertTrue(blocksContentEqual(viewModel.blocks, [EditorBlock(kind: .paragraph, text: "Draft content")]))
    }

    func testLoadIgnoresStoredDraftOlderThanServer() async {
        let (viewModel, _, draftStore) = makeEnvironment()
        stubLoad(content: "Server content")
        draftStore.save(PendingDraft(documentID: documentID, title: "Old", markdown: "Stale draft", updatedAt: Date(timeIntervalSince1970: 0)))

        await viewModel.load()

        XCTAssertEqual(viewModel.rawMarkdown, "Server content")
    }

    func testLoadDefaultsToMarkdownModeWhenRoundTripUnsafe() async {
        let (viewModel, _, _) = makeEnvironment()
        // A lone opening fence can't round-trip through block editing.
        stubLoad(content: "```")

        await viewModel.load()
        viewModel.startEditing()

        XCTAssertTrue(viewModel.openInMarkdownMode)
        XCTAssertEqual(viewModel.mode, .markdown)
    }

    // MARK: - Editing session

    func testStartEditingEntersBlocksMode() async {
        let (viewModel, _, _) = makeEnvironment()
        stubLoad(content: "Original text")
        await viewModel.load()

        viewModel.startEditing()

        XCTAssertTrue(viewModel.isEditing)
        XCTAssertEqual(viewModel.mode, .blocks)
        XCTAssertFalse(viewModel.isDirty)
    }

    func testStartEditingOnEmptyDocumentSeedsAParagraph() async {
        let (viewModel, _, _) = makeEnvironment()
        stubLoad(content: nil)
        await viewModel.load()

        viewModel.startEditing()

        XCTAssertEqual(viewModel.mode, .blocks)
        XCTAssertEqual(viewModel.blocks.count, 1)
        XCTAssertEqual(viewModel.blocks[0].kind, .paragraph)
        XCTAssertEqual(viewModel.focusedBlockID, viewModel.blocks[0].id)
    }

    func testStartEditingIsBlockedUntilContentLoads() async {
        let (viewModel, _, _) = makeEnvironment()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }
        await viewModel.load()

        viewModel.startEditing()

        // Editing an unloaded document would autosave an empty draft over
        // the entire server copy.
        XCTAssertFalse(viewModel.isEditing)
        XCTAssertEqual(viewModel.mode, .reading)
    }

    func testEditingMarksDirty() async {
        let (viewModel, _, _) = makeEnvironment()
        stubLoad(content: "Original text")
        await viewModel.load()
        viewModel.startEditing()

        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Changed text")

        XCTAssertTrue(viewModel.isDirty)
        XCTAssertEqual(viewModel.saveState, .dirty)
    }

    func testAutosaveFlushesAfterInterval() async {
        let log = RequestRecorder()
        let (viewModel, _, _) = makeEnvironment(autosaveInterval: .milliseconds(80))
        stubLoadAndSavePipeline(content: "Original text", log: log)
        await viewModel.load()
        viewModel.startEditing()

        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Changed text")

        XCTAssertEqual(savesInFlight(log), 0)
        await waitUntil { self.savesInFlight(log) >= 1 && viewModel.saveState == .saved }

        XCTAssertEqual(viewModel.saveState, .saved)
        XCTAssertGreaterThanOrEqual(savesInFlight(log), 1)
    }

    func testTypingRestartsTheDebounce() async {
        let log = RequestRecorder()
        let (viewModel, _, _) = makeEnvironment(autosaveInterval: .milliseconds(400))
        stubLoadAndSavePipeline(content: "Original text", log: log)
        await viewModel.load()
        viewModel.startEditing()

        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Change one")
        try? await Task.sleep(for: .milliseconds(200))
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Change two")

        // 200ms after the first edit the (restarted) debounce must not have fired.
        XCTAssertEqual(savesInFlight(log), 0)

        await waitUntil { viewModel.saveState == .saved }
        XCTAssertEqual(savesInFlight(log), 1)
    }

    func testFlushSkipsWhenContentUnchanged() async {
        let log = RequestRecorder()
        let (viewModel, _, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "Original text", log: log)
        await viewModel.load()
        viewModel.startEditing()
        let blockID = viewModel.blocks[0].id

        viewModel.updateText(blockID: blockID, text: "Changed")
        viewModel.updateText(blockID: blockID, text: "Original text")
        viewModel.flushPendingChanges()

        XCTAssertFalse(viewModel.isDirty)
        XCTAssertEqual(savesInFlight(log), 0)
        XCTAssertEqual(viewModel.saveState, .idle)
    }

    func testDoneFlushesPendingChangesAndExits() async {
        let log = RequestRecorder()
        let (viewModel, _, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "Original text", log: log)
        await viewModel.load()
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Changed text")

        viewModel.finishEditing()

        XCTAssertEqual(viewModel.mode, .reading)
        XCTAssertFalse(viewModel.isDirty)
        XCTAssertNil(viewModel.focusedBlockID)
        await waitUntil { viewModel.saveState == .saved }
        XCTAssertEqual(savesInFlight(log), 1)
    }

    func testFailedSaveSurfacesFailedStateAndKeepsDraft() async {
        let log = RequestRecorder()
        let (viewModel, _, draftStore) = makeEnvironment()
        stubLoadAndSavePipeline(content: "Original text", log: log, contentStatus: 500)
        await viewModel.load()
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Changed text")

        viewModel.flushPendingChanges()

        await waitUntil {
            if case .failed = viewModel.saveState { return true }
            return false
        }
        guard case .failed = viewModel.saveState else {
            return XCTFail("Expected failed save state, got \(viewModel.saveState)")
        }
        XCTAssertEqual(draftStore.draft(for: documentID)?.markdown, "Changed text\n")
        XCTAssertTrue(viewModel.isEditing)
    }

    func testSaveNowRetriesAfterFailure() async {
        let log = RequestRecorder()
        let (viewModel, _, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "Original text", log: log, contentStatus: 500)
        await viewModel.load()
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Changed text")
        viewModel.flushPendingChanges()
        await waitUntil {
            if case .failed = viewModel.saveState { return true }
            return false
        }

        stubLoadAndSavePipeline(content: "Original text", log: log, contentStatus: 204)
        viewModel.saveNow()

        await waitUntil { viewModel.saveState == .saved }
        XCTAssertEqual(viewModel.saveState, .saved)
    }

    // MARK: - Mode toggle

    func testSwitchingToMarkdownSerializesBlocks() async {
        let (viewModel, _, _) = makeEnvironment()
        stubLoad(content: "# Title\\n\\nBody")
        await viewModel.load()
        viewModel.startEditing()

        viewModel.setMode(.markdown)

        XCTAssertEqual(viewModel.mode, .markdown)
        XCTAssertEqual(viewModel.rawMarkdown, "# Title\n\nBody\n")
    }

    func testSwitchingBackToBlocksReparsesMarkdown() async {
        let (viewModel, _, _) = makeEnvironment()
        stubLoad(content: "# Title")
        await viewModel.load()
        viewModel.startEditing()
        viewModel.setMode(.markdown)

        viewModel.updateRawMarkdown("# Title\n\n- New item\n")
        viewModel.setMode(.blocks)

        XCTAssertEqual(viewModel.mode, .blocks)
        XCTAssertTrue(blocksContentEqual(viewModel.blocks, [
            EditorBlock(kind: .heading(level: 1), text: "Title"),
            EditorBlock(kind: .bulletItem, text: "New item"),
        ]))
        XCTAssertTrue(viewModel.isDirty)
    }

    func testCurrentMarkdownFollowsTheActiveMode() async {
        let (viewModel, _, _) = makeEnvironment()
        stubLoad(content: "# Title")
        await viewModel.load()
        viewModel.startEditing()

        XCTAssertEqual(viewModel.currentMarkdown(), "# Title\n")

        viewModel.setMode(.markdown)
        viewModel.updateRawMarkdown("raw edited")

        XCTAssertEqual(viewModel.currentMarkdown(), "raw edited")
    }
}
