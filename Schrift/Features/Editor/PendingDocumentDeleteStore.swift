import Foundation

/// A deletion the user asked for that the server has not been told about yet.
///
/// The mirror image of `PendingDocumentCreate`, and the two never overlap: a create record
/// names an id the server has **never** seen, a tombstone names one it definitely has. That
/// is the invariant everything here rests on — `documentID` is always a **server** id, never
/// a client-minted one. A document that exists only on this device has nothing to DELETE, so
/// deleting it is complete the moment its record and draft are dropped; it never gets a
/// tombstone. (A *checkpointed* create record is the one shape that is both at once, and
/// even there the tombstone names its `syncedServerID`, which is a real server document.)
///
/// Every field added later must stay **Optional-on-decode**, for the same reason the create
/// record's doc comment gives: `loadAll` is all-or-nothing, so one non-optional addition
/// makes every existing device's tombstones undecodable at once.
struct PendingDocumentDelete: Codable, Equatable, Sendable {
    /// The **server** id the DELETE addresses.
    let documentID: UUID

    /// When the user asked. Carries the replay order, so it is encoded in milliseconds —
    /// ISO-8601 truncates to whole seconds and would make two deletions in the same second
    /// order arbitrarily.
    let requestedAt: Date

    /// Which server this deletion is for. Necessary but **not sufficient** to decide whether
    /// it may be sent: it identifies the server, not the account. See `ownerUserID`.
    let serverOrigin: String

    /// Who asked. Tombstones survive sign-out (the deletion is still owed), so without this a
    /// user signing in on the same device would replay a stranger's deletion under their own
    /// session — and, worse, be *shown* the struck-through row and offered an undo of it.
    /// Optional only because the schema must tolerate an older or damaged record; the
    /// coordinator's `recordPendingDelete` takes a non-optional one, so nil can only mean "we
    /// don't know", which resolves to neither sent nor listed.
    let ownerUserID: UUID?
}

/// Persists the deletions queued on this device, following the same UserDefaults-store
/// conventions as `PendingDocumentCreateStore` (reverse-DNS key, injectable defaults, `try?`
/// returning a safe empty default, millisecond dates because `requestedAt` carries order).
///
/// Backup-**included** and **not** cleared on sign-out, like the create store and
/// `PendingDraftStore`: a queued deletion is work the user asked for that has not happened
/// yet, and `ownerUserID` — not the absence of the record — is what keeps it from reaching
/// the wrong account.
///
/// **One deliberate divergence from the create store: there is no batch remove.** That
/// store's one-write rule exists for the sub-page cascade, where a partially-removed subtree
/// is a state the replay would misread. Tombstones have no cascade — one completes, or is
/// undone, on its own — so a single-id remove is the whole API and a batch one would only
/// invite the idea that deleting a parent should sweep its children's tombstones, which is
/// exactly what must not happen (each names a document the server holds independently).
final class PendingDocumentDeleteStore {
    private static let deletesKey = "dev.llun.Schrift.pendingDeletes"
    /// Where an undecodable blob is moved before the live key is reused, so a schema slip
    /// costs the tombstones' *usability* rather than their bytes.
    private static let quarantineKey = "dev.llun.Schrift.pendingDeletes.unreadable"

    private let userDefaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    func save(_ pendingDelete: PendingDocumentDelete) {
        // Before the first write of a session that found the blob unreadable — otherwise this
        // `loadAll` reads `[:]` and the `persist` below silently overwrites tombstones we
        // could not decode but which are still deletions the user is owed.
        quarantineUnreadableDataIfNeeded()
        var deletes = loadAll()
        deletes[pendingDelete.documentID.uuidString] = pendingDelete
        persist(deletes)
    }

    func pendingDelete(for documentID: UUID) -> PendingDocumentDelete? {
        loadAll()[documentID.uuidString]
    }

    func remove(documentID: UUID) {
        // Same reasoning as `save`: this is a read-modify-write, so on a corrupt blob the
        // `loadAll` below reads `[:]` and the `persist` overwrites it.
        quarantineUnreadableDataIfNeeded()
        var deletes = loadAll()
        deletes[documentID.uuidString] = nil
        persist(deletes)
    }

