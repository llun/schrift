import XCTest

@testable import Schrift

/// Byte-exact tests for the lib0 read primitives. Every golden hex string is
/// output captured from the real `lib0` 0.2.117 encoder (`lib0/encoding`), so a
/// pass means `Lib0Decoder` reads exactly what lib0 writes — and, via the
/// round-trip tests, that `Lib0Encoder` and `Lib0Decoder` are mutual inverses.
///
/// Regenerate with the session-local `scratchpad/fixtures/gen.mjs` script
/// (pinned lib0 0.2.117); it is never committed (zero-dependency rule).
final class Lib0DecoderTests: XCTestCase {

    // MARK: readVarUInt

    func testReadVarUIntGoldenValues() throws {
        let cases: [(UInt, String)] = [
            (0, "00"), (1, "01"), (127, "7f"), (128, "8001"), (255, "ff01"), (300, "ac02"),
            (16383, "ff7f"), (16384, "808001"), (0xDEAD_BEEF, "effdb6f50d"), (4_294_967_295, "ffffffff0f"),
        ]
        for (value, hex) in cases {
            var decoder = Lib0Decoder(Data(hex: hex))
            XCTAssertEqual(try decoder.readVarUInt(), value, "decoding \(hex)")
            XCTAssertFalse(decoder.hasMoreData, "consumed all of \(hex)")
        }
    }

    // MARK: readVarInt

    func testReadVarIntGoldenValues() throws {
        let cases: [(Int, String)] = [
            (0, "00"), (1, "01"), (63, "3f"), (64, "8001"), (127, "bf01"), (8191, "bf7f"),
            (1_000_000, "80897a"), (2_147_483_647, "bfffffff0f"),
            (-1, "41"), (-64, "c001"), (-65, "c101"), (-127, "ff01"), (-8191, "ff7f"),
            (-1_000_000, "c0897a"), (-2_147_483_647, "ffffffff0f"),
        ]
        for (value, hex) in cases {
            var decoder = Lib0Decoder(Data(hex: hex))
            XCTAssertEqual(try decoder.readVarInt(), value, "decoding \(hex)")
            XCTAssertFalse(decoder.hasMoreData, "consumed all of \(hex)")
        }
    }

    // MARK: readVarString

    func testReadVarStringGoldenValues() throws {
        let cases: [(String, String)] = [
            ("", "00"), ("hi", "026869"), ("café 😀", "0a636166c3a920f09f9880"),
            ("document-store", "0e646f63756d656e742d73746f7265"),
        ]
        for (value, hex) in cases {
            var decoder = Lib0Decoder(Data(hex: hex))
            XCTAssertEqual(try decoder.readVarString(), value, "decoding \(hex)")
        }
    }

    func testReadVarStringLongPayload() throws {
        let hex = "c801" + String(repeating: "61", count: 200)
        var decoder = Lib0Decoder(Data(hex: hex))
        XCTAssertEqual(try decoder.readVarString(), String(repeating: "a", count: 200))
    }

