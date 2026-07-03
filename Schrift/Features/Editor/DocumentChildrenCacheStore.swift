import Foundation

/// One document's cached children list (sub pages), keyed externally by the
/// parent's UUID. `syncedAt` is the wall-clock of the fetch that produced it
/// and drives eviction recency.
struct CachedChildrenEntry: Codable, Equatable {
    var documents: [Document]
    var syncedAt: Date
}

/// UserDefaults-backed cache of children lists keyed by parent document.
/// These are list metadata (titles, dates, abilities) — small enough for
/// UserDefaults, unlike the full bodies `DocumentContentCacheStore` keeps on
/// disk. Capped to the `limit` parents with the newest `syncedAt`, selected
/// by the same pure `contentCacheEvictions` function the content cache uses.
/// Like the other stores it never throws; `children(for:)` returns nil when a
/// parent was never cached — distinct from a cached empty list, which is a
/// real fetch result.
final class DocumentChildrenCacheStore {
    private static let key = "dev.llun.Schrift.cachedDocumentChildren"

    private let userDefaults: UserDefaults
    private let limit: Int
    private let now: () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(userDefaults: UserDefaults = .standard, limit: Int = 100, now: @escaping () -> Date = Date.init) {
        self.userDefaults = userDefaults
        self.limit = limit
        self.now = now
        // Millisecond precision, matching PendingDraftStore: plain .iso8601
        // truncates to whole seconds, which would make same-second saves tie
        // on `syncedAt` and turn eviction recency arbitrary.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    func children(for parentID: UUID) -> [Document]? {
        loadEntries()[parentID]?.documents
    }

    func save(_ documents: [Document], for parentID: UUID) {
        var entries = loadEntries()
        entries[parentID] = CachedChildrenEntry(documents: documents, syncedAt: now())
        let index = entries.map { ContentCacheIndexEntry(id: $0.key, syncedAt: $0.value.syncedAt) }
        for evicted in contentCacheEvictions(index: index, limit: limit) {
            entries.removeValue(forKey: evicted)
        }
        saveEntries(entries)
    }

    func remove(parentID: UUID) {
        var entries = loadEntries()
        guard entries.removeValue(forKey: parentID) != nil else { return }
        saveEntries(entries)
    }

    /// Strips a deleted/revoked document out of every parent's cached list.
    /// `remove(parentID:)` alone would leave the document as a ghost child of
    /// its parent (and of any other cached list containing it) until the next
    /// successful revalidation — which offline never comes.
    func removeDocument(_ documentID: UUID) {
        var entries = loadEntries()
        var changed = false
        for (parentID, entry) in entries where entry.documents.contains(where: { $0.id == documentID }) {
            var updated = entry
            updated.documents.removeAll { $0.id == documentID }
            entries[parentID] = updated
            changed = true
        }
        guard changed else { return }
        saveEntries(entries)
    }

    func removeAll() {
        userDefaults.removeObject(forKey: Self.key)
    }

    private func loadEntries() -> [UUID: CachedChildrenEntry] {
        guard let data = userDefaults.data(forKey: Self.key),
            let entries = try? decoder.decode([UUID: CachedChildrenEntry].self, from: data)
        else {
            return [:]
        }
        return entries
    }

    private func saveEntries(_ entries: [UUID: CachedChildrenEntry]) {
        guard let data = try? encoder.encode(entries) else { return }
        userDefaults.set(data, forKey: Self.key)
    }
}
