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
/// confined to `@MainActor` callers. Entries hold full user document text —
/// never log or print their contents.
final class DocumentContentCacheStore {
    private let directory: URL
    private let fileManager: FileManager
    private let limit: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directory: URL? = nil, fileManager: FileManager = .default, limit: Int = 50) {
        self.fileManager = fileManager
        self.directory =
            directory
            ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.llun.Schrift/ContentCache", isDirectory: true)
        self.limit = limit
        // Millisecond precision, matching PendingDraftStore: plain .iso8601
        // truncates to whole seconds.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    func content(for documentID: UUID) -> CachedDocumentContent? {
        guard let data = try? Data(contentsOf: fileURL(for: documentID)) else { return nil }
        return try? decoder.decode(CachedDocumentContent.self, from: data)
    }

    func save(_ entry: CachedDocumentContent) {
        guard let data = try? encoder.encode(entry) else { return }
        ensureDirectory()
        try? data.write(to: fileURL(for: entry.documentID), options: .atomic)
        evictBeyondLimit()
    }

    func remove(documentID: UUID) {
        try? fileManager.removeItem(at: fileURL(for: documentID))
    }

    func removeAll() {
        try? fileManager.removeItem(at: directory)
    }

    // MARK: - Private

    private func fileURL(for documentID: UUID) -> URL {
        directory.appendingPathComponent("\(documentID.uuidString.lowercased()).json")
    }

    private func ensureDirectory() {
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Cached content is re-downloadable from the user's own server; full
        // document bodies must not flow into iCloud/device backups. Unsaved
        // work still backs up via PendingDraftStore.
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// The eviction index comes from file modification dates: every path that
    /// bumps an entry's `syncedAt` rewrites its file at that same moment, so
    /// mtime tracks `syncedAt` and building the index never reads or decodes
    /// file contents.
    private func evictBeyondLimit() {
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
            remove(documentID: id)
        }
    }
}
