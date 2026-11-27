import Foundation
import Synchronization

/// One row of the attachment-cache eviction index. `Equatable` so the selection
/// below is a top-level pure function testable without the filesystem, exactly
/// like `contentCacheEvictions`.
struct AttachmentCacheIndexEntry: Equatable {
    let fileName: String
    let byteSize: Int
    /// File modification date, which this cache bumps on *read* (see
    /// `AttachmentCacheStore.cachedFileURL(for:)`).
    let lastUsedAt: Date
}

/// File names to evict so that at most `countLimit` entries and `byteLimit`
/// total bytes remain, dropping least-recently-used first.
///
/// Two caps rather than the content cache's one, because attachment sizes vary
/// by orders of magnitude: a count alone would let a hundred videos fill the
/// disk, and a byte cap alone would let thousands of tiny files accumulate.
///
/// Two deliberate properties:
///   * **The most-recently-used entry is never evicted.** `store` runs this
///     immediately after writing, so evicting the file just written would make
///     the loader re-download it on every render, forever.
///   * **The walk is greedy, not prefix-truncating.** An entry that doesn't fit
///     is dropped and *older, smaller* entries may still be kept, which keeps a
///     single large attachment from evicting everything behind it. That trades
///     strict LRU ordering for cache utility; it is a cache, so utility wins.
func attachmentCacheEvictions(index: [AttachmentCacheIndexEntry], countLimit: Int, byteLimit: Int) -> [String] {
    // Ties on mtime are real (two files written in the same millisecond), so
    // break them by name to keep the answer deterministic.
    let ordered = index.sorted {
        $0.lastUsedAt == $1.lastUsedAt ? $0.fileName < $1.fileName : $0.lastUsedAt > $1.lastUsedAt
    }
    var keptCount = 0
    var keptBytes = 0
    var evictions: [String] = []
    for (position, entry) in ordered.enumerated() {
        let fits = keptCount < countLimit && keptBytes + entry.byteSize <= byteLimit
        if position == 0 || fits {
            keptCount += 1
            keptBytes += entry.byteSize
        } else {
            evictions.append(entry.fileName)
        }
    }
    return evictions
}

/// On-disk cache of downloaded attachment bytes: one file per attachment under
/// Application Support, named for the server's own storage key.
///
/// Modeled on `DocumentContentCacheStore` — durable rather than in Caches (an
/// attachment the user opened offline must still be there next launch),
/// backup-excluded (re-downloadable from the user's own server), stateless over
/// its directory so independently constructed instances stay consistent, and
/// never throwing to callers.
///
/// Two differences from the content cache, both deliberate:
///   * recency is **last use**, not last write — attachments are read-hot and a
///     write-recency cache would evict the one the user keeps reopening;
///   * eviction is capped by bytes as well as count (`attachmentCacheEvictions`).
///
/// Entries hold document content the user may consider private: never log a
/// path or its bytes, and `RootView`'s sign-out closure clears the whole store.
/// A write that started before a clear is refused (`generation`): the file name
/// carries no account, so a download finishing after sign-out would hand the
/// next account this one's bytes with no server access check.
final class AttachmentCacheStore {
    /// Per directory, bumped by every `removeAll` and shared by every instance, since sign-out clears through
    /// a fresh one. Process-wide is enough: no download outlives the process. Also serializes write vs clear.
    private static let generations = Mutex<[String: Int]>([:])

    private let directory: URL
    /// The `generations` key: one folder spelled two ways (a symlink, a `..`) must share one generation.
    private let generationKey: String
    private let fileManager: FileManager
    private let countLimit: Int
    private let byteLimit: Int

    init(
        directory: URL? = nil,
        fileManager: FileManager = .default,
        countLimit: Int = 100,
        byteLimit: Int = 200 * 1024 * 1024
    ) {
        self.fileManager = fileManager
        self.directory =
            directory
            ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.llun.Schrift/AttachmentCache", isDirectory: true)
        self.generationKey = Self.canonicalPath(of: self.directory, fileManager: fileManager)
        self.countLimit = countLimit
        self.byteLimit = byteLimit
    }

