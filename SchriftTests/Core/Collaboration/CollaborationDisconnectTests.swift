import XCTest

@testable import Schrift

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
        do {
            _ = try webSocketData(from: .string("oops"))
            XCTFail("expected unexpectedTextFrame")
        } catch let error as WebSocketProtocolError {
            XCTAssertEqual(error, .unexpectedTextFrame)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
