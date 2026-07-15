import Foundation

/// The local user's awareness state broadcast to peers: `{name, color}`, exactly
/// what the Docs web client puts in its awareness state (BlockNote reads the
/// caret/name/color from it). Built with `JSONSerialization` so a name with
/// quotes/backslashes is escaped, never string-interpolated into JSON.
struct LocalAwarenessState: Equatable, Sendable {
    let name: String
    let color: String

    /// The `{name, color}` object as a JSON string, the value that rides inside an
    /// awareness entry's `stateJSON`. Built with `JSONSerialization` (slashes
    /// left unescaped to match `JSON.stringify`); `"{}"` if encoding somehow
    /// fails, so a broadcast never carries a malformed body.
    func json() -> String {
        let object = ["name": name, "color": color]
        guard
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
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
    init?(clientID: UInt, stateJSON: String) {
        guard stateJSON != "null",
            let data = stateJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let name = object["name"] as? String, !name.isEmpty,
            let color = object["color"] as? String
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
func updatedPeers(
    _ current: [CollaborationPeer], applying entries: [AwarenessEntry], excludingLocalClientID localClientID: UInt
) -> [CollaborationPeer] {
    var byID = Dictionary(current.map { ($0.clientID, $0) }, uniquingKeysWith: { _, new in new })
    for entry in entries where entry.clientID != localClientID {
        if let peer = CollaborationPeer(clientID: entry.clientID, stateJSON: entry.stateJSON) {
            byID[entry.clientID] = peer
        } else {
            byID.removeValue(forKey: entry.clientID)
        }
    }
    return byID.values.sorted { $0.clientID < $1.clientID }
}
