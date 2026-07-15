import XCTest

@testable import Schrift

/// Byte-exact tests for the Yjs sync-protocol payload codec. Golden hex is
/// captured from y-protocols 1.0.7 (`writeSyncStep1`/`writeSyncStep2`/
/// `writeUpdate`) via `scratchpad/fixtures/gen.mjs`.
final class SyncMessageTests: XCTestCase {
    // The 57-byte update `Y.encodeStateAsUpdate` produces for a doc containing a
    // single `<paragraph>hi</paragraph>` in the `document-store` fragment.
    private let updateHex =
        "0103effdb6f50d0007010e646f63756d656e742d73746f726503097061726167726170680700effdb6f50d00060400effdb6f50d0102686900"

    // MARK: - decode

    func testDecodesStep1EmptyStateVector() throws {
        // writeSyncStep1 over an empty Y.Doc: subtype 0 + varUint8Array([0x00]).
        let message = try SyncMessage(decodingPayload: Data(hex: "000100"))
        XCTAssertEqual(message.step, .step1)
        XCTAssertEqual(message.data, Data([0x00]))
    }

    func testDecodesStep1WithContentStateVector() throws {
        let message = try SyncMessage(decodingPayload: Data(hex: "000701effdb6f50d04"))
        XCTAssertEqual(message.step, .step1)
        XCTAssertEqual(message.data, Data(hex: "01effdb6f50d04"))
    }

    func testDecodesStep2Update() throws {
        let message = try SyncMessage(decodingPayload: Data(hex: "0139" + updateHex))
        XCTAssertEqual(message.step, .step2)
        XCTAssertEqual(message.data, Data(hex: updateHex))
    }

    func testDecodesUnsolicitedUpdate() throws {
        let message = try SyncMessage(decodingPayload: Data(hex: "0239" + updateHex))
        XCTAssertEqual(message.step, .update)
        XCTAssertEqual(message.data, Data(hex: updateHex))
    }

    // MARK: - encode

    func testEncodesStep1EmptyStateVectorGolden() {
        let message = SyncMessage(step: .step1, data: Data([0x00]))
        XCTAssertEqual(message.encodedPayload().hexString, "000100")
    }

    func testEncodesUpdateGolden() {
        let message = SyncMessage(step: .update, data: Data(hex: updateHex))
        XCTAssertEqual(message.encodedPayload().hexString, "0239" + updateHex)
    }

    func testEncodeDecodeRoundTrip() throws {
        for step in [SyncStep.step1, .step2, .update] {
            for data in [Data(), Data([0x00]), Data(hex: updateHex)] {
                let message = SyncMessage(step: step, data: data)
                let decoded = try SyncMessage(decodingPayload: message.encodedPayload())
                XCTAssertEqual(decoded, message)
            }
        }
    }

    // MARK: - unknown sub-types

    func testUnknownSyncStepThrows() {
        // subtype 3 + empty uint8Array — 3 is not a modeled sync sub-type.
        assertThrows(SyncMessageError.unknownStep(3)) { _ = try SyncMessage(decodingPayload: Data(hex: "0300")) }
    }

    func testTruncatedPayloadThrows() {
        // step-2, then a varUint8Array claiming 0x39 = 57 bytes but supplying one.
        assertThrows(Lib0DecodingError.truncated) { _ = try SyncMessage(decodingPayload: Data(hex: "013900")) }
    }
}
