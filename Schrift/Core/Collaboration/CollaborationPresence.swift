import Foundation

/// A collaborator's selection as y-prosemirror's cursor plugin publishes it
/// (`{"cursor": {"anchor": …, "head": …}}`): two directed relative positions,
/// in `relativePositionToJSON` shape. `anchor` may follow `head`.
struct AwarenessCursor: Equatable, Codable, Sendable {
    var anchor: YRelativePositionJSON
    var head: YRelativePositionJSON

    /// A peer's cursor field, or nil when it is absent, null or malformed.
    /// Malformed never drops the peer: only its cursor is hidden.
    static func parse(stateJSON: String) -> AwarenessCursor? {
        struct Envelope: Decodable { let cursor: AwarenessCursor? }
        return (try? JSONDecoder().decode(Envelope.self, from: Data(stateJSON.utf8)))?.cursor
    }
}

/// The local user's awareness: flat `{name, color}` for Hocuspocus, nested under
/// `user` for y-websocket/BlockNote peers. Built with `JSONSerialization` so a name with
/// quotes/backslashes is escaped, never string-interpolated into JSON.
struct LocalAwarenessState: Equatable, Sendable {
    let name: String
    let color: String
    /// The native editor's selection (PR10), published beside `user` as
    /// y-prosemirror does; nil leaves the field out (no cursor on the web).
    var cursor: AwarenessCursor? = nil

    /// The protocol's user object as JSON, the value that rides inside an
    /// awareness entry's `stateJSON`. Built with `JSONSerialization` (slashes
    /// left unescaped to match `JSON.stringify`); `"{}"` if encoding somehow
    /// fails, so a broadcast never carries a malformed body.
    func json(wireProtocol: CollaborationWireProtocol = .hocuspocus) -> String {
        let user = ["name": name, "color": color]
        var object: [String: Any] = wireProtocol == .yWebSocket ? ["user": user] : user
        if let cursor, let data = try? JSONEncoder().encode(cursor),
            let encoded = try? JSONSerialization.jsonObject(with: data)
        {
            object["cursor"] = encoded
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.withoutEscapingSlashes, .sortedKeys]),
            let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }
}

/// A remote collaborator currently in the room, parsed from an awareness entry's
/// state JSON. `Identifiable` by `clientID` so `AvatarGroup`/`ForEach` are stable.
struct CollaborationPeer: Equatable, Identifiable, Sendable {
    let clientID: UInt
    let name: String
    let color: String

    var id: UInt { clientID }

    /// Parses a peer from an awareness entry's state JSON. Returns nil for a
    /// removed client (`"null"`), an unparseable object, or a missing/empty name
    /// — such an entry drops the peer rather than showing a blank avatar.
    init?(clientID: UInt, stateJSON: String, wireProtocol: CollaborationWireProtocol = .hocuspocus) {
        guard stateJSON != "null",
            let data = stateJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let user = wireProtocol == .yWebSocket ? object["user"] as? [String: Any] : object,
            let name = user["name"] as? String, !name.isEmpty,
            let color = user["color"] as? String
        else { return nil }
        self.clientID = clientID
        self.name = name
        self.color = color
    }
}

/// Folds a batch of awareness entries into the peer list: upsert a parseable
/// peer, drop one whose state is null/invalid, and never include our own
/// `localClientID` (the server echoes our own awareness back). Sorted by
/// `clientID` so the avatar order is stable. Pure, so it is unit-testable.
///
/// Inbound awareness is untrusted, so the fold applies the native controller's
/// bounds: an entry over `NativeAwarenessController.maxStateBytes` is skipped, a
/// new client is refused once `maxPeers` are present, and an entry whose clock is
/// not newer than the one already seen is stale (y-protocols: an equal clock does
/// not renew). `clocks` is the per-client clock the caller keeps between frames.
func updatedPeers(
    _ current: [CollaborationPeer], clocks: [UInt: UInt], applying entries: [AwarenessEntry],
    excludingLocalClientID localClientID: UInt, wireProtocol: CollaborationWireProtocol = .hocuspocus
) -> (peers: [CollaborationPeer], clocks: [UInt: UInt]) {
    var byID = Dictionary(current.map { ($0.clientID, $0) }, uniquingKeysWith: { _, new in new })
    var clocks = clocks
    for entry in entries where entry.clientID != localClientID {
        guard entry.stateJSON.utf8.count <= NativeAwarenessController.maxStateBytes else { continue }
        if let known = clocks[entry.clientID],
            !(entry.clock > known || (entry.clock == known && entry.stateJSON == "null"))
        {
            continue
        }
        // The cap counts shown peers: a new or previously removed one waits for a free slot.
        if byID[entry.clientID] == nil, byID.count >= NativeAwarenessController.maxPeers { continue }
        if let peer = CollaborationPeer(
            clientID: entry.clientID, stateJSON: entry.stateJSON, wireProtocol: wireProtocol)
        {
            byID[entry.clientID] = peer
            clocks[entry.clientID] = entry.clock
        } else {
            byID.removeValue(forKey: entry.clientID)
            // Keep the removal's clock, so a delayed older state can't bring the peer back.
            clocks[entry.clientID] = entry.clock
        }
    }
    // Removed peers' clocks are kept only up to a bound, so churning ids can't grow the table.
    if clocks.count > NativeAwarenessController.maxPeers * 4 {
        clocks = clocks.filter { byID[$0.key] != nil }
    }
    return (byID.values.sorted { $0.clientID < $1.clientID }, clocks)
}
