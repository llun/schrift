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

    func testFailureAfterMarkerReturnsTheNewestFailure() {
        let log = APIDiagnosticsLog()
        log.record(failure(400))
        let marker = log.marker()
        log.record(failure(403))

        XCTAssertEqual(log.failure(after: marker)?.statusCode, 403)
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
}
