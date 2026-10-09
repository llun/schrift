import XCTest

@testable import Schrift

@MainActor
final class EditorViewModelSubpagesTests: EditorViewModelTestCase {
    // MARK: - Subpages fetch-awareness

    func testSubpagesAreNilBeforeAnySuccessfulFetch() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry())
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        await viewModel.load()

        XCTAssertNil(viewModel.subpages, "offline: unknown, not 'none'")
    }

    func testSubpagesBecomeEmptyArrayAfterSuccessfulFetch() async {
        let (viewModel, _, _, _) = makeEnvironment()
        // Stub both endpoints explicitly: formatted-content, and an empty
        // paginated children list (do not rely on stubLoad's handling of the
        // children URL — a decode failure must now read as "not fetched").
        let docBody = formattedBody(content: "# Doc")
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("children") {
                return MockURLProtocol.Stub(
                    statusCode: 200, headers: [:],
                    body: Data(#"{"count": 0, "next": null, "previous": null, "results": []}"#.utf8),
                    error: nil
                )
            }
            return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: docBody, error: nil)
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.subpages, [])
    }

    func testHandleDidDeletePurgesCacheAndDrafts() async {
        let (viewModel, _, draftStore, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry())
        draftStore.save(PendingDraft(documentID: documentID, title: "D", markdown: "# D", updatedAt: Date()))

        viewModel.handleDidDelete()

        XCTAssertNil(contentCache.content(for: documentID))
        XCTAssertNil(draftStore.draft(for: documentID))
    }

    /// A **queued** deletion is still cancellable, so the teardown purges nothing: the draft
    /// and the cached body are exactly what the undo restores.
    /// `DocumentSaveCoordinator.completePendingDelete` removes them when the DELETE really
    /// lands, in an order a crash cannot tear.
    func testHandleDidQueueDeleteEndsTheSessionWithoutPurging() async {
        let (viewModel, _, draftStore, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry())
        draftStore.save(PendingDraft(documentID: documentID, title: "D", markdown: "# D", updatedAt: Date()))

        viewModel.handleDidQueueDelete()

        XCTAssertNotNil(contentCache.content(for: documentID), "kept for the undo")
        XCTAssertNotNil(draftStore.draft(for: documentID), "and so is the body")
        XCTAssertTrue(viewModel.isDocumentDiscarded, "but nothing here may write again")
        XCTAssertFalse(viewModel.isDirty)
    }

    /// The revive is the one completion that runs with an editor open — deferring it would let
    /// the sync pass reap the draft instead — so this screen can be left live on an id the
    /// server no longer has. A keystroke there would write a fresh draft under the dead id and
    /// have it reaped by the *next launch's* pass, when the in-memory `.failed` that protected
    /// it is gone. Ending the session is what stops those edits going somewhere that loses them.
    func testALandedDeletionOfThisDocumentEndsTheSession() async {
        let env = makeEnvironment()
        stubLoadAndSavePipeline(content: "# Server", log: RequestRecorder())
        await env.viewModel.load()
        XCTAssertFalse(env.viewModel.isDocumentDiscarded, "precondition: a live session")

        env.coordinator.announceDocumentDeletedForTesting(documentID)

        XCTAssertTrue(env.viewModel.isDocumentDiscarded, "nothing here may write again")
        XCTAssertNil(env.contentCache.content(for: documentID), "and its local copies are gone")
    }

    /// Opening a document whose deletion is queued says so and asks the server nothing — the
    /// whole point of a deletion queued offline. `hasLoadedContent` stays false, so
    /// `startEditing` cannot fire and no funnel here can enqueue.
    func testLoadingATombstonedDocumentShowsTheMessageWithoutAnyRequest() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        env.contentCache.save(cachedEntry(markdown: "# Cached"))
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 200, headers: [:], body: Data(), error: nil)
        }
        env.coordinator.recordPendingDelete(
            documentID: documentID, ownerUserID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)

        await env.viewModel.load()

        // The notice is rendered from the predicate, not from `errorKey` — a key set here would
        // be invisible while the tombstone stands (the view shows the notice instead) and then
        // latch into view, danger-styled, the moment the deletion is undone or refused.
        XCTAssertTrue(env.viewModel.isDocumentPendingDelete, "the state the notice renders from")
        XCTAssertNil(env.viewModel.errorKey, "and nothing left to latch once it is undone")
        XCTAssertEqual(log.methods.count, 0, "nothing is asked about a document being deleted")
        XCTAssertFalse(env.viewModel.hasLoadedContent, "so editing can never begin")
        XCTAssertTrue(env.viewModel.blocks.isEmpty, "and the body it would restore stays off screen")
    }

    /// And it is not terminal: undoing the deletion makes the next load behave normally.
    func testUndoingTheDeletionLetsTheDocumentOpenAgain() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        stubLoadAndSavePipeline(content: "# Server", log: log)
        env.coordinator.recordPendingDelete(
            documentID: documentID, ownerUserID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
        await env.viewModel.load()
        XCTAssertEqual(log.methods.count, 0, "precondition: nothing asked")

        env.coordinator.cancelPendingDelete(documentID: documentID)
        await env.viewModel.load()

        XCTAssertNil(env.viewModel.errorKey)
        XCTAssertFalse(env.viewModel.isDocumentPendingDelete)
        XCTAssertTrue(env.viewModel.hasLoadedContent)
    }

    /// Pull-to-refresh is the other way in, and takes the same gate: a 404 here is what the
    /// document's own queued DELETE predicts, and `becomeUnavailable` would bury an undoable
    /// state under a permanent one.
    func testRefreshingATombstonedDocumentAsksNothing() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        stubLoadAndSavePipeline(content: "# Server", log: log)
        await env.viewModel.load()
        let asked = log.methods.count
        env.coordinator.recordPendingDelete(
            documentID: documentID, ownerUserID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)

        await env.viewModel.refresh()

        XCTAssertEqual(log.methods.count, asked, "no further requests")
        XCTAssertFalse(env.viewModel.isUnavailable, "and not torn down either")
    }

    /// The revalidation counterpart of
    /// `DocumentSaveCoordinatorTests.testSaveLandingAfterADeleteNeverRecreatesTheCacheEntry`:
    /// a content GET issued before the delete can be answered with a 200 *after*
    /// `handleDidDelete` purged the cache — and before SwiftUI cancels the
    /// editor's `.task`. `reconcileClean` write-throughs unconditionally, so
    /// without the generation bump the deleted body reappears on disk and keeps
    /// rendering from retained Search/Shared results until eviction.
    func testRevalidationLandingAfterADeleteNeverRecreatesTheCacheEntry() async {
        let log = RequestRecorder()
        let (viewModel, _, _, contentCache) = makeEnvironment()
        // Seeded so load()'s synchronous local phase installs it: the fetch that
        // follows is a revalidation, and `apply` reaches `reconcileClean`.
        contentCache.save(cachedEntry(markdown: "# Cached"))
        stubLoadAndSavePipeline(content: "# Server", log: log, getDelay: 0.2)

        async let loading: Void = viewModel.load()
        // The stub records at issue time, before the delayed delivery — so this
        // resolves while the GET is genuinely still in flight.
        await waitUntil { log.count(ofMethod: "GET", urlContaining: "formatted-content") >= 1 }
        viewModel.handleDidDelete()
        await loading

        XCTAssertNil(contentCache.content(for: documentID), "the purge survives the late 200")
        XCTAssertTrue(viewModel.isDocumentDiscarded)
    }
}
