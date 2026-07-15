import XCTest

@testable import Schrift

/// Byte-exact tests for the Hocuspocus frame codec. Golden hex is captured from
/// the real `@hocuspocus/provider` 3.4.4 framing
/// (`writeVarString(documentName) + writeVarUint(type) + payload`), reproduced
/// by `scratchpad/fixtures/gen.mjs` (never committed — zero-dependency rule).
final class HocuspocusMessageTests: XCTestCase {
    private let doc = "11111111-1111-4111-8111-111111111111"

    // Frames over `doc` for the documentName; payloads verified elsewhere.
    private let closeFrame = "2431313131313131312d313131312d343131312d383131312d31313131313131313131313107"
    private let queryAwarenessFrame = "2431313131313131312d313131312d343131312d383131312d31313131313131313131313103"
    private let syncStep1EmptyFrame =
        "2431313131313131312d313131312d343131312d383131312d31313131313131313131313100000100"

    // MARK: decode

    func testDecodesSyncFrame() throws {
        let message = try HocuspocusMessage(decoding: Data(hex: syncStep1EmptyFrame))
        XCTAssertEqual(message.documentName, doc)
        XCTAssertEqual(message.type, HocuspocusMessageType.sync.rawValue)
        XCTAssertEqual(message.knownType, .sync)
        XCTAssertEqual(message.payload.hexString, "000100")
    }

    func testDecodesPayloadlessFrames() throws {
        let close = try HocuspocusMessage(decoding: Data(hex: closeFrame))
        XCTAssertEqual(close.documentName, doc)
        XCTAssertEqual(close.knownType, .close)
        XCTAssertTrue(close.payload.isEmpty)

        let query = try HocuspocusMessage(decoding: Data(hex: queryAwarenessFrame))
        XCTAssertEqual(query.knownType, .queryAwareness)
        XCTAssertTrue(query.payload.isEmpty)
    }

    // MARK: encode

    func testEncodesSyncFrameGolden() {
        let message = HocuspocusMessage(documentName: doc, type: .sync, payload: Data(hex: "000100"))
        XCTAssertEqual(message.encoded().hexString, syncStep1EmptyFrame)
    }

    func testEncodesCloseFrameGolden() {
        let message = HocuspocusMessage(documentName: doc, type: .close)
        XCTAssertEqual(message.encoded().hexString, closeFrame)
    }

    func testEncodeDecodeRoundTripPreservesPayload() throws {
        let payload = Data(hex: "02390103effdb6f50d00")
        let message = HocuspocusMessage(documentName: doc, type: .sync, payload: payload)
        let decoded = try HocuspocusMessage(decoding: message.encoded())
        XCTAssertEqual(decoded, message)
        XCTAssertEqual(decoded.payload, payload)
    }

    // MARK: unknown types are tolerated, not fatal

    func testUnknownInboundTypeSurvivesAsRawValue() throws {
        // 99 is not a modeled type (e.g. a future/unconfirmed message kind).
        let message = HocuspocusMessage(documentName: doc, type: 99, payload: Data([0xAB]))
        let decoded = try HocuspocusMessage(decoding: message.encoded())
        XCTAssertEqual(decoded.type, 99)
        XCTAssertNil(decoded.knownType, "an unknown type decodes to nil, never throws")
        XCTAssertEqual(decoded.payload, Data([0xAB]))
    }

    func testServerOriginatedTypesAreRecognised() {
        // The provider does not *send* 4/6, but the server can, so we recognise them.
        XCTAssertEqual(HocuspocusMessageType(rawValue: 4), .syncReply)
        XCTAssertEqual(HocuspocusMessageType(rawValue: 6), .broadcastStateless)
        XCTAssertEqual(HocuspocusMessageType(rawValue: 8), .syncStatus)
    }

    func testTruncatedFrameThrows() {
        // A lone continuation byte where the documentName length varUint should be.
        assertThrows(Lib0DecodingError.truncated) { _ = try HocuspocusMessage(decoding: Data([0x80])) }
    }
}
