import Foundation

final class DocumentCacheStore {
    private static let pinnedKey = "dev.llun.Schrift.cachedPinnedDocuments"
    private static let recentKey = "dev.llun.Schrift.cachedRecentDocuments"

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
    }

    func loadPinnedDocuments() -> [Document] {
        load(forKey: Self.pinnedKey)
    }

    func loadRecentDocuments() -> [Document] {
        load(forKey: Self.recentKey)
    }

    func savePinnedDocuments(_ documents: [Document]) {
        save(documents, forKey: Self.pinnedKey)
    }

    func saveRecentDocuments(_ documents: [Document]) {
        save(documents, forKey: Self.recentKey)
    }

    private func load(forKey key: String) -> [Document] {
        guard let data = userDefaults.data(forKey: key),
              let documents = try? decoder.decode([Document].self, from: data) else {
            return []
        }
        return documents
    }

    private func save(_ documents: [Document], forKey key: String) {
        guard let data = try? encoder.encode(documents) else { return }
        userDefaults.set(data, forKey: key)
    }
}
