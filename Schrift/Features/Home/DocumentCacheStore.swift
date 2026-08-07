import Foundation

/// Cached document-list metadata (titles, dates, abilities — never content).
/// The Optional loads return nil when a list was never cached, which is
/// distinct from a cached empty list (a real fetch result): the nil case is
/// what allows the UI to show its one first-run spinner.
final class DocumentCacheStore {
    private static let pinnedKey = "dev.llun.Schrift.cachedPinnedDocuments"
    private static let recentKey = "dev.llun.Schrift.cachedRecentDocuments"
    private static let sharedWithMeKey = "dev.llun.Schrift.cachedSharedWithMeDocuments"

    private let userDefaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        // The shared-by-me list was removed; drop any entry a previous app
        // version left stranded so it doesn't linger unread in UserDefaults.
        userDefaults.removeObject(forKey: "dev.llun.Schrift.cachedSharedByMeDocuments")
    }

    func loadPinnedDocuments() -> [Document] {
        load(forKey: Self.pinnedKey) ?? []
    }

    func loadRecentDocuments() -> [Document]? {
        load(forKey: Self.recentKey)
    }

    func loadSharedWithMeDocuments() -> [Document]? {
        load(forKey: Self.sharedWithMeKey)
    }

    func savePinnedDocuments(_ documents: [Document]) {
        save(documents, forKey: Self.pinnedKey)
    }

    func saveRecentDocuments(_ documents: [Document]) {
        save(documents, forKey: Self.recentKey)
    }

    func saveSharedWithMeDocuments(_ documents: [Document]) {
        save(documents, forKey: Self.sharedWithMeKey)
    }

    /// Strip a document from every cached list — what a landed deletion owes the lists that
    /// were showing it. Without it the row survives until the next *successful* fetch, which
    /// is exactly what a deletion queued offline does not have.
    ///
    /// **Never fabricates.** A list that was never cached stays never-cached: nil and `[]` are
    /// read as different everywhere (nil is what lets a screen show its one first-run
    /// placeholder), so writing an empty array here would tell Home it had fetched and found
    /// nothing. Only a list that actually holds the document is rewritten, so this is also a
    /// no-op for the common case.
    func removeDocument(_ documentID: UUID) {
        for key in [Self.pinnedKey, Self.recentKey, Self.sharedWithMeKey] {
            guard let documents = load(forKey: key), documents.contains(where: { $0.id == documentID }) else {
                continue
            }
            save(documents.filter { $0.id != documentID }, forKey: key)
        }
    }

    private func load(forKey key: String) -> [Document]? {
        guard let data = userDefaults.data(forKey: key),
            let documents = try? decoder.decode([Document].self, from: data)
        else {
            return nil
        }
        return documents
    }

    private func save(_ documents: [Document], forKey key: String) {
        guard let data = try? encoder.encode(documents) else { return }
        userDefaults.set(data, forKey: key)
    }
}
