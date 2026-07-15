import Foundation

// MARK: - Yjs sync-protocol payload (inside a `.sync` frame)

/// The y-protocols 1.0.7 sync sub-message types. A `.sync` Hocuspocus frame's
/// payload is `writeVarUint(step) + writeVarUint8Array(data)`.
enum SyncStep: UInt, Equatable {
    /// A state vector; the peer replies with the updates we are missing.
    case step1 = 0
    /// An update computed against a received state vector (the reply to step1).
    case step2 = 1
    /// An unsolicited incremental update.
    case update = 2
}

/// The payload of a `.sync` Hocuspocus frame. `data` is the *unwrapped* Yjs
/// bytes — a state vector for `.step1`, an update for `.step2`/`.update` — with
/// the lib0 length prefix stripped on decode and re-applied on encode.
///
/// Milestone A uses only the empty-state-vector trick: send `.step1` with a
/// one-byte empty state vector (`Data([0x00])`) and treat any inbound
/// `.step2`/`.update` as a change signal without applying it. The CRDT core
/// (Milestone B/C) later applies `data` for real.
struct SyncMessage: Equatable {
    var step: SyncStep
    var data: Data

    init(step: SyncStep, data: Data) {
        self.step = step
        self.data = data
    }

    /// The `.sync` frame payload: `varUint(step) + varUint8Array(data)`.
    func encodedPayload() -> Data {
        var encoder = Lib0Encoder()
        encoder.writeVarUInt(step.rawValue)
        encoder.writeVarUint8Array(data)
        return encoder.data
    }

    /// Decodes a `.sync` frame payload. Throws `SyncMessageError.unknownStep`
    /// for a sync sub-type this client does not model.
    init(decodingPayload payload: Data) throws {
        var decoder = Lib0Decoder(payload)
        let rawStep = try decoder.readVarUInt()
        guard let step = SyncStep(rawValue: rawStep) else {
            throw SyncMessageError.unknownStep(rawStep)
        }
        self.init(step: step, data: try decoder.readUint8Array())
    }
}

/// Raised while decoding a sync payload whose sub-type is unrecognised.
enum SyncMessageError: Error, Equatable {
    case unknownStep(UInt)
}
