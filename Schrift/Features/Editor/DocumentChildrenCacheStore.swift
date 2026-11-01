import Foundation

/// One document's cached children list (sub pages), keyed externally by the
/// parent's UUID. `syncedAt` is the wall-clock of the fetch that produced it
/// and drives eviction recency.
struct CachedChildrenEntry: Codable, Equatable, Sendable {
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
    /// Shared by every instance (the save coordinator, the editor and the Pages drawer each
    /// build one over `.standard`): it memoizes the decode of whatever bytes were last read, so
    /// a write by any of them is seen by all — see `DecodedBlobMemo`.
    private static let memo = DecodedBlobMemo<[UUID: CachedChildrenEntry]>()

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

    func document(for documentID: UUID) -> Document? {
        loadEntries().values.flatMap(\.documents).first { $0.id == documentID }
    }

    /// Every document in every cached children list, the most recently synced list
    /// first. A document listed under two parents appears twice; callers de-duplicate.
    /// One of the offline sources of the editor's `[[` page picker.
    func allDocuments() -> [Document] {
        loadEntries().values.sorted { $0.syncedAt > $1.syncedAt }.flatMap(\.documents)
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
        guard let data = userDefaults.data(forKey: Self.key), let entries = decoded(data) else {
            return [:]
        }
        return entries
    }

    /// The blob's decode, memoized on its bytes: a read with no write since the last one costs a
    /// byte comparison, not a decode of every cached list. nil means undecodable, exactly as the
    /// direct `try? decode` it replaces.
    private func decoded(_ data: Data) -> [UUID: CachedChildrenEntry]? {
        Self.memo.value(for: data) { try? decoder.decode([UUID: CachedChildrenEntry].self, from: $0) }
    }

    private func saveEntries(_ entries: [UUID: CachedChildrenEntry]) {
        guard let data = try? encoder.encode(entries) else { return }
        userDefaults.set(data, forKey: Self.key)
    }
}
