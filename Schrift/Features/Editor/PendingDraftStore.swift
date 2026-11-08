import Foundation

/// A document edit that has been handed to the save pipeline but not yet
/// confirmed persisted by the server. Written before any network call so the
/// content survives suspension, process death, or a failed save.
///
/// `baseline` and `lastPushedMarkdown` are optional and decode as nil from drafts
/// written before they existed (legacy drafts route to the tolerance rule). They
/// let the sync path distinguish "the server moved on while I was offline" from
/// "the server only changed because my own save landed" — see `draftSyncDecision`.
/// `baseline` is supplied by the editor (the server state the edit descends from).
/// `lastPushedMarkdown` is the markdown `DocumentSaveCoordinator` last confirmed
/// pushed for this document (copied from `lastConfirmedPushMarkdown` by `enqueue`
/// and refreshed on a surviving draft in `finish`), so `draftSyncDecision` rule 1
/// can recognise our own write — including across a relaunch — and not flag a
/// false conflict against it.
struct PendingDraft: Codable, Equatable, Sendable {
    let documentID: UUID
    let title: String
    let markdown: String
    let updatedAt: Date
    let baseline: DraftBaseline?
    let lastPushedMarkdown: String?
    /// The server `updated_at` of a **detected but unanswered sync conflict**, mirrored here
    /// from `DocumentSaveCoordinator.conflicts` so the **enqueue-hold survives a relaunch**.
    ///
    /// It has to be persisted, not merely re-derivable. The in-memory record alone meant a
    /// conflict the app had already *detected and shown the user* evaporated on process death:
    /// on the next launch `restoreLocalContent` puts the draft on screen synchronously and
    /// `hasLoadedContent` unblocks editing **before** any revalidation returns, so a Done tap
    /// or an autosave could reach `enqueue` with `conflicts` still empty — and push a full
    /// overwrite over the co-author's body the user had literally just been warned about. Rule
    /// 1 and the baseline are persisted for the same reason; the hold is no different.
    let conflictServerUpdatedAt: Date?
    /// Presence reserves this draft for raw replay, even with the switch off.
    /// Missing on older drafts; never silently migrate those into a replica.
    let replica: ReplicaDraftReference?

