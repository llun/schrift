import XCTest

@testable import Schrift

@MainActor
final class HomeViewModelSignedInUserTests: HomeViewModelTestCase {
    /// This runs at launch and after re-authentication, and it is the only `/users/me/` a user
    /// who never opens Profile while online ever makes. Without the write-through, their first
    /// offline visit to Profile would still have nothing to show — the bug, moved rather than
    /// fixed. The response is already in hand, so the cache costs no extra request.
    func testRefreshingTheSignedInUserCachesTheProfileForOfflineDisplay() async {
        let suiteName = "HomeViewModelTests.profileCache.\(UUID().uuidString)"
        coordinatorSuiteNames.append(suiteName)
        let cachedUser = CurrentUserCacheStore(userDefaults: UserDefaults(suiteName: suiteName)!)
        MockURLProtocol.stubHandler = { _ in
            .init(
                statusCode: 200, headers: [:],
                body: Data(
                    """
                    {"id":"11111111-1111-4111-8111-111111111111","email":"ada@example.org",
                     "full_name":"Ada Lovelace","short_name":"Ada","language":"en-us"}
                    """.utf8),
                error: nil)
        }
        let signedIn = makeSignedInUser(userID: nil)
        let viewModel = makeViewModel(signedInUser: signedIn, cachedUser: cachedUser)

        await viewModel.refreshSignedInUser()

        XCTAssertEqual(cachedUser.user?.email, "ada@example.org")
        XCTAssertEqual(cachedUser.user?.fullName, "Ada Lovelace")
        // The method's other write-through, otherwise untested anywhere: this is the only
        // call to `refreshSignedInUser` in the suite, and the id is what gates whether an
        // offline-created document may be listed or replayed at all.
        XCTAssertEqual(signedIn.userID, UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
    }

    /// Failing closed is right; staying closed is not. `SessionStore.noteSessionCookiesReplaced`
    /// leaves the identity unknown when a login's confirming `/users/me/` fails — and that sheet
    /// often completes unattended, so an ordinary blip reaches it with the *same* account signed
    /// in. The store's only other writers run at launch and after a **successful** re-auth, so
    /// without this the user's own offline-created documents stay listed to nobody, and `+`
    /// keeps refusing to mint another, until they relaunch or happen to open Profile.
    func testAPullToRefreshReAsksWhoIsSignedInWhenNothingKnows() async {
        let log = RequestRecorder()
        let empty = Self.emptyFixture
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            // `contains`, not `hasSuffix`: `URL.path` drops the trailing slash, so matching the
            // endpoint's own `users/me/` spelling never fires.
            let path = request.url?.path ?? ""
            if path.contains("users/me") {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data(#"{"id":"11111111-1111-4111-8111-111111111111","email":"ada@example.org"}"#.utf8),
                    error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: empty, error: nil)
        }
        let signedIn = makeSignedInUser(userID: nil)
        let viewModel = makeViewModel(signedInUser: signedIn)

        await viewModel.refresh()

        XCTAssertEqual(signedIn.userID, UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "users/me/"), 1)
    }

    /// The passive half: reconnect and foreground both land here, so a session left without an
    /// identity recovers without the user having to know to pull.
    func testAReconnectSyncReAsksWhoIsSignedInWhenNothingKnows() async {
        let log = RequestRecorder()
        let empty = Self.emptyFixture
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let path = request.url?.path ?? ""
            if path.contains("users/me") {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data(#"{"id":"11111111-1111-4111-8111-111111111111","email":"ada@example.org"}"#.utf8),
                    error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: empty, error: nil)
        }
        let signedIn = makeSignedInUser(userID: nil)
        let viewModel = makeViewModel(signedInUser: signedIn)

        await viewModel.syncPendingDrafts()

        XCTAssertEqual(signedIn.userID, UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
        XCTAssertEqual(
            log.count(ofMethod: "GET", urlContaining: "users/me/"), 1,
            "asked once — the guard has to hold on this path too, not just on pull-to-refresh")
        // Learning the id un-hides this device's local rows, and `SignedInUserStore` is neither
        // `@Observable` nor cached — so without a load nothing would redraw them.
        XCTAssertGreaterThan(
            log.count(ofMethod: "GET", urlContaining: "documents/"), 0,
            "a re-learn must be followed by a load, or the rows stay hidden until something else invalidates")
    }

    /// …and only when it actually learned something. A sync that asks and gets nothing back
    /// must not turn every reconnect into a list fetch.
    func testAReconnectSyncThatLearnsNothingDoesNotLoad() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }
        let viewModel = makeViewModel(signedInUser: makeSignedInUser(userID: nil))

        await viewModel.syncPendingDrafts()

        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "documents/"), 0)
        // …and it did ask. Without this the test cannot tell "asked, learned nothing, so did
        // not load" from "the retry was deleted from this path entirely".
        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "users/me/"), 1)
    }

    /// **Work Offline is a strict no-network contract on every read path**, and this retry runs
    /// *ahead* of `load()`, so `load()`'s own early return cannot cover it. Unguarded, a
    /// pull-to-refresh in the mode parks the spinner on a 60s `/users/me/` — carrying session
    /// cookies the user asked not to send — and pays it again on every pull, because the id can
    /// never be learned while the network is refused.
    func testWorkOfflineWithholdsTheIdentityRetry() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 200, headers: [:], body: Data(), error: nil)
        }
        let suiteName = "HomeViewModelTests.workOfflineIdentity.\(UUID().uuidString)"
        coordinatorSuiteNames.append(suiteName)
        let preferences = UserDefaults(suiteName: suiteName)!
        preferences.set(true, forKey: "schrift.workOffline")
        let signedIn = makeSignedInUser(userID: nil)
        let viewModel = makeViewModel(userDefaults: preferences, signedInUser: signedIn)

        await viewModel.refresh()
        await viewModel.syncPendingDrafts()

        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "users/me/"), 0)
        XCTAssertNil(signedIn.userID, "and the identity stays unknown, which is the honest answer offline")
    }

    /// And only while the answer is missing — the retry is for a session whose identity was
    /// dropped, not a `/users/me/` on every pull-to-refresh.
    func testAPullToRefreshDoesNotReAskWhoIsSignedInWhenItAlreadyKnows() async {
        let log = RequestRecorder()
        let empty = Self.emptyFixture
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 200, headers: [:], body: empty, error: nil)
        }
        let known = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let signedIn = makeSignedInUser(userID: known)
        let viewModel = makeViewModel(signedInUser: signedIn)

        await viewModel.refresh()

        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "users/me/"), 0)
        XCTAssertEqual(signedIn.userID, known, "and it must not be disturbed")
    }
}
