import XCTest

@testable import Schrift

/// `MockURLProtocol.stubHandler` is a single global closure, read fresh inside
/// `startLoading`. A `DocumentSaveCoordinator` save runs in an unstructured `Task`
/// that deliberately outlives its test (navigating away must not cancel a save),
/// and its `session.data(for:)` runs on the `DocsAPIClient` actor — off the main
/// actor. Under load such a task can *initiate* its content PATCH after its test
/// tore down, while a **later** test's `stubHandler` is installed — recording a
/// phantom `PATCH …/content/` into the later test's `RequestRecorder` and flaking
/// its `waitAndConfirmNever` / `savesInFlight` assertions (observed on
/// `EditorViewModelTests`).
///
/// The fix is central and test-only: `makeSession()` tags every request with a
/// token that `reset()` retires at teardown, and `startLoading` rejects a
/// retired-token request before it reads `stubHandler` — so a leaked task can never
/// record into another test's log. (Invalidating the session would also stop the
/// recording, but creating a new task on an invalidated `URLSession` raises an
/// uncatchable ObjC `NSException` that crashes the whole test process — worse than
/// the flake it cures.) These tests reproduce the leak directly — no reliance on a
/// load-dependent race — so the isolation guarantee is pinned deterministically.
final class MockURLProtocolIsolationTests: XCTestCase {
    private let contentURL = URL(
        string: "https://docs.example.org/api/v1.0/documents/11111111-1111-4111-8111-111111111111/content/")!

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func patchContentRequest() -> URLRequest {
        var request = URLRequest(url: contentURL)
        request.httpMethod = "PATCH"
        return request
    }

    /// The regression: a session handed to an earlier test, whose leaked save `Task`
    /// only reaches the network *after* that test tore down, must not record into a
    /// later test's handler. Without the retired-token rejection this fails, because
    /// the leaked request runs through `startLoading`, reads the now-global later
    /// handler, and records a phantom `PATCH …/content/`.
    func testResetRetiresSessionTokensSoALeakedRequestCannotRecordIntoALaterHandler() async {
        // "Test A": takes a session and installs its handler, then tears down.
        let leakedSession = MockURLProtocol.makeSession()
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        MockURLProtocol.reset()  // Test A's tearDown.

        // "Test B": a fresh handler recording into its own log.
        let logB = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            logB.record(request)
            return MockURLProtocol.Stub(statusCode: 204, headers: [:], body: Data(), error: nil)
        }

        // Test A's leaked task initiates its content PATCH on the session it still holds.
        _ = try? await leakedSession.data(for: patchContentRequest())

        XCTAssertEqual(
            logB.count(ofMethod: "PATCH", urlContaining: "/content/"), 0,
            "a request from a torn-down test's session must never record into a later test's handler")
    }

    /// Retiring tokens must not break the normal path: a session still in use records
    /// its request exactly as before.
    func testALiveSessionsRequestStillRecords() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return MockURLProtocol.Stub(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        let session = MockURLProtocol.makeSession()

        _ = try? await session.data(for: patchContentRequest())

        XCTAssertEqual(
            log.count(ofMethod: "PATCH", urlContaining: "/content/"), 1,
            "retiring session tokens at reset() must not break a live session's normal request path")
    }

    /// The epoch isolation the whole fix rests on: a session made *after* `reset()`
    /// is live, while the earlier retired session stays rejected. A token retired at
    /// `reset()` is never reissued (tokens are UUIDs), so the earlier session's
    /// leaked request can't be revived by a later session sharing its identity.
    func testASessionMadeAfterResetIsLiveWhileTheEarlierRetiredSessionStaysRejected() async {
        let earlierSession = MockURLProtocol.makeSession()
        MockURLProtocol.reset()  // retires the earlier session's token.
        let laterSession = MockURLProtocol.makeSession()

        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return MockURLProtocol.Stub(statusCode: 204, headers: [:], body: Data(), error: nil)
        }

        // The earlier (retired) session's leaked request stays rejected...
        _ = try? await earlierSession.data(for: patchContentRequest())
        XCTAssertEqual(
            log.count(ofMethod: "PATCH", urlContaining: "/content/"), 0,
            "a session retired at reset() must stay rejected even after a new session is made")

        // ...while the later session's own request records normally.
        _ = try? await laterSession.data(for: patchContentRequest())
        XCTAssertEqual(
            log.count(ofMethod: "PATCH", urlContaining: "/content/"), 1,
            "a session made after reset() is live and records")
    }

    /// A session built directly — not via `makeSession()` — carries no token, so
    /// `startLoading` must leave it alone rather than reject it. Nothing in the suite
    /// builds such a session today; this locks the "no token ⇒ untouched" contract so
    /// a future hardening of the rejection can't silently start dropping it.
    func testAnUntaggedSessionsRequestRecordsNormally() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let untaggedSession = URLSession(configuration: configuration)

        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return MockURLProtocol.Stub(statusCode: 204, headers: [:], body: Data(), error: nil)
        }

        _ = try? await untaggedSession.data(for: patchContentRequest())

        XCTAssertEqual(
            log.count(ofMethod: "PATCH", urlContaining: "/content/"), 1,
            "a session with no token (not from makeSession) must be left alone, not rejected")
    }
}
