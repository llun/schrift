import Foundation

/// What the durable owner marker says about one document on one server.
///
/// `.unreadable` is deliberately not `.none`: when the marker blob cannot be
/// decoded the app cannot prove a document is *not* native-owned, so every
/// document must stay read-only rather than fall back to the classic writer.
enum ReplicaOwnership: Equatable, Sendable {
    case none
    case owned(ReplicaScope)
    case unreadable

    var scope: ReplicaScope? {
        guard case .owned(let scope) = self else { return nil }
        return scope
    }
}

/// The durable "the native replica owns this document" marker.
///
/// A draft reference protects unsaved work, but a successful save removes that
/// draft. Without a marker that outlives the draft, disabling the switch (or a
/// relaunch after a clean save) would resume the classic Markdown writer over a
/// clean native replica. The marker is keyed by server origin and document id,
/// and carries the full scope so an offline open can restore the replica without
/// a config fetch.
///
/// The blob is versioned and checksummed. A corrupt blob is never overwritten:
/// `mark` and `clear` refuse while it is unreadable, so ownership stays unknown
/// (read-only) instead of silently becoming "not owned" (classic-editable).
@MainActor
final class ReplicaOwnershipStore {
    private static let key = "dev.llun.Schrift.replicaOwnership"
    private static let currentVersion = 1

    private struct Envelope: Codable {
        let version: Int
        let entries: [String: ReplicaScope]
        let digest: String
    }

    private enum ReadResult {
        case missing
        case entries([String: ReplicaScope])
        case unreadable
    }

    private let userDefaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        self.encoder = encoder
    }

    func owner(documentID: UUID, serverOrigin: String) -> ReplicaOwnership {
        switch read() {
        case .missing:
            return .none
        case .unreadable:
            return .unreadable
        case .entries(let entries):
            return entries[Self.key(documentID: documentID, serverOrigin: serverOrigin)].map(ReplicaOwnership.owned)
                ?? .none
        }
    }

    /// Returns false when the marker could not be written. A replica must not be
    /// created without a marker, or the classic writer could later open it.
    /// One document has one owner: a marker for another account or org is never
    /// replaced, or that scope's replica would become unreachable.
    @discardableResult
    func mark(_ scope: ReplicaScope) -> Bool {
        guard scope.isValid else { return false }
        var entries: [String: ReplicaScope]
        switch read() {
        case .missing:
            entries = [:]
        case .entries(let existing):
            entries = existing
        case .unreadable:
            return false
        }
        let key = Self.key(documentID: scope.documentID, serverOrigin: scope.serverOrigin)
        guard entries[key] == nil || entries[key] == scope else { return false }
        entries[key] = scope
        return write(entries)
    }

    /// Returns false when the marker could not be cleared. The document then
    /// stays read-only, which is the safe direction. Clears only this scope's
    /// marker; another account's marker for the same document stays.
    @discardableResult
    func clear(_ scope: ReplicaScope) -> Bool {
        var entries: [String: ReplicaScope]
        switch read() {
        case .missing:
            return true
        case .entries(let existing):
            entries = existing
        case .unreadable:
            return false
        }
        let key = Self.key(documentID: scope.documentID, serverOrigin: scope.serverOrigin)
        guard entries[key] == scope else { return true }
        entries[key] = nil
        return write(entries)
    }

    /// Whether any marker data exists, readable or not. A replica directory
    /// without it means the marker was lost: ownership is unknown, not absent.
    var hasData: Bool { userDefaults.data(forKey: Self.key) != nil }

    /// There is marker data and it does not decode — ownership is unknown, not
    /// absent. Sticky until the blob is repaired or removed by a future
    /// migration; routine writes never overwrite it.
    var holdsUnreadableData: Bool {
        if case .unreadable = read() { return true }
        return false
    }

    private static func key(documentID: UUID, serverOrigin: String) -> String {
        "\(serverOrigin)|\(documentID.uuidString.lowercased())"
    }

    private func read() -> ReadResult {
        guard let data = userDefaults.data(forKey: Self.key) else { return .missing }
        guard let envelope = try? decoder.decode(Envelope.self, from: data),
            envelope.version == Self.currentVersion,
            let entriesData = try? encoder.encode(envelope.entries),
            replicaDigest(entriesData) == envelope.digest
        else { return .unreadable }
        return .entries(envelope.entries)
    }

    private func write(_ entries: [String: ReplicaScope]) -> Bool {
        guard let entriesData = try? encoder.encode(entries),
            let envelopeData = try? encoder.encode(
                Envelope(version: Self.currentVersion, entries: entries, digest: replicaDigest(entriesData)))
        else { return false }
        userDefaults.set(envelopeData, forKey: Self.key)
        return true
    }
}
