import XCTest

@testable import Schrift

final class APIDiagnosticsLogTests: XCTestCase {
    private func failure(_ statusCode: Int) -> RequestFailure {
        RequestFailure(method: "POST", path: "documents/", statusCode: statusCode, body: Data())
    }

    func testFailureAfterMarkerReturnsNilWhenNothingWasRecorded() {
        let log = APIDiagnosticsLog()
        let marker = log.marker()

        XCTAssertNil(log.failure(after: marker))
    }

    func testFailureAfterMarkerReturnsTheFirstFailureRecordedSince() {
        let log = APIDiagnosticsLog()
        log.record(failure(400))
        let marker = log.marker()
        log.record(failure(403))

        XCTAssertEqual(log.failure(after: marker)?.statusCode, 403)
    }

    /// First, not last. One call can issue several requests, and the later ones are
    /// consequences: `formattedContent`'s confirmation probe records a 404 of its own, for a
    /// document id that does not exist. Quoting it would show the user a reason belonging to
    /// a request they never made.
    func testFailureAfterMarkerIgnoresLaterFailuresFromTheSameCall() {
        let log = APIDiagnosticsLog()
        let marker = log.marker()
        log.record(failure(404))  // the document's own response — the cause
        log.record(failure(410))  // a confirmation probe issued afterwards

        XCTAssertEqual(log.failure(after: marker)?.statusCode, 404)
    }

    /// When the causal failure has been evicted, the oldest still held is the closest thing.
    func testFailureAfterMarkerDegradesGracefullyOnceTheCauseIsEvicted() {
        let log = APIDiagnosticsLog()
        let marker = log.marker()
        for _ in 0..<(APIDiagnosticsLog.capacity + 3) { log.record(failure(500)) }

        XCTAssertNotNil(log.failure(after: marker))
        XCTAssertEqual(log.recentFailures.count, APIDiagnosticsLog.capacity)
    }

    /// The point of the marker: an offline `.network` failure records nothing, so the catch
    /// must not quote the unrelated 403 that came before it.
    func testFailureAfterMarkerIgnoresFailuresRecordedBeforeIt() {
        let log = APIDiagnosticsLog()
        log.record(failure(403))
        let marker = log.marker()

        XCTAssertNil(log.failure(after: marker))
    }

    func testMarkerStaysMonotonicOnceCapacityEvicts() {
        let log = APIDiagnosticsLog()
        for _ in 0..<(APIDiagnosticsLog.capacity + 5) { log.record(failure(500)) }
        let marker = log.marker()
        log.record(failure(403))

        XCTAssertEqual(log.recentFailures.count, APIDiagnosticsLog.capacity)
        XCTAssertEqual(log.failure(after: marker)?.statusCode, 403)
    }

    /// A request issued concurrently with the one that threw can be recorded first; the filter
    /// skips it without losing "first" among the rest — and still honours the marker.
    func testTheFilterSkipsAConcurrentRequestsFailureButKeepsTheMarker() {
        let log = APIDiagnosticsLog()
        log.record(RequestFailure(method: "GET", path: "documents/a/", statusCode: 500, body: Data()))
        let marker = log.marker()
        log.record(RequestFailure(method: "GET", path: "documents/a/children/", statusCode: 403, body: Data()))
        log.record(RequestFailure(method: "GET", path: "documents/a/formatted-content/", statusCode: 404, body: Data()))
        log.record(RequestFailure(method: "GET", path: "documents/0/formatted-content/", statusCode: 410, body: Data()))

        XCTAssertEqual(log.failure(after: marker)?.statusCode, 403, "unfiltered, the first is the list's")
        XCTAssertEqual(log.failure(after: marker, where: isBodyReadFailure)?.statusCode, 404)
        XCTAssertNil(log.failure(after: log.marker(), where: isBodyReadFailure))
    }
}
