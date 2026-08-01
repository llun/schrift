import Foundation

/// A document the user created **on this device** that the server has never seen.
///
/// The server assigns document ids (and `path`, `depth`, the timestamps) — there is no
/// client-supplied-id mechanism — so a document created offline exists under a
/// client-minted `localID` until a create replay POSTs it and migrates everything keyed
/// by that id onto the real one.
///
/// This record is deliberately *not* a flag on `PendingDraft`. The draft carries the
/// title and body already, but it is removed by several legitimate paths (a landed save,
/// a resolved conflict), and a document created but never typed into has no draft content
/// at all — yet still has to be POSTed. The record is what says "this exists", separately
/// from "this has unsaved text".
struct PendingDocumentCreate: Codable, Equatable, Sendable {
    /// Client-minted. The server never sees it; it is the key every local store uses
    /// until the replay migrates them.
    let localID: UUID
    /// The title at creation time. A rename made before the replay lives on the draft,
    /// which is what the replay actually POSTs — this is the fallback.
    let title: String
    /// The **server** id of the parent, or nil for a root document. v1 never creates
    /// under a parent that is itself pending (the synthetic document's
    /// `abilities.childrenCreate` is false), so this is always a real server id and the
    /// replay needs no dependency ordering. `var` because the replay rewrites it to nil
    /// when the parent turns out to be gone or forbidden, retrying as a root create —
    /// degrading the document's *placement* rather than stranding its content.
    var parentID: UUID?
    /// Replay order, and the synthetic document's dates.
    let createdAt: Date
    /// The server this record was minted against (`siteOrigin`), which decides whether it
    /// may be **sent** — never whether it is protected (see `isPendingCreate`).
    let serverOrigin: String
    /// The user who created it, when known. Origin alone identifies the *server*, not the
    /// *account*, and records deliberately survive sign-out — so user B signing in to the
    /// same server would otherwise inherit user A's unsynced documents and POST them into
    /// B's account. Checked by the replay, which can await `/users/me/`; the coordinator is
    /// built before that returns, so it cannot gate on this at mirror time.
    ///
    /// Optional, and every field added here must stay Optional-on-decode: the store decodes
    /// the whole blob in one `try?`, so a single undecodable record silently drops **all**
    /// of them — which, with the holds keyed off those records, would turn a schema slip
    /// into content loss rather than degraded behavior.
    let ownerUserID: UUID?
    /// Set the instant the create POST lands, **before** anything is migrated. It is the
    /// two-phase checkpoint that keeps a relaunch from POSTing a second copy: a record
    /// found with this set skips straight to migration. Nothing else can close that
    /// window — the backend supports no idempotency key.
    var syncedServerID: UUID?

    init(
        localID: UUID,
        title: String,
        parentID: UUID? = nil,
        createdAt: Date,
        serverOrigin: String,
        ownerUserID: UUID? = nil,
        syncedServerID: UUID? = nil
    ) {
        self.localID = localID
        self.title = title
        self.parentID = parentID
        self.createdAt = createdAt
        self.serverOrigin = serverOrigin
        self.ownerUserID = ownerUserID
        self.syncedServerID = syncedServerID
    }
}

/// Documents created on this device and not yet POSTed. Follows the repo's
/// UserDefaults-store conventions (reverse-DNS key, injectable defaults, `try?` returning
/// a safe empty default, millisecond dates because `createdAt` carries replay order).
///
/// Backup-**included**, like `PendingDraftStore` and unlike `DocumentContentCacheStore`:
/// for a document that exists nowhere else, this record and the draft beside it are the
/// only copies of the user's work.
final class PendingDocumentCreateStore {
    private static let createsKey = "dev.llun.Schrift.pendingCreates"

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

    func save(_ create: PendingDocumentCreate) {
        var creates = loadAll()
        creates[create.localID.uuidString] = create
        persist(creates)
    }

    func create(for localID: UUID) -> PendingDocumentCreate? {
        loadAll()[localID.uuidString]
    }

    func remove(localID: UUID) {
        var creates = loadAll()
        creates[localID.uuidString] = nil
        persist(creates)
    }

    /// Oldest first — the order a replay must POST them in, so a document created after
    /// another never reaches the server before it. The `localID` tie-break makes that a
    /// real guarantee rather than an approximate one: `values` has no defined order,
    /// Swift's `sorted` is not stable, and `Date()` is not monotonic across a clock change.
    func allCreates() -> [PendingDocumentCreate] {
        loadAll().values.sorted { orderedByCreation($0, $1) }
    }

