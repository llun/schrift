import XCTest

@testable import Schrift

/// `applyLiveRemoteChange` and `canEngageLiveEditing` — the C1 bridge's
/// caret-preserving content-swap funnel and its engagement gate. Kept in its
/// own file (see `EditorViewModelTests` for the general save-invariant suite)
/// per the mirrored-test-tree convention for a large existing test file.
@MainActor
final class EditorViewModelLiveTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!

    private var cacheDirectory: URL!
    private var childrenSuiteName: String!
    private var draftSuiteNames: [String] = []

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorViewModelLiveTests-\(UUID().uuidString)", isDirectory: true)
        childrenSuiteName = "EditorViewModelLiveTests.children.\(UUID().uuidString)"
        draftSuiteNames = []
    }

    override func tearDown() {
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: cacheDirectory)
        UserDefaults(suiteName: childrenSuiteName)?.removePersistentDomain(forName: childrenSuiteName)
        for suiteName in draftSuiteNames {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    private func makeEnvironment(
        title: String = "Untitled document",
        autosaveInterval: Duration = .seconds(10),
        remoteChangeDebounce: Duration = .milliseconds(600)
    ) -> (
        viewModel: EditorViewModel, coordinator: DocumentSaveCoordinator, draftStore: PendingDraftStore,
        contentCache: DocumentContentCacheStore
    ) {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let suiteName = "EditorViewModelLiveTests.\(UUID().uuidString)"
        draftSuiteNames.append(suiteName)
        let draftStore = PendingDraftStore(userDefaults: UserDefaults(suiteName: suiteName)!)
        let contentCache = DocumentContentCacheStore(directory: cacheDirectory)
        let childrenCache = DocumentChildrenCacheStore(userDefaults: UserDefaults(suiteName: childrenSuiteName)!)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: draftStore, contentCache: contentCache, backgroundTasks: .noop)
        let viewModel = EditorViewModel(
            client: client,
            documentID: documentID,
            title: title,
            saveCoordinator: coordinator,
            contentCache: contentCache,
            childrenCache: childrenCache,
            autosaveInterval: autosaveInterval,
            remoteChangeDebounce: remoteChangeDebounce
        )
        return (viewModel, coordinator, draftStore, contentCache)
    }

    private func formattedBody(
        content: String?, title: String = "Doc", updatedAt: String = "2026-01-15T10:30:00Z"
    ) -> Data {
        let contentJSON = content.map { "\"\($0)\"" } ?? "null"
        return Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "\(title)", "content": \(contentJSON), "created_at": "2026-01-15T10:30:00Z", "updated_at": "\(updatedAt)"}
            """.utf8)
    }

    private func stubLoad(content: String?, log: RequestRecorder? = nil) {
        let body = formattedBody(content: content)
        MockURLProtocol.stubHandler = { request in
            log?.record(request)
            return .init(statusCode: 200, headers: [:], body: body, error: nil)
        }
    }

    private func stubStatus(_ code: Int) {
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: code, headers: [:], body: Data(), error: nil)
        }
    }

    /// GET returns `content`; every PATCH answers with `contentStatus` (e.g. 503 to
    /// force a transient/`.pendingSync` failure) or 200 for the title PATCH.
    private func stubLoadAndSavePipeline(content: String?, log: RequestRecorder, contentStatus: Int) {
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
                return .init(statusCode: 200, headers: [:], body: Data(), error: nil)
            default:
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
            }
        }
    }

    private func savesInFlight(_ log: RequestRecorder) -> Int {
        log.count(ofMethod: "PATCH", urlContaining: "/content/")
    }

    /// Loads a three-paragraph document ("Alpha" / "Beta" / "Gamma") into a clean
    /// view model and returns it alongside the three blocks' ids in document order.
    private func loadThreeBlockDocument() async -> (
        viewModel: EditorViewModel, coordinator: DocumentSaveCoordinator, ids: [UUID]
    ) {
        let (viewModel, coordinator, _, _) = makeEnvironment()
        stubLoad(content: "Alpha\\n\\nBeta\\n\\nGamma")
        await viewModel.load()
        return (viewModel, coordinator, viewModel.blocks.map(\.id))
    }

    // MARK: - Block identity + application

    func testApplyLiveRemoteChangePreservesUntouchedBlockIdentity() async {
        let (viewModel, _, ids) = await loadThreeBlockDocument()
        let (idA, idB, idC) = (ids[0], ids[1], ids[2])

        viewModel.applyLiveRemoteChange(
            LiveChangeSet(changes: [.update(id: idB, kind: .paragraph, text: "Beta2")]),
            projectedMarkdown: serializeMarkdown([
                EditorBlock(id: idA, kind: .paragraph, text: "Alpha"),
                EditorBlock(id: idB, kind: .paragraph, text: "Beta2"),
                EditorBlock(id: idC, kind: .paragraph, text: "Gamma"),
            ]))

        XCTAssertEqual(viewModel.blocks.map(\.id), [idA, idB, idC], "no block was re-identified")
        XCTAssertEqual(viewModel.blocks[1].text, "Beta2")
        XCTAssertEqual(viewModel.blocks[0].text, "Alpha", "block A is untouched")
        XCTAssertEqual(viewModel.blocks[2].text, "Gamma", "block C is untouched")
        XCTAssertFalse(viewModel.isDirty)
    }

    // MARK: - Caret preservation

    func testCaretInFocusedBlockShiftsWithRemoteInsertBeforeIt() async {
        let (viewModel, _, ids) = await loadThreeBlockDocument()
        let idB = ids[1]
        // Re-seed B with text whose caret math is easy to hand-verify.
        viewModel.applyLiveRemoteChange(
            LiveChangeSet(changes: [.update(id: idB, kind: .paragraph, text: "the cat sat")]),
            projectedMarkdown: "seed")
        viewModel.focusedBlockID = idB
        viewModel.selection = NSRange(location: 8, length: 0)
        viewModel.cursorRequest = EditorViewModel.CursorRequest(blockID: idB, offset: 8)

        // Insert "big " right after "the " (before the caret at 8): "the cat sat" -> "the big cat sat".
        viewModel.applyLiveRemoteChange(
            LiveChangeSet(changes: [.update(id: idB, kind: .paragraph, text: "the big cat sat")]),
            projectedMarkdown: "the big cat sat\n")

        XCTAssertEqual(viewModel.focusedBlockID, idB)
        XCTAssertEqual(viewModel.cursorRequest?.offset, 12, "caret shifts right by the 4 inserted characters")
        XCTAssertEqual(viewModel.selection?.location, 12)
        XCTAssertEqual(viewModel.selection?.length, 0)
    }

    func testRemoteInsertAfterCaretLeavesCaret() async {
        let (viewModel, _, ids) = await loadThreeBlockDocument()
        let idB = ids[1]
        viewModel.applyLiveRemoteChange(
            LiveChangeSet(changes: [.update(id: idB, kind: .paragraph, text: "the cat sat")]),
            projectedMarkdown: "seed")
        viewModel.focusedBlockID = idB
        viewModel.selection = NSRange(location: 4, length: 0)
        viewModel.cursorRequest = EditorViewModel.CursorRequest(blockID: idB, offset: 4)

        // Insert "XYZ " after "the cat " (well past the caret at 4): "the cat sat" -> "the cat XYZ sat".
        viewModel.applyLiveRemoteChange(
            LiveChangeSet(changes: [.update(id: idB, kind: .paragraph, text: "the cat XYZ sat")]),
            projectedMarkdown: "the cat XYZ sat\n")

        XCTAssertEqual(viewModel.cursorRequest?.offset, 4, "caret is unaffected by an insert after it")
        XCTAssertEqual(viewModel.selection?.location, 4)
    }

    func testRemoteChangeToDifferentBlockLeavesFocusAndCaret() async {
        let (viewModel, _, ids) = await loadThreeBlockDocument()
        let (idA, idB) = (ids[0], ids[1])
        viewModel.focusedBlockID = idB
        viewModel.selection = NSRange(location: 2, length: 0)
        viewModel.cursorRequest = EditorViewModel.CursorRequest(blockID: idB, offset: 2)
        let cursorRequestBefore = viewModel.cursorRequest

        viewModel.applyLiveRemoteChange(
            LiveChangeSet(changes: [.update(id: idA, kind: .paragraph, text: "Alpha-changed")]),
            projectedMarkdown: "Alpha-changed\n\nBeta\n\nGamma\n")

        XCTAssertEqual(viewModel.focusedBlockID, idB, "focus stays on B")
        XCTAssertEqual(viewModel.cursorRequest, cursorRequestBefore, "no fresh CursorRequest was minted")
        XCTAssertEqual(viewModel.selection, NSRange(location: 2, length: 0))
        XCTAssertEqual(viewModel.blocks.first(where: { $0.id == idA })?.text, "Alpha-changed")
    }

    func testFocusedBlockRemovedClampsFocusToNeighbour() async {
        let (viewModel, _, ids) = await loadThreeBlockDocument()
        let (idB, idC) = (ids[1], ids[2])
        viewModel.focusedBlockID = idB
        viewModel.selection = NSRange(location: 1, length: 0)
        viewModel.cursorRequest = EditorViewModel.CursorRequest(blockID: idB, offset: 1)

        viewModel.applyLiveRemoteChange(
            LiveChangeSet(changes: [.remove(id: idB)]), projectedMarkdown: "Alpha\n\nGamma\n")

        XCTAssertEqual(viewModel.focusedBlockID, idC, "focus follows to the block that took B's position")
        XCTAssertEqual(viewModel.cursorRequest?.blockID, idC)
        XCTAssertEqual(viewModel.cursorRequest?.offset, 0)
        XCTAssertFalse(viewModel.blocks.contains { $0.id == idB })
    }

    func testFocusedBlockRemovedWithNoSurvivorsClearsFocus() async {
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoad(content: "Solo")
        await viewModel.load()
        let idOnly = viewModel.blocks[0].id
        viewModel.focusedBlockID = idOnly
        viewModel.selection = NSRange(location: 1, length: 0)
        viewModel.cursorRequest = EditorViewModel.CursorRequest(blockID: idOnly, offset: 1)

        viewModel.applyLiveRemoteChange(LiveChangeSet(changes: [.remove(id: idOnly)]), projectedMarkdown: "")

        XCTAssertNil(viewModel.focusedBlockID)
        XCTAssertNil(viewModel.cursorRequest)
        XCTAssertNil(viewModel.selection)
        XCTAssertTrue(viewModel.blocks.isEmpty)
    }

    // MARK: - No side effects on the save machinery

    func testApplyLiveRemoteChangeAdvancesBaselineAndEnqueuesNothing() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, _, _) = makeEnvironment()
        stubLoad(content: "Original", log: log)
        await viewModel.load()
        let onlyBlockID = viewModel.blocks[0].id
        XCTAssertEqual(savesInFlight(log), 0)

        let projected = serializeMarkdown([EditorBlock(id: onlyBlockID, kind: .paragraph, text: "Changed")])
        viewModel.applyLiveRemoteChange(
            LiveChangeSet(changes: [.update(id: onlyBlockID, kind: .paragraph, text: "Changed")]),
            projectedMarkdown: projected,
            projectedTitle: "Live Title")

        XCTAssertFalse(viewModel.isDirty, "a live apply is not local work")
        XCTAssertNil(coordinator.pendingSave(documentID: documentID), "nothing was enqueued by the apply itself")
        XCTAssertEqual(savesInFlight(log), 0, "no PATCH was made")
        XCTAssertEqual(viewModel.title, "Live Title")

        // `currentMarkdown()` only reflects `blocks` in editing mode; entering it here
        // does not itself touch `savedMarkdown`/`serverBaseline`/`isDirty`.
        viewModel.startEditing()

        // Round-trip through a real (later) local edit that reverts the text back to
        // exactly what the live apply projected. If `savedMarkdown` had not advanced
        // to `projected`, this flush would see a divergence and enqueue a save; since
        // it *did* advance, the flush recognizes "no-op" and enqueues nothing.
        viewModel.updateText(blockID: onlyBlockID, text: "Temp")
        viewModel.updateText(blockID: onlyBlockID, text: "Changed")
        viewModel.flushPendingChanges()

        XCTAssertFalse(viewModel.isDirty)
        XCTAssertEqual(savesInFlight(log), 0, "the reverted edit serializes back to the live-applied baseline")

        // `serverBaseline` also advanced: force a real divergent edit through so
        // `enqueue` fires, and check the baseline it carries is the live-applied one
        // (its markdown/title), not the edit's own content.
        viewModel.updateText(blockID: onlyBlockID, text: "Genuinely different")
        viewModel.flushPendingChanges()
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) != nil }

        let draft = coordinator.storedDraft(documentID: documentID)
        XCTAssertEqual(draft?.baseline?.markdown, projected)
        XCTAssertEqual(draft?.baseline?.title, "Live Title")
        XCTAssertNil(draft?.baseline?.serverUpdatedAt, "a live-applied baseline carries no server timestamp")

        // Let the save settle before the test ends, so nothing outlives it into tearDown.
        await waitUntil { coordinator.state(for: self.documentID) != .saving }
    }

    func testApplyLiveRemoteChangeIsANoOpBeforeContentHasLoaded() {
        let (viewModel, coordinator, _, _) = makeEnvironment()

        viewModel.applyLiveRemoteChange(
            LiveChangeSet(changes: [.insert(id: UUID(), kind: .paragraph, text: "New", afterID: nil)]),
            projectedMarkdown: "New\n")

        XCTAssertTrue(viewModel.blocks.isEmpty, "the funnel never creates content out of nothing")
        XCTAssertFalse(viewModel.isDirty)
        XCTAssertNil(coordinator.pendingSave(documentID: documentID))
    }

    // MARK: - canEngageLiveEditing truth table

    func testCanEngageLiveEditingTrueWhenCleanAndIdle() async {
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoad(content: "Hello")
        await viewModel.load()

        XCTAssertTrue(viewModel.canEngageLiveEditing)
    }

    func testCanEngageLiveEditingFalseBeforeContentLoads() {
        let (viewModel, _, _, _) = makeEnvironment()
        XCTAssertFalse(viewModel.canEngageLiveEditing)
    }

    func testCanEngageLiveEditingFalseWhenDirty() async {
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoad(content: "Hello")
        await viewModel.load()
        viewModel.startEditing()

        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Hello there")

        XCTAssertTrue(viewModel.isDirty)
        XCTAssertFalse(viewModel.canEngageLiveEditing)
    }

    func testCanEngageLiveEditingFalseWhenConflictRecorded() async {
        let (viewModel, coordinator, _, _) = makeEnvironment()
        stubLoad(content: "Hello")
        await viewModel.load()

        coordinator.recordConflict(documentID: documentID, serverUpdatedAt: Date())

        XCTAssertFalse(viewModel.canEngageLiveEditing)
    }

    func testCanEngageLiveEditingFalseWhenDraftIsStored() async {
        let (viewModel, _, draftStore, _) = makeEnvironment()
        stubLoad(content: "Hello")
        await viewModel.load()

        draftStore.save(
            PendingDraft(documentID: documentID, title: "Doc", markdown: "Stashed from elsewhere", updatedAt: Date())
        )

        XCTAssertFalse(viewModel.canEngageLiveEditing)
    }

    func testCanEngageLiveEditingFalseWhenSaveIsPending() async {
        let (viewModel, coordinator, _, _) = makeEnvironment()
        stubLoad(content: "Hello")
        await viewModel.load()

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "Somebody else's save")

        XCTAssertNotNil(coordinator.pendingSave(documentID: documentID))
        XCTAssertFalse(viewModel.canEngageLiveEditing)

        // Let the save settle before the test ends, so nothing outlives it into tearDown.
        await waitUntil { coordinator.state(for: self.documentID) != .saving }
    }

    func testCanEngageLiveEditingFalseWhenPendingSync() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, _, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "Hello", log: log, contentStatus: 503)
        await viewModel.load()
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Hello there")
        viewModel.flushPendingChanges()
        await waitUntil { coordinator.state(for: self.documentID) == .pendingSync }

        XCTAssertFalse(viewModel.isDirty, "the failed flush already cleared it")
        XCTAssertFalse(viewModel.canEngageLiveEditing)
    }

    func testCanEngageLiveEditingFalseWhenDiscarded() async {
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoad(content: "Hello")
        await viewModel.load()

        viewModel.handleDidDelete()

        XCTAssertTrue(viewModel.isDocumentDiscarded)
        XCTAssertFalse(viewModel.canEngageLiveEditing)
    }

    func testCanEngageLiveEditingFalseWhenUnavailable() async {
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoad(content: "Hello")
        await viewModel.load()

        stubStatus(404)
        await viewModel.refresh()

        XCTAssertTrue(viewModel.isUnavailable)
        XCTAssertFalse(viewModel.canEngageLiveEditing)
    }

    // MARK: - Live-write mode split (C2c)

    func testLiveEditForwardsAndSkipsClassicDirtyMachinery() async {
        let (viewModel, coordinator, _, _) = makeEnvironment()
        stubLoad(content: "Alpha")
        await viewModel.load()
        let live = FakeLiveWrite()
        live.handleLive = true
        viewModel.liveWrite = live

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Alpha edited")

        XCTAssertEqual(live.forwardCount, 1, "the keystroke was offered to the live delegate")
        XCTAssertFalse(viewModel.isDirty, "live mode never engages the classic dirty machinery")
        XCTAssertNil(coordinator.pendingSave(documentID: documentID), "no classic REST save enqueued")
    }

    func testClassicEditIsUntouchedWhenLiveDelegateDeclines() async {
        let (viewModel, coordinator, _, _) = makeEnvironment()
        stubLoad(content: "Alpha")
        await viewModel.load()
        let live = FakeLiveWrite()
        live.handleLive = false  // downgrade / not engaged
        viewModel.liveWrite = live

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Alpha edited")

        XCTAssertEqual(live.forwardCount, 1, "the edit was offered to the delegate, which declined")
        XCTAssertTrue(viewModel.isDirty, "the classic dirty machinery runs exactly as before")
        // The edit is not lost: the autosave debounce holds it (10 s), and it is
        // captured in `blocks`. Downgrade never drops an edit.
        _ = coordinator
    }

    func testPersistLiveSnapshotEnqueuesLiveSaveAndAdvancesBaseline() async {
        let (viewModel, coordinator, _, _) = makeEnvironment()
        stubLoad(content: "Alpha")
        await viewModel.load()
        XCTAssertNil(coordinator.storedDraft(documentID: documentID))

        viewModel.persistLiveSnapshot(Data([0x0A, 0x0B]), projectedMarkdown: "Alpha live")

        // The projected markdown is the live save's write-ahead draft body (read
        // synchronously — a confirmed save removes the draft in the coordinator's `finish`).
        // Its own baseline still describes the pre-snapshot server state the snapshot descends
        // from ("Alpha"), exactly like a classic save's baseline.
        let liveDraft = coordinator.storedDraft(documentID: documentID)
        XCTAssertEqual(liveDraft?.markdown, "Alpha live", "the projected markdown is the live save's write-ahead body")
        XCTAssertEqual(
            liveDraft?.baseline?.markdown, "Alpha", "the snapshot descends from the pre-snapshot server state")

        // Let the live save settle (its stub returns 200), recording `lastConfirmedPush`
        // and clearing the draft.
        await waitUntil { coordinator.state(for: self.documentID) != .saving }

        // The VM's dirty baseline advanced to the projected content: a later classic edit's
        // draft carries "Alpha live" as its baseline (markdown + title), so a downgrade
        // reconciles by body-equality and never false-conflicts (C2b coherence).
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Alpha classic")
        viewModel.flushPendingChanges()
        let classicDraft = coordinator.storedDraft(documentID: documentID)
        XCTAssertEqual(classicDraft?.markdown, "Alpha classic\n", "the classic edit is what enqueued this draft")
        XCTAssertEqual(classicDraft?.baseline?.markdown, "Alpha live", "the baseline advanced to the live snapshot")
        XCTAssertEqual(classicDraft?.baseline?.title, "Doc")

        // Let the classic save settle so nothing outlives the test into tearDown.
        await waitUntil { coordinator.state(for: self.documentID) != .saving }
    }

    func testFlushPendingChangesFiresLiveFlush() async {
        let (viewModel, _, _, _) = makeEnvironment()
        let live = FakeLiveWrite()
        viewModel.liveWrite = live

        viewModel.flushPendingChanges()

        XCTAssertEqual(live.flushCount, 1, "the pending live snapshot is flushed before the classic guard")
    }

    func testNoLiveDelegateRunsClassicPathUnchanged() async {
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoad(content: "Alpha")
        await viewModel.load()
        // No `liveWrite` set — the mode-split guard is a pure no-op (`nil?.x == true`
        // is false), so the classic dirty machinery runs exactly as today.
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Alpha edited")

        XCTAssertTrue(viewModel.isDirty, "with no delegate the classic path is untouched")
    }
}

/// A scripted stand-in for the C1/C2c `LiveEditingBridge`. `handleLive` toggles
/// whether `forwardLocalEdit()` claims the edit (live) or declines it (downgrade).
@MainActor
private final class FakeLiveWrite: EditorLiveWriteCoordinating {
    var handleLive = false
    private(set) var forwardCount = 0
    private(set) var flushCount = 0
    func forwardLocalEdit() -> Bool {
        forwardCount += 1
        return handleLive
    }
    func flushPendingLiveSnapshot() { flushCount += 1 }
}
