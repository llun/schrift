import CoreGraphics
import Foundation

/// Where a reader left a document: the block that was at the top of the screen.
///
/// Block ids are minted fresh by every parse (`parseEditorBlocks`), so an id only survives
/// within one view model's life — it matches when a screen is rebuilt over the same session,
/// never across a relaunch. The `fingerprint` is what carries the position across launches
/// and across edits made elsewhere: it names the block by *what it says*, so a document that
/// gained or lost paragraphs above it still resolves to the same passage. `blockIndex` only
/// breaks ties between blocks that say the same thing (two identical bullets).
///
/// No document text is stored — the fingerprint is a hash of a normalised prefix of it — so
/// the record is a position, not content.
struct ReadingPosition: Codable, Equatable, Sendable {
    var blockID: UUID
    var fingerprint: String
    var blockIndex: Int
    var savedAt: Date
}

/// The most positions kept; the least recently read go first.
let readingPositionCapacity = 200

/// A block at or before this index (0-based, exclusive upper bound) counts as "near the top":
/// the first screenful already shows it, so restoring would only move the page by a line or
/// two and the saved entry is cleared instead.
let readingPositionNearTopBlockCount = 2

/// How much of a block's text feeds its fingerprint.
private let readingPositionFingerprintLength = 160

/// A short, stable name for a block's content, or `""` when the block has nothing that could
/// name it (a divider, an empty paragraph).
///
/// FNV-1a over the UTF-8 of the normalised prefix — `Hashable` is out because it is seeded per
/// process, and this has to match on the next launch. Normalising (trim, collapse runs of
/// whitespace, lowercase) keeps a retyped space or a capitalisation fix from orphaning the
/// position; only the first `readingPositionFingerprintLength` characters count, so editing the
/// tail of a long paragraph does not either.
func readingPositionFingerprint(of block: EditorBlock) -> String {
    let source: String
    switch block.kind {
    case .divider:
        return ""
    case .image(_, let url), .attachment(_, let url):
        source = url
    default:
        // Bounded before normalising, so a huge code block is not split in full just to
        // keep its first line.
        source = String(block.text.prefix(readingPositionFingerprintLength * 4))
    }
    let normalized = String(
        source.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
            .prefix(readingPositionFingerprintLength))
    guard !normalized.isEmpty else { return "" }
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in normalized.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return String(hash, radix: 16)
}

/// The UserDefaults key of one document's position, scoped by server so that the same
/// document id on two servers (or a server the user signs out of and into again as someone
/// else, once the store is cleared) can never read the other's.
func readingPositionKey(serverOrigin: String, documentID: UUID) -> String {
    var origin = serverOrigin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    while origin.hasSuffix("/") { origin.removeLast() }
    return "\(origin)|\(documentID.uuidString.lowercased())"
}

/// `entries` with `position` stored under `key`, trimmed to the `limit` most recently saved.
///
/// The position being recorded always survives, even when its `savedAt` is older than every
/// other entry's (a clock that moved backwards); the least recently saved of the rest are
/// dropped, ties broken by key so the outcome never depends on dictionary order.
func recordingReadingPosition(
    _ position: ReadingPosition, forKey key: String, in entries: [String: ReadingPosition],
    limit: Int = readingPositionCapacity
) -> [String: ReadingPosition] {
    let others = entries.filter { $0.key != key }.sorted { lhs, rhs in
        if lhs.value.savedAt != rhs.value.savedAt { return lhs.value.savedAt > rhs.value.savedAt }
        return lhs.key < rhs.key
    }
    var result: [String: ReadingPosition] = [:]
    for entry in others.prefix(max(limit, 1) - 1) { result[entry.key] = entry.value }
    result[key] = position
    return result
}

/// What reopening a document should do about its saved position.
enum ReadingPositionRestore: Equatable {
    case none
    case restore(blockID: UUID)
}

/// The index of the block `saved` refers to in `blocks`: by id first, else by fingerprint
/// (the nearest to the old index when several say the same thing), else nil.
func readingPositionTargetIndex(saved: ReadingPosition, blocks: [EditorBlock]) -> Int? {
    if let index = blocks.firstIndex(where: { $0.id == saved.blockID }) { return index }
    guard !saved.fingerprint.isEmpty else { return nil }
    let candidates = blocks.indices.filter { readingPositionFingerprint(of: blocks[$0]) == saved.fingerprint }
    return candidates.min { (abs($0 - saved.blockIndex), $0) < (abs($1 - saved.blockIndex), $1) }
}

