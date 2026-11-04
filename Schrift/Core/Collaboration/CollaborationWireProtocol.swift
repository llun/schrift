import Foundation

/// Framing at the byte-pipe boundary. Sync and awareness payloads are shared;
/// y-websocket selects its room in the URL and has no document-name prefix.
/// `HocuspocusMessage` is the logical envelope inside the existing session: for
/// y-websocket its documentName is supplied locally, never read off the wire.
enum CollaborationWireProtocol: Equatable, Sendable {
    case hocuspocus
    case yWebSocket

    init(config: ServerConfig?) {
        self = config?.usesCollaborationYDocServer == true ? .yWebSocket : .hocuspocus
    }

    func encode(_ message: HocuspocusMessage) -> Data {
        if self == .hocuspocus { return message.encoded() }
        var encoder = Lib0Encoder()
        encoder.writeVarUInt(message.type)
        var data = encoder.data
        data.append(message.payload)
        return data
    }

    func decode(_ data: Data, documentName: String) throws -> HocuspocusMessage {
        if self == .hocuspocus { return try HocuspocusMessage(decoding: data) }
        var decoder = Lib0Decoder(data)
        let type = try decoder.readVarUInt()
        return HocuspocusMessage(documentName: documentName, type: type, payload: decoder.readRemaining())
    }
}
