import Foundation

/// Remembers the decoded form of the one UserDefaults blob a store keeps, so a read that finds
/// the **same bytes** it decoded last time costs a byte comparison instead of a JSON decode.
///
/// `PendingDraftStore` and `DocumentChildrenCacheStore` each keep everything in a single blob
/// (every draft body; up to 100 parents' children lists), and every read used to decode all of
/// it — several times per autosave on the main actor, and per keystroke in live mode, where
/// `canEngageLiveEditing` reads the stored draft.
///
/// **UserDefaults stays the only source of truth; this is a memo of `decode(bytes)`, never a
/// copy of the store.** Every read still fetches the current bytes and reuses the cached value
/// only when they are byte-for-byte what was decoded. Three things follow, each deliberate:
/// - **No staleness, whoever writes.** Production builds several store instances over
///   `.standard` (the save coordinator, editor and Pages view models), and tests write raw
///   bytes to the key, wipe it with `removePersistentDomain`, and run many suites one after the
///   other. A mirror of the *store* would need invalidating on every one of those; a memo keyed
///   on the bytes cannot go stale, so one slot can be shared by every instance and every suite.
/// - **Exactly the old semantics, including corrupt data.** An undecodable blob is memoized as
///   undecodable (`nil`) — still "unknown, not absent" for `holdsUnreadableData`, still read as
///   empty by the store's load, so a later write replaces it exactly as before.
/// - **Writes do not seed it.** A write encodes the store's whole dictionary; seeding the memo
///   with the dictionary it encoded would hand readers values that never went through the
///   decoder, and the `.millisecondsSince1970` date round trip is not bit-exact (a baseline's
///   `serverUpdatedAt` could then compare differently in-process than after a relaunch). So the
///   first read after a write decodes once, and every read until the next write is free.
///
/// Lock-guarded rather than actor-isolated because the stores are synchronous and may be
/// called from any isolation domain; the decode itself runs outside the lock.
final class DecodedBlobMemo<Value: Sendable>: @unchecked Sendable {
    private struct Entry {
        let bytes: Data
        /// nil when `bytes` did not decode.
        let value: Value?
    }

    private let lock = NSLock()
    private var entry: Entry?

    /// `decode(data)`, reusing the previous answer when `data` equals the bytes it was computed
    /// from. Always called with the bytes the caller just read, never a remembered copy.
    func value(for data: Data, decode: (Data) -> Value?) -> Value? {
        lock.lock()
        if let entry, entry.bytes == data {
            let value = entry.value
            lock.unlock()
            return value
        }
        lock.unlock()

        let decoded = decode(data)

        lock.lock()
        // Whichever racing reader stores last wins; either pair is internally consistent,
        // because the value is always the decode of the bytes stored beside it.
        entry = Entry(bytes: data, value: decoded)
        lock.unlock()
        return decoded
    }
}
