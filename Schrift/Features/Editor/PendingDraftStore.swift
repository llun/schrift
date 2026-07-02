import Foundation

/// A document edit that has been handed to the save pipeline but not yet
/// confirmed persisted by the server. Written before any network call so the
/// content survives suspension, process death, or a failed save.
struct PendingDraft: Codable, Equatable, Sendable {
    let documentID: UUID
    let title: String
    let markdown: String
    let updatedAt: Date
}

final class PendingDraftStore {
    private static let draftsKey = "dev.llun.Schrift.pendingDrafts"

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

    func save(_ draft: PendingDraft) {
        var drafts = loadAll()
        drafts[draft.documentID.uuidString] = draft
        persist(drafts)
    }

    func draft(for documentID: UUID) -> PendingDraft? {
        loadAll()[documentID.uuidString]
    }

    func remove(documentID: UUID) {
        var drafts = loadAll()
        drafts[documentID.uuidString] = nil
        persist(drafts)
    }

    func allDrafts() -> [PendingDraft] {
        loadAll().values.sorted { $0.updatedAt < $1.updatedAt }
    }

    private func loadAll() -> [String: PendingDraft] {
        guard let data = userDefaults.data(forKey: Self.draftsKey),
              let drafts = try? decoder.decode([String: PendingDraft].self, from: data) else {
            return [:]
        }
        return drafts
    }

    private func persist(_ drafts: [String: PendingDraft]) {
        guard let data = try? encoder.encode(drafts) else { return }
        userDefaults.set(data, forKey: Self.draftsKey)
    }
}
