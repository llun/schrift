import XCTest
@testable import Schrift

final class DocumentContentCacheStoreTests: XCTestCase {
    // MARK: - contentCacheEvictions (pure, filesystem-free)

    private func entry(_ n: Int, minutesAgo: Int) -> ContentCacheIndexEntry {
        ContentCacheIndexEntry(
            id: UUID(uuidString: String(format: "%08d-0000-0000-0000-000000000000", n))!,
            syncedAt: Date(timeIntervalSince1970: 1_000_000 - TimeInterval(minutesAgo * 60))
        )
    }

    func testEvictionsAtOrUnderLimitReturnsEmpty() {
        XCTAssertEqual(contentCacheEvictions(index: [], limit: 2), [])
        XCTAssertEqual(contentCacheEvictions(index: [entry(1, minutesAgo: 0)], limit: 2), [])
        XCTAssertEqual(
            contentCacheEvictions(index: [entry(1, minutesAgo: 0), entry(2, minutesAgo: 5)], limit: 2),
            []
        )
    }

    func testEvictionsReturnsOldestBeyondLimit() {
        let index = [entry(1, minutesAgo: 10), entry(2, minutesAgo: 0), entry(3, minutesAgo: 20), entry(4, minutesAgo: 5)]
        // Keep the 2 newest (2, 4); evict 1 and 3.
        XCTAssertEqual(Set(contentCacheEvictions(index: index, limit: 2)), Set([entry(1, minutesAgo: 0).id, entry(3, minutesAgo: 0).id]))
    }

    func testEvictionsKeepsNewestNBySyncedAt() {
        let index = [entry(1, minutesAgo: 3), entry(2, minutesAgo: 2), entry(3, minutesAgo: 1)]
        XCTAssertEqual(contentCacheEvictions(index: index, limit: 1), [entry(2, minutesAgo: 0).id, entry(1, minutesAgo: 0).id])
    }
}
