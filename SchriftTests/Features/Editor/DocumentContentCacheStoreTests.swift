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
        let index = [
            entry(1, minutesAgo: 10), entry(2, minutesAgo: 0), entry(3, minutesAgo: 20), entry(4, minutesAgo: 5),
        ]
        // Keep the 2 newest (2, 4); evict 1 and 3.
        XCTAssertEqual(
            Set(contentCacheEvictions(index: index, limit: 2)),
            Set([entry(1, minutesAgo: 0).id, entry(3, minutesAgo: 0).id]))
    }

    func testEvictionsKeepsNewestNBySyncedAt() {
        let index = [entry(1, minutesAgo: 3), entry(2, minutesAgo: 2), entry(3, minutesAgo: 1)]
        XCTAssertEqual(
            contentCacheEvictions(index: index, limit: 1), [entry(2, minutesAgo: 0).id, entry(1, minutesAgo: 0).id])
    }

    // MARK: - DocumentContentCacheStore

    private var directory: URL!
    private let documentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentContentCacheStoreTests.\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    private func makeStore(limit: Int = 50) -> DocumentContentCacheStore {
        DocumentContentCacheStore(directory: directory, limit: limit)
    }

    private func makeEntry(id: UUID? = nil, markdown: String = "# Hello") -> CachedDocumentContent {
        CachedDocumentContent(
            documentID: id ?? documentID,
            title: "Doc",
            markdown: markdown,
            syncedAt: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    // MARK: - CRUD

    func testSaveThenContentRoundTrips() {
        let store = makeStore()
        let entry = makeEntry()
        store.save(entry)
        XCTAssertEqual(store.content(for: documentID), entry)
    }

    func testContentForUnknownDocumentReturnsNil() {
        XCTAssertNil(makeStore().content(for: documentID))
    }

    func testCorruptFileReturnsNil() {
        let store = makeStore()
        store.save(makeEntry())
        let file = directory.appendingPathComponent("\(documentID.uuidString.lowercased()).json")
        try? Data("not json".utf8).write(to: file)
        XCTAssertNil(store.content(for: documentID))
    }

    func testRemoveDeletesEntry() {
        let store = makeStore()
        store.save(makeEntry())
        store.remove(documentID: documentID)
        XCTAssertNil(store.content(for: documentID))
    }

    func testRemoveAllDeletesEveryEntry() {
        let store = makeStore()
        let other = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        store.save(makeEntry())
        store.save(makeEntry(id: other))
        store.removeAll()
        XCTAssertNil(store.content(for: documentID))
        XCTAssertNil(store.content(for: other))
    }

    func testIndependentInstancesShareTheDirectory() {
        // The store is stateless: a second instance over the same directory
        // sees the first instance's writes (spec §1 "Stateless").
        makeStore().save(makeEntry())
        XCTAssertEqual(makeStore().content(for: documentID), makeEntry())
    }

    // MARK: - Eviction

    func testSaveEvictsOldestBeyondLimit() throws {
        let store = makeStore(limit: 2)
        let a = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let b = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let c = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
        store.save(makeEntry(id: a))
        store.save(makeEntry(id: b))
        // Force distinct, deterministic mtimes (mtime IS the eviction index).
        let fm = FileManager.default
        try fm.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: directory.appendingPathComponent("\(a.uuidString.lowercased()).json").path)
        try fm.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: directory.appendingPathComponent("\(b.uuidString.lowercased()).json").path)
        store.save(makeEntry(id: c))  // triggers eviction; c has mtime "now"
        XCTAssertNil(store.content(for: a), "oldest entry is evicted")
        XCTAssertNotNil(store.content(for: b))
        XCTAssertNotNil(store.content(for: c))
    }

    // MARK: - Backup exclusion

    func testCacheDirectoryIsExcludedFromBackup() throws {
        makeStore().save(makeEntry())
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }
}
