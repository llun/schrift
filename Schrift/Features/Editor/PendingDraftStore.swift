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
    /// The account the draft belongs to: only that account is shown or replays it. Stamped by
    /// `PendingDraftStore.save`; nil on a draft no account could be named for (see `owner`).
    let ownerUserID: UUID?

    init(
        documentID: UUID,
        title: String,
        markdown: String,
        updatedAt: Date,
        baseline: DraftBaseline? = nil,
        lastPushedMarkdown: String? = nil,
        conflictServerUpdatedAt: Date? = nil,
        replica: ReplicaDraftReference? = nil,
        ownerUserID: UUID? = nil
    ) {
        self.documentID = documentID
        self.title = title
        self.markdown = markdown
        self.updatedAt = updatedAt
        self.baseline = baseline
        self.lastPushedMarkdown = lastPushedMarkdown
        self.conflictServerUpdatedAt = conflictServerUpdatedAt
        self.replica = replica
        self.ownerUserID = ownerUserID
    }

    /// A native draft's account is its replica's, whatever the stamp says.
    var owner: UUID? { replica?.scope.ownerUserID ?? ownerUserID }

    func owned(by owner: UUID?) -> PendingDraft {
        PendingDraft(
            documentID: documentID, title: title, markdown: markdown, updatedAt: updatedAt, baseline: baseline,
            lastPushedMarkdown: lastPushedMarkdown, conflictServerUpdatedAt: conflictServerUpdatedAt,
            replica: replica, ownerUserID: owner)
    }
}

/// Slack applied when comparing a client-stamped draft timestamp against the
/// server's `updated_at`: they come from different clocks, and a save's
/// server timestamp always lands after the client stamped the draft that
/// produced it. Within this window a stranded draft is treated as newer —
/// losing the user's own typed content is worse than replaying it over a
/// near-simultaneous web edit (full-overwrite saves are already last-writer-wins).
let pendingDraftClockTolerance: TimeInterval = 120

/// Every draft stays on disk until its own account sends or discards it, but the plain reads
/// (`draft(for:)`, `allDrafts()`) and `remove` see only the signed-in account's — and nothing
/// while no account is known (`SignedInUserStore` answers nil), exactly as the owner-scoped
/// create and delete stores fail closed. `allDraftsOfEveryAccount()` is for the protections
/// that must hold whoever is signed in (backup exclusion, replica purge, photo collection,
/// conflict holds), never for showing or sending.
///
/// Stored under `<owner>|<document>`, so two accounts' drafts of one shared document never
/// replace each other. A bare `<document>` key is a draft with no account to name — one from an
/// earlier build that `assignOwnersToEarlierDrafts` could not place, or one that arrived while
/// the account was unknown. It is set aside: shown to nobody and replayed by nobody, but kept.
final class PendingDraftStore {
    private static let draftsKey = "dev.llun.Schrift.pendingDrafts"
    private static let ownersAssignedKey = "dev.llun.Schrift.pendingDrafts.ownersAssigned"
    private static let earlierBlobCountKey = "dev.llun.Schrift.pendingDrafts.ownersAssigned.unreadableCount"
    private static let earlierBlobOwnerKey = "dev.llun.Schrift.pendingDrafts.ownersAssigned.unreadableOwner"
    private static let quarantineKey = "dev.llun.Schrift.pendingDrafts.unreadable"
    private static let additionalQuarantineKey = "dev.llun.Schrift.pendingDrafts.unreadable.additional"
    /// Shared by every instance and every `UserDefaults`: it memoizes the decode of whatever
    /// bytes were last read, so it can never answer for bytes it did not decode — see
    /// `DecodedBlobMemo`.
    private static let memo = DecodedBlobMemo<DraftIndex>()

    /// One decoded blob, indexed once: the reads on keystroke and render paths look drafts up
    /// rather than re-deriving owners and re-sorting every draft on each call.
    private struct DraftIndex: Sendable {
        let drafts: [String: PendingDraft]
        let sorted: [PendingDraft]
        /// The newest draft per account and document.
        let byOwner: [UUID: [UUID: PendingDraft]]

