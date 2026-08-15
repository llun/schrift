import Foundation

/// The URL scheme a queued photo carries until its upload lands.
///
/// A photo picked while offline cannot be uploaded, so the block that goes into the document
/// names the *record* instead of a media URL: `schrift-attachment://<localID>`. The scheme is
/// allowlisted by `parseImageLine` beside http(s) — deliberately, and it is the only non-http
/// scheme that classifies as an image — so the block is a real `.image` block everywhere
/// downstream: `addsImage`'s re-parse verification passes, `canonicalizeLine` stays consistent
/// with classification for free, and the encoder emits an ordinary BlockNote image leaf.
///
/// What keeps that from reaching the server is not the scheme but
/// `markdownReferencesPendingAttachment`: a save whose parsed markdown contains one of these is
/// **held** by `DocumentSaveCoordinator.enqueue` exactly as a conflict or a pending create holds
/// one. The hold is keyed on the *content* rather than on this store, so a store that cannot be
/// read can stall a replay but can never leak a placeholder.
let pendingAttachmentURLScheme = "schrift-attachment"

/// The scheme with its separator, which is also the fast-path needle
/// `markdownReferencesPendingAttachment` scans for before parsing.
let pendingAttachmentURLPrefix = pendingAttachmentURLScheme + "://"

/// The placeholder URL for a record. Lowercased, like every other id the app puts on the wire.
func pendingAttachmentPlaceholderURL(for localID: UUID) -> String {
    pendingAttachmentURLPrefix + localID.uuidString.lowercased()
}

/// The record a placeholder URL names, or nil for anything else.
///
/// Strict about shape — nothing after the id but an optional trailing slash — and parsed by
/// string rather than through `URL.host`, so the answer cannot move with Foundation's handling of
/// authority components in a non-special scheme.
///
/// **The scheme comparison is case-insensitive, and that is load-bearing rather than lenient.**
/// `parseImageLine` classifies on `url.scheme?.lowercased()`, so `SCHRIFT-ATTACHMENT://…` is a
/// real image block; a case-sensitive test here would answer nil for it, the save hold would not
/// engage, and the placeholder would be pushed to the server. Whatever the parser accepts as a
/// placeholder, this must recognise — the two are a matched pair, and a gap in either direction
/// is a bug (too strict here leaks; too lenient in the *rewriter* wedges).
func pendingAttachmentID(fromPlaceholderURL urlString: String) -> UUID? {
    guard let separator = urlString.range(of: "://") else { return nil }
    guard urlString[urlString.startIndex..<separator.lowerBound].lowercased() == pendingAttachmentURLScheme
    else { return nil }
    var identifier = String(urlString[separator.upperBound...])
    if identifier.hasSuffix("/") { identifier.removeLast() }
    return UUID(uuidString: identifier)
}

