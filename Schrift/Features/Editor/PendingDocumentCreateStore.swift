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
    /// replay needs no dependency ordering.
    var parentID: UUID?
    /// Replay order, and the synthetic document's dates.
    let createdAt: Date
    /// The server this record was minted against (`siteOrigin`). Drafts and metadata
    /// caches deliberately survive sign-out, so without this a record could be replayed
    /// into a *different* account or server — POSTing the user's content somewhere they
    /// never wrote it. A record whose origin doesn't match the session stays dormant; it
    /// is never deleted, because the user may sign back in.
    let serverOrigin: String
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
        syncedServerID: UUID? = nil
    ) {
        self.localID = localID
        self.title = title
        self.parentID = parentID
        self.createdAt = createdAt
        self.serverOrigin = serverOrigin
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
    /// another never reaches the server before it.
    func allCreates() -> [PendingDocumentCreate] {
        loadAll().values.sorted { $0.createdAt < $1.createdAt }
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
/// The abilities are the honest set: it can be edited and deleted locally, and nothing
/// else — sharing, favoriting and duplicating are all server calls against an id the
/// server has never seen. `childrenCreate` is false, which is what holds
/// children-of-local-parents out of scope until a replay can order them.
func localDocument(from create: PendingDocumentCreate) -> Document {
    var abilities = DocumentAbilities()
    abilities.update = true
    abilities.partialUpdate = true
    abilities.destroy = true
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

/// Fold documents that exist only on this device into a fetched list, newest first.
///
/// Applied at **read** time, never persisted. A list load replaces its array and its cache
/// entry wholesale, so a locally-inserted row would simply vanish on the next successful
/// fetch; merging on read is what survives that. The id de-duplication is defence in depth
/// for the window where a replay has landed and the fetched list already carries the real
/// document while its record is still being torn down — the server's row wins.
func mergedWithLocalDocuments(fetched: [Document], local: [PendingDocumentCreate]) -> [Document] {
    guard !local.isEmpty else { return fetched }
    let fetchedIDs = Set(fetched.map(\.id))
    let pending =
        local
        .filter { !fetchedIDs.contains($0.localID) }
        .sorted { $0.createdAt > $1.createdAt }
        .map(localDocument(from:))
    return pending + fetched
}
