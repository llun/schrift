import Foundation

// MARK: - lib0 variable-length decoding primitives (yjs UpdateEncoderV1 wire format)

/// Errors raised while reading a lib0-encoded byte stream.
enum Lib0DecodingError: Error, Equatable {
    /// Reached the end of the buffer before the requested value was complete.
    case truncated
    /// A variable-length integer ran longer than 64 bits — a malformed stream.
    case malformedVarInt
    /// A `readVarString` payload was not valid UTF-8.
    case invalidUTF8
    /// `readAny` met a lib0 type tag this decoder does not yet model. The full
    /// tag set is completed additively by the CRDT core (roadmap PR B1); the
    /// wire codecs in this PR never exercise `readAny`.
    case unsupportedAnyTag(UInt8)
}

/// Cursor over a byte buffer implementing the subset of lib0's binary *decoding*
/// that Schrift needs. It is the read-side mirror of `Lib0Encoder`
/// (`YjsUpdateEncoder.swift`) — every `read*` here undoes exactly one `write*`
/// there. Kept in `Core/Yjs` as the single lib0 read implementation, shared by
/// the collaboration wire codecs and (later) the Yjs CRDT core.
///
/// See github.com/dmonad/lib0 `decoding.js`. Decoding is pure value code: it
/// carries no concurrency annotations and is callable from any isolation domain.
struct Lib0Decoder {
    private let bytes: [UInt8]
    /// Read cursor, in bytes from the start of the buffer.
    private(set) var offset = 0

    init(_ data: Data) {
        self.bytes = [UInt8](data)
    }

    /// Whether any unread bytes remain.
    var hasMoreData: Bool { offset < bytes.count }

    /// Count of unread bytes.
    var remainingCount: Int { bytes.count - offset }

    /// Reads a single byte.
    mutating func readUInt8() throws -> UInt8 {
        guard offset < bytes.count else { throw Lib0DecodingError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    /// Reads `count` raw bytes.
    mutating func readBytes(_ count: Int) throws -> Data {
        // `count <= remaining` (both non-negative) also prevents `offset + count`
        // from overflowing, so a bogus huge length reads as truncation, not a trap.
        guard count >= 0, count <= bytes.count - offset else { throw Lib0DecodingError.truncated }
        let slice = bytes[offset..<offset + count]
        offset += count
        return Data(slice)
    }

    /// Reads and returns every remaining byte, advancing the cursor to the end.
    mutating func readRemaining() -> Data {
        let slice = bytes[offset...]
        offset = bytes.count
        return Data(slice)
    }

    /// Unsigned LEB128 — the inverse of `Lib0Encoder.writeVarUInt`.
    mutating func readVarUInt() throws -> UInt {
        var result: UInt = 0
        var shift: UInt = 0
        while true {
            let byte = try readUInt8()
            // A well-formed varUInt for any 64-bit value is at most 10 bytes;
            // beyond that the shift would drop bits, so reject it.
            guard shift <= 63 else { throw Lib0DecodingError.malformedVarInt }
            result |= UInt(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    /// lib0 signed varint — the inverse of `Lib0Encoder.writeVarInt`: the first
    /// byte carries the sign in bit `0x40` and the continuation flag in `0x80`,
    /// leaving 6 low value bits; further bytes are 7-bit groups.
    mutating func readVarInt() throws -> Int {
        let first = try readUInt8()
        let negative = (first & 0x40) != 0
        var result = UInt(first & 0x3F)
        var shift: UInt = 6
        var byte = first
        while byte & 0x80 != 0 {
            byte = try readUInt8()
            guard shift <= 63 else { throw Lib0DecodingError.malformedVarInt }
            result |= UInt(byte & 0x7F) << shift
            shift += 7
        }
        // Reconstruct the signed value without a trapping narrowing conversion:
        // `Int(bitPattern:)` reinterprets and never traps, while the guards reject
        // a magnitude too large to be a valid `Int` of that sign (a malformed
        // stream) — yet still admit `Int.min` (magnitude 2^63, negative), so the
        // full `Int` range that `Lib0Encoder.writeVarInt` can emit round-trips.
        if negative {
            guard result <= UInt(Int.max) &+ 1 else { throw Lib0DecodingError.malformedVarInt }
            return Int(bitPattern: ~result &+ 1)  // two's-complement negation
        } else {
            guard result <= UInt(Int.max) else { throw Lib0DecodingError.malformedVarInt }
            return Int(bitPattern: result)
        }
    }

    /// `varUInt(utf8 byte length)` followed by that many UTF-8 bytes. Reuses
    /// `readUint8Array` so the length + clamped-read logic lives in one place.
    ///
    /// lib0 decodes with `ignoreBOM: true`, so a leading U+FEFF is a real scalar,
    /// not a byte-order mark to swallow — a `writeVarString`/`readVarString` pair
    /// must therefore round-trip it. `String(data:encoding:.utf8)` rejects
    /// ill-formed UTF-8 (nil) but *strips* a leading BOM, while
    /// `String(decoding:as:)` keeps the BOM but silently substitutes U+FFFD for
    /// bad bytes. So validate with the former and decode with the latter: invalid
    /// UTF-8 still throws, and the BOM survives.
    mutating func readVarString() throws -> String {
        let data = try readUint8Array()
        guard String(data: data, encoding: .utf8) != nil else {
            throw Lib0DecodingError.invalidUTF8
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// `varUInt(length)` followed by that many raw bytes — the inverse of
    /// `Lib0Encoder.writeVarUint8Array`.
    mutating func readUint8Array() throws -> Data {
        let length = try readVarUInt()
        return try readBytes(Int(exactly: length) ?? Int.max)
    }

    /// A lib0 `readAny` value, limited to the tags `Lib0Encoder.writeAny`
    /// currently emits. Any other tag throws `unsupportedAnyTag`; the CRDT core
    /// (PR B1) extends both sides together.
    mutating func readAny() throws -> YAnyValue {
        let tag = try readUInt8()
        switch tag {
        case 119: return .string(try readVarString())
        case 125: return .int(try readVarInt())
        case 120: return .bool(true)
        case 121: return .bool(false)
        case 126: return .null
        case 127: return .undefined
        default: throw Lib0DecodingError.unsupportedAnyTag(tag)
        }
    }
}