/// A photo picked on this device whose upload has not landed yet.
///
/// The bytes live beside this record as a file; the record is what says "a placeholder in some
/// document names these bytes, and they still owe the server an upload". It is deliberately not
/// a field on `PendingDraft`: a draft is removed by several legitimate paths (a landed save, a
/// resolved conflict) while the attachment it referenced may still be mid-upload, and one draft
/// can owe several uploads.
struct PendingAttachment: Codable, Equatable, Sendable {
    /// Client-minted, and the identity the placeholder URL carries.
    let localID: UUID
    /// The document the placeholder sits in. `var` because a document created on this device is
    /// re-keyed from its `localID` onto the server's id when a locally-created document is
    /// POSTed. **Owed by the replay work**: `migrateCreatedDocument` does not rewrite this yet,
    /// and must do so in the same sweep that repoints child create records — before the create
    /// record is removed, so the parent-create gate holds throughout.
    var documentID: UUID
    /// Replay order.
    let createdAt: Date
    /// The server this was minted against (`siteOrigin`), which — with `ownerUserID` — decides
    /// whether it may be **sent**, never whether it is protected. A record belonging to another
    /// server or account is kept, rendered as unavailable, and never uploaded or collected:
    /// dormant means no requests *and* no deletion.
    let serverOrigin: String
    /// The account that picked the photo. Origin identifies the *server*, not the user, and
    /// records survive sign-out — so without this, user B signing in to the same server would
    /// upload user A's photo into a document under B's session.
    ///
    /// Optional, and every field added here must stay Optional-on-decode: the store decodes the
    /// whole blob in one `try?`, so one undecodable record drops **all** of them.
    let ownerUserID: UUID?
    /// The resolved media URL, stamped the instant the upload is confirmed ready and **before**
    /// any markdown is rewritten. It is the two-phase checkpoint that keeps a relaunch from
    /// uploading a second copy: a record found with this set skips straight to the rewrite.
    /// Nothing else can close that window — the attachment endpoint has no idempotency key.
    var uploadedURLString: String?
    /// Set when the server rejected the upload on the merits (a 400, a too-large file) — a
    /// failure that retrying cannot fix on its own. Unlike the in-memory `.failed` save state,
    /// this is persisted, because the affordances it will drive (Retry / Remove, on the image
    /// leaf itself — **owed by the rendering work**, which is what makes this state answerable)
    /// have to survive a relaunch: the document's saves stay held until the user answers, and a
    /// state the user cannot see is a state they cannot answer.
    var failedAt: Date?

    init(
        localID: UUID,
        documentID: UUID,
        createdAt: Date,
        serverOrigin: String,
        ownerUserID: UUID? = nil,
        uploadedURLString: String? = nil,
        failedAt: Date? = nil
    ) {
        self.localID = localID
        self.documentID = documentID
        self.createdAt = createdAt
        self.serverOrigin = serverOrigin
        self.ownerUserID = ownerUserID
        self.uploadedURLString = uploadedURLString
        self.failedAt = failedAt
    }

    /// The placeholder URL this record's block carries.
    var placeholderURL: String { pendingAttachmentPlaceholderURL(for: localID) }
}

/// Photos queued on this device: records in UserDefaults, bytes as files.
///
/// Entries hold the user's own photographs — never log, print, or transmit their contents
/// anywhere but the attachment upload.
///
/// Split that way for the same reason `DocumentContentCacheStore` is file-based — JPEG bytes do
/// not belong in a UserDefaults blob — while the records follow the repo's UserDefaults-store
/// conventions (reverse-DNS key, injectable defaults, `try?` returning a safe empty default,
/// millisecond dates because `createdAt` carries replay order).
///
/// **Both halves are backup-included**, which is the one place this store deliberately diverges
/// from the `DocumentContentCacheStore` template it otherwise copies: that cache is excluded from
/// backups because it is re-downloadable from the user's own server, and these bytes are the
/// opposite — until the upload lands they exist nowhere else, exactly like the draft text beside
/// them. So `ensureDirectory` must **not** set `isExcludedFromBackup`, and there is no eviction
/// here: `contentCacheEvictions` selects by recency, which for this store would silently delete
/// the only copy of a photo the user is still looking at.
final class PendingAttachmentStore {
    private static let attachmentsKey = "dev.llun.Schrift.pendingAttachments"
    /// Where an undecodable blob is moved before the live key is reused, so a schema slip costs
    /// the records' *usability* rather than their bytes.
    private static let quarantineKey = "dev.llun.Schrift.pendingAttachments.unreadable"

    private let userDefaults: UserDefaults
    private let directory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        userDefaults: UserDefaults = .standard,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.userDefaults = userDefaults
        self.fileManager = fileManager
        self.directory =
            directory
            ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.llun.Schrift/PendingAttachments", isDirectory: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    // MARK: - Records