/// Whether to scroll a reopened document, and to which block.
///
/// Nothing to do without a saved position, with an empty document, when neither the id nor
/// the fingerprint finds the block (a rewritten document starts at the top rather than at a
/// guess), or when the block is within the first `nearTopBlockCount` blocks.
func readingPositionRestore(
    saved: ReadingPosition?, blocks: [EditorBlock], nearTopBlockCount: Int = readingPositionNearTopBlockCount
) -> ReadingPositionRestore {
    guard let saved, let index = readingPositionTargetIndex(saved: saved, blocks: blocks) else { return .none }
    return index < nearTopBlockCount ? .none : .restore(blockID: blocks[index].id)
}

/// What leaving a document should do to its saved position.
enum ReadingPositionUpdate: Equatable {
    /// Nothing known about where the reader is; leave the stored position alone.
    case keep
    /// The reader is at the top: forget any earlier position.
    case clear
    case save(blockID: UUID, fingerprint: String, blockIndex: Int)
}

func readingPositionUpdate(
    topVisibleBlockID: UUID?, blocks: [EditorBlock], nearTopBlockCount: Int = readingPositionNearTopBlockCount
) -> ReadingPositionUpdate {
    guard let topVisibleBlockID, let index = blocks.firstIndex(where: { $0.id == topVisibleBlockID }) else {
        return .keep
    }
    guard index >= nearTopBlockCount else { return .clear }
    return .save(
        blockID: topVisibleBlockID, fingerprint: readingPositionFingerprint(of: blocks[index]), blockIndex: index)
}

/// The block nearest the top edge of the viewport that still shows some of itself, from the
/// frames the surfaces report in the scroll view's coordinate space. Layout is a single
/// column, so the smallest `minY` among the blocks not yet scrolled off is the first one —
/// no block order is needed.
func topVisibleBlockID(in frames: [UUID: CGRect]) -> UUID? {
    var best: (id: UUID, minY: CGFloat)?
    for (id, frame) in frames where frame.maxY > 0 {
        if let current = best, current.minY <= frame.minY { continue }
        best = (id, frame.minY)
    }
    return best?.id
}

/// UserDefaults-backed reading positions, one per document, keyed by server origin and
/// document id (`readingPositionKey`) and capped to the `limit` most recently read.
///
/// Like the other stores it never throws to callers: an unreadable blob reads as empty and is
/// replaced by the next save. It is **cleared on sign-out** (RootView's `onSignOut`, next to the
/// content caches): a position is not unsynced work, and it is only meaningful against the
/// content the signed-in account could read.
final class ReadingPositionStore {
    private static let key = "dev.llun.Schrift.readingPositions"

    private let userDefaults: UserDefaults
    private let limit: Int
    private let now: () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        userDefaults: UserDefaults = .standard, limit: Int = readingPositionCapacity,
        now: @escaping () -> Date = Date.init
    ) {
        self.userDefaults = userDefaults
        self.limit = limit
        self.now = now
        // Millisecond precision, like the other recency-carrying stores: whole seconds would
        // tie same-second saves and make the eviction order arbitrary.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    func position(serverOrigin: String, documentID: UUID) -> ReadingPosition? {
        loadEntries()[readingPositionKey(serverOrigin: serverOrigin, documentID: documentID)]
    }

    func save(
        blockID: UUID, fingerprint: String, blockIndex: Int, serverOrigin: String, documentID: UUID
    ) {
        let position = ReadingPosition(
            blockID: blockID, fingerprint: fingerprint, blockIndex: blockIndex, savedAt: now())
        let key = readingPositionKey(serverOrigin: serverOrigin, documentID: documentID)
        saveEntries(recordingReadingPosition(position, forKey: key, in: loadEntries(), limit: limit))
    }

    func remove(serverOrigin: String, documentID: UUID) {
        var entries = loadEntries()
        guard entries.removeValue(forKey: readingPositionKey(serverOrigin: serverOrigin, documentID: documentID)) != nil
        else { return }
        saveEntries(entries)
    }

    func removeAll() {
        userDefaults.removeObject(forKey: Self.key)
    }

    private func loadEntries() -> [String: ReadingPosition] {
        guard let data = userDefaults.data(forKey: Self.key),
            let entries = try? decoder.decode([String: ReadingPosition].self, from: data)
        else { return [:] }
        return entries
    }

    private func saveEntries(_ entries: [String: ReadingPosition]) {
        guard let data = try? encoder.encode(entries) else { return }
        userDefaults.set(data, forKey: Self.key)
    }
}
