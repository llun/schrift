import Foundation
import XCTest

@testable import Schrift

private final class RedirectRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?

    func set(_ request: URLRequest?) { lock.withLock { self.request = request } }
    var value: URLRequest? { lock.withLock { request } }
}

/// Close-code classification: only 1000 is the terminal permission-reset; every
/// other peer close is a reconnect candidate. Plus the text-frame rejection.
final class CollaborationDisconnectTests: XCTestCase {
    func testNormalClosureIsPermissionsReset() {
        XCTAssertEqual(CollaborationDisconnect.classify(closeCode: .normalClosure), .permissionsReset)
    }

    func testOtherCodesAreTransient() {
        for code: URLSessionWebSocketTask.CloseCode in [.goingAway, .abnormalClosure, .invalid, .internalServerError] {
            XCTAssertEqual(CollaborationDisconnect.classify(closeCode: code), .transient, "\(code)")
        }
    }

    func testWebSocketDataUnwrapsBinaryFrame() throws {
        XCTAssertEqual(try webSocketData(from: .data(Data([0x01, 0x02]))), Data([0x01, 0x02]))
    }

    func testWebSocketDataRejectsTextFrame() {
        assertThrows(WebSocketProtocolError.unexpectedTextFrame) { _ = try webSocketData(from: .string("oops")) }
    }

    func testWebSocketSessionDelegateRefusesUpgradeRedirects() {
        let initialURL = URL(string: "https://docs.example.org/collaboration/ws/")!
        let destinationURL = URL(string: "https://other.example/collaboration/ws/")!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: initialURL)
        let response = HTTPURLResponse(url: initialURL, statusCode: 302, httpVersion: nil, headerFields: [:])!
        let request = URLRequest(url: destinationURL)
        let capture = RedirectRequestCapture()

        CollaborationWebSocketSessionDelegate().urlSession(
            session, task: task, willPerformHTTPRedirection: response, newRequest: request,
            completionHandler: { capture.set($0) })

        XCTAssertNil(capture.value)
    }
}
