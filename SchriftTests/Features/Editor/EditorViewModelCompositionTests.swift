import XCTest

@testable import Schrift

/// Input-method composition through `updateComposition`: marked (uncommitted) text may sit in
/// the model for display and layout, but only the commit reaches `markDirty` — and from there
/// peers (live write), the autosave and the draft.
@MainActor
final class EditorViewModelCompositionTests: EditorViewModelTestCase {
    private func makeEditingEnvironment(
        live: CompositionLiveWriteSpy? = nil, autosaveInterval: Duration = .seconds(10), log: RequestRecorder
    ) async -> (viewModel: EditorViewModel, coordinator: DocumentSaveCoordinator, blockID: UUID) {
        let (viewModel, coordinator, _, _) = makeEnvironment(autosaveInterval: autosaveInterval)
        stubLoadAndSavePipeline(content: "Alpha", log: log, contentStatus: 503)
        await viewModel.load()
        viewModel.liveWrite = live
        viewModel.startEditing()
        let blockID = viewModel.blocks[0].id
        viewModel.focusedBlockID = blockID
        return (viewModel, coordinator, blockID)
    }

    private func compose(
        _ text: String, marked: Bool, in blockID: UUID, of viewModel: EditorViewModel
    ) {
        viewModel.updateComposition(
            blockID: blockID, text: text,
            selection: NSRange(location: (text as NSString).length, length: 0), isMarked: marked)
    }

    // MARK: - Marked text is held

