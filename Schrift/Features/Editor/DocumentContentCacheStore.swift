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
    return index
        .sorted { $0.syncedAt > $1.syncedAt }
        .dropFirst(limit)
        .map(\.id)
}