    /// The cached file, or nil when this attachment has not been downloaded.
    ///
    /// Not a pure accessor: a hit **bumps the file's modification date**, which
    /// is what makes eviction least-recently-*used* rather than -written. The
    /// touch is best-effort — a failure costs recency accuracy, never a hit.
    func cachedFileURL(for display: AttachmentDisplay) -> URL? {
        guard let url = fileURL(for: display), fileManager.fileExists(atPath: url.path) else { return nil }
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    /// Read when a write starts that `store` finishes later (a download), and passed back as `ifGeneration`.
    var generation: Int { Self.generations.withLock { $0[generationKey, default: 0] } }

    /// Writes the bytes and returns the file they landed in, or nil if the write
    /// failed (a full disk, a name the store refuses) or `ifGeneration` predates
    /// a `removeAll`. A nil return is not an error the user needs to see: the
    /// bytes are still in memory for this render, only the offline copy is lost.
    func store(_ data: Data, for display: AttachmentDisplay, ifGeneration generation: Int) -> URL? {
        guard let url = fileURL(for: display),
            write(ifGeneration: generation, { (try? data.write(to: url, options: .atomic)) != nil })
        else { return nil }
        evictBeyondLimits()
        return url
    }

    /// `store` for bytes already on disk (a streamed video or audio download): moves the file in.
    /// The source is consumed either way.
    func store(movingFileAt source: URL, for display: AttachmentDisplay, ifGeneration generation: Int) -> URL? {
        guard let url = fileURL(for: display),
            write(
                ifGeneration: generation,
                {
                    try? fileManager.removeItem(at: url)
                    return (try? fileManager.moveItem(at: source, to: url)) != nil
                })
        else {
            try? fileManager.removeItem(at: source)
            return nil
        }
        evictBeyondLimits()
        return url
    }

    func removeAll() {
        Self.generations.withLock {
            $0[generationKey, default: 0] += 1
            try? fileManager.removeItem(at: directory)
        }
    }

    // MARK: - Private

    /// `url` with symlinks resolved, though it may not exist yet (`removeAll` deletes it, and
    /// `resolvingSymlinksInPath` leaves a missing path untouched): resolves its deepest existing ancestor.
    private static func canonicalPath(of url: URL, fileManager: FileManager) -> String {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while !fileManager.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        return missing.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
    }

    /// Runs `write` under the generation lock, unless the cache was cleared since `generation` was read.
    private func write(ifGeneration generation: Int, _ write: () -> Bool) -> Bool {
        Self.generations.withLock { generations in
            guard generation == generations[generationKey, default: 0] else { return false }
            ensureDirectory()
            return write()
        }
    }

    /// The name is `attachmentCacheFileName(for:)` — **both** server ids, built
    /// from the classifier's validated UUIDs and extension, never from the
    /// author-controlled label. Keying on the file id alone would let one
    /// document's cached bytes answer another document's link with no request,
    /// and so with no server access check.
    ///
    /// `AttachmentDisplay` is a freely constructible value type, so this layer
    /// re-checks rather than trusting that the classifier vouched for this one:
    /// a name carrying a separator or a `..` would escape the cache directory.
    private func fileURL(for display: AttachmentDisplay) -> URL? {
        let name = attachmentCacheFileName(for: display)
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else { return nil }
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    private func ensureDirectory() {
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Attachment bytes are re-downloadable from the user's own server and
        // can be large; they must not inflate iCloud/device backups.
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private func evictBeyondLimits() {
        guard
            let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
            )
        else { return }
        let index = urls.map { url -> AttachmentCacheIndexEntry in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return AttachmentCacheIndexEntry(
                fileName: url.lastPathComponent,
                byteSize: values?.fileSize ?? 0,
                lastUsedAt: values?.contentModificationDate ?? .distantPast)
        }
        for name in attachmentCacheEvictions(index: index, countLimit: countLimit, byteLimit: byteLimit) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name, isDirectory: false))
        }
    }
}
