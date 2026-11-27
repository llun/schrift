import Foundation

/// One row of the content-cache eviction index. Kept `Equatable` so the
/// selection logic below is a top-level pure function testable without the
/// filesystem (mirroring `addingRecentServer`/`addingRecentSearch`).
struct ContentCacheIndexEntry: Equatable {
    let id: UUID
    let syncedAt: Date
}

/// IDs to evict so that only the `limit` most-recently-synced entries remain,
/// ordered most-recently-evictable first (i.e. newest of the evicted first).
func contentCacheEvictions(index: [ContentCacheIndexEntry], limit: Int) -> [UUID] {
    guard index.count > limit else { return [] }
    return
        index
        .sorted { $0.syncedAt > $1.syncedAt }
        .dropFirst(limit)
        .map(\.id)
}

/// A previously-synced copy of a document's content. `syncedAt` is the client
/// wall-clock of the successful fetch/save that produced it (used only for
/// eviction ordering, never for freshness).
///
/// `serverUpdatedAt` is the server's own `updated_at` when this copy came from a
/// fetch, and nil when it came from a void save (the save PATCHes return no
/// timestamp). It exists so a cache-derived draft baseline can compare
/// server-clock-to-server-clock — the original "no server timestamp" objection
/// was about mixing the client and server clocks, which a server-clock-only
/// comparison does not do; nil truthfully means "unknown after a void save" and
/// the entry's `markdown` still anchors a content comparison. It is Optional, so
/// entries written before the field existed decode as nil.
struct CachedDocumentContent: Codable, Equatable, Sendable {
    let documentID: UUID
    let title: String?
    let markdown: String
    let syncedAt: Date
    let serverUpdatedAt: Date?

    init(
        documentID: UUID,
        title: String?,
        markdown: String,
        syncedAt: Date,
        serverUpdatedAt: Date? = nil
    ) {
        self.documentID = documentID
        self.title = title
        self.markdown = markdown
        self.syncedAt = syncedAt
        self.serverUpdatedAt = serverUpdatedAt
    }
}

/// On-disk cache of document content: one JSON file per document under
/// Application Support (durable — "keep local" means it survives; Caches
/// would be OS-reclaimable). Stateless: the eviction index is derived from
/// disk on every call, so independently constructed instances over the same
/// directory stay consistent. Like the other stores it never throws and is
/// confined to `@MainActor` callers (the closure `allContentsReader()` returns is
/// the one piece meant to run elsewhere). Entries hold full user document text —
/// never log or print their contents.
///
/// One folder per account under `root`, resolved on every call from `SignedInUserStore`, so a
/// store built before an account change reads the new account's folder and never the old one's,
/// and nothing is wiped when the account changes. With no account known it reads and writes
/// nothing. `directory` pins a single folder instead (tests).
final class DocumentContentCacheStore {
    static let defaultRoot = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("dev.llun.Schrift/ContentCache", isDirectory: true)
    private static let accountFoldersKey = "dev.llun.Schrift.contentCache.accountFolders"