    func testReadVarStringRejectsInvalidUTF8() {
        // varUint length 1, then 0xFF — never a valid single UTF-8 byte.
        var decoder = Lib0Decoder(Data(hex: "01ff"))
        do {
            _ = try decoder.readVarString()
            XCTFail("expected invalidUTF8")
        } catch let error as Lib0DecodingError {
            XCTAssertEqual(error, .invalidUTF8)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: readUint8Array

    func testReadUint8ArrayGoldenValues() throws {
        let cases: [(String, String)] = [("", "00"), ("000102", "03000102"), ("ff007f80", "04ff007f80")]
        for (bodyHex, hex) in cases {
            var decoder = Lib0Decoder(Data(hex: hex))
            XCTAssertEqual(try decoder.readUint8Array(), Data(hex: bodyHex), "decoding \(hex)")
        }
    }

    // MARK: readAny

    func testReadAnyModeledTags() throws {
        let cases: [(YAnyValue, String)] = [
            (.string("hello"), "770568656c6c6f"), (.int(0), "7d00"), (.int(42), "7d2a"), (.int(-7), "7d47"),
            (.bool(true), "78"), (.bool(false), "79"), (.null, "7e"), (.undefined, "7f"),
        ]
        for (value, hex) in cases {
            var decoder = Lib0Decoder(Data(hex: hex))
            XCTAssertEqual(try decoder.readAny(), value, "decoding \(hex)")
        }
    }

    func testReadAnyRejectsUnmodeledTag() {
        // 124 is lib0's float32 tag — not modeled until the CRDT core (PR B1).
        var decoder = Lib0Decoder(Data(hex: "7c00000000"))
        do {
            _ = try decoder.readAny()
            XCTFail("expected unsupportedAnyTag")
        } catch let error as Lib0DecodingError {
            XCTAssertEqual(error, .unsupportedAnyTag(124))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: round-trips against Lib0Encoder

    func testVarUIntRoundTrips() throws {
        for value: UInt in [0, 1, 63, 64, 127, 128, 255, 256, 16383, 16384, 1_000_000, 0xDEAD_BEEF, 4_294_967_295] {
            var encoder = Lib0Encoder()
            encoder.writeVarUInt(value)
            var decoder = Lib0Decoder(encoder.data)
            XCTAssertEqual(try decoder.readVarUInt(), value)
        }
    }

    func testVarIntRoundTrips() throws {
        // Includes the full Int boundaries: Int.min (magnitude 2^63) and Int.max
        // must round-trip without the decoder trapping on the narrowing back to Int.
        let values = [
            0, 1, -1, 63, -63, 64, -64, 127, -128, 8191, -8192, 1_000_000, -1_000_000,
            Int(Int32.max), Int(Int32.min), Int.max, Int.min,
        ]
        for value in values {
            var encoder = Lib0Encoder()
            encoder.writeVarInt(value)
            var decoder = Lib0Decoder(encoder.data)
            XCTAssertEqual(try decoder.readVarInt(), value, "round-tripping \(value)")
        }
    }

    func testVarStringRoundTrips() throws {
        for value in ["", "hi", "café 😀", "document-store", "line\nbreak\ttab", "{\"href\":\"https://x/y\"}"] {
            var encoder = Lib0Encoder()
            encoder.writeVarString(value)
            var decoder = Lib0Decoder(encoder.data)
            XCTAssertEqual(try decoder.readVarString(), value)
        }
    }

    func testVarUint8ArrayRoundTripAndGolden() throws {
        // Golden: the additive encoder primitive matches lib0's writeVarUint8Array.
        var empty = Lib0Encoder()
        empty.writeVarUint8Array(Data())
        XCTAssertEqual(empty.data.hexString, "00")
        var three = Lib0Encoder()
        three.writeVarUint8Array(Data([0, 1, 2]))
        XCTAssertEqual(three.data.hexString, "03000102")

        for body in [Data(), Data([0, 1, 2]), Data([0xff, 0x00, 0x7f, 0x80]), Data(repeating: 0xab, count: 300)] {
            var encoder = Lib0Encoder()
            encoder.writeVarUint8Array(body)
            var decoder = Lib0Decoder(encoder.data)
            XCTAssertEqual(try decoder.readUint8Array(), body)
        }
    }

    // MARK: cursor & truncation

    func testCursorTracksOffsetAcrossMixedReads() throws {
        // varString("hi") + varUint(300) + uint8Array([0,1,2])
        var decoder = Lib0Decoder(Data(hex: "026869" + "ac02" + "03000102"))
        XCTAssertEqual(try decoder.readVarString(), "hi")
        XCTAssertEqual(decoder.offset, 3)
        XCTAssertEqual(try decoder.readVarUInt(), 300)
        XCTAssertEqual(decoder.offset, 5)
        XCTAssertEqual(try decoder.readUint8Array(), Data([0, 1, 2]))
        XCTAssertFalse(decoder.hasMoreData)
        XCTAssertEqual(decoder.remainingCount, 0)
    }

    func testReadRemainingReturnsTail() throws {
        var decoder = Lib0Decoder(Data(hex: "01" + "aabbcc"))
        XCTAssertEqual(try decoder.readUInt8(), 1)
        XCTAssertEqual(decoder.readRemaining().hexString, "aabbcc")
        XCTAssertFalse(decoder.hasMoreData)
        XCTAssertEqual(decoder.readRemaining(), Data(), "readRemaining at end is empty")
    }

    func testReadUInt8OnEmptyThrowsTruncated() {
        var decoder = Lib0Decoder(Data())
        assertTruncated { _ = try decoder.readUInt8() }
    }

    func testUnterminatedVarUIntThrowsTruncated() {
        // 0x80 sets the continuation bit but no further byte follows.
        var decoder = Lib0Decoder(Data([0x80]))
        assertTruncated { _ = try decoder.readVarUInt() }
    }

    func testVarStringLengthBeyondBufferThrowsTruncated() {
        // Claims 5 bytes, supplies 2.
        var decoder = Lib0Decoder(Data(hex: "056869"))
        assertTruncated { _ = try decoder.readVarString() }
    }

    func testOverlongVarUIntThrowsMalformed() {
        // 11 continuation bytes: byte 11 is read at shift 70, tripping the
        // shift > 63 guard. (10 continuation bytes throw `.truncated` instead,
        // because the 11th read finds no byte — asserted below.)
        var overlong = Lib0Decoder(Data(repeating: 0x80, count: 11))
        assertMalformed { _ = try overlong.readVarUInt() }
        var justTruncated = Lib0Decoder(Data(repeating: 0x80, count: 10))
        assertTruncated { _ = try justTruncated.readVarUInt() }
    }

    func testOutOfRangeVarIntThrowsMalformed() {
        // A negative varInt whose accumulated magnitude is 2^63 + 1 — larger than
        // any valid Int — must throw rather than trap on the signed reconstruction.
        var decoder = Lib0Decoder(Data([0xC1, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02]))
        assertMalformed { _ = try decoder.readVarInt() }
    }

    func testUint8ArrayLengthBeyondIntMaxThrowsTruncated() {
        // A length varUint of 2^63 exceeds Int.max, so `Int(exactly:) ?? Int.max`
        // clamps it to Int.max and readBytes reports truncation instead of trapping
        // on the narrowing conversion. (Mutating the guard to `Int(length)` traps.)
        var decoder = Lib0Decoder(Data(hex: "80808080808080808001"))
        assertTruncated { _ = try decoder.readUint8Array() }
    }

    private func assertTruncated(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        do {
            try body()
            XCTFail("expected truncated", file: file, line: line)
        } catch let error as Lib0DecodingError {
            XCTAssertEqual(error, .truncated, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    private func assertMalformed(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        do {
            try body()
            XCTFail("expected malformedVarInt", file: file, line: line)
        } catch let error as Lib0DecodingError {
            XCTAssertEqual(error, .malformedVarInt, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}
