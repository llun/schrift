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

    /// Strip a document from the **recents** list alone — what a document that has just been
    /// filed under a parent owes Home's top-level feed.
    ///
    /// Deliberately not `removeDocument`, which would take the pinned and shared entries with
    /// it. Neither is a fact about placement: a favorite is a per-user annotation the server
    /// keeps across a move, and shared-with-me membership is decided by access, which a move
    /// does not change. Removing either would hide a document the next fetch puts straight
    /// back, and an offline relaunch would show neither.
    ///
    /// **Never fabricates**, for the same reason as its neighbours.
    func removeRecentDocument(_ documentID: UUID) {
        guard let documents = load(forKey: Self.recentKey), documents.contains(where: { $0.id == documentID })
        else { return }
        save(documents.filter { $0.id != documentID }, forKey: Self.recentKey)
    }

    /// Put a document at the top of the cached recents list — what a promotion to the top level
    /// owes a Home that may not fetch again before the next launch.
    ///
    /// **Never fabricates**, so a device whose recents were never cached stays never-cached and
    /// keeps its first-run placeholder, exactly as `insertIntoListCaches` refuses to.
    func insertRecentDocument(_ document: Document) {
        guard var recents = load(forKey: Self.recentKey), !recents.contains(where: { $0.id == document.id })
        else { return }
        recents.insert(document, at: 0)
        save(recents, forKey: Self.recentKey)
    }

    /// Reflect a pin/unpin in every cached list, so a relaunch — or an offline launch, which
    /// has nothing else to go on — does not show the pre-pin answer until the next successful
    /// fetch.
    ///
    /// **Never fabricates**, for exactly the reason `removeDocument` does not: nil and `[]`
    /// are read as different everywhere, and writing an empty recents array here would tell
    /// Home it had fetched and found nothing, suppressing its first-run placeholder. The
    /// pinned key is the one safe exception and only when it already exists —
    /// `loadPinnedDocuments` collapses nil to `[]`, so it has no never-cached state to
    /// destroy, but staying consistent with the others costs nothing.
    ///
    /// `document` is the row to insert when pinning something the cached pinned list does not
    /// yet hold; unpinning ignores it.
    func setFavorite(_ documentID: UUID, isFavorite: Bool, document: Document?) {
        // The flag, wherever the document appears.
        for key in [Self.recentKey, Self.sharedWithMeKey] {
            guard let documents = load(forKey: key), documents.contains(where: { $0.id == documentID }) else {
                continue
            }
            save(
                applyingFavoriteFlag(documents, documentID: documentID, isFavorite: isFavorite),
                forKey: key)
        }

        // …and membership of the pinned list.
        guard var pinned = load(forKey: Self.pinnedKey) else { return }
        let alreadyPinned = pinned.contains { $0.id == documentID }
        if isFavorite {
            guard !alreadyPinned, var copy = document else { return }
            copy.isFavorite = true
            pinned.insert(copy, at: 0)
        } else {
            guard alreadyPinned else { return }
            pinned.removeAll { $0.id == documentID }
        }
        save(pinned, forKey: Self.pinnedKey)
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
