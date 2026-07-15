import Foundation

// MARK: - Awareness protocol payload (inside an `.awareness` frame)

/// One client's entry in an awareness update. Mirrors y-protocols 1.0.7's
/// `encodeAwarenessUpdate` per-client record: `varUint(clientID)`,
/// `varUint(clock)`, `varString(stateJSON)`. `stateJSON` is the JSON of the
/// client's awareness state (Schrift broadcasts `{"name":…,"color":…}`), or the
/// literal `"null"` when the client has been removed.
struct AwarenessEntry: Equatable {
    var clientID: UInt
    var clock: UInt
    var stateJSON: String

    init(clientID: UInt, clock: UInt, stateJSON: String) {
        self.clientID = clientID
        self.clock = clock
        self.stateJSON = stateJSON
    }
}

/// Encodes and decodes awareness updates, matching y-protocols 1.0.7 exactly.
///
/// Two layers, kept explicit because the wire has both: the *inner update*
/// (`encode`/`decode`, byte-identical to `encodeAwarenessUpdate`) is what an
/// `.awareness` Hocuspocus frame carries, but the frame wraps it once more in a
/// lib0 `varUint8Array` (verified against the provider's `AwarenessMessage`).
/// `encodePayload`/`decodePayload` produce and read that framed form — the value
/// a `HocuspocusMessage(type: .awareness)` carries as its `payload`.
enum AwarenessCodec {
    /// The inner awareness update: `varUint(count)` then, per client,
    /// `varUint(clientID) + varUint(clock) + varString(stateJSON)`.
    static func encode(_ entries: [AwarenessEntry]) -> Data {
        var encoder = Lib0Encoder()
        encoder.writeVarUInt(UInt(entries.count))
        for entry in entries {
            encoder.writeVarUInt(entry.clientID)
            encoder.writeVarUInt(entry.clock)
            encoder.writeVarString(entry.stateJSON)
        }
        return encoder.data
    }

    static func decode(_ data: Data) throws -> [AwarenessEntry] {
        var decoder = Lib0Decoder(data)
        let count = try decoder.readVarUInt()
        var entries: [AwarenessEntry] = []
        // Bound the reservation by the bytes actually present: a hostile `count`
        // (a ~5-byte varUint can claim billions of entries) must not force a huge
        // speculative allocation before the per-entry read hits `.truncated`.
        entries.reserveCapacity(min(Int(exactly: count) ?? 0, decoder.remainingCount))
        for _ in 0..<count {
            let clientID = try decoder.readVarUInt()
            let clock = try decoder.readVarUInt()
            let stateJSON = try decoder.readVarString()
            entries.append(AwarenessEntry(clientID: clientID, clock: clock, stateJSON: stateJSON))
        }
        return entries
    }

    /// The `.awareness` frame payload: `varUint8Array(encode(entries))`.
    static func encodePayload(_ entries: [AwarenessEntry]) -> Data {
        var encoder = Lib0Encoder()
        encoder.writeVarUint8Array(encode(entries))
        return encoder.data
    }

    /// Reads a `.awareness` frame payload back into entries.
    static func decodePayload(_ payload: Data) throws -> [AwarenessEntry] {
        var decoder = Lib0Decoder(payload)
        return try decode(decoder.readUint8Array())
    }
}
