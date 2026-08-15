import XCTest

@testable import Schrift

/// `MockURLProtocol.ResponseGate` — the "hold this response until I say so" stub.
///
/// `Stub(delay:)` can only defer delivery by a fixed interval, so a test whose subject is
/// an *ordering* ("the stale snapshot may only land once the create has resolved") has to
/// approximate it by betting that interval against the machine — and a loaded runner wins
/// the bet, failing the test for a reason no one can act on. A gate says the ordering
/// outright.
///
/// **Every test here pins its response as registered before asserting anything about
/// withholding.** Without that, a slow `Task` start makes the negative half trivially true,
/// the gate latches open, the late request is delivered, and the test passes having
/// exercised nothing — the same vacuity this whole change exists to remove, reintroduced in
/// the tests that are supposed to guard against it.
///
/// The signal is `deferredDeliveryCount`, **not** `lastRequest`: `startLoading` sets
/// `lastRequest` before the handler runs and before anything is registered, so a test
/// polling it can proceed while the delivery is still unregistered. Harmless for the
/// withholding tests, but fatal for the two drain tests, whose whole subject is what
/// `reset()` can cancel — a `reset()` issued inside that window would drain nothing, and
/// they would pass, or fail, for reasons unrelated to the drain.
final class MockURLProtocolGateTests: XCTestCase {
    private let contentURL = URL(
        string: "https://docs.example.org/api/v1.0/documents/11111111-1111-4111-8111-111111111111/content/")!
    private let versionsURL = URL(
        string: "https://docs.example.org/api/v1.0/documents/11111111-1111-4111-8111-111111111111/versions/")!
    /// Short enough to test the failsafe, and every "did it stay quiet?" wait is a
    /// comfortable multiple of it.
    private let shortFailsafe: TimeInterval = 0.1

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    /// Issues one request and records how it resolved, so a test can assert on the delivery
    /// itself rather than merely on the continuation having resumed — a gated path that
    /// resumed with a *failure*, or replayed a different stub, must not read as success.
    private final class RequestOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private var _statusCode: Int?
        private var _error: Error?
        private var _isFinished = false

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _isFinished
        }
        var statusCode: Int? {
            lock.lock()
            defer { lock.unlock() }
            return _statusCode
        }
        var error: Error? {
            lock.lock()
            defer { lock.unlock() }
            return _error
        }

        func record(statusCode: Int?, error: Error?) {
            lock.lock()
            defer { lock.unlock() }
            _statusCode = statusCode
            _error = error
            _isFinished = true
        }
    }

    private func issue(_ url: URL, on session: URLSession) -> (Task<Void, Never>, RequestOutcome) {
        let outcome = RequestOutcome()
        let task = Task {
            do {
                let (_, response) = try await session.data(from: url)
                outcome.record(statusCode: (response as? HTTPURLResponse)?.statusCode, error: nil)
            } catch {
                outcome.record(statusCode: nil, error: error)
            }
        }
        return (task, outcome)
    }

    private func stub(_ gate: MockURLProtocol.ResponseGate, statusCode: Int = 204, error: Error? = nil) {
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(
                statusCode: statusCode, headers: [:], body: Data(), error: error, releasedBy: gate)
        }
    }

    // MARK: - Withholding and release

    /// Delivered strictly on `open()` — the property every gated ordering rests on. The
    /// negative half is the one that matters, so the request's arrival is pinned first;
    /// otherwise "nothing was delivered" could just mean "nothing had been requested yet".
    @MainActor
    func testAGatedResponseIsWithheldUntilTheGateIsOpenedAndThenDelivered() async {
        let gate = MockURLProtocol.ResponseGate()
        stub(gate)
        let session = MockURLProtocol.makeSession()

        let (request, outcome) = issue(contentURL, on: session)
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }

        await waitAndConfirmNever { outcome.isFinished }

        gate.open()

        await waitUntil { outcome.isFinished }
        await request.value
        XCTAssertEqual(outcome.statusCode, 204, "and it is this stub that is delivered, not a failure")
        XCTAssertNil(outcome.error)
    }

    /// A request reaching an already-open gate is delivered rather than held, so a test
    /// cannot deadlock on an `open()` that has already been and gone.
    ///
    /// **This is on the real path, not a corner case**: `log.record(request)` runs inside the
    /// stub handler, which `startLoading` calls *before* `hold(_:until:)`, so a test's
    /// `waitUntil` on a recorded request can return — and its `open()` can run — before the
    /// protocol thread ever reaches `gate.hold(item)`. The latch is what makes that
    /// interleaving benign.
    ///
    /// Asserted through `waitUntil`, deliberately, so a broken latch fails here in 3s naming
    /// the latch. Asserting the status code alone would be inert: the request would hang, and
    /// 30s later the failsafe would fire and *itself* call `open()`, delivering the 204 — so
    /// the status assertion would pass, and the test would report "a gate was never opened",
    /// which is both the wrong diagnosis and pointed at the wrong file.
    @MainActor
    func testAGateThatIsAlreadyOpenDeliversImmediately() async {
        let gate = MockURLProtocol.ResponseGate()
        gate.open()
        stub(gate)
        let session = MockURLProtocol.makeSession()

        let (request, outcome) = issue(contentURL, on: session)

        await waitUntil { outcome.isFinished }
        await request.value
        XCTAssertEqual(outcome.statusCode, 204)
    }

    /// One gate can hold several requests, and releases all of them together — the plural
    /// path through `held`. Opening twice is a no-op rather than a double delivery.
    @MainActor
    func testOneGateHoldsEveryRequestAndReleasesThemTogether() async {
        let gate = MockURLProtocol.ResponseGate()
        stub(gate)
        let session = MockURLProtocol.makeSession()

        let (firstRequest, firstOutcome) = issue(contentURL, on: session)
        let (secondRequest, secondOutcome) = issue(versionsURL, on: session)
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 2 }
        await waitAndConfirmNever { firstOutcome.isFinished || secondOutcome.isFinished }

        gate.open()
        gate.open()  // latched: releases nothing further, and delivers nothing twice.

        await waitUntil { firstOutcome.isFinished && secondOutcome.isFinished }
        await firstRequest.value
        await secondRequest.value
        XCTAssertEqual(firstOutcome.statusCode, 204)
        XCTAssertEqual(secondOutcome.statusCode, 204)
    }

    /// A gate defers the stub, whatever the stub says — an `error:` stub still fails the
    /// request, on `open()` rather than at once.
    @MainActor
    func testAGateDefersAnErrorStubToo() async {
        let gate = MockURLProtocol.ResponseGate()
        stub(gate, error: URLError(.notConnectedToInternet))
        let session = MockURLProtocol.makeSession()

        let (request, outcome) = issue(contentURL, on: session)
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        await waitAndConfirmNever { outcome.isFinished }

        gate.open()

        await waitUntil { outcome.isFinished }
        await request.value
        XCTAssertEqual((outcome.error as? URLError)?.code, .notConnectedToInternet)
    }

    /// `releasedBy:` wins over `delay:`, which is worth pinning because someone converting a
    /// timed test to a gate will plausibly leave the `delay:` argument behind. With the
    /// precedence reversed this would deliver on the timer and the negative half would fail.
    @MainActor
    func testAGatedStubIgnoresItsDelay() async {
        let gate = MockURLProtocol.ResponseGate()
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(
                statusCode: 204, headers: [:], body: Data(), error: nil, delay: 0.05, releasedBy: gate)
        }
        let session = MockURLProtocol.makeSession()

        let (request, outcome) = issue(contentURL, on: session)
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }

        // Far longer than the delay, which must not be what releases this.
        await waitAndConfirmNever { outcome.isFinished }

        gate.open()

        await waitUntil { outcome.isFinished }
        await request.value
    }

    // MARK: - The drain

    /// The drain contract every deferred delivery in this file owes: one left holding at
    /// `tearDown` must not be able to fire into the next test's session. Opening the gate
    /// after `reset()` delivers nothing.
    ///
    /// Non-inert: drop the `pendingDeliveries` registration and `open()` dispatches an
    /// uncancelled item whose `isCancelled` guard is false, `deliver` runs, and the
    /// `waitAndConfirmNever` fails.
    @MainActor
    func testResetDrainsAGatedDeliveryThatWasNeverOpened() async {
        let gate = MockURLProtocol.ResponseGate()
        stub(gate)
        let session = MockURLProtocol.makeSession()

        let (request, outcome) = issue(contentURL, on: session)
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }

        MockURLProtocol.reset()  // the test's tearDown, with the gate still shut.
        gate.open()

        await waitAndConfirmNever { outcome.isFinished }

        // Release the suspended request rather than leaking it — cancelling fails the
        // URLSession task, which resumes the awaiting continuation.
        request.cancel()
        await request.value
    }

    /// `reset()` must cancel the **failsafe** as well as the delivery, and this is the half
    /// that matters for isolation: an uncancelled one fires `XCTFail` inside whatever
    /// unrelated test is running when it comes due. The drain test above cannot cover it —
    /// it opens its gate, so `isHoldingAnything` short-circuits and a live failsafe would
    /// stay silent anyway.
    /// The assertion is XCTest itself: a failsafe that fired would record an `XCTFail`
    /// against whichever test was running, which here is this one. So the only thing the
    /// body must do is let the deadline pass — advancing real time past a timer, the one
    /// case `Task.sleep` is for.
    @MainActor
    func testResetCancelsTheFailsafeSoItCannotFailALaterTest() async {
        let gate = MockURLProtocol.ResponseGate(failsafeTimeout: shortFailsafe)
        stub(gate)
        let session = MockURLProtocol.makeSession()

        let (request, _) = issue(contentURL, on: session)
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }

        MockURLProtocol.reset()  // must retire the failsafe with the delivery.

        try? await Task.sleep(for: .seconds(shortFailsafe * 5))

        request.cancel()
        await request.value
    }

    /// The window between the token check and registration, closed deterministically.
    ///
    /// `startLoading` checks the session token, then calls `handler(request)` — arbitrary
    /// test code — and only then registers. A `reset()` landing in that gap used to drain an
    /// empty list and leave the delivery *and its failsafe* scheduled with nothing able to
    /// cancel them; the failsafe would then report `XCTFail` inside whatever unrelated test
    /// was running when it came due. Calling `reset()` from inside the handler puts it in
    /// exactly that gap, every run, instead of waiting for a race to show up on CI.
    ///
    /// The request must be refused outright, as `startLoading` refuses a retired token.
    /// Non-inert in both directions: register unconditionally and the failsafe fires here,
    /// failing this test with the message it would have carried into someone else's.
    @MainActor
    func testAResetDuringTheHandlerStrandsNothing() async {
        let gate = MockURLProtocol.ResponseGate(failsafeTimeout: shortFailsafe)
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.reset()  // lands after the token check, before registration
            return MockURLProtocol.Stub(
                statusCode: 204, headers: [:], body: Data(), error: nil, releasedBy: gate)
        }
        let session = MockURLProtocol.makeSession()

        let (request, outcome) = issue(contentURL, on: session)

        await waitUntil { outcome.isFinished }
        await request.value
        XCTAssertEqual((outcome.error as? URLError)?.code, .cancelled, "refused, not left scheduled")
        XCTAssertEqual(MockURLProtocol.deferredDeliveryCount, 0, "and nothing was registered")

        // Past the failsafe's deadline: it must never have been scheduled at all.
        try? await Task.sleep(for: .seconds(shortFailsafe * 5))
    }

    /// The same window on the **timed** path, which shares the one registration helper. Its
    /// stranded item is a plain timer rather than a failsafe, but it fires into a torn-down
    /// session, which is the hang this file's deferred deliveries were built to avoid.
    @MainActor
    func testAResetDuringTheHandlerStrandsNothingOnTheTimedPathEither() async {
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.reset()
            return MockURLProtocol.Stub(
                statusCode: 204, headers: [:], body: Data(), error: nil, delay: 0.05)
        }
        let session = MockURLProtocol.makeSession()

        let (request, outcome) = issue(contentURL, on: session)

        await waitUntil { outcome.isFinished }
        await request.value
        XCTAssertEqual((outcome.error as? URLError)?.code, .cancelled)
        XCTAssertEqual(MockURLProtocol.deferredDeliveryCount, 0)
    }

    // MARK: - The failsafe

    /// A gate nothing opens would suspend the test body past the `tearDown` whose `reset()`
    /// would have drained it, so the hang is unbounded and the run dies naming nothing. The
    /// failsafe converts that into a named failure — and then releases the gate, so the body
    /// goes on to fail on its own assertions rather than hanging anyway.
    ///
    /// Worth pinning rather than trusting: the latch test above shows the failsafe can end up
    /// silently carrying another test's regression coverage, and a backstop nothing exercises
    /// is one nobody knows is broken.
    /// `XCTExpectFailure` is strict, so this also fails if the failsafe *doesn't* fire.
    ///
    /// The generous wait is the one place in this file where a timeout is not about our own
    /// code: the failsafe records its `XCTFail` and calls `open()` from the same main-queue
    /// block, so the release is queued **behind XCTest's issue recording**, whose cost is
    /// neither small nor bounded by anything here — measured at ~0.5s locally, and it
    /// overran `waitUntil`'s 3s default on a cold CI runner (run 31889803157), which is how
    /// this was found. It is a liveness bound, not an ordering, and it costs nothing on a
    /// healthy run — the test measures ~0.6s.
    ///
    /// **This is the one test the failsafe cannot rescue**, being its own subject: every
    /// other test here that hangs is released by it 30s later, so `await request.value` is
    /// safe. Here a broken failsafe would record the timeout and then suspend that `await`
    /// forever — a hung run on top of a recorded failure, which is the exact outcome the
    /// failsafe exists to prevent. So this one cancels the request itself rather than
    /// awaiting a resumption that may never come.
    @MainActor
    func testAnUnopenedGateFailsTheTestAndThenReleasesTheRequest() async {
        let gate = MockURLProtocol.ResponseGate(failsafeTimeout: shortFailsafe)
        stub(gate)
        let session = MockURLProtocol.makeSession()
        let expected = XCTExpectedFailure.Options()
        expected.issueMatcher = { $0.compactDescription.contains("ResponseGate holding GET") }
        XCTExpectFailure("the gate is deliberately never opened", options: expected)

        let (request, outcome) = issue(contentURL, on: session)

        await waitUntil(timeout: 30) { outcome.isFinished }
        if !outcome.isFinished { request.cancel() }
        await request.value
        XCTAssertEqual(outcome.statusCode, 204, "released, so the body fails on its own assertions")
    }

    /// And it stays quiet on the ordinary path — an opened gate must not report itself as a
    /// wiring bug once its deadline passes. Without the `isHoldingAnything` short-circuit
    /// every gated test in the suite would fail spuriously, this one included: as above, the
    /// assertion is that XCTest records nothing against this test while the deadline passes.
    @MainActor
    func testAnOpenedGateNeverFiresItsFailsafe() async {
        let gate = MockURLProtocol.ResponseGate(failsafeTimeout: shortFailsafe)
        stub(gate)
        let session = MockURLProtocol.makeSession()

        let (request, outcome) = issue(contentURL, on: session)
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        gate.open()
        await waitUntil { outcome.isFinished }
        await request.value

        try? await Task.sleep(for: .seconds(shortFailsafe * 5))
    }
}