    private let pinnedDirectory: URL?
    private let root: URL
    private let signedInUser: SignedInUserStore
    private let fileManager: FileManager
    private let limit: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        directory: URL? = nil, root: URL = DocumentContentCacheStore.defaultRoot,
        userDefaults: UserDefaults = .standard, fileManager: FileManager = .default, limit: Int = 50
    ) {
        self.fileManager = fileManager
        self.pinnedDirectory = directory
        self.root = root
        self.signedInUser = SignedInUserStore(userDefaults: userDefaults)
        self.limit = limit
        // Millisecond precision, matching PendingDraftStore: plain .iso8601
        // truncates to whole seconds.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        self.encoder = encoder
        self.decoder = Self.makeDecoder()
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    /// Run once, at launch before any sign-in can name an account: bodies an earlier build kept
    /// in the flat `root` move into the account signed in at that moment. With none known they are
    /// deleted — a re-downloadable cache, not unsent work. Files an older build writes there later
    /// are never read, and go with the sign-out wipe of `root`.
    static func moveEarlierBodiesIntoAccountFolder(
        root: URL = defaultRoot, userDefaults: UserDefaults = .standard, fileManager: FileManager = .default
    ) {
        guard !userDefaults.bool(forKey: accountFoldersKey) else { return }
        let store = DocumentContentCacheStore(root: root, userDefaults: userDefaults, fileManager: fileManager)
        let files = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            if let directory = store.directory {
                store.ensureDirectory(directory)
                try? fileManager.moveItem(at: file, to: directory.appendingPathComponent(file.lastPathComponent))
            } else {
                try? fileManager.removeItem(at: file)
            }
        }
        userDefaults.set(true, forKey: accountFoldersKey)
    }

    func content(for documentID: UUID) -> CachedDocumentContent? {
        guard let url = fileURL(for: documentID), let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(CachedDocumentContent.self, from: data)
    }

    /// `session` is the sign-in the body was fetched or saved under: a response that lands after
    /// the session changed is written nowhere, so it can neither reach another account's folder
    /// nor come back after a sign-out wiped it.
    func save(_ entry: CachedDocumentContent, during session: SignedInSession? = nil) {
        if let session, pinnedDirectory == nil, !session.isStill(signedInUser.session) { return }
        guard let directory, let data = try? encoder.encode(entry) else { return }
        ensureDirectory(directory)
        try? data.write(to: Self.fileURL(for: entry.documentID, in: directory), options: .atomic)
        evictBeyondLimit(in: directory)
    }

    /// Every entry on disk, in no particular order. A file that no longer
    /// decodes is skipped rather than failing the whole listing, the same
    /// answer `content(for:)` gives for it.
    func allContents() -> [CachedDocumentContent] {
        guard let directory else { return [] }
        return Self.readAllContents(in: directory, fileManager: fileManager, decoder: decoder)
    }

    /// `allContents()` as a closure that may run on any thread, for a caller that
    /// must keep the whole-directory read and decode — up to `limit` files — off
    /// the main actor (the Attachments list). It captures only the directory, which
    /// is `Sendable`, and builds its own decoder at call time; it reads through
    /// `FileManager.default`, which is what every production store uses. The store
    /// is stateless over its directory, so this answers what `allContents()` would
    /// at the moment it runs, for the account signed in when it was made.
    func allContentsReader() -> @Sendable () -> [CachedDocumentContent] {
        guard let directory else { return { [] } }
        return {
            DocumentContentCacheStore.readAllContents(
                in: directory, fileManager: .default, decoder: DocumentContentCacheStore.makeDecoder())
        }
    }

    private static func readAllContents(
        in directory: URL, fileManager: FileManager, decoder: JSONDecoder
    ) -> [CachedDocumentContent] {
        guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return urls.compactMap { url in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(CachedDocumentContent.self, from: data)
        }
    }

    func remove(documentID: UUID) {
        guard let url = fileURL(for: documentID) else { return }
        try? fileManager.removeItem(at: url)
    }

    /// Every account's bodies, not only the signed-in one's: this is the sign-out wipe.
    func removeAll() {
        try? fileManager.removeItem(at: pinnedDirectory ?? root)
    }

    // MARK: - Private

    private var directory: URL? {
        pinnedDirectory
            ?? signedInUser.userID.map { root.appendingPathComponent($0.uuidString.lowercased(), isDirectory: true) }
    }

    private func fileURL(for documentID: UUID) -> URL? {
        directory.map { Self.fileURL(for: documentID, in: $0) }
    }

    private static func fileURL(for documentID: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(documentID.uuidString.lowercased()).json")
    }

    private func ensureDirectory(_ directory: URL) {
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Cached content is re-downloadable from the user's own server; full
        // document bodies must not flow into iCloud/device backups. Unsaved
        // work still backs up via PendingDraftStore. The root too, so nothing
        // written beside the account folders (an older build's flat files) is
        // backed up either.
        for folder in Set([directory, pinnedDirectory == nil ? root : directory]) {
            var url = folder
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
    }

    /// The eviction index comes from file modification dates: every path that
    /// bumps an entry's `syncedAt` rewrites its file at that same moment, so
    /// mtime tracks `syncedAt` and building the index never reads or decodes
    /// file contents.
    private func evictBeyondLimit(in directory: URL) {
        guard
            let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )
        else { return }
        let index = urls.compactMap { url -> ContentCacheIndexEntry? in
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
            let date =
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            return ContentCacheIndexEntry(id: id, syncedAt: date)
        }
        for id in contentCacheEvictions(index: index, limit: limit) {
            try? fileManager.removeItem(at: Self.fileURL(for: id, in: directory))
        }
    }
}
