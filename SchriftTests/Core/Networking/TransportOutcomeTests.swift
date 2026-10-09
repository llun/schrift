import XCTest

@testable import Schrift

final class TransportOutcomeTests: XCTestCase {
    func testConnectivityClassErrorsAreConnectivityFailures() {
        let codes: [URLError.Code] = [
            .notConnectedToInternet, .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
            .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive,
        ]
        for code in codes {
            XCTAssertTrue(isConnectivityFailure(URLError(code)), "\(code.rawValue) means the server is unreachable")
        }
    }

    /// A cancellation is the app's own doing and a certificate or malformed-response error
    /// is a misconfigured server — none of them mean "offline".
    func testOtherErrorsAreNotConnectivityFailures() {
        XCTAssertFalse(isConnectivityFailure(URLError(.cancelled)))
        XCTAssertFalse(isConnectivityFailure(URLError(.serverCertificateUntrusted)))
        XCTAssertFalse(isConnectivityFailure(URLError(.badServerResponse)))
        XCTAssertFalse(isConnectivityFailure(DocsAPIError.decoding("x")))
    }
}
