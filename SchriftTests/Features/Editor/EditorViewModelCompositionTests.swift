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
        live?.viewModel = viewModel
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
    /// the marked characters. The commit then publishes them, and its `markDirty` arms a fresh
    /// 50 ms timer whose flush is the save.
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

    /// The flush itself still runs (background, Done, onDisappear): it saves what was typed
    /// before the composition and leaves the marked characters out of the save and the draft.
    func testFlushDuringACompositionSavesTheCommittedTextOnly() async {
        let (viewModel, coordinator, blockID) = await makeEditingEnvironment(log: RequestRecorder())
        viewModel.updateText(blockID: blockID, text: "Alpha!")
        compose("Alpha!に", marked: true, in: blockID, of: viewModel)
        XCTAssertTrue(viewModel.isDirty)

        viewModel.flushPendingChanges()

        let save = coordinator.pendingSave(documentID: documentID)
        XCTAssertEqual(save?.markdown.contains("Alpha!"), true, "the flush was not skipped")
        XCTAssertEqual(save?.markdown.contains("に"), false, "…but it left the marked characters out")
        let draft = coordinator.storedDraft(documentID: documentID)
        XCTAssertEqual(draft?.markdown.contains("Alpha!"), true)
        XCTAssertEqual(draft?.markdown.contains("に"), false)
        XCTAssertEqual(viewModel.currentMarkdown().contains("に"), false)
        XCTAssertEqual(viewModel.blocks[0].text, "Alpha!に", "the model still holds them for display")
        await waitUntil { coordinator.state(for: self.documentID) != .saving }
    }

    /// Another edit mid-composition (a format change, a checklist toggle) forwards every block;
    /// the composing one goes out with the text it had before the composition.
    func testAnUnrelatedEditDuringACompositionForwardsThePublishedText() async {
        let live = CompositionLiveWriteSpy()
        live.handleLive = true
        let (viewModel, _, blockID) = await makeEditingEnvironment(live: live, log: RequestRecorder())
        compose("Alphaに", marked: true, in: blockID, of: viewModel)

        viewModel.convertBlock(blockID: blockID, to: .checklistItem(checked: false))

        XCTAssertEqual(live.forwardCount, 1)
        XCTAssertEqual(live.forwardedTexts.last, ["Alpha"], "the marked characters did not go out")
        XCTAssertEqual(viewModel.blocks[0].text, "Alphaに")

        compose("Alphaに", marked: false, in: blockID, of: viewModel)

        XCTAssertEqual(live.forwardedTexts.last, ["Alphaに"], "the commit publishes them")
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

    /// Done mid-composition: the held text counts as committed, is published, and no
    /// composition state survives the session.
    func testDoneDuringACompositionPublishesAndClearsTheState() async {
        let live = CompositionLiveWriteSpy()
        live.handleLive = true
        let (viewModel, _, blockID) = await makeEditingEnvironment(live: live, log: RequestRecorder())
        compose("Alphaに", marked: true, in: blockID, of: viewModel)
        XCTAssertEqual(live.forwardCount, 0)

        viewModel.finishEditing()

        XCTAssertEqual(live.forwardedTexts.last, ["Alphaに"])
        XCTAssertNil(viewModel.markedTextBlockID)
        XCTAssertEqual(viewModel.publishableBlocks.map(\.text), ["Alphaに"])
        XCTAssertEqual(viewModel.mode, .reading)
    }

    func testDoneDuringACompositionSavesTheTextOnAClassicDocument() async {
        let (viewModel, coordinator, blockID) = await makeEditingEnvironment(log: RequestRecorder())
        compose("Alphaに", marked: true, in: blockID, of: viewModel)

        viewModel.finishEditing()

        XCTAssertEqual(coordinator.pendingSave(documentID: documentID)?.markdown.contains("Alphaに"), true)
        XCTAssertNil(viewModel.markedTextBlockID)
        await waitUntil { coordinator.state(for: self.documentID) != .saving }
    }

    /// An unmark the text view reports through a selection change alone has no text event after
    /// it, so the held characters are published on their own.
    func testAnUnmarkReportedBySelectionAloneStillPublishes() async {
        let live = CompositionLiveWriteSpy()
        live.handleLive = true
        let (viewModel, _, blockID) = await makeEditingEnvironment(live: live, log: RequestRecorder())
        compose("Alphaに", marked: true, in: blockID, of: viewModel)

        viewModel.noteMarkedText(false, in: blockID)

        await waitUntil { live.forwardCount == 1 }
        XCTAssertEqual(live.forwardedTexts.last, ["Alphaに"])
    }

    /// A commit that does arrive through `updateText` is published once, not also by the
    /// selection-only fallback.
    func testACommitThroughATextEventPublishesOnlyOnce() async {
        let live = CompositionLiveWriteSpy()
        live.handleLive = true
        let (viewModel, _, blockID) = await makeEditingEnvironment(live: live, log: RequestRecorder())
        viewModel.noteMarkedText(true, in: blockID)
        viewModel.updateText(blockID: blockID, text: "Alphaに")

        viewModel.noteMarkedText(false, in: blockID)
        viewModel.updateText(blockID: blockID, text: "Alpha日")
        await waitAndConfirmNever(timeout: 0.1) { live.forwardCount > 1 }

        XCTAssertEqual(live.forwardedTexts, [["Alpha日"]])
    }

    /// A stale flag (the block lost focus without an unmark) must not stop the autosave.
    func testALostFocusDoesNotDisableTheAutosave() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, blockID) = await makeEditingEnvironment(
            autosaveInterval: .milliseconds(50), log: log)
        viewModel.updateText(blockID: blockID, text: "Alpha!")
        compose("Alpha!に", marked: true, in: blockID, of: viewModel)
        viewModel.focusedBlockID = nil

        await waitUntil { coordinator.pendingSave(documentID: self.documentID) != nil }
    }

    // MARK: - Peers

    /// A peer's edit to the composing block does not replace the marked characters. The replica
    /// now holds the peer's text, so that is what the bridge diffs against; the commit rebases
    /// the user's edit onto it and forwards the merge.
    func testAPeerUpdateDuringACompositionDoesNotClobberTheBlock() async {
        let live = CompositionLiveWriteSpy()
        live.handleLive = true
        let (viewModel, _, blockID) = await makeEditingEnvironment(live: live, log: RequestRecorder())
        compose("Alphaに", marked: true, in: blockID, of: viewModel)

        viewModel.applyLiveRemoteChange(
            LiveChangeSet(changes: [.update(id: blockID, kind: .paragraph, text: "XAlpha")]),
            projectedMarkdown: "XAlpha")

        XCTAssertEqual(viewModel.blocks[0].text, "Alphaに", "the marked characters are untouched")
        XCTAssertEqual(viewModel.publishableBlocks.map(\.text), ["XAlpha"], "the baseline is the peer's text")

        compose("Alpha日", marked: false, in: blockID, of: viewModel)

        XCTAssertEqual(live.forwardedTexts.last, ["XAlpha日"], "the user's edit landed in the peer's text")
        XCTAssertEqual(viewModel.blocks[0].text, "XAlpha日")
    }

    /// The peer changed the text the edit is measured against: the committed text stands, and it
    /// overwrites the peer's text consistently from the peer's baseline.
    func testAPeerUpdateThatTouchesTheEditedTextFallsBackToTheCommittedText() async {
        let live = CompositionLiveWriteSpy()
        live.handleLive = true
        let (viewModel, _, blockID) = await makeEditingEnvironment(live: live, log: RequestRecorder())
        compose("Alphaに", marked: true, in: blockID, of: viewModel)
        viewModel.applyLiveRemoteChange(
            LiveChangeSet(changes: [.update(id: blockID, kind: .paragraph, text: "Be")]),
            projectedMarkdown: "Be")

        compose("Alpha日", marked: false, in: blockID, of: viewModel)

        XCTAssertEqual(live.forwardedTexts.last, ["Alpha日"])
        XCTAssertEqual(viewModel.blocks[0].text, "Alpha日")
    }

    func testRebasedCompositionText() {
        XCTAssertEqual(rebasedCompositionText(original: "abc", committed: "ab日c", onto: "Xabc"), "Xab日c")
        XCTAssertEqual(rebasedCompositionText(original: "abc", committed: "abc日", onto: "abcY"), "abc日Y")
        XCTAssertEqual(rebasedCompositionText(original: "abc", committed: "aXc", onto: "1abc2"), "1aXc2")
        XCTAssertEqual(rebasedCompositionText(original: "abc", committed: "abc", onto: "Xabc"), "Xabc")
        XCTAssertNil(rebasedCompositionText(original: "abc", committed: "ab日c", onto: "ac"), "touched")
        XCTAssertNil(rebasedCompositionText(original: "abc", committed: "ab日c", onto: ""), "deleted")
        XCTAssertNil(rebasedCompositionText(original: "ab", committed: "ab日", onto: "abab"), "ambiguous")
        XCTAssertNil(rebasedCompositionText(original: "", committed: "日", onto: "x"), "nothing to anchor on")
        XCTAssertEqual(
            rebasedCompositionText(original: "e\u{301}a", committed: "e\u{301}a日", onto: "Xe\u{301}a"),
            "Xe\u{301}a日", "graphemes are kept whole")
    }

    // MARK: - Focus

    /// Live editing has no autosave timer: a composition whose block lost focus without an
    /// unmark is published by the next edit anywhere.
    func testALostFocusCompositionIsPublishedByTheNextLiveEdit() async {
        let live = CompositionLiveWriteSpy()
        live.handleLive = true
        let (viewModel, _, blockID) = await makeEditingEnvironment(live: live, log: RequestRecorder())
        let other = EditorBlock(kind: .paragraph, text: "Beta")
        viewModel.blocks.append(other)
        compose("Alphaに", marked: true, in: blockID, of: viewModel)
        viewModel.focusedBlockID = other.id

        viewModel.updateText(blockID: other.id, text: "Beta!")

        XCTAssertGreaterThan(live.forwardCount, 0)
        XCTAssertTrue(live.forwardedTexts.allSatisfy { $0 == ["Alphaに", "Beta!"] }, "A's text went out with B's")
        XCTAssertNil(viewModel.markedTextBlockID)
    }

    func testAFocusChangeNotificationPublishesTheLeftBehindComposition() async {
        let live = CompositionLiveWriteSpy()
        live.handleLive = true
        let (viewModel, _, blockID) = await makeEditingEnvironment(live: live, log: RequestRecorder())
        let other = EditorBlock(kind: .paragraph, text: "Beta")
        viewModel.blocks.append(other)
        compose("Alphaに", marked: true, in: blockID, of: viewModel)
        XCTAssertEqual(live.forwardCount, 0)
        viewModel.focusedBlockID = other.id

        viewModel.noteFocusChange()

        XCTAssertEqual(live.forwardedTexts, [["Alphaに", "Beta"]])
    }

    func testAPeerUpdateToAnotherBlockStillApplies() async {
        let live = CompositionLiveWriteSpy()
        live.handleLive = true
        let (viewModel, _, blockID) = await makeEditingEnvironment(live: live, log: RequestRecorder())
        let other = EditorBlock(kind: .paragraph, text: "Beta")
        viewModel.blocks.append(other)
        compose("Alphaに", marked: true, in: blockID, of: viewModel)

        viewModel.applyLiveRemoteChange(
            LiveChangeSet(changes: [.update(id: other.id, kind: .paragraph, text: "Beta peer")]),
            projectedMarkdown: "Alpha\n\nBeta peer")

        XCTAssertEqual(viewModel.blocks.map(\.text), ["Alphaに", "Beta peer"])
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
    /// What the real bridge reads on a forward: the blocks every peer may see.
    weak var viewModel: EditorViewModel?
    private(set) var forwardCount = 0
    private(set) var forwardedTexts: [[String]] = []
    var isHandlingLocalEditsLive: Bool { handleLive }
    func forwardLocalEdit() -> Bool {
        forwardCount += 1
        forwardedTexts.append(viewModel?.publishableBlocks.map(\.text) ?? [])
        return handleLive
    }
    func flushPendingLiveSnapshot() {}
}
