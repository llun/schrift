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

/// Slack applied when comparing a client-stamped draft timestamp against the
/// server's `updated_at`: they come from different clocks, and a save's
/// server timestamp always lands after the client stamped the draft that
/// produced it. Within this window a stranded draft is treated as newer —
/// losing the user's own typed content is worse than replaying it over a
/// near-simultaneous web edit (full-overwrite saves are already last-writer-wins).
let pendingDraftClockTolerance: TimeInterval = 120

final class PendingDraftStore {
    private static let draftsKey = "dev.llun.Schrift.pendingDrafts"

    private let userDefaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let encoder = JSONEncoder()
        // Millisecond precision: plain .iso8601 truncates to whole seconds,
        // which can make a draft look older than the save it raced against.
        encoder.dateEncodingStrategy = .millisecondsSince1970
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
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
            let drafts = try? decoder.decode([String: PendingDraft].self, from: data)
        else {
            return [:]
        }
        return drafts
    }

    private func persist(_ drafts: [String: PendingDraft]) {
        guard let data = try? encoder.encode(drafts) else { return }
        userDefaults.set(data, forKey: Self.draftsKey)
    }
}