    func save(_ attachment: PendingAttachment) {
        // Before the first write of a session that found the blob unreadable — otherwise this
        // `loadAll` reads `[:]` and the `persist` below silently overwrites records we could not
        // decode but whose bytes are still someone's only copy of a photo.
        quarantineUnreadableDataIfNeeded()
        var attachments = loadAll()
        attachments[attachment.localID.uuidString] = attachment
        persist(attachments)
    }

    func attachment(for localID: UUID) -> PendingAttachment? {
        loadAll()[localID.uuidString]
    }

    /// Every record naming a document, oldest first.
    func attachments(forDocumentID documentID: UUID) -> [PendingAttachment] {
        loadAll().values
            .filter { $0.documentID == documentID }
            .sorted { orderedByAttachmentCreation($0, $1) }
    }

    /// Oldest first — the order a replay uploads them in. The `localID` tie-break makes that
    /// order deterministic rather than approximate: `values` has no defined order, Swift's
    /// `sorted` is not stable, and `Date()` is not monotonic across a clock change.
    func allAttachments() -> [PendingAttachment] {
        loadAll().values.sorted { orderedByAttachmentCreation($0, $1) }
    }

    /// Removes the record **and** its bytes — the two are only ever meaningful together.
    func remove(localID: UUID) {
        remove(localIDs: [localID])
    }

    /// Remove several records in **one** write. Every method here is a read-modify-write of a
    /// single blob, so a loop leaves intermediate states on disk; one write makes a half-removed
    /// set unrepresentable, matching `PendingDocumentCreateStore.remove(localIDs:)`.
    func remove(localIDs: [UUID]) {
        guard !localIDs.isEmpty else { return }
        quarantineUnreadableDataIfNeeded()
        var attachments = loadAll()
        for localID in localIDs { attachments[localID.uuidString] = nil }
        // Records first, then bytes — the mirror of `saveData`'s rule, and for the same reason.
        // Deleting the files first could leave a record pointing at bytes that no longer exist;
        // this way a failure leaves bytes with no record, which is inert and collectable. That
        // only holds if the write is actually known to have landed, which is why `persist`
        // reports rather than swallowing: an unreported failure would delete the bytes anyway and
        // reach the very state the ordering exists to prevent, just from the other side.
        guard persist(attachments) else { return }
        for localID in localIDs { removeData(for: localID) }
    }

    /// Drops every record for a document, bytes included — used by the delete and
    /// discard-the-local-work paths, where the placeholders go with the content that named them.
    func removeAll(forDocumentID documentID: UUID) {
        remove(localIDs: attachments(forDocumentID: documentID).map(\.localID))
    }

    /// There is stored data and it does not decode — so the records are **unknown**, which is a
    /// different thing from "there are none".
    ///
    /// Load-bearing for the same reason it is on the create store: the replay collects a record
    /// whose placeholder no document references any more, and reading a corrupt blob as "no
    /// records exist" would instead make every *surviving* placeholder record-less — each one a
    /// document whose saves are held with no way to answer but deleting the image. **Owed by the
    /// replay work**: that pass must refuse to run at all while this is true. Nothing consults it
    /// yet.
    ///
    /// **Sticky across launches**, like the create store's and unlike `PendingDraftStore`'s
    /// detection-only flag. Quarantining preserves the bytes, but on its own the live key comes
    /// back clean next launch and the pass resumes collecting — so a surviving quarantine keeps
    /// answering true.
    var holdsUnreadableData: Bool {
        userDefaults.data(forKey: Self.quarantineKey) != nil || liveDataIsUnreadable
    }

    // MARK: - Bytes