        init(_ decoded: [String: PendingDraft]) {
            drafts = PendingDraftStore.ownersFromKeys(decoded)
            sorted = drafts.values.sorted { $0.updatedAt < $1.updatedAt }
            var byOwner: [UUID: [UUID: PendingDraft]] = [:]
            for draft in sorted {
                if let owner = draft.owner { byOwner[owner, default: [:]][draft.documentID] = draft }
            }
            self.byOwner = byOwner
        }
    }

    private let userDefaults: UserDefaults
    private let signedInUser: SignedInUserStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.signedInUser = SignedInUserStore(userDefaults: userDefaults)
        let encoder = JSONEncoder()
        // Millisecond precision: plain .iso8601 truncates to whole seconds,
        // which can make a draft look older than the save it raced against.
        encoder.dateEncodingStrategy = .millisecondsSince1970
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    /// Stamps the draft with the signed-in account (a native draft keeps its replica's, and a
    /// draft already stamped keeps its stamp) and replaces only that account's draft of the
    /// document. Nothing saves while no account is known — pages are read-only then — so an
    /// owner-less draft is set aside under its bare document key rather than lost, shown to
    /// nobody, exactly like a set-aside draft from an earlier build. It never replaces one
    /// already there: that slot is only ever read now.
    func save(_ draft: PendingDraft) {
        quarantineUnreadableDataIfNeeded()
        var drafts = loadAll()
        let stamped = draft.owned(by: draft.owner ?? signedInUser.userID)
        if let owner = stamped.owner {
            drafts = drafts.filter { $0.value.documentID != draft.documentID || $0.value.owner != owner }
            drafts[Self.key(owner: owner, documentID: draft.documentID)] = stamped
        } else if drafts[draft.documentID.uuidString] == nil {
            drafts[draft.documentID.uuidString] = stamped
        }
        persist(drafts)
    }

    /// The sign-in the plain reads are scoped to.
    var session: SignedInSession { signedInUser.session }

    func draft(for documentID: UUID) -> PendingDraft? {
        draft(for: documentID, owner: signedInUser.userID)
    }

    /// `owner`'s draft, whoever is signed in: for work that started under that account and
    /// settles after a switch (a save landing, a replay).
    func draft(for documentID: UUID, owner: UUID?) -> PendingDraft? {
        guard let owner else { return nil }
        return index()?.byOwner[owner]?[documentID]
    }

    func remove(documentID: UUID) {
        remove(documentID: documentID, owner: signedInUser.userID)
    }

    func remove(documentID: UUID, owner: UUID?) {
        guard let owner else { return }
        quarantineUnreadableDataIfNeeded()
        var drafts = loadAll()
        drafts = drafts.filter { $0.value.documentID != documentID || $0.value.owner != owner }
        persist(drafts)
    }

    private static func key(owner: UUID, documentID: UUID) -> String {
        "\(owner.uuidString)|\(documentID.uuidString)"
    }

    func allDrafts() -> [PendingDraft] {
        guard let owner = signedInUser.userID else { return [] }
        return allDraftsOfEveryAccount().filter { $0.owner == owner }
    }

    func allDraftsOfEveryAccount() -> [PendingDraft] {
        index()?.sorted ?? []
    }

