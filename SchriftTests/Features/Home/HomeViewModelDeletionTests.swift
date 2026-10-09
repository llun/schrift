import XCTest

@testable import Schrift

@MainActor
final class HomeViewModelDeletionTests: HomeViewModelTestCase {
    /// **A landed deletion must not make Home discard its own list fetch.** `load()` captures a
    /// generation, kicks `recoverDrafts()`, then awaits the two list calls — so a deletion
    /// landing in that window fires the observer *inside* the load. Bumping the shared
    /// generation there is far too blunt: it throws away the whole fetch, not just the deleted
    /// row, leaving the list stale and the offline flag unset.
    func testALandedDeletionDoesNotDiscardAnInFlightListFetch() async {
        let user = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let viewModel = makeViewModel(signedInUser: makeSignedInUser(userID: user))
        let doomed = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let kept = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let pinnedBody = Self.paginatedFixture(
            id: doomed.uuidString.lowercased(), title: "Doomed", isFavorite: true)
        let recentBody = Self.paginatedFixture(
            id: kept.uuidString.lowercased(), title: "Kept", isFavorite: false)
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            return .init(
                statusCode: 200, headers: [:],
                body: url.contains("favorite_list") ? pinnedBody : recentBody, error: nil, delay: 0.2)
        }

        let loading = Task { await viewModel.load() }
        // Lands while the two list calls are still in flight.
        try? await Task.sleep(for: .milliseconds(60))
        viewModel.saveCoordinator.announceDocumentDeletedForTesting(doomed)
        await loading.value