    /// Oldest first — the order a replay sends them in. The `documentID` tie-break makes that
    /// order *deterministic* rather than approximate, for the same three reasons the create
    /// store gives: `values` has no defined order, Swift's `sorted` is not stable, and
    /// `Date()` is not monotonic across a clock change.
    ///
    /// Unlike the create order this carries no dependency at all — one tombstone's outcome
    /// never gates another's, because each names a document the server holds in its own
    /// right. It is purely "oldest intent first".
    func allDeletes() -> [PendingDocumentDelete] {
        loadAll().values.sorted { orderedByDeletionRequest($0, $1) }
    }

    /// There is stored data, and it does not decode — so the tombstones are **unknown**,
    /// which is a different thing from "there are none".
    ///
    /// Most of the consequence is milder here than for the create store. There, unknown records
    /// disarm the holds and let the next sync pass delete the only copy of every
    /// offline-created document. Here, most of what unknown tombstones cost is that queued
    /// deletions stop replaying and their rows stop being struck through — recoverable by
    /// deleting again.
    ///
    /// **But two consequences are not mild, and the coordinator mirrors this flag for them**
    /// (`DocumentSaveCoordinator.deleteStoreUnreadable`). With every tombstone unknown,
    /// `isPendingDelete` answers false for every tombstoned document — so (a) the create
    /// pass's resume start-over reads a 404 caused by the app's own DELETE as "the document is
    /// gone", clears the checkpoint, and **re-POSTs a document the user deleted** under a new
    /// id, which no later launch can undo; and (b) `runSyncPass`'s 404 reap reads the same 404
    /// as a co-author's delete and removes the draft — the undo's only payload. Do not delete
    /// those two guards on the strength of "this store's corruption is harmless"; it is
    /// harmless only where those guards already stand.
    ///
    /// **Sticky across launches**, like the create store's: quarantining leaves the live key
    /// clean, so an un-sticky answer would report a healthy store next launch while the
    /// deletions it was protecting stayed unknown.
    var holdsUnreadableData: Bool {
        userDefaults.data(forKey: Self.quarantineKey) != nil || liveDataIsUnreadable
    }

    /// Whether the **live** key currently holds something that won't decode. Distinct from
    /// `holdsUnreadableData`, which is sticky: this one drives *quarantining*, and reading
    /// the sticky answer here would make the first write after a quarantine move the new,
    /// healthy blob aside as well.
    private var liveDataIsUnreadable: Bool {
        guard let data = userDefaults.data(forKey: Self.deletesKey) else { return false }
        return (try? decoder.decode([String: PendingDocumentDelete].self, from: data)) == nil
    }

    /// Move an undecodable blob aside so the next write cannot silently destroy it — every
    /// method here is a read-modify-write through a `loadAll` that answers `[:]` for a corrupt
    /// blob, so without this the first queued deletion wipes the unknown ones.
    private func quarantineUnreadableDataIfNeeded() {
        guard liveDataIsUnreadable, let data = userDefaults.data(forKey: Self.deletesKey) else { return }
        // First corruption wins. A second one would mean the store was already rebuilt after
        // the first, so the earlier blob is the one still holding tombstones nothing else has.
        if userDefaults.data(forKey: Self.quarantineKey) == nil {
            userDefaults.set(data, forKey: Self.quarantineKey)
        }
        userDefaults.removeObject(forKey: Self.deletesKey)
    }

    private func loadAll() -> [String: PendingDocumentDelete] {
        guard let data = userDefaults.data(forKey: Self.deletesKey),
            let deletes = try? decoder.decode([String: PendingDocumentDelete].self, from: data)
        else {
            return [:]
        }
        return deletes
    }

    private func persist(_ deletes: [String: PendingDocumentDelete]) {
        guard let data = try? encoder.encode(deletes) else { return }
        userDefaults.set(data, forKey: Self.deletesKey)
    }
}

/// Replay order: `requestedAt`, then `documentID` so equal timestamps still order the same
/// way on every run. The deletion twin of `orderedByCreation`.
func orderedByDeletionRequest(_ lhs: PendingDocumentDelete, _ rhs: PendingDocumentDelete) -> Bool {
    if lhs.requestedAt != rhs.requestedAt { return lhs.requestedAt < rhs.requestedAt }
    return lhs.documentID.uuidString < rhs.documentID.uuidString
}
