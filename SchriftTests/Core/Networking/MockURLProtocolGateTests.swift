import XCTest

@testable import Schrift

/// `MockURLProtocol.ResponseGate` — the "hold this response until I say so" stub.
///
/// `Stub(delay:)` can only defer delivery by a fixed interval, so a test whose subject is
/// an *ordering* ("the stale snapshot may only land once the create has resolved") has to
/// approximate it by betting that interval against the machine — and a loaded runner wins
/// the bet, failing the test for a reason no one can act on. A gate says the ordering
/// outright. These tests pin the three properties the gated tests rely on: nothing is
/// delivered before `open()`, everything is after it, and `reset()` drains a gate that was
/// never opened so it cannot fire into a later test.
final class MockURLProtocolGateTests: XCTestCase {
    private let contentURL = URL(
        string: "https://docs.example.org/api/v1.0/documents/11111111-1111-4111-8111-111111111111/content/")!

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    /// Delivered strictly on `open()` — the property the ordering rests on. The negative
    /// half is the one that matters: without the gate, `Stub(delay:)`'s timer could fire
    /// here whatever the test was waiting for.
    @MainActor
    func testAGatedResponseIsWithheldUntilTheGateIsOpenedAndThenDelivered() async {
        let gate = MockURLProtocol.ResponseGate()
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 204, headers: [:], body: Data(), error: nil, releasedBy: gate)
        }
        let session = MockURLProtocol.makeSession()
        let finished = Counter()

        let request = Task { [contentURL] in
            _ = try? await session.data(from: contentURL)
            _ = finished.next()
        }

        await waitAndConfirmNever { finished.current > 0 }

        gate.open()

        await waitUntil { finished.current == 1 }
        await request.value
    }

    /// A request that arrives at an already-open gate is delivered rather than held: the
    /// gate latches, so a test cannot deadlock on an `open()` that has already happened.
    @MainActor
    func testAGateThatIsAlreadyOpenDeliversImmediately() async {
        let gate = MockURLProtocol.ResponseGate()
        gate.open()
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 204, headers: [:], body: Data(), error: nil, releasedBy: gate)
        }
        let session = MockURLProtocol.makeSession()

        let response = try? await session.data(from: contentURL)

        XCTAssertEqual((response?.1 as? HTTPURLResponse)?.statusCode, 204)
    }

    /// The drain contract every deferred delivery in this file owes: one left holding at
    /// `tearDown` must not be able to fire into the next test's session. Opening the gate
    /// after `reset()` delivers nothing.
    @MainActor
    func testResetDrainsAGatedDeliveryThatWasNeverOpened() async {
        let gate = MockURLProtocol.ResponseGate()
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 204, headers: [:], body: Data(), error: nil, releasedBy: gate)
        }
        let session = MockURLProtocol.makeSession()
        let log = RequestRecorder()
        let finished = Counter()

        let request = Task { [contentURL] in
            _ = try? await session.data(from: contentURL)
            _ = finished.next()
        }
        await waitUntil { MockURLProtocol.lastRequest != nil }

        MockURLProtocol.reset()  // the test's tearDown, with the gate still shut.
        // A later test's handler, which the drained delivery must never reach.
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return MockURLProtocol.Stub(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        gate.open()

        await waitAndConfirmNever { finished.current > 0 }
        XCTAssertEqual(log.methods.count, 0, "a drained delivery reaches no handler at all")

        // Release the suspended request rather than leaking it — cancelling fails the
        // URLSession task, which resumes the awaiting continuation.
        request.cancel()
        await request.value
    }
}