        XCTAssertEqual(
            viewModel.recentDocuments.map(\.id), [kept],
            "the fetch was applied rather than thrown away")
        XCTAssertFalse(viewModel.isLoading, "and the load finished")
        XCTAssertTrue(
            viewModel.pinnedDocuments.isEmpty,
            "with the deleted row filtered out of what it applied")
    }

    func testARowIsAnnotatedOnceItsDeletionIsQueued() {
        let user = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let viewModel = makeViewModel(signedInUser: makeSignedInUser(userID: user))
        let document = documentFixture(UUID())
        XCTAssertFalse(viewModel.isDeletePending(document))

        viewModel.saveCoordinator.recordPendingDelete(documentID: document.id, ownerUserID: user)

        XCTAssertTrue(viewModel.isDeletePending(document))
    }

    /// **Scoped to the account.** Tombstones survive sign-out and these caches are neither
    /// account-scoped nor cleared, so an unscoped predicate would strike one user's document
    /// through another's list — and offer them a button cancelling a deletion they never made.
    func testARowIsNeverAnnotatedForAnotherAccountsDeletion() {
        let viewModel = makeViewModel(
            signedInUser: makeSignedInUser(userID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!))
        let document = documentFixture(UUID())

        viewModel.saveCoordinator.recordPendingDelete(
            documentID: document.id, ownerUserID: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!)

        XCTAssertTrue(
            viewModel.saveCoordinator.isPendingDelete(documentID: document.id),
            "precondition: it really was queued — protected, just not this session's to see")
        XCTAssertFalse(viewModel.isDeletePending(document))
    }

    /// Undo takes the annotation off and kicks the funnel, so a draft suppressed while the
    /// tombstone stood becomes replayable again rather than waiting for an unrelated trigger.
    func testUndoingADeletionClearsTheAnnotation() {
        let user = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let viewModel = makeViewModel(signedInUser: makeSignedInUser(userID: user))
        let document = documentFixture(UUID())
        viewModel.saveCoordinator.recordPendingDelete(documentID: document.id, ownerUserID: user)
        XCTAssertTrue(viewModel.isDeletePending(document), "precondition: annotated to begin with")
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: Data(), error: nil) }

        viewModel.undoPendingDelete(document)

        XCTAssertFalse(viewModel.isDeletePending(document))
        XCTAssertFalse(viewModel.saveCoordinator.isPendingDelete(documentID: document.id))
    }

    /// The rows are dropped by the coordinator's announcement, which `DocumentActions` now
    /// fires for an immediate delete — not by `deleteDocument` reaching into the arrays. Two
    /// writers for one fact is how the two get to disagree.
    func testDeletingARowDropsItFromEveryList() async {
        let user = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let viewModel = makeViewModel(signedInUser: makeSignedInUser(userID: user))
        let doomed = documentFixture(UUID(uuidString: "44444444-4444-4444-8444-444444444444")!)
        viewModel.pinnedDocuments = [doomed]
        viewModel.fetchedRecentDocuments = [doomed]
        viewModel.searchResults = [doomed]
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 204, headers: [:], body: Data(), error: nil) }

        await viewModel.deleteDocument(doomed)

        XCTAssertTrue(viewModel.pinnedDocuments.isEmpty)
        XCTAssertTrue(viewModel.fetchedRecentDocuments.isEmpty)
        XCTAssertTrue(viewModel.searchResults.isEmpty, "the inline search list is a third list of the same rows")
        XCTAssertNil(viewModel.errorKey)
    }

    /// Offline, the row **stays** — struck through — because the deletion is still cancellable.
    func testDeletingARowOfflineQueuesItAndKeepsTheRowAnnotated() async {
        let user = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let viewModel = makeViewModel(signedInUser: makeSignedInUser(userID: user))
        let doomed = documentFixture(UUID(uuidString: "44444444-4444-4444-8444-444444444444")!)
        viewModel.fetchedRecentDocuments = [doomed]
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        await viewModel.deleteDocument(doomed)

        XCTAssertEqual(viewModel.fetchedRecentDocuments.map(\.id), [doomed.id])
        XCTAssertTrue(viewModel.isDeletePending(doomed))
        XCTAssertNil(viewModel.errorKey, "a queued deletion is not a failure")
    }

    func testARejectedDeleteReportsAndKeepsTheRow() async {
        let user = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let viewModel = makeViewModel(signedInUser: makeSignedInUser(userID: user))
        let doomed = documentFixture(UUID(uuidString: "44444444-4444-4444-8444-444444444444")!)
        viewModel.fetchedRecentDocuments = [doomed]
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 403, headers: [:], body: Data(), error: nil) }

        await viewModel.deleteDocument(doomed)

        XCTAssertEqual(viewModel.fetchedRecentDocuments.map(\.id), [doomed.id])
        XCTAssertEqual(viewModel.errorKey, .options_error_delete)
        XCTAssertFalse(viewModel.isDeletePending(doomed))
    }

    /// A second swipe on a row whose delete is still in flight must not send twice — the
    /// second DELETE would take a 404 and, being non-retryable, report a failure for a
    /// deletion that is actually succeeding.
    func testASecondDeleteWhileOneIsInFlightIsRefused() async {
        let user = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let viewModel = makeViewModel(signedInUser: makeSignedInUser(userID: user))
        let doomed = documentFixture(UUID(uuidString: "44444444-4444-4444-8444-444444444444")!)
        viewModel.fetchedRecentDocuments = [doomed]
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil, delay: 0.2)
        }

        async let first: Void = viewModel.deleteDocument(doomed)
        await waitUntil { log.count(ofMethod: "DELETE") >= 1 }
        await viewModel.deleteDocument(doomed)
        await first

        XCTAssertEqual(log.count(ofMethod: "DELETE"), 1, "the in-flight guard swallowed the second")
    }

    /// The one delete path with **no announcement**: a locally-created row has no server id to
    /// announce, so its row leaves only because `discardPendingWork` bumps
    /// `pendingCreatesVersion`, which invalidates the `recentDocuments` memo.
    func testDeletingALocallyCreatedRowRemovesItWithNoRequest() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        let user = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let viewModel = makeViewModel(signedInUser: makeSignedInUser(userID: user))
        let local = viewModel.saveCoordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        XCTAssertEqual(viewModel.recentDocuments.map(\.id), [local.id], "precondition")

        await viewModel.deleteDocument(local)

        XCTAssertEqual(log.count(ofMethod: "DELETE"), 0, "there is nothing on the server to delete")
        XCTAssertTrue(viewModel.recentDocuments.isEmpty)
    }
}
