import XCTest

@testable import Schrift

@MainActor
final class EditorViewModelConflictLifecycleTests: EditorViewModelTestCase {
    // MARK: - The conflict record's lifecycle
    //
    // The rule the four detection sites share: **a conflict record is meaningful only while
    // local work exists that would overwrite the observed server body.** Record it when such
    // work appears; release it the moment it is gone. Both halves are load-bearing — one way
    // the user loses a co-author's edit, the other way the document's save pipeline wedges.

    /// Merely *entering* edit mode is not local work, so it must record nothing. Recording
    /// there produced a **phantom conflict**: a pill and an enqueue-hold on a document with no
    /// unsaved changes, which nothing on the clean path cleared and whose "Keep my version"
    /// had nothing to push.
    func testEnteringEditModeOverAnUpdateBannerRecordsNoConflict() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, _, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "# Server body", log: log)
        await viewModel.load()

        // Editing session; a co-author's body lands and is stashed behind the banner.
        viewModel.startEditing()
        stubDivergedServer(content: "# Co-author edit", log: log)
        await viewModel.load()
        XCTAssertTrue(viewModel.updateAvailable)

        // Done without typing, then tap back into the text to read.
        viewModel.finishEditing()
        viewModel.startEditing()

        XCTAssertNil(
            viewModel.syncConflict,
            "entering edit mode is not local work — a conflict here is a phantom that wedges every future save")
        XCTAssertFalse(viewModel.isDirty)
    }

    /// …but the stash must survive that, or the first real keystroke has nothing left to
    /// detect. (This is why `startEditing` hides the banner instead of destroying the stash.)
    func testTheStashSurvivesEnteringEditModeSoTheFirstKeystrokeStillDetects() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, _, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "# Server body", log: log)
        await viewModel.load()

        viewModel.startEditing()
        stubDivergedServer(content: "# Co-author edit", log: log)
        await viewModel.load()
        viewModel.finishEditing()
        viewModel.startEditing()  // stash kept, banner hidden, nothing recorded
        XCTAssertNil(viewModel.syncConflict)

        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "My edit")

        XCTAssertNotNil(
            viewModel.syncConflict,
            "the first keystroke IS local work — and the server body we fetched must not be overwritten unasked")
        viewModel.flushPendingChanges()
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }
        XCTAssertNotNil(coordinator.pendingSave(documentID: documentID), "the push is held")
    }

    /// The release side, exercised with the conflict **still standing** when the decision comes
    /// back `.push`. This is the property that matters: the record is the only thing holding the
    /// enqueue, and `syncPendingDrafts` skips any document that has one — so if it is never
    /// released, the document can **never sync again**, with a destructive "Keep the server
    /// version" armed against whatever the user types next.
    ///
    /// (An earlier version of this test resolved the conflict via `resolveConflictKeepingServer()`
    /// first — which clears the record inside the coordinator — so it passed with every
    /// `clearResolvedConflict` call site deleted. It asserted the right thing about the wrong
    /// state. The conflict must be live at the moment the `.push` decision lands.)
    func testAPushDecisionReleasesAStandingConflictSoTheDocumentCanSyncAgain() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Mine", updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000), markdown: "# Base")
            )
        )
        stubDivergedServer(content: "# Co-author edit", log: log)
        await viewModel.load()
        XCTAssertNotNil(viewModel.syncConflict, "a conflict stands over the queued draft")

        // The co-author reverts: the server body is the baseline again, so the decision is
        // `.push` — and the conflict is STILL RECORDED when that decision lands.
        stubDivergedServer(content: "# Base", log: log)
        await viewModel.refresh()

        XCTAssertNil(
            viewModel.syncConflict,
            "the conflict is moot — releasing it is the only thing that lets this document sync again")
        // The hold is genuinely gone: the draft actually reaches the network.
        await waitUntil { self.savesInFlight(log) >= 1 }
        XCTAssertNil(coordinator.conflict(for: documentID))
    }

    /// The same release, via `reconcileClean` — reached only with no pending save, no draft and
    /// not dirty, i.e. no local work by construction, so a record there cannot be live. Here the
    /// local work is destroyed by a *successful save* rather than by a resolver, so
    /// `clearResolvedConflict` is the only thing that can null the record.
    func testReconcileCleanReleasesAConflictLeftOverAfterTheLocalWorkIsGone() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "# Server body", log: log)
        await viewModel.load()

        // Local work, saved successfully → no draft, not dirty, nothing pending.
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "My edit")
        viewModel.flushPendingChanges()
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
        viewModel.finishEditing()
        XCTAssertNil(draftStore.draft(for: documentID))
        XCTAssertFalse(viewModel.isDirty)

        // A conflict record survives from earlier (e.g. the sync pass recorded one before the
        // save landed). It is now moot: there is no local work left to overwrite anything.
        coordinator.recordConflict(documentID: documentID, serverUpdatedAt: Date())
        XCTAssertNotNil(viewModel.syncConflict)

        await viewModel.refresh()  // clean path

        XCTAssertNil(
            viewModel.syncConflict,
            "no pending save, no draft, not dirty — the record has nothing left to protect and must be released")

        // …and the pipeline is genuinely unwedged: new work reaches the network.
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Fresh unrelated work")
        viewModel.flushPendingChanges()
        await waitUntil { self.savesInFlight(log) >= 2 }
    }

    /// reconcileClean's unchanged-body (else) branch advances the baseline's
    /// timestamp: a cache-restored entry with an unknown (void-save) server
    /// timestamp gets promoted to the real server clock once a clean revalidation
    /// confirms the same body.
    func testReconcileCleanUnchangedBodyAdvancesBaselineTimestamp() async {
        let (viewModel, coordinator, draftStore, contentCache) = makeEnvironment()
        contentCache.save(
            CachedDocumentContent(
                documentID: documentID, title: "Doc", markdown: "# Body",
                syncedAt: Date(timeIntervalSince1970: 1_000_000), serverUpdatedAt: nil))
        stubLoad(content: "# Body")  // same body (serverChanged == false), known updated_at
        await viewModel.load()  // reconcileClean else-branch promotes nil → the server timestamp

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Body edited")
        viewModel.flushPendingChanges()

        XCTAssertEqual(
            draftStore.draft(for: documentID)?.baseline?.serverUpdatedAt, fetchedUpdatedAt,
            "an unchanged-body revalidation advances the baseline timestamp from nil to the server clock")
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
    }

    /// Mirror of testCacheServerCopyDoesNotAdvanceTheBaseline for the *editing-but-
    /// clean* path: a diverged server body that lands mid-edit is stashed behind the
    /// "Updated" banner, and the on-screen (older) body must keep owning the
    /// baseline — the caret is in it, so an edit descends from it, not the stash.
    func testReconcileCleanStashDoesNotAdvanceTheBaseline() async {
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        stubLoad(content: "# Server body")
        await viewModel.load()  // baseline A

        viewModel.startEditing()  // editing, not yet dirty
        stubLoad(content: "# Co-author edit")
        await viewModel.load()  // server changed mid-edit → stashed, baseline stays A
        XCTAssertTrue(viewModel.updateAvailable)

        // Edit WITHOUT opting into the stash, then flush.
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# My edit")
        viewModel.flushPendingChanges()

        XCTAssertEqual(
            draftStore.draft(for: documentID)?.baseline?.markdown, "# Server body",
            "the editing stash must not advance the baseline over an observed web edit")
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
    }

    /// A fetch that races one of our own saves (mayPredateLocalSave == true) makes
    /// `apply` early-return, taking nothing from the response — including the
    /// baseline. If it did, a later full-overwrite save would push the resurrected
    /// stale body back to the server.
    func testMayPredateFetchDoesNotAdvanceTheBaseline() async {
        let (viewModel, coordinator, draftStore, contentCache) = makeEnvironment()
        stubLoad(content: "# Server body")
        await viewModel.load()  // baseline A, cached A

        // Hold the save's content PATCH open so it stays in flight; a GET that lands
        // during it is answered with a diverged body and races the save.
        let bodyB = formattedBody(content: "# Co-author edit")
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: bodyB, error: nil)
            }
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") {
                return MockURLProtocol.Stub(statusCode: 204, headers: [:], body: Data(), error: nil, delay: 0.4)
            }
            return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: Data(), error: nil)
        }
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# My edit")
        viewModel.flushPendingChanges()  // save enqueued, PATCH held → in flight
        XCTAssertNotNil(coordinator.pendingSave(documentID: documentID))

        await viewModel.refresh()  // fetch B races the in-flight save → apply early-returns

        // The mayPredate early-return uniquely takes NOTHING from the raced fetch:
        // in particular it does not write-through the cache with body B (the
        // pendingSave branch's cacheServerCopy would, so this is what distinguishes
        // the guard from that branch). Asserted while the first save is still held.
        XCTAssertEqual(
            contentCache.content(for: documentID)?.markdown, "# Server body",
            "the raced fetch's body must not be installed or cached")

        // Edit again and flush; the still-in-flight save queues this, writing a draft.
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# My edit 2")
        viewModel.flushPendingChanges()
        XCTAssertEqual(
            draftStore.draft(for: documentID)?.baseline?.markdown, "# Server body",
            "a fetch racing our own save must not advance the baseline to the raced body")
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
    }

    /// The `saveNow` failed-save retry is a baseline-carrying enqueue site too: it
    /// must re-push with the stored draft's baseline, not nil (which would degrade
    /// a retried offline save to the legacy tolerance rule).
    func testSaveNowRetryPreservesTheBaseline() async {
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        let bodyA = formattedBody(content: "# Server body")
        // GET ok (baseline A); the content PATCH is rejected with a non-retryable
        // 400 so the save reaches `.failed` (the retry state), and the draft (with
        // its baseline) survives to be retried.
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: bodyA, error: nil)
            }
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") {
                return MockURLProtocol.Stub(statusCode: 400, headers: [:], body: Data(), error: nil)
            }
            return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: Data(), error: nil)
        }
        await viewModel.load()  // installFetched → baseline A

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Server body edited")
        viewModel.flushPendingChanges()
        await waitUntil {
            if case .failed = coordinator.state(for: self.documentID) { return true }
            return false
        }
        XCTAssertEqual(
            draftStore.draft(for: documentID)?.baseline?.markdown, "# Server body",
            "the failed draft carries the baseline")

        viewModel.saveNow()  // retry re-enqueues with the stored draft's baseline
        let baseline = draftStore.draft(for: documentID)?.baseline
        XCTAssertEqual(baseline?.markdown, "# Server body")
        XCTAssertEqual(baseline?.serverUpdatedAt, fetchedUpdatedAt)
        await waitUntil {
            if case .failed = coordinator.state(for: self.documentID) { return true }
            return false
        }
    }
}
