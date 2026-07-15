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

    // MARK: - readVarUInt

    func testReadVarUIntGoldenValues() throws {
        let cases: [(UInt, String)] = [
            (0, "00"), (1, "01"), (127, "7f"), (128, "8001"), (255, "ff01"), (300, "ac02"),
            (16383, "ff7f"), (16384, "808001"), (0xDEAD_BEEF, "effdb6f50d"), (4_294_967_295, "ffffffff0f"),
            // 6–8 byte encodings exercise the high-shift accumulation path with a
            // value check (a `shift % 35`-style mutation corrupts these).
            (34_359_738_368, "808080808001"),  // 2^35
            (562_949_953_421_312, "8080808080808001"),  // 2^49
            (4_503_599_627_370_495, "ffffffffffffff07"),  // 2^52 - 1
        ]
        for (value, hex) in cases {
            var decoder = Lib0Decoder(Data(hex: hex))
            XCTAssertEqual(try decoder.readVarUInt(), value, "decoding \(hex)")
            XCTAssertFalse(decoder.hasMoreData, "consumed all of \(hex)")
        }
    }

    // MARK: - readVarInt

    func testReadVarIntGoldenValues() throws {
        let cases: [(Int, String)] = [
            (0, "00"), (1, "01"), (63, "3f"), (64, "8001"), (127, "bf01"), (8191, "bf7f"),
            (1_000_000, "80897a"), (2_147_483_647, "bfffffff0f"),
            (-1, "41"), (-64, "c001"), (-65, "c101"), (-127, "ff01"), (-8191, "ff7f"),
            (-1_000_000, "c0897a"), (-2_147_483_647, "ffffffff0f"),
            // 5–8 byte encodings, both signs, exercise the high-shift accumulation
            // against an independent oracle (round-trips alone are circular).
            (2_147_483_648, "8080808010"), (-2_147_483_648, "c080808010"),  // ±2^31 (5 bytes)
            (1_099_511_627_776, "808080808040"), (-1_099_511_627_776, "c08080808040"),  // ±2^40 (6 bytes)
            (562_949_953_421_311, "bfffffffffffff01"),
            (-562_949_953_421_311, "ffffffffffffff01"),  // ±(2^49-1) (8 bytes)
        ]
        for (value, hex) in cases {
            var decoder = Lib0Decoder(Data(hex: hex))
            XCTAssertEqual(try decoder.readVarInt(), value, "decoding \(hex)")
            XCTAssertFalse(decoder.hasMoreData, "consumed all of \(hex)")
        }
    }

    // MARK: - readVarString

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
        assertThrows(Lib0DecodingError.invalidUTF8) { _ = try decoder.readVarString() }
    }

    func testReadVarStringPreservesLeadingBOM() throws {
        // lib0 decodes with ignoreBOM: true, so a leading U+FEFF is a real scalar
        // that must survive: `05 ef bb bf 68 69` is a varString of "\u{FEFF}hi".
        var decoder = Lib0Decoder(Data(hex: "05efbbbf6869"))
        XCTAssertEqual(try decoder.readVarString(), "\u{FEFF}hi")
    }

    // MARK: - readVarUint8Array

    func testReadVarUint8ArrayGoldenValues() throws {
        let cases: [(String, String)] = [("", "00"), ("000102", "03000102"), ("ff007f80", "04ff007f80")]
        for (bodyHex, hex) in cases {
            var decoder = Lib0Decoder(Data(hex: hex))
            XCTAssertEqual(try decoder.readVarUint8Array(), Data(hex: bodyHex), "decoding \(hex)")
        }
    }

    // MARK: - readAny

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

    func testReadAnyDecodesFloat32AsRawBytes() throws {
        // 124 is lib0's float32 tag — now modeled (B1) as its raw 4 big-endian
        // bytes, so a decode→writeAny round-trip is byte-identical.
        var decoder = Lib0Decoder(Data(hex: "7c3fc00000"))  // 1.5
        XCTAssertEqual(try decoder.readAny(), .float32(Data(hex: "3fc00000")))
    }

    func testReadAnyRejectsATagBelowTheLib0Range() {
        // lib0 `writeAny` only ever emits tags 116–127; anything lower is
        // malformed input and must throw rather than trap.
        var decoder = Lib0Decoder(Data(hex: "7300000000"))  // 0x73 = 115
        assertThrows(Lib0DecodingError.unsupportedAnyTag(115)) { _ = try decoder.readAny() }
    }

    // MARK: - round-trips against Lib0Encoder

    func testVarUIntRoundTrips() throws {
        // Includes the full 64-bit range — UInt(Int.max) (9 bytes) and UInt.max
        // (10 bytes) value-verify shifts 56/63, beyond what lib0's JS encoder can
        // emit (it caps at 2^53). The Swift encoder covers them, so the round-trip
        // is the value check for the top of the shift path.
        let values: [UInt] = [
            0, 1, 63, 64, 127, 128, 255, 256, 16383, 16384, 1_000_000, 0xDEAD_BEEF, 4_294_967_295,
            UInt(Int.max), UInt.max,
        ]
        for value in values {
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
        let values = [
            "", "hi", "café 😀", "document-store", "line\nbreak\ttab", "{\"href\":\"https://x/y\"}",
            "\u{FEFF}hi",  // a leading BOM must round-trip (lib0 ignoreBOM: true)
        ]
        for value in values {
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
            XCTAssertEqual(try decoder.readVarUint8Array(), body)
        }
    }

    // MARK: - cursor & truncation

    func testCursorTracksOffsetAcrossMixedReads() throws {
        // varString("hi") + varUint(300) + uint8Array([0,1,2])
        var decoder = Lib0Decoder(Data(hex: "026869" + "ac02" + "03000102"))
        XCTAssertEqual(try decoder.readVarString(), "hi")
        XCTAssertEqual(decoder.offset, 3)
        XCTAssertEqual(try decoder.readVarUInt(), 300)
        XCTAssertEqual(decoder.offset, 5)
        XCTAssertEqual(try decoder.readVarUint8Array(), Data([0, 1, 2]))
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
        assertThrows(Lib0DecodingError.truncated) { _ = try decoder.readUInt8() }
    }

    func testUnterminatedVarUIntThrowsTruncated() {
        // 0x80 sets the continuation bit but no further byte follows.
        var decoder = Lib0Decoder(Data([0x80]))
        assertThrows(Lib0DecodingError.truncated) { _ = try decoder.readVarUInt() }
    }

    func testVarStringLengthBeyondBufferThrowsTruncated() {
        // Claims 5 bytes, supplies 2.
        var decoder = Lib0Decoder(Data(hex: "056869"))
        assertThrows(Lib0DecodingError.truncated) { _ = try decoder.readVarString() }
    }

    func testOverlongVarUIntThrowsMalformed() {
        // 11 continuation bytes: byte 11 is read at shift 70, tripping the
        // shift > 63 guard. (10 continuation bytes throw `.truncated` instead,
        // because the 11th read finds no byte — asserted below.)
        var overlong = Lib0Decoder(Data(repeating: 0x80, count: 11))
        assertThrows(Lib0DecodingError.malformedVarInt) { _ = try overlong.readVarUInt() }
        var justTruncated = Lib0Decoder(Data(repeating: 0x80, count: 10))
        assertThrows(Lib0DecodingError.truncated) { _ = try justTruncated.readVarUInt() }
    }

    func testOutOfRangeVarIntThrowsMalformed() {
        // A negative varInt whose accumulated magnitude is 2^63 + 1 — larger than
        // any valid Int — must throw rather than trap on the signed reconstruction.
        var negative = Lib0Decoder(Data([0xC1, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02]))
        assertThrows(Lib0DecodingError.malformedVarInt) { _ = try negative.readVarInt() }

        // The positive mirror: magnitude 2^63 with the sign bit clear. Without the
        // positive guard this would decode via Int(bitPattern:) to Int.min — a
        // positive wire value silently returned as a large negative Int.
        var positive = Lib0Decoder(Data([0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02]))
        assertThrows(Lib0DecodingError.malformedVarInt) { _ = try positive.readVarInt() }
    }

    func testOutOfRangeVarUIntThrowsMalformed() {
        // A 10-byte varUInt whose 10th group (shift 63) carries more than bit 0
        // exceeds UInt.max; it must throw, not silently drop the overflow. (The
        // same bytes readVarInt rejects in testOutOfRangeVarIntThrowsMalformed.)
        var decoder = Lib0Decoder(Data([0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02]))
        assertThrows(Lib0DecodingError.malformedVarInt) { _ = try decoder.readVarUInt() }
    }

    func testOverRangeVarIntWithDroppedHighBitsThrows() {
        // The mirror of testOutOfRangeVarUIntThrowsMalformed: a top group (shift 62)
        // carrying more than 2 bits would silently drop its high bits (mapping past
        // bit 63) and decode to a bounded-but-wrong value. These must throw, not
        // decode: [0x80]×9+[0x7D] would otherwise return 2^62, and the negative
        // forms below would return Int.min / 0.
        for bytes in [
            Data([0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x7D]),
            Data([0xC0, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x06]),
            Data([0xC0, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x04]),
        ] {
            var decoder = Lib0Decoder(bytes)
            assertThrows(Lib0DecodingError.malformedVarInt) { _ = try decoder.readVarInt() }
        }
    }

    func testOverlongVarIntTripsShiftGuard() {
        // Mirrors testOverlongVarUIntThrowsMalformed for readVarInt: nine 0x80
        // continuation bytes push shift past 63, so the tenth continuation read
        // trips the shift guard (distinct from the magnitude guard above — every
        // group carries value 0, so without the shift guard this would decode to -1).
        var decoder = Lib0Decoder(Data([0xC1] + Array(repeating: 0x80, count: 9) + [0x00]))
        assertThrows(Lib0DecodingError.malformedVarInt) { _ = try decoder.readVarInt() }
    }

    func testUnterminatedVarIntThrowsTruncated() {
        // First byte sets the continuation bit but no further byte follows.
        var decoder = Lib0Decoder(Data([0xC1]))
        assertThrows(Lib0DecodingError.truncated) { _ = try decoder.readVarInt() }
    }

    func testVarUint8ArrayLengthBeyondIntMaxThrowsTruncated() {
        // A length varUint of 2^63 exceeds Int.max, so `Int(exactly:) ?? Int.max`
        // clamps it to Int.max and readBytes reports truncation instead of trapping
        // on the narrowing conversion. (Mutating the guard to `Int(length)` traps.)
        var decoder = Lib0Decoder(Data(hex: "80808080808080808001"))
        assertThrows(Lib0DecodingError.truncated) { _ = try decoder.readVarUint8Array() }
    }
}