    /// Run once, at launch before any sign-in can name an account: drafts from an earlier build
    /// carry no owner, so they go to the account signed in at that moment. With none known (signed
    /// out, or a login handover not yet confirmed — which may be another account's) they are set
    /// aside instead, and the flag keeps a later sign-in from claiming them. Native drafts need
    /// nothing: their replica names the account.
    ///
    /// Blobs that do not decode yet (live or quarantined) are earlier-build drafts too, but their
    /// repair can come at any later launch, under any account. So the account signed in now is
    /// recorded with how many such blobs there are, and `recoverQuarantinedDrafts` gives exactly
    /// that account — or nobody — their ownerless drafts.
    func assignOwnersToEarlierDrafts() {
        guard !userDefaults.bool(forKey: Self.ownersAssignedKey) else { return }
        let owner = signedInUser.userID
        if let data = userDefaults.data(forKey: Self.draftsKey), var drafts = decoded(data)?.drafts, let owner {
            for (key, draft) in drafts where draft.owner == nil {
                drafts[key] = nil
                drafts[Self.key(owner: owner, documentID: draft.documentID)] = draft.owned(by: owner)
            }
            persist(drafts)
        }
        // Quarantined first, so the count is of the blobs actually retained (a live blob equal to
        // one already quarantined is not retained twice): the first `count` recovery blobs are
        // exactly these, and any later one is not.
        quarantineUnreadableDataIfNeeded()
        let unreadable = quarantinedData.count
        if unreadable > 0 {
            userDefaults.set(unreadable, forKey: Self.earlierBlobCountKey)
            userDefaults.set(owner?.uuidString, forKey: Self.earlierBlobOwnerKey)
        }
        userDefaults.set(true, forKey: Self.ownersAssignedKey)
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
        let earlierBlobs = userDefaults.integer(forKey: Self.earlierBlobCountKey)
        let earlierOwner = userDefaults.string(forKey: Self.earlierBlobOwnerKey).flatMap(UUID.init(uuidString:))
        for (index, data) in quarantinedData.enumerated() {
            guard let recovered = decoded(data)?.drafts else { return false }
            for (key, draft) in recovered {
                // An earlier-build draft goes to the account recorded at the first launch of this
                // build, never to whoever happens to be signed in at the repair.
                let isEarlier = index < earlierBlobs && draft.owner == nil && !key.contains("|")
                let draft = isEarlier ? draft.owned(by: earlierOwner) : draft
                guard let owner = draft.owner else {
                    if let live = drafts[key], live.updatedAt >= draft.updatedAt { continue }
                    drafts[key] = draft
                    continue
                }
                // One draft per account and document, whichever key either copy sat under.
                let existing = drafts.filter { $0.value.documentID == draft.documentID && $0.value.owner == owner }
                if existing.values.contains(where: { $0.updatedAt >= draft.updatedAt }) { continue }
                for liveKey in existing.keys { drafts[liveKey] = nil }
                drafts[Self.key(owner: owner, documentID: draft.documentID)] = draft
            }
        }
        guard let data = try? encoder.encode(drafts) else { return false }
        userDefaults.set(data, forKey: Self.draftsKey)
        userDefaults.removeObject(forKey: Self.quarantineKey)
        userDefaults.removeObject(forKey: Self.additionalQuarantineKey)
        userDefaults.removeObject(forKey: Self.earlierBlobCountKey)
        userDefaults.removeObject(forKey: Self.earlierBlobOwnerKey)
        return true
    }

    /// An older build re-encodes every draft without `ownerUserID`, so the key's owner prefix
    /// stands in for a stamp it dropped.
    private func loadAll() -> [String: PendingDraft] {
        index()?.drafts ?? [:]
    }

    private func index() -> DraftIndex? {
        userDefaults.data(forKey: Self.draftsKey).flatMap(decoded)
    }

    private static func ownersFromKeys(_ drafts: [String: PendingDraft]) -> [String: PendingDraft] {
        drafts.reduce(into: [:]) { result, entry in
            let (key, draft) = entry
            let parts = key.split(separator: "|")
            let keyOwner = parts.count == 2 ? UUID(uuidString: String(parts[0])) : nil
            result[key] = draft.owner == nil && keyOwner != nil ? draft.owned(by: keyOwner) : draft
        }
    }

    /// The blob's decode, memoized on its bytes: a read with no write since the last one costs a
    /// byte comparison, not a decode of every draft body. nil means undecodable, exactly as the
    /// direct `try? decode` it replaces.
    private func decoded(_ data: Data) -> DraftIndex? {
        Self.memo.value(for: data) { (try? decoder.decode([String: PendingDraft].self, from: $0)).map(DraftIndex.init) }
    }

    private func persist(_ drafts: [String: PendingDraft]) {
        guard let data = try? encoder.encode(drafts) else { return }
        userDefaults.set(data, forKey: Self.draftsKey)
    }
}