    init(
        documentID: UUID,
        title: String,
        markdown: String,
        updatedAt: Date,
        baseline: DraftBaseline? = nil,
        lastPushedMarkdown: String? = nil,
        conflictServerUpdatedAt: Date? = nil,
        replica: ReplicaDraftReference? = nil
    ) {
        self.documentID = documentID
        self.title = title
        self.markdown = markdown
        self.updatedAt = updatedAt
        self.baseline = baseline
        self.lastPushedMarkdown = lastPushedMarkdown
        self.conflictServerUpdatedAt = conflictServerUpdatedAt
        self.replica = replica
    }
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
    private static let quarantineKey = "dev.llun.Schrift.pendingDrafts.unreadable"
    private static let additionalQuarantineKey = "dev.llun.Schrift.pendingDrafts.unreadable.additional"
    /// Shared by every instance and every `UserDefaults`: it memoizes the decode of whatever
    /// bytes were last read, so it can never answer for bytes it did not decode — see
    /// `DecodedBlobMemo`.
    private static let memo = DecodedBlobMemo<[String: PendingDraft]>()

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
        quarantineUnreadableDataIfNeeded()
        var drafts = loadAll()
        drafts[draft.documentID.uuidString] = draft
        persist(drafts)
    }

    func draft(for documentID: UUID) -> PendingDraft? {
        loadAll()[documentID.uuidString]
    }

    func remove(documentID: UUID) {
        quarantineUnreadableDataIfNeeded()
        var drafts = loadAll()
        drafts[documentID.uuidString] = nil
        persist(drafts)
    }

    func allDrafts() -> [PendingDraft] {
        loadAll().values.sorted { $0.updatedAt < $1.updatedAt }
    }

    /// There is stored draft data and it does not decode — so the drafts are **unknown**,
    /// not absent.
    ///
    /// `loadAll` is all-or-nothing, so one undecodable blob makes every `draft(for:)` answer
    /// nil. Read as "there is no draft" that is merely invisible, which is how the app behaved
    /// before the create replay existed. The replay is what turns that read into *destroyed*
    /// content: it POSTs a document whose body it believes empty and then deletes the create
    /// record, which is the only thing that could have driven a recovery after a shipped
    /// decode fix. So it asks this first. (Not the only irreversible consumer, though —
    /// `DocumentSaveCoordinator.init`'s conflict rehydration reads the same empty answer and
    /// silently drops every persisted hold, after which the next `enqueue` full-overwrites a
    /// server body the user was warned about. That one predates the replay.)
    ///
    /// Sticky across writes and launches. Before reusing an unreadable live key,
    /// retain its bytes separately; a second corrupt blob must survive too.
    /// Only explicit successful recovery releases this hold.
    ///
    /// Corollary inherited from that store: **every field added to `PendingDraft` or
    /// `DraftBaseline` must stay Optional-on-decode.** A non-optional addition makes this
    /// return true for every existing device and gate replay until recovery.
    var holdsUnreadableData: Bool {
        !quarantinedData.isEmpty || liveDataIsUnreadable
    }

    private var liveDataIsUnreadable: Bool {
        guard let data = userDefaults.data(forKey: Self.draftsKey) else { return false }
        return decoded(data) == nil
    }

    /// Recovery payloads are document content: never log them or purge them on
    /// sign-out. The first slot keeps the same layout as the other draft stores.
    private var quarantinedData: [Data] {
        let first = userDefaults.data(forKey: Self.quarantineKey).map { [$0] } ?? []
        return first + (userDefaults.array(forKey: Self.additionalQuarantineKey) as? [Data] ?? [])
    }

    private func quarantineUnreadableDataIfNeeded() {
        guard liveDataIsUnreadable, let data = userDefaults.data(forKey: Self.draftsKey) else { return }
        if userDefaults.data(forKey: Self.quarantineKey) == nil {
            userDefaults.set(data, forKey: Self.quarantineKey)
        } else if !quarantinedData.contains(data) {
            var additional = userDefaults.array(forKey: Self.additionalQuarantineKey) as? [Data] ?? []
            additional.append(data)
            userDefaults.set(additional, forKey: Self.additionalQuarantineKey)
        }
        userDefaults.removeObject(forKey: Self.draftsKey)
    }

    /// Retry after a decoder repair. Merge only when *all* retained blobs can
    /// be decoded, keep newer live edits, and write before clearing recovery
    /// slots. Repeating after an interruption is idempotent. The caller decides
    /// when to retry; routine reads never silently resolve unknown work.
    @discardableResult
    func recoverQuarantinedDrafts() -> Bool {
        quarantineUnreadableDataIfNeeded()
        guard !quarantinedData.isEmpty else { return true }
        var drafts = loadAll()
        for data in quarantinedData {
            guard let recovered = decoded(data) else { return false }
            for (id, draft) in recovered {
                if let live = drafts[id], live.updatedAt >= draft.updatedAt { continue }
                drafts[id] = draft
            }
        }
        guard let data = try? encoder.encode(drafts) else { return false }
        userDefaults.set(data, forKey: Self.draftsKey)
        userDefaults.removeObject(forKey: Self.quarantineKey)
        userDefaults.removeObject(forKey: Self.additionalQuarantineKey)
        return true
    }

    private func loadAll() -> [String: PendingDraft] {
        guard let data = userDefaults.data(forKey: Self.draftsKey), let drafts = decoded(data) else {
            return [:]
        }
        return drafts
    }

    /// The blob's decode, memoized on its bytes: a read with no write since the last one costs a
    /// byte comparison, not a decode of every draft body. nil means undecodable, exactly as the
    /// direct `try? decode` it replaces.
    private func decoded(_ data: Data) -> [String: PendingDraft]? {
        Self.memo.value(for: data) { try? decoder.decode([String: PendingDraft].self, from: $0) }
    }

    private func persist(_ drafts: [String: PendingDraft]) {
        guard let data = try? encoder.encode(drafts) else { return }
        userDefaults.set(data, forKey: Self.draftsKey)
    }
}