    /// Writes the prepared JPEG. Returns false when the write fails, which the caller must treat
    /// as "the photo was not queued" — bytes are written **before** the record, so a failure here
    /// leaves nothing behind, and a crash between the two leaves orphaned bytes (inert, collected
    /// by the pass) rather than a record whose photo does not exist.
    @discardableResult
    func saveData(_ data: Data, for localID: UUID) -> Bool {
        ensureDirectory()
        do {
            try data.write(to: fileURL(for: localID), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func data(for localID: UUID) -> Data? {
        try? Data(contentsOf: fileURL(for: localID))
    }

    // MARK: - Private

    private func fileURL(for localID: UUID) -> URL {
        directory.appendingPathComponent("\(localID.uuidString.lowercased()).jpg")
    }

    private func removeData(for localID: UUID) {
        try? fileManager.removeItem(at: fileURL(for: localID))
    }

    private func ensureDirectory() {
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Deliberately *not* excluded from backup — see the type's doc comment. These bytes are
        // unsaved work, not a re-downloadable cache.
    }

    /// Whether the **live** key currently holds something that won't decode. Distinct from
    /// `holdsUnreadableData`, which is sticky: this one drives *quarantining*, and reading the
    /// sticky answer here would make the first write after a quarantine move the new, healthy
    /// blob aside as well.
    private var liveDataIsUnreadable: Bool {
        guard let data = userDefaults.data(forKey: Self.attachmentsKey) else { return false }
        return (try? decoder.decode([String: PendingAttachment].self, from: data)) == nil
    }

    /// Move an undecodable blob aside so the next write cannot silently destroy it.
    private func quarantineUnreadableDataIfNeeded() {
        guard liveDataIsUnreadable, let data = userDefaults.data(forKey: Self.attachmentsKey) else { return }
        // First corruption wins: a second would mean the store was already rebuilt after the
        // first, so the earlier blob is the one still holding records nothing else has.
        if userDefaults.data(forKey: Self.quarantineKey) == nil {
            userDefaults.set(data, forKey: Self.quarantineKey)
        }
        userDefaults.removeObject(forKey: Self.attachmentsKey)
    }

    private func loadAll() -> [String: PendingAttachment] {
        guard let data = userDefaults.data(forKey: Self.attachmentsKey),
            let attachments = try? decoder.decode([String: PendingAttachment].self, from: data)
        else {
            return [:]
        }
        return attachments
    }

    @discardableResult
    private func persist(_ attachments: [String: PendingAttachment]) -> Bool {
        guard let data = try? encoder.encode(attachments) else { return false }
        userDefaults.set(data, forKey: Self.attachmentsKey)
        return true
    }
}

/// Replay order: `createdAt`, then `localID` so equal timestamps still order the same way on
/// every run. Mirrors `orderedByCreation` for pending creates.
func orderedByAttachmentCreation(_ lhs: PendingAttachment, _ rhs: PendingAttachment) -> Bool {
    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
    return lhs.localID.uuidString < rhs.localID.uuidString
}

/// What the editor should render for a queued photo's placeholder block.
///
/// `.missing` is the escape hatch as much as a state: a placeholder whose record or bytes are
/// gone — hand-authored content, a corrupted store, another account's photo — holds the
/// document's saves, and the only way out is removing the block. A card that says so, with a
/// Remove button, is what makes that reachable.
enum PendingAttachmentDisplay: Equatable {
    case pending(Data)
    case failed(Data)
    case missing
    /// The record is fine and its bytes are on disk — this session just cannot say **whose**
    /// they are, because `SessionStore.noteSessionCookiesReplaced` left the identity unknown
    /// and nothing has re-learned it yet.
    ///
    /// Distinct from `.missing` because the two differ in the only way that matters here:
    /// `.missing` states the photo is gone and offers **Remove**, which deletes the only copy
    /// of it that exists. Saying that over bytes that are present is both false and
    /// destructive, and it contradicts the rule `isAttachmentReplayable` states for exactly
    /// this condition — "kept, silent, and untouched … Dormant means no requests *and* no
    /// deletion". Nor may the photo simply be shown: an unknown session is not *proof* of the
    /// same account, and a co-author's queued photo must not appear in somebody else's.
    /// So: say nothing about it, offer nothing, and wait to be told who we are.
    case unattributable
}
