import XCTest

@testable import Schrift

@MainActor
final class HomeViewModelMigrationTests: HomeViewModelTestCase {
    /// The memo must re-derive when the *account* changes. Re-auth swaps who may be listed
    /// without touching the fetched array or the record version, so a memo keyed only on
    /// those two would keep serving the previous user's documents to the new one.
    func testTheMergedListReDerivesWhenTheAccountChanges() async {
        let signedIn = makeSignedInUser()
        let viewModel = makeViewModel(signedInUser: signedIn)
        preferences.set(true, forKey: "schrift.workOffline")
        _ = await viewModel.createDocument()
        XCTAssertEqual(viewModel.recentDocuments.count, 1)

        // A different account answers the re-login sheet.
        signedIn.remember(UUID(uuidString: "22222222-2222-4222-8222-222222222222")!)

        XCTAssertTrue(
            viewModel.recentDocuments.isEmpty,
            "the previous user's unsynced documents are not listed to the new one")
    }

    /// The adopt-the-server branch drops the record and `return`s **before** the end of the
    /// migration, and a resume whose cosmetic fetch failed carries no document. Pinning the
    /// callback to the last statement skipped both — the record goes, the local row is
    /// withheld, and nothing refetches. `defer` is what makes every exit fire.
    func testAnAdoptedMigrationStillTriggersARefetch() async {
        let log = RequestRecorder()
        let serverID = "88888888-8888-4888-8888-888888888888"
        let viewModel = makeViewModel(signedInUser: makeSignedInUser())
        preferences.set(true, forKey: "schrift.workOffline")
        let local = await viewModel.createDocument()
        preferences.set(false, forKey: "schrift.workOffline")
        // A checkpointed record whose resume finds a server body: the local seed body is
        // canonically empty, so the migration adopts the server and returns early.
        var record = viewModel.saveCoordinator.pendingCreateForTesting(localID: local!.id)!
        record.syncedServerID = UUID(uuidString: serverID)!
        viewModel.saveCoordinator.savePendingCreateForTesting(record)

        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("users/me/") {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data("{\"id\": \"11111111-1111-4111-8111-111111111111\"}".utf8), error: nil)
            }
            if url.contains("formatted-content") {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data(
                        """
                        {"id": "\(serverID)", "title": "Untitled document",
                         "content": "# Written on the web", "created_at": "2026-03-01T12:00:00Z",
                         "updated_at": "2026-03-01T12:00:00Z"}
                        """.utf8), error: nil)
            }
            return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }

        await viewModel.syncPendingDrafts()
        await waitUntil { viewModel.saveCoordinator.isPendingCreate(documentID: local!.id) == false }

        await waitUntil { log.count(ofMethod: "GET", urlContaining: "documents/?") > 0 }
    }

    /// Work Offline must not clobber a just-migrated in-memory row with a nil cache. The
    /// replay reads no `workOffline` gate, so it runs in that mode — and on a fresh install
    /// `insertIntoListCaches` correctly declines to write a cache that was never fetched, so
    /// a bare `fetchedRecentDocuments = cachedRecents ?? []` dropped the document that had
    /// just synced out of every list, with no way back while the toggle stayed on.
    func testWorkOfflineDoesNotClobberAJustMigratedRow() async {
        let serverID = "99999999-9999-4999-8999-999999999999"
        let cache = makeCache()
        let viewModel = makeViewModel(cache: cache, signedInUser: makeSignedInUser())
        preferences.set(true, forKey: "schrift.workOffline")
        let local = await viewModel.createDocument()
        XCTAssertNil(cache.loadRecentDocuments(), "never fetched")

        // The toggle stays ON, and the network is actually up.
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("users/me/") {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data("{\"id\": \"11111111-1111-4111-8111-111111111111\"}".utf8), error: nil)
            }
            if request.httpMethod == "POST" {
                return .init(
                    statusCode: 201, headers: [:],
                    body: Data(
                        """
                        {"id": "\(serverID)", "title": "Untitled document",
                         "abilities": {"destroy": true, "partial_update": true}, "content": "",
                         "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-01T12:00:00Z",
                         "depth": 1, "numchild": 0, "path": "00000A", "link_reach": "restricted",
                         "link_role": "reader", "user_role": "owner"}
                        """.utf8), error: nil)
            }
            return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }

        await viewModel.syncPendingDrafts()
        await waitUntil { viewModel.saveCoordinator.isPendingCreate(documentID: local!.id) == false }

        await waitUntil { viewModel.recentDocuments.map { $0.id.uuidString.lowercased() } == [serverID] }
    }

    /// The case the refetch alone cannot cover: a fresh install used offline first has **no**
    /// recents cache, so `insertIntoListCaches` correctly declines to fabricate one — and if
    /// the refetch that follows fails, the document is in no list at all. The real row is
    /// swapped into memory before the refetch, so it never blinks out.
    func testAMigratedDocumentSurvivesAFailedRefetchOnAFreshInstall() async {
        let serverID = "77777777-7777-4777-8777-777777777777"
        let cache = makeCache()
        let viewModel = makeViewModel(cache: cache, signedInUser: makeSignedInUser())
        preferences.set(true, forKey: "schrift.workOffline")
        let local = await viewModel.createDocument()
        preferences.set(false, forKey: "schrift.workOffline")
        XCTAssertNil(cache.loadRecentDocuments(), "never fetched — nothing to re-seed from")

        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("users/me/") {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data("{\"id\": \"11111111-1111-4111-8111-111111111111\"}".utf8), error: nil)
            }
            if request.httpMethod == "POST" {
                return .init(
                    statusCode: 201, headers: [:],
                    body: Data(
                        """
                        {"id": "\(serverID)", "title": "Untitled document",
                         "abilities": {"destroy": true, "partial_update": true}, "content": "",
                         "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-01T12:00:00Z",
                         "depth": 1, "numchild": 0, "path": "00000A", "link_reach": "restricted",
                         "link_role": "reader", "user_role": "owner"}
                        """.utf8), error: nil)
            }
            // Every list fetch fails — the flaky-reconnect profile.
            return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }

        await viewModel.syncPendingDrafts()
        await waitUntil { viewModel.saveCoordinator.isPendingCreate(documentID: local!.id) == false }

        await waitUntil { viewModel.recentDocuments.map { $0.id.uuidString.lowercased() } == [serverID] }
        XCTAssertNil(cache.loadRecentDocuments(), "and no cache entry was fabricated")
    }

    /// A migrated document must not vanish from a live Home. The record is dropped, so the
    /// local row is correctly withheld — but the *real* row exists only in a server response
    /// this view model has not made yet, and the fetch it is holding predates the create.
    ///
    /// The create must actually **land** here: a failed replay leaves the record in place and
    /// the row on screen, which is the shape an earlier version of this test had — it passed
    /// with the refetch deleted, with the gate inverted, and with `load()` swapped for
    /// `refresh()`, because no migration ever happened.
    func testAMigratedDocumentIsRefetchedRatherThanDisappearing() async {
        let log = RequestRecorder()
        let serverID = "66666666-6666-4666-8666-666666666666"
        let viewModel = makeViewModel(signedInUser: makeSignedInUser())
        preferences.set(true, forKey: "schrift.workOffline")
        let local = await viewModel.createDocument()
        XCTAssertEqual(viewModel.recentDocuments.count, 1)
        preferences.set(false, forKey: "schrift.workOffline")

        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("users/me/") {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data("{\"id\": \"11111111-1111-4111-8111-111111111111\"}".utf8), error: nil)
            }
            if request.httpMethod == "POST" {
                return .init(
                    statusCode: 201, headers: [:],
                    body: Data(
                        """
                        {"id": "\(serverID)", "title": "Untitled document",
                         "abilities": {"destroy": true, "partial_update": true}, "content": "",
                         "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-01T12:00:00Z",
                         "depth": 1, "numchild": 0, "path": "00000A", "link_reach": "restricted",
                         "link_role": "reader", "user_role": "owner"}
                        """.utf8), error: nil)
            }
            return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }

        await viewModel.syncPendingDrafts()
        await waitUntil { viewModel.saveCoordinator.isPendingCreate(documentID: local!.id) == false }

        // The migration itself must have driven a refetch — not the caller, since two of the
        // four things that start a create pass never come through `syncPendingDrafts()`.
        await waitUntil { log.count(ofMethod: "GET", urlContaining: "documents/") > 0 }
    }

    /// A fresh install in airplane mode that has created a document must render that row, not
    /// the never-fetched placeholder. `isCurrentListKnown` gates the empty state, and a local
    /// document *is* a real answer about what this device holds.
    func testALocalDocumentMakesTheListKnownWithoutAnyFetch() async {
        let viewModel = makeViewModel(signedInUser: makeSignedInUser())
        preferences.set(true, forKey: "schrift.workOffline")
        XCTAssertFalse(viewModel.isCurrentListKnown, "nothing fetched, nothing local")

        _ = await viewModel.createDocument()

        XCTAssertTrue(viewModel.isCurrentListKnown)
    }

    /// The row must leave a live Home the moment the replay migrates it — not at the next
    /// successful fetch. That is what reading `pendingCreatesVersion` in the computed property
    /// buys, and what the coordinator's counter exists for.
    func testAMigratedRowLeavesTheListWithoutARefetch() async {
        let viewModel = makeViewModel(signedInUser: makeSignedInUser())
        preferences.set(true, forKey: "schrift.workOffline")
        let document = await viewModel.createDocument()
        XCTAssertEqual(viewModel.recentDocuments.count, 1)

        // What the migration ends with: the record is dropped.
        viewModel.saveCoordinator.discardPendingWork(documentID: document!.id)

        XCTAssertTrue(viewModel.recentDocuments.isEmpty, "no fetch needed")
    }
}
