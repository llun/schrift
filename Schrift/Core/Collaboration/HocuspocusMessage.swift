import Foundation

// MARK: - Hocuspocus frame

/// The message types y-provider / Hocuspocus 3.4.4 puts in the frame's type
/// slot. Verified against `@hocuspocus/provider` 3.4.4's `MessageType` enum and
/// the y-provider server. The provider *sends* only a subset (Sync, Awareness,
/// Auth, QueryAwareness, Stateless, CLOSE, SyncStatus); `syncReply` (4) and
/// `broadcastStateless` (6) are server-originated and appear here so an inbound
/// frame can be recognised. Anything outside this set (e.g. an unconfirmed
/// Ping/Pong 9/10) is tolerated as an unknown type — see `HocuspocusMessage.type`.
enum HocuspocusMessageType: UInt, Equatable, CaseIterable {
    case sync = 0
    case awareness = 1
    case auth = 2
    case queryAwareness = 3
    case syncReply = 4
    case stateless = 5
    case broadcastStateless = 6
    case close = 7
    case syncStatus = 8
}

/// One Hocuspocus wire frame. Every frame is
/// `writeVarString(documentName) + writeVarUint(type) + payload`, verified
/// against `@hocuspocus/provider` 3.4.4's `OutgoingMessage` subclasses. The
/// `documentName` must equal the connection's `room` UUID (lowercase v4).
///
/// `type` is kept as the raw `UInt` off the wire rather than the enum so an
/// unknown inbound type survives decoding intact (the protocol rule is to
/// ignore unknown inbound types, never to fail on them, and never to send one).
/// Interpret a known type through `knownType`.
struct HocuspocusMessage: Equatable {
    var documentName: String
    var type: UInt
    var payload: Data

    init(documentName: String, type: UInt, payload: Data = Data()) {
        self.documentName = documentName
        self.type = type
        self.payload = payload
    }

    init(documentName: String, type: HocuspocusMessageType, payload: Data = Data()) {
        self.init(documentName: documentName, type: type.rawValue, payload: payload)
    }

    /// The typed message kind, or nil when the type is one this client does not
    /// model (which the caller ignores rather than treating as an error).
    var knownType: HocuspocusMessageType? { HocuspocusMessageType(rawValue: type) }

    /// The frame's bytes: `varString(documentName) + varUint(type) + payload`.
    func encoded() -> Data {
        var encoder = Lib0Encoder()
        encoder.writeVarString(documentName)
        encoder.writeVarUInt(type)
        var data = encoder.data
        data.append(payload)
        return data
    }

    /// Decodes one frame; the bytes after the type varUint become `payload`
    /// verbatim (the type-specific codecs — `SyncMessage`, `AwarenessCodec` —
    /// interpret it).
    init(decoding data: Data) throws {
        var decoder = Lib0Decoder(data)
        let documentName = try decoder.readVarString()
        let type = try decoder.readVarUInt()
        self.init(documentName: documentName, type: type, payload: decoder.readRemaining())
    }
}