    func testMarkedUpdatesDoNotPushToPeersSaveOrDraft() async {
        let log = RequestRecorder()
        let live = CompositionLiveWriteSpy()
        live.handleLive = true
        let (viewModel, coordinator, blockID) = await makeEditingEnvironment(live: live, log: log)

        compose("Alphaに", marked: true, in: blockID, of: viewModel)
        compose("Alphaにほ", marked: true, in: blockID, of: viewModel)
        viewModel.flushPendingChanges()

        XCTAssertEqual(viewModel.blocks[0].text, "Alphaにほ", "the model holds the marked text for display")
        XCTAssertEqual(viewModel.markedTextBlockID, blockID)
        XCTAssertEqual(live.forwardCount, 0, "nothing reached the live delegate")
        XCTAssertFalse(viewModel.isDirty)
        XCTAssertNil(coordinator.pendingSave(documentID: documentID))
        XCTAssertNil(coordinator.storedDraft(documentID: documentID), "no draft was written")
        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: "/content/"), 0)
    }

    func testMarkedUpdatesDoNotMarkAClassicDocumentDirty() async {
        let (viewModel, coordinator, blockID) = await makeEditingEnvironment(log: RequestRecorder())

        compose("Alphaに", marked: true, in: blockID, of: viewModel)

        XCTAssertFalse(viewModel.isDirty)
        viewModel.flushPendingChanges()
        XCTAssertNil(coordinator.pendingSave(documentID: documentID))
        XCTAssertNil(coordinator.storedDraft(documentID: documentID))
    }

    /// The text view reports marked text before the characters on the path that does not hand
    /// the composition off, so a plain `updateText` for a marked block is held the same way.
    func testPlainTextEventsForAMarkedBlockAreHeldToo() async {
        let live = CompositionLiveWriteSpy()
        live.handleLive = true
        let (viewModel, _, blockID) = await makeEditingEnvironment(live: live, log: RequestRecorder())

        viewModel.noteMarkedText(true, in: blockID)
        viewModel.updateText(blockID: blockID, text: "Alphaに")

        XCTAssertEqual(viewModel.blocks[0].text, "Alphaに")
        XCTAssertEqual(live.forwardCount, 0)
        XCTAssertFalse(viewModel.isDirty)

        viewModel.noteMarkedText(false, in: blockID)
        viewModel.updateText(blockID: blockID, text: "Alpha日")

        XCTAssertEqual(live.forwardCount, 1, "the commit publishes")
    }

    /// An autosave armed by an earlier keystroke fires mid-composition: it must not serialize
    /// the marked characters. The commit then publishes them.
    func testAnAutosaveDuringACompositionDoesNotSaveTheMarkedText() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, blockID) = await makeEditingEnvironment(
            autosaveInterval: .milliseconds(50), log: log)
        viewModel.updateText(blockID: blockID, text: "Alpha!")
        compose("Alpha!に", marked: true, in: blockID, of: viewModel)

        await waitAndConfirmNever { coordinator.pendingSave(documentID: self.documentID) != nil }
        XCTAssertTrue(viewModel.isDirty, "the earlier keystroke is still unsaved")

        compose("Alpha!日", marked: false, in: blockID, of: viewModel)
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) != nil }

        XCTAssertEqual(coordinator.pendingSave(documentID: documentID)?.markdown.contains("Alpha!日"), true)
    }

    // MARK: - The commit publishes

    func testCommitPublishesTheCommittedText() async {
        let live = CompositionLiveWriteSpy()
        live.handleLive = true
        let (viewModel, _, blockID) = await makeEditingEnvironment(live: live, log: RequestRecorder())
        compose("Alphaに", marked: true, in: blockID, of: viewModel)
        compose("Alphaにほ", marked: true, in: blockID, of: viewModel)
        XCTAssertEqual(live.forwardCount, 0)

        compose("Alpha日本", marked: false, in: blockID, of: viewModel)

        XCTAssertEqual(viewModel.blocks[0].text, "Alpha日本")
        XCTAssertNil(viewModel.markedTextBlockID)
        XCTAssertEqual(live.forwardCount, 1, "one push, carrying the committed text")
    }

    func testCommitMarksAClassicDocumentDirty() async {
        let (viewModel, _, blockID) = await makeEditingEnvironment(log: RequestRecorder())
        compose("Alphaに", marked: true, in: blockID, of: viewModel)
        XCTAssertFalse(viewModel.isDirty)

        compose("Alpha日", marked: false, in: blockID, of: viewModel)

        XCTAssertTrue(viewModel.isDirty)
    }

    /// The model already holds the last marked text, so `updateText` sees no change: the
    /// commit still has to publish it.
    func testCommitWithTheLastMarkedTextStillPublishes() async {
        let live = CompositionLiveWriteSpy()
        live.handleLive = true
        let (viewModel, _, blockID) = await makeEditingEnvironment(live: live, log: RequestRecorder())
        compose("Alphaに", marked: true, in: blockID, of: viewModel)
        XCTAssertEqual(live.forwardCount, 0)

        compose("Alphaに", marked: false, in: blockID, of: viewModel)

        XCTAssertEqual(live.forwardCount, 1)
        XCTAssertEqual(viewModel.blocks[0].text, "Alphaに")
    }

    func testCommitWithTheLastMarkedTextStillDirtiesAClassicDocument() async {
        let (viewModel, _, blockID) = await makeEditingEnvironment(log: RequestRecorder())
        compose("Alphaに", marked: true, in: blockID, of: viewModel)

        compose("Alphaに", marked: false, in: blockID, of: viewModel)

        XCTAssertTrue(viewModel.isDirty)
    }

    /// A composition that ends where nothing changed (no marked text was ever written) is not
    /// an edit, and publishes nothing.
    func testAnUnmarkWithoutAnyMarkedChangePublishesNothing() async {
        let live = CompositionLiveWriteSpy()
        live.handleLive = true
        let (viewModel, _, blockID) = await makeEditingEnvironment(live: live, log: RequestRecorder())

        compose("Alpha", marked: true, in: blockID, of: viewModel)
        compose("Alpha", marked: false, in: blockID, of: viewModel)

        XCTAssertEqual(live.forwardCount, 0)
        XCTAssertFalse(viewModel.isDirty)
    }

    /// The publish happens once: a later unmarked report with the same text is not a new edit.
    func testALaterIdenticalReportDoesNotPublishAgain() async {
        let live = CompositionLiveWriteSpy()
        live.handleLive = true
        let (viewModel, _, blockID) = await makeEditingEnvironment(live: live, log: RequestRecorder())
        compose("Alphaに", marked: true, in: blockID, of: viewModel)
        compose("Alphaに", marked: false, in: blockID, of: viewModel)

        viewModel.updateText(blockID: blockID, text: "Alphaに")

        XCTAssertEqual(live.forwardCount, 1)
    }

    // MARK: - Existing behaviour

    /// A composition that stops a nested link line being one still steps it out past its nested
    /// siblings right away, as before: that is about layout, not publishing.
    func testMarkedTextStillDetachesABlockThatNoLongerNests() {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let suiteName = "EditorViewModelCompositionTests.\(UUID().uuidString)"
        draftSuiteNames.append(suiteName)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: PendingDraftStore(userDefaults: UserDefaults(suiteName: suiteName)!),
            backgroundTasks: .noop)
        let viewModel = EditorViewModel(
            client: client, documentID: documentID, title: "Doc", saveCoordinator: coordinator)
        let parent = EditorBlock(kind: .checklistItem(checked: false), text: "a")
        let linkLine = EditorBlock(kind: .paragraph, text: "[r](https://docs.example.org/media/r.pdf)", indent: 1)
        let photo = EditorBlock(kind: .image(alt: "p", url: "https://docs.example.org/media/p.jpg"), indent: 1)
        viewModel.blocks = [parent, linkLine, photo]
        viewModel.mode = .blocks

        compose("[r](https://docs.example.org/media/r.pdf) に", marked: true, in: linkLine.id, of: viewModel)

        XCTAssertEqual(viewModel.blocks.map(\.id), [parent.id, photo.id, linkLine.id])
        XCTAssertEqual(viewModel.blocks.map(\.indent), [0, 1, 0], "the photo stays under its item")
        XCTAssertFalse(viewModel.isDirty, "…and nothing was published")
    }
}

@MainActor
private final class CompositionLiveWriteSpy: EditorLiveWriteCoordinating {
    var handleLive = false
    private(set) var forwardCount = 0
    var isHandlingLocalEditsLive: Bool { handleLive }
    func forwardLocalEdit() -> Bool {
        forwardCount += 1
        return handleLive
    }
    func flushPendingLiveSnapshot() {}
}
