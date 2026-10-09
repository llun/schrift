import XCTest

@testable import Schrift

@MainActor
final class EditorViewModelBaselineTests: EditorViewModelTestCase {
    // MARK: - Server baseline capture (plumbing for offline sync)

    /// A flush after editing fetched content carries the server body and its
    /// `updated_at` as the draft's baseline — the state the edit descends from.
    func testFlushCapturesServerBaselineFromFetchedContent() async {
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        stubLoad(content: "# Server body")
        await viewModel.load()  // installFetched captures the server baseline

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Server body edited")
        viewModel.flushPendingChanges()  // enqueue writes the draft synchronously

        // Read before the background save (all-200 stub) can settle and clear it.
        let baseline = draftStore.draft(for: documentID)?.baseline
        XCTAssertEqual(baseline?.markdown, "# Server body")
        // The exact server clock, not the client clock — a Date() regression in
        // installFetched would keep this non-nil but wrong.
        XCTAssertEqual(baseline?.serverUpdatedAt, fetchedUpdatedAt)
        XCTAssertEqual(baseline?.title, "Doc", "the baseline records the server's TITLE too, or a rename can't be seen")

        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
    }

    /// The baseline can also come from a cache-restored copy — carrying the
    /// server `updated_at` the cache entry recorded (nil for void-save entries).
    func testFlushCapturesBaselineFromCacheRestoredContent() async {
        let (viewModel, coordinator, draftStore, contentCache) = makeEnvironment()
        let serverDate = Date(timeIntervalSince1970: 1_700_000_000)
        contentCache.save(
            CachedDocumentContent(
                documentID: documentID, title: "Cached Doc", markdown: "# Cached",
                syncedAt: Date(timeIntervalSince1970: 1_000_000), serverUpdatedAt: serverDate))
        stubOffline()
        await viewModel.load()  // cached copy on screen; revalidation fails, baseline from cache

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Cached edited")
        viewModel.flushPendingChanges()

        let baseline = draftStore.draft(for: documentID)?.baseline
        XCTAssertEqual(baseline?.markdown, "# Cached")
        XCTAssertEqual(baseline?.serverUpdatedAt, serverDate)
        XCTAssertEqual(baseline?.title, "Cached Doc", "the cache entry's title anchors rename detection too")

        // The offline save fails (draft stays); let it settle so no request
        // outlives the test.
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
    }

    /// Load-bearing: while a dirty screen observes a diverged server body, the
    /// revalidation routes through `cacheServerCopy`, which must NOT advance the
    /// baseline — the edit still descends from the body it was made against, so a
    /// later conflict check (a stack PR) must not push over the web edit we saw.
    func testCacheServerCopyDoesNotAdvanceTheBaseline() async {
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        stubLoad(content: "# Server body")
        await viewModel.load()  // baseline = server body A

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# My local edit")
        XCTAssertTrue(viewModel.isDirty)

        // A revalidation lands with a diverged body while the screen is dirty →
        // apply short-circuits to cacheServerCopy(B).
        stubLoad(content: "# Co-author edit")
        await viewModel.load()

        viewModel.flushPendingChanges()
        XCTAssertEqual(
            draftStore.draft(for: documentID)?.baseline?.markdown, "# Server body",
            "cacheServerCopy must not advance the baseline over an observed web edit")

        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
    }

    /// A server change installed while NOT editing (reconcileClean install branch)
    /// advances the baseline to the freshly-installed body.
    func testReconcileCleanInstallCapturesBaseline() async {
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        stubLoad(content: "# Server body")
        await viewModel.load()  // baseline = A, reading mode

        stubLoad(content: "# Co-author edit")
        await viewModel.load()  // not editing, not dirty → installs B, baseline = B

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Co-author edit and mine")
        viewModel.flushPendingChanges()

        let baseline = draftStore.draft(for: documentID)?.baseline
        XCTAssertEqual(baseline?.markdown, "# Co-author edit")
        XCTAssertEqual(baseline?.serverUpdatedAt, fetchedUpdatedAt)
        XCTAssertEqual(baseline?.title, "Doc")
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
    }

    /// Opting into a body stashed behind the "Updated" banner (applyPendingUpdate)
    /// makes that body the baseline — the on-screen content now descends from it.
    func testApplyPendingUpdateCapturesBaseline() async {
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        stubLoad(content: "# Server body")
        await viewModel.load()  // baseline = A

        viewModel.startEditing()  // editing, not dirty
        stubLoad(content: "# Co-author edit")
        await viewModel.load()  // server changed mid-edit → stashed behind the banner
        XCTAssertTrue(viewModel.updateAvailable)

        viewModel.finishEditing()
        viewModel.applyPendingUpdate()  // installs the stashed body → baseline = B

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Co-author edit and mine")
        viewModel.flushPendingChanges()

        let baseline = draftStore.draft(for: documentID)?.baseline
        XCTAssertEqual(baseline?.markdown, "# Co-author edit")
        XCTAssertEqual(baseline?.serverUpdatedAt, fetchedUpdatedAt)
        XCTAssertEqual(baseline?.title, "Doc", "the stashed body's fetch also recorded its title")
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
    }