    /// There is stored data, and it does not decode — so the records are **unknown**,
    /// which is a different thing from "there are none".
    ///
    /// The distinction is load-bearing rather than pedantic: the holds key off these
    /// records, and `runSyncPass` deletes a draft whose document 404s. Reading a corrupt
    /// blob as "no local documents exist" would therefore disarm every hold and let the
    /// next sync pass destroy the content of every offline-created document at once. The
    /// coordinator asks this at init and suppresses that delete entirely.
    var holdsUnreadableData: Bool {
        guard let data = userDefaults.data(forKey: Self.createsKey) else { return false }
        return (try? decoder.decode([String: PendingDocumentCreate].self, from: data)) == nil
    }

    private func loadAll() -> [String: PendingDocumentCreate] {
        guard let data = userDefaults.data(forKey: Self.createsKey),
            let creates = try? decoder.decode([String: PendingDocumentCreate].self, from: data)
        else {
            return [:]
        }
        return creates
    }

    private func persist(_ creates: [String: PendingDocumentCreate]) {
        guard let data = try? encoder.encode(creates) else { return }
        userDefaults.set(data, forKey: Self.createsKey)
    }
}

/// Replay order: `createdAt`, then `localID` so equal timestamps still order the same way
/// on every run. Shared by the store's ascending listing and the coordinator's descending
/// (newest-first) one, so the two can never disagree about what "same instant" means.
func orderedByCreation(_ lhs: PendingDocumentCreate, _ rhs: PendingDocumentCreate) -> Bool {
    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
    return lhs.localID.uuidString < rhs.localID.uuidString
}

/// The `Document` value the UI navigates to and renders rows for, for a document that
/// exists only on this device.
///
/// Every field the server would own is either the record's own (`id`, `title`, the dates)
/// or an inert placeholder: `path` is a treebeard segment allocated from sibling ordering
/// and cannot be computed here, and `depth`/`numchild` are its tree bookkeeping. Nothing
/// in the app reads them — which is exactly why a synthetic document must **never** be
/// written into `DocumentCacheStore` or `DocumentChildrenCacheStore`, where it would
/// afterwards be indistinguishable from a real one. Lists merge it in at read time
/// instead (`mergedWithLocalDocuments`).
///
/// The abilities are the honest set: editing is local and works, and **nothing else does
/// yet**. Sharing, favoriting and duplicating are server calls against an id the server has
/// never seen. `destroy` is false too, even though deleting such a document *should*
/// eventually be a local no-network operation: today `OptionsViewModel.delete()` only ever
/// calls the server, which would 404, so advertising the ability would promise a delete
/// that cannot happen — and, because `discardPendingWork` is reached only from a
/// *successful* delete, would leave the record un-removable. It flips to true with the
/// local-delete branch in the UI change. `childrenCreate` is false for the same
/// discipline: it holds children-of-local-parents out of scope until a replay can order
/// them.
///
/// `title` is the record's, i.e. the title at creation time. Callers that can see the
/// draft should prefer the draft's — the user may have renamed the document since, and
/// `DocumentSaveCoordinator.pendingLocalDocuments` does exactly that overlay.
func localDocument(from create: PendingDocumentCreate) -> Document {
    var abilities = DocumentAbilities()
    abilities.update = true
    abilities.partialUpdate = true
    return Document(
        id: create.localID,
        title: create.title,
        excerpt: nil,
        abilities: abilities,
        linkReach: .restricted,
        linkRole: .reader,
        computedLinkReach: nil,
        computedLinkRole: nil,
        isFavorite: false,
        depth: 1,
        numchild: 0,
        path: "",
        createdAt: create.createdAt,
        updatedAt: create.createdAt,
        userRole: .owner,
        creator: nil)
}

/// Fold documents that exist only on this device into a fetched list, local ones first.
///
/// Applied at **read** time, never persisted. A list load replaces its array and its cache
/// entry wholesale, so a locally-inserted row would simply vanish on the next successful
/// fetch; merging on read is what survives that.
///
/// Takes `[Document]` on both sides so it composes directly with
/// `DocumentSaveCoordinator.pendingLocalDocuments(parentID:)`, which is what already
/// applies the parent filter, the origin scoping and the newest-first order. Taking records
/// instead left the only reachable source `createStore.allCreates()` — every origin and
/// every parent — which would have leaked other servers' documents into a list.
///
/// The id de-duplication is a cheap guard against the caller handing overlapping lists; it
/// is **not** a solution to the replay window, and an earlier comment here wrongly claimed
/// it was. After a replay the fetched row carries the *server* id while a not-yet-torn-down
/// record still surfaces under its `localID`, so no id-based filter can match the two. That
/// window belongs to the replay, which must stop surfacing a record once its
/// `syncedServerID` is set — the id a document is *known by* changes there, and nothing on
/// this side can infer it.
func mergedWithLocalDocuments(fetched: [Document], local: [Document]) -> [Document] {
    guard !local.isEmpty else { return fetched }
    let fetchedIDs = Set(fetched.map(\.id))
    return local.filter { !fetchedIDs.contains($0.id) } + fetched
}
