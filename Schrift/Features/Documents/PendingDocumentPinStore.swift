import Foundation

/// The latest desired pin state for one server document and one account. Backup-included
/// and retained across sign-out, like pending deletes. Optimistic rows live here rather
/// than in the unscoped metadata caches, so another account cannot inherit the intent.
struct PendingDocumentPin: Codable, Equatable, Sendable {
    let documentID: UUID
    let serverOrigin: String
    let ownerUserID: UUID
    var isPinned: Bool
    var previousValue: Bool
    var row: Document?
    let intentID: UUID
    let requestedAt: Date
    var wasRejected: Bool? = nil
    /// A landed filing disables synthetic Recent insertion, even across relaunch.
    var allowsRecentFallback: Bool? = nil

    var key: String { Self.key(documentID: documentID, serverOrigin: serverOrigin, ownerUserID: ownerUserID) }

    static func key(documentID: UUID, serverOrigin: String, ownerUserID: UUID) -> String {
        "\(serverOrigin)|\(ownerUserID.uuidString)|\(documentID.uuidString)"
    }
}

final class PendingDocumentPinStore {
    private static let key = "dev.llun.Schrift.pendingPins"
    private static let quarantineKey = "dev.llun.Schrift.pendingPins.unreadable"
    private let userDefaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    func allPins() -> [PendingDocumentPin] {
        loadAll().values.sorted {
            $0.requestedAt == $1.requestedAt ? $0.key < $1.key : $0.requestedAt < $1.requestedAt
        }
    }

    @discardableResult
    func save(_ intent: PendingDocumentPin) -> Bool {
        var all = loadAll()
        all[intent.key] = intent
        guard let encoded = try? encoder.encode(all) else { return false }
        // Preserve unknown work before rebuilding a corrupt live key.
        if let data = userDefaults.data(forKey: Self.key),
            (try? decoder.decode([String: PendingDocumentPin].self, from: data)) == nil,
            userDefaults.data(forKey: Self.quarantineKey) == nil
        {
            userDefaults.set(data, forKey: Self.quarantineKey)
        }
        userDefaults.set(encoded, forKey: Self.key)
        return true
    }

    private static let settledKey = "dev.llun.Schrift.settledPins"

    func allSettled() -> [PendingDocumentPin] {
        guard let data = userDefaults.data(forKey: Self.settledKey),
            let all = try? decoder.decode([String: PendingDocumentPin].self, from: data)
        else { return [] }
        return Array(all.values)
    }

    /// Retain the settled projection until a later Home fetch has written a newer raw
    /// snapshot. This closes the success → stale cache overwrite → relaunch window.
    @discardableResult
    func saveSettled(_ intent: PendingDocumentPin) -> Bool {
        var all = Dictionary(allSettled().map { ($0.key, $0) }, uniquingKeysWith: { _, b in b })
        all[intent.key] = intent
        guard let encoded = try? encoder.encode(all) else { return false }
        userDefaults.set(encoded, forKey: Self.settledKey)
        return true
    }

    func removeSettled(_ intent: PendingDocumentPin) {
        var all = Dictionary(allSettled().map { ($0.key, $0) }, uniquingKeysWith: { _, b in b })
        guard all[intent.key]?.intentID == intent.intentID else { return }
        all[intent.key] = nil
        guard let encoded = try? encoder.encode(all) else { return }
        userDefaults.set(encoded, forKey: Self.settledKey)
    }

    /// A delayed completion must never remove the intent that superseded it.
    func remove(_ intent: PendingDocumentPin) {
        var all = loadAll()
        guard all[intent.key]?.intentID == intent.intentID else { return }
        all[intent.key] = nil
        guard let encoded = try? encoder.encode(all) else { return }
        userDefaults.set(encoded, forKey: Self.key)
    }

    private func loadAll() -> [String: PendingDocumentPin] {
        guard let data = userDefaults.data(forKey: Self.key),
            let all = try? decoder.decode([String: PendingDocumentPin].self, from: data)
        else { return [:] }
        return all
    }
}
