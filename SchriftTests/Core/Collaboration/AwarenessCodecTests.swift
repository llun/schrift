import XCTest

@testable import Schrift

/// Byte-exact tests for the awareness codec. Golden hex is captured from
/// y-protocols 1.0.7 `encodeAwarenessUpdate` and the provider's awareness
/// framing (an extra `varUint8Array` wrap) via `scratchpad/fixtures/gen.mjs`.
final class AwarenessCodecTests: XCTestCase {
    private let adaJSON = ##"{"name":"Ada","color":"#0E7C66"}"##
    private let boJSON = ##"{"name":"Bo","color":"#B54708"}"##

    private let oneClientUpdate = "010101207b226e616d65223a22416461222c22636f6c6f72223a2223304537433636227d"
    private let twoClientUpdate =
        "020101207b226e616d65223a22416461222c22636f6c6f72223a2223304537433636227d2a011f7b226e616d65223a22426f222c22636f6c6f72223a2223423534373038227d"

    // MARK: - decode (inner update)

    func testDecodesOneClient() throws {
        let entries = try AwarenessCodec.decode(Data(hex: oneClientUpdate))
        XCTAssertEqual(entries, [AwarenessEntry(clientID: 1, clock: 1, stateJSON: adaJSON)])
    }

    func testDecodesTwoClients() throws {
        let entries = try AwarenessCodec.decode(Data(hex: twoClientUpdate))
        XCTAssertEqual(
            entries,
            [
                AwarenessEntry(clientID: 1, clock: 1, stateJSON: adaJSON),
                AwarenessEntry(clientID: 42, clock: 1, stateJSON: boJSON),
            ])
    }

    func testDecodesRemovedClientAsNullState() throws {
        // A removed client encodes its state as the JSON literal `null`.
        let entries = try AwarenessCodec.decode(Data(hex: "010703046e756c6c"))
        XCTAssertEqual(entries, [AwarenessEntry(clientID: 7, clock: 3, stateJSON: "null")])
    }

    // MARK: - encode (inner update)

    func testEncodesOneClientGolden() {
        let data = AwarenessCodec.encode([AwarenessEntry(clientID: 1, clock: 1, stateJSON: adaJSON)])
        XCTAssertEqual(data.hexString, oneClientUpdate)
    }

    func testEncodesTwoClientsGolden() {
        let data = AwarenessCodec.encode([
            AwarenessEntry(clientID: 1, clock: 1, stateJSON: adaJSON),
            AwarenessEntry(clientID: 42, clock: 1, stateJSON: boJSON),
        ])
        XCTAssertEqual(data.hexString, twoClientUpdate)
    }

    func testEncodeDecodeRoundTrip() throws {
        let entries = [
            AwarenessEntry(clientID: 1, clock: 5, stateJSON: adaJSON),
            AwarenessEntry(clientID: 0xDEAD_BEEF, clock: 0, stateJSON: "null"),
        ]
        XCTAssertEqual(try AwarenessCodec.decode(AwarenessCodec.encode(entries)), entries)
    }

    func testEmptyUpdateBoundary() throws {
        // Zero clients encodes as a single varUint(0); decoding it yields no entries.
        XCTAssertEqual(AwarenessCodec.encode([]).hexString, "00")
        XCTAssertEqual(try AwarenessCodec.decode(Data([0x00])), [])
    }

    // MARK: - frame payload (the extra varUint8Array wrap)

    func testEncodePayloadWrapsUpdateInVarUint8Array() {
        // The awareness frame payload is varUint8Array(inner update): the inner
        // update is 0x24 = 36 bytes, so the payload prefixes it with `24`.
        let payload = AwarenessCodec.encodePayload([AwarenessEntry(clientID: 1, clock: 1, stateJSON: adaJSON)])
        XCTAssertEqual(payload.hexString, "24" + oneClientUpdate)
    }

    func testDecodePayloadRoundTrip() throws {
        let entries = [AwarenessEntry(clientID: 1, clock: 1, stateJSON: adaJSON)]
        XCTAssertEqual(try AwarenessCodec.decodePayload(AwarenessCodec.encodePayload(entries)), entries)
    }

    /// The full `.awareness` frame, end to end: documentName + type + the
    /// varUint8Array-wrapped update. Golden bytes from the real provider.
    func testFullAwarenessFrameGolden() {
        let doc = "11111111-1111-4111-8111-111111111111"
        let payload = AwarenessCodec.encodePayload([AwarenessEntry(clientID: 1, clock: 1, stateJSON: adaJSON)])
        let frame = HocuspocusMessage(documentName: doc, type: .awareness, payload: payload)
        XCTAssertEqual(
            frame.encoded().hexString,
            "2431313131313131312d313131312d343131312d383131312d3131313131313131313131310124" + oneClientUpdate)
    }

    // MARK: - hostile / malformed input (this codec parses untrusted network bytes)

    func testDecodeTruncatedInnerUpdateThrows() {
        // Claims 5 clients, supplies none.
        assertThrows(Lib0DecodingError.truncated) { _ = try AwarenessCodec.decode(Data([0x05])) }
    }

    func testDecodeHugeCountDoesNotOverAllocateAndThrows() {
        // count = 4_294_967_295 with an empty body. The reserveCapacity clamp must
        // keep this from attempting a multi-GB allocation; the per-entry read then
        // throws .truncated. (Reverting the clamp would OOM/crash here instead.)
        assertThrows(Lib0DecodingError.truncated) { _ = try AwarenessCodec.decode(Data(hex: "ffffffff0f")) }
    }

    func testDecodeMidEntryTruncationThrows() {
        // count 1, clientID 1, then the clock varUint is missing.
        assertThrows(Lib0DecodingError.truncated) { _ = try AwarenessCodec.decode(Data([0x01, 0x01])) }
    }

    func testDecodeInvalidUTF8StateThrows() {
        // count 1, clientID 1, clock 1, stateJSON length 1 + a lone 0xFF byte.
        assertThrows(Lib0DecodingError.invalidUTF8) {
            _ = try AwarenessCodec.decode(Data([0x01, 0x01, 0x01, 0x01, 0xFF]))
        }
    }

    func testDecodePayloadWrapperOverrunThrows() {
        // The outer varUint8Array claims 5 bytes but only 1 follows.
        assertThrows(Lib0DecodingError.truncated) { _ = try AwarenessCodec.decodePayload(Data([0x05, 0x00])) }
    }
}