    /// The primary offline scenario: a draft persisted by an earlier session is
    /// reopened offline (restoreLocalContent's `.draft` branch reconstructs the
    /// baseline from it), edited, and flushed — the re-enqueued draft must still
    /// descend from the original server baseline, so a later conflict check can't
    /// tolerance-discard baseline-carrying work.
    func testDraftRestoreReconstructsBaselineForOfflineReopen() async {
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        let serverDate = Date(timeIntervalSince1970: 1_700_000_000)
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Offline edit",
                updatedAt: Date(), baseline: DraftBaseline(serverUpdatedAt: serverDate, markdown: "# Server base")))
        stubOffline()
        await viewModel.load()  // restoreLocalContent .draft branch → serverBaseline = draft.baseline

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Offline edit more")
        viewModel.flushPendingChanges()

        // The flush actually re-enqueued the NEW edit (not just left the identical
        // pre-existing draft in place) — otherwise the baseline check is vacuous.
        XCTAssertTrue(
            draftStore.draft(for: documentID)?.markdown.contains("more") ?? false,
            "the flush re-enqueued the edited content")
        XCTAssertEqual(draftStore.draft(for: documentID)?.baseline?.markdown, "# Server base")
        XCTAssertEqual(draftStore.draft(for: documentID)?.baseline?.serverUpdatedAt, serverDate)
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
    }

    /// Reopening a document whose save is still in flight runs restoreLocalContent's
    /// `.pendingSave` branch, which reconstructs the baseline from the stored draft.
    func testPendingSaveRestoreReconstructsBaseline() async {
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        let baseline = DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 1_000), markdown: "# Base")
        // Hold the content PATCH open so the save stays in flight while we reopen.
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return MockURLProtocol.Stub(
                    statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
            }
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") {
                return MockURLProtocol.Stub(statusCode: 204, headers: [:], body: Data(), error: nil, delay: 0.3)
            }
            return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: Data(), error: nil)
        }
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Queued", baseline: baseline)
        XCTAssertNotNil(coordinator.pendingSave(documentID: documentID), "the save is in flight")

        await viewModel.load()  // restoreLocalContent .pendingSave branch
        XCTAssertEqual(viewModel.displaySource, .pendingSave)

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Queued edit")
        viewModel.flushPendingChanges()

        // The flush actually re-enqueued the NEW edit, not the original "# Queued".
        XCTAssertTrue(
            draftStore.draft(for: documentID)?.markdown.contains("Queued edit") ?? false,
            "the flush re-enqueued the edited content")
        XCTAssertEqual(draftStore.draft(for: documentID)?.baseline?.markdown, "# Base")
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
    }

    /// A 404 mid-edit tears the document down, but `becomeUnavailable` flushes
    /// write-ahead *first* — the persisted draft must carry the baseline so a
    /// transient 404's replay (recoverDrafts / reconcileDraft) can reconcile it.
    func testTeardownFlushCarriesTheServerBaseline() async {
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        stubLoad(content: "# Server body")
        await viewModel.load()  // installFetched → baseline A

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Server body edited")
        XCTAssertTrue(viewModel.isDirty)

        stubStatus(404)
        await viewModel.load()  // 404 → becomeUnavailable flushes write-ahead with the baseline
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }

        XCTAssertEqual(
            draftStore.draft(for: documentID)?.baseline?.markdown, "# Server body",
            "the write-ahead teardown flush persists the baseline the edit descended from")
    }

    /// A stored draft plus a successful fetch reaches reconcileDraft's push
    /// (draft-wins) branch, which re-enqueues the draft. That re-enqueue must carry
    /// the draft's own baseline through — the draft-replay reconciliation the
    /// baseline exists to serve.
    func testReconcileDraftReplayCarriesTheBaseline() async {
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        // Baseline no older than the fixture's 2026-01-15 server updated_at, so
        // `draftSyncDecision` rule 2 pushes (the server has not moved past the baseline)
        // and reconcileDraft re-enqueues with the draft's baseline.
        let serverDate = Date(timeIntervalSince1970: 1_800_000_000)
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Draft body", updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: serverDate, markdown: "# Server base")))
        let body = formattedBody(content: "# Server")
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: body, error: nil)
            }
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") {
                return MockURLProtocol.Stub(statusCode: 204, headers: [:], body: Data(), error: nil, delay: 0.3)
            }
            return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: Data(), error: nil)
        }

        await viewModel.load()  // reconcileDraft baseline-push re-enqueues with draft.baseline

        // The replay must actually have fired (not just left the identical draft
        // untouched): the re-enqueued save is in flight, held open by the stub.
        XCTAssertNotNil(
            coordinator.pendingSave(documentID: documentID), "the tolerance replay re-enqueued a save")
        // …and that in-flight draft carries the baseline through.
        let baseline = draftStore.draft(for: documentID)?.baseline
        XCTAssertEqual(baseline?.markdown, "# Server base")
        XCTAssertEqual(baseline?.serverUpdatedAt, serverDate)
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
    }
}
