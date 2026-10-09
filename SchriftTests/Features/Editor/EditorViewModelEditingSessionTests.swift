import XCTest

@testable import Schrift

@MainActor
final class EditorViewModelEditingSessionTests: EditorViewModelTestCase {
    func testEnteringAndLeavingEditingKeepsTheImageBlockAndExactURL() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        let url = "https://docs.example.org/media/photo.png?revision=1"
        let markdown = "![Diagram](\(url))"
        contentCache.save(cachedEntry(markdown: markdown))
        stubOffline()
        await viewModel.load()
        XCTAssertEqual(viewModel.blocks.first?.kind, .image(alt: "Diagram", url: url))
        viewModel.startEditing()
        XCTAssertEqual(viewModel.blocks.first?.kind, .image(alt: "Diagram", url: url))
        viewModel.finishEditing()
        XCTAssertEqual(viewModel.rawMarkdown, markdown)
        XCTAssertEqual(viewModel.blocks.first?.kind, .image(alt: "Diagram", url: url))
    }

    // MARK: - Editing session

    func testStartEditingEntersBlocksMode() async {
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoad(content: "Original text")
        await viewModel.load()

        viewModel.startEditing()

        XCTAssertTrue(viewModel.isEditing)
        XCTAssertEqual(viewModel.mode, .blocks)
        XCTAssertFalse(viewModel.isDirty)
    }

    func testStartEditingOnEmptyDocumentSeedsAParagraph() async {
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoad(content: nil)
        await viewModel.load()

        viewModel.startEditing()

        XCTAssertEqual(viewModel.mode, .blocks)
        XCTAssertEqual(viewModel.blocks.count, 1)
        XCTAssertEqual(viewModel.blocks[0].kind, .paragraph)
        XCTAssertEqual(viewModel.focusedBlockID, viewModel.blocks[0].id)
    }

    func testStartEditingIsBlockedUntilContentLoads() async {
        let (viewModel, _, _, _) = makeEnvironment()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }
        await viewModel.load()

        viewModel.startEditing()

        // Editing an unloaded document would autosave an empty draft over
        // the entire server copy.
        XCTAssertFalse(viewModel.isEditing)
        XCTAssertEqual(viewModel.mode, .reading)
    }

    func testEditingMarksDirty() async {
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoad(content: "Original text")
        await viewModel.load()
        viewModel.startEditing()

        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Changed text")

        XCTAssertTrue(viewModel.isDirty)
        XCTAssertEqual(viewModel.saveState, .dirty)
    }

    func testAutosaveFlushesAfterInterval() async {
        let log = RequestRecorder()
        let (viewModel, _, _, _) = makeEnvironment(autosaveInterval: .milliseconds(80))
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
        // A 2 s debounce with a 200 ms gap between edits leaves ~1.8 s of slack for
        // the negative assertion — the earlier 400 ms/200 ms pairing left only
        // ~200 ms, which a loaded CI runner routinely overran, firing the save early.
        let (viewModel, _, _, _) = makeEnvironment(autosaveInterval: .seconds(2))
        stubLoadAndSavePipeline(content: "Original text", log: log)
        await viewModel.load()
        viewModel.startEditing()

        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Change one")
        try? await Task.sleep(for: .milliseconds(200))
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Change two")

        // A fraction into the (restarted) debounce, the save must not have fired.
        XCTAssertEqual(savesInFlight(log), 0)

        await waitUntil(timeout: 6) { viewModel.saveState == .saved }
        XCTAssertEqual(savesInFlight(log), 1, "the two edits coalesced into one save")
    }

    func testFlushSkipsWhenContentUnchanged() async {
        let log = RequestRecorder()
        let (viewModel, _, _, _) = makeEnvironment()
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
        let (viewModel, _, _, _) = makeEnvironment()
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
        let (viewModel, _, draftStore, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "Original text", log: log, contentStatus: 400)
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

    /// A transient (5xx/offline) save failure surfaces as `.pendingSync`, not the
    /// scary `.failed`, and still counts as unsaved local content (its draft is the
    /// user's only copy until the queued sync lands).
    func testTransientSaveFailureSurfacesPendingSyncAndCountsAsUnsaved() async {
        let log = RequestRecorder()
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "# Server body", log: log, contentStatus: 503)
        await viewModel.load()
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Server body edited")
        viewModel.flushPendingChanges()
        await waitUntil { viewModel.saveState == .pendingSync }

        XCTAssertEqual(viewModel.saveState, .pendingSync)
        XCTAssertTrue(viewModel.hasUnsavedLocalContent, "a pending-sync draft is unsaved local content")
    }

    /// Regression: a queued offline (`.pendingSync`) draft must survive a
    /// pull-to-refresh even when a co-author moved the server past the tolerance
    /// window. reconcileDraft's guard covers `.pendingSync`, not only `.failed`;
    /// without it the draft is silently discarded and the server body installed.
    func testPendingSyncDraftSurvivesAPullToRefreshBeyondTolerance() async {
        let log = RequestRecorder()
        let (viewModel, _, draftStore, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "# Server body", log: log, contentStatus: 503)
        await viewModel.load()
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Offline edit")
        viewModel.flushPendingChanges()
        await waitUntil { viewModel.saveState == .pendingSync }
        XCTAssertNotNil(draftStore.draft(for: documentID))

        // A co-author edits: the server updated_at is now far past the window.
        let futureBody = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "# Co-author", "created_at": "2099-01-01T00:00:00Z", "updated_at": "2099-01-01T00:00:00Z"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: futureBody, error: nil)
        }
        await viewModel.refresh()

        XCTAssertTrue(
            draftStore.draft(for: documentID)?.markdown.contains("Offline edit") ?? false,
            "the queued offline edit is preserved, not tolerance-discarded on refresh")
    }

    /// Recoverability: an online transient failure parks the save at `.pendingSync`
    /// with no auto-sync trigger able to fire, so `saveNow()` must re-enqueue it
    /// (the manual retry the caption offers when online).
    func testSaveNowRetriesAPendingSyncDraft() async {
        let log = RequestRecorder()
        let (viewModel, _, draftStore, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "# Server body", log: log, contentStatus: 503)
        await viewModel.load()
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Edited")
        viewModel.flushPendingChanges()
        await waitUntil { viewModel.saveState == .pendingSync }

        // The server recovers; the manual retry re-enqueues and it succeeds.
        stubLoadAndSavePipeline(content: "# Server body", log: log, contentStatus: 204)
        viewModel.saveNow()
        await waitUntil { viewModel.saveState == .saved }
        XCTAssertNil(draftStore.draft(for: documentID), "the retried pending-sync draft synced and cleared")
    }

    /// Typing and undoing after a failed save leaves `isDirty` true with content
    /// that matches `savedMarkdown`, so the flush enqueues nothing. `saveNow()` must
    /// still fire the retry — swallowing it strands the document behind its failed
    /// save (`reconcileDraft` pins the screen while that draft survives), and the
    /// reading surface has no retry affordance at all.
    func testSaveNowRetriesWhenADirtyFlushEnqueuesNothing() async {
        let log = RequestRecorder()
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "Original text", log: log, contentStatus: 400)
        await viewModel.load()
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Changed text")
        viewModel.flushPendingChanges()
        await waitUntil {
            if case .failed = viewModel.saveState { return true }
            return false
        }

        // Type and undo: dirty again, but the content is what the failed save held.
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Changed text!")
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Changed text")
        XCTAssertTrue(viewModel.isDirty)

        stubLoadAndSavePipeline(content: "Original text", log: log, contentStatus: 204)
        viewModel.saveNow()

        await waitUntil { viewModel.saveState == .saved }
        XCTAssertEqual(viewModel.saveState, .saved)
    }

    /// `applyPendingUpdate` is the last content-installing path; a draft must veto
    /// it, or it becomes the same install-over-unsaved-work bug review already found.
    func testApplyPendingUpdateRefusesWhileADraftExists() async {
        let (viewModel, _, draftStore, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Old"))
        stubOffline()
        await viewModel.load()
        viewModel.startEditing()
        stubLoad(content: "# New")
        await viewModel.load()
        XCTAssertTrue(viewModel.updateAvailable)
        viewModel.finishEditing()

        draftStore.save(PendingDraft(documentID: documentID, title: "Doc", markdown: "# Mine", updatedAt: Date()))
        viewModel.applyPendingUpdate()

        XCTAssertEqual(viewModel.blocks.first?.text, "Old", "unsaved work is never installed over")
    }

    func testSaveNowRetriesAfterFailure() async {
        let log = RequestRecorder()
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "Original text", log: log, contentStatus: 400)
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

    // MARK: - currentMarkdown

    func testCurrentMarkdownSerializesBlocksWhileEditing() async {
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoad(content: "# Title")
        await viewModel.load()
        viewModel.startEditing()

        XCTAssertEqual(viewModel.mode, .blocks)
        XCTAssertEqual(viewModel.currentMarkdown(), "# Title\n")
    }

    func testCurrentMarkdownReturnsTheLoadedSourceWhileReading() async {
        // Reading mode keeps `rawMarkdown` as the authoritative loaded source — a
        // late photo insert saves from it, not from a re-serialization of the lossy
        // blocks. A lone opening fence can't round-trip, so this is where it matters.
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoad(content: "```")
        await viewModel.load()

        XCTAssertEqual(viewModel.mode, .reading)
        XCTAssertEqual(viewModel.currentMarkdown(), "```")
    }

    func testNonRoundTrippableDocClosedWithoutEditingEnqueuesNoSave() async {
        // Removing the markdown fallback means a doc whose markdown can't survive a
        // block round-trip (a lone opening fence) now opens in `.blocks` rather than
        // a markdown source view. Opening and closing it without an edit must NOT
        // enqueue a full-overwrite save that would normalize the fence — the dirty
        // baseline `savedMarkdown = serializeMarkdown(blocks)` is what guarantees it.
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        stubLoad(content: "```")
        await viewModel.load()

        viewModel.startEditing()
        XCTAssertEqual(viewModel.mode, .blocks)
        viewModel.finishEditing()

        XCTAssertFalse(viewModel.isDirty)
        XCTAssertNil(coordinator.pendingSave(documentID: documentID), "a no-op session must not overwrite the fence")
        XCTAssertNil(draftStore.draft(for: documentID))
        XCTAssertEqual(viewModel.rawMarkdown, "```", "the untouched source is preserved verbatim")
    }

    func testFinishEditingSyncsTheReadingSourceToTheEditedBlocks() async {
        // `finishEditing`'s conditional resync is the sole path keeping the
        // reading-mode source fresh after an edit; a stale source would let a later
        // photo insert or Options "copy markdown" reflect the loaded body, not the edit.
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoad(content: "# Title")
        await viewModel.load()
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Edited heading")
        viewModel.finishEditing()

        XCTAssertEqual(viewModel.mode, .reading)
        XCTAssertEqual(viewModel.currentMarkdown(), "# Edited heading\n")
    }
}
