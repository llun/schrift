import XCTest

@testable import Schrift

final class TransportFailureTests: XCTestCase {
    func testClassifiesWhichFailuresAreWorthOneRetry() {
        let cases: [(name: String, error: Error, expected: Bool)] = [
            ("cancelled", URLError(.cancelled), false),
            ("bad server response", URLError(.badServerResponse), false),
            ("body too large", URLError(.dataLengthExceedsMaximum), false),
            ("server 500", DocsAPIError.server(statusCode: 500), false),
            ("not found", DocsAPIError.notFound, false),
            ("not connected", URLError(.notConnectedToInternet), true),
            ("timed out", URLError(.timedOut), true),
            ("wrapped network", DocsAPIError.network("x"), true),
        ]
        for testCase in cases {
            XCTAssertEqual(isTransportFailure(testCase.error), testCase.expected, testCase.name)
        }
    }
}
