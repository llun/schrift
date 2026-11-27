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

    func testAllContentsListsEverySavedEntry() {
        let store = makeStore()
        let other = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        store.save(makeEntry())
        store.save(makeEntry(id: other, markdown: "Other"))
        XCTAssertEqual(Set(store.allContents().map(\.documentID)), [documentID, other])
    }

    func testAllContentsSkipsAnUndecodableFile() throws {
        let store = makeStore()
        store.save(makeEntry())
        try Data("not json".utf8).write(
            to: directory.appendingPathComponent("22222222-2222-4222-8222-222222222222.json"))
        XCTAssertEqual(store.allContents().map(\.documentID), [documentID])
    }

    func testAllContentsIsEmptyWithNoCacheDirectory() {
        XCTAssertEqual(makeStore().allContents(), [])
    }

    func testContentForUnknownDocumentReturnsNil() {
        XCTAssertNil(makeStore().content(for: documentID))
    }

    func testEntryWithServerUpdatedAtRoundTrips() {
        let store = makeStore()
        let entry = CachedDocumentContent(
            documentID: documentID,
            title: "Doc",
            markdown: "# Hello",
            syncedAt: Date(timeIntervalSince1970: 1_000_000),
            serverUpdatedAt: Date(timeIntervalSince1970: 999_999))
        store.save(entry)
        let loaded = store.content(for: documentID)
        XCTAssertEqual(loaded, entry)
        XCTAssertEqual(loaded?.serverUpdatedAt, Date(timeIntervalSince1970: 999_999))
    }

    /// An entry written before `serverUpdatedAt` existed must still decode — with
    /// that field nil (a truthful "unknown", not a fabricated timestamp).
    func testLegacyEntryWithoutServerUpdatedAtDecodesNil() {
        let store = makeStore()
        let file = directory.appendingPathComponent("\(documentID.uuidString.lowercased()).json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // syncedAt is millisecondsSince1970 (matching the store's encoder).
        let legacyJSON = """
            {"documentID": "\(documentID.uuidString)", "title": "Doc", "markdown": "# Legacy", "syncedAt": 1000000000}
            """
        try? Data(legacyJSON.utf8).write(to: file)

        let loaded = store.content(for: documentID)
        XCTAssertEqual(loaded?.markdown, "# Legacy")
        XCTAssertNil(loaded?.serverUpdatedAt)
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

    // MARK: - One folder per account

    private let accountA = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let accountB = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!

    private func makeDefaults(signedIn account: UUID?) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "DocumentContentCacheStoreTests.\(UUID().uuidString)")!
        SignedInUserStore(userDefaults: defaults).remember(account)
        return defaults
    }

    private func signIn(_ account: UUID?, in defaults: UserDefaults) {
        let signedIn = SignedInUserStore(userDefaults: defaults)
        signedIn.clear()
        signedIn.remember(account)
    }

    /// One long-lived instance, as the coordinator and screens that survive a re-login hold.
    func testEachAccountReadsOnlyItsOwnBodiesAcrossAnAccountChange() {
        let defaults = makeDefaults(signedIn: accountA)
        let store = DocumentContentCacheStore(root: directory, userDefaults: defaults)
        store.save(makeEntry(markdown: "# A's"))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(
                    "\(accountA.uuidString.lowercased())/\(documentID.uuidString.lowercased()).json"
                ).path))

        signIn(accountB, in: defaults)
        XCTAssertNil(store.content(for: documentID))
        XCTAssertTrue(store.allContents().isEmpty)
        XCTAssertTrue(store.allContentsReader()().isEmpty)
        store.save(makeEntry(markdown: "# B's"))
        XCTAssertEqual(store.content(for: documentID)?.markdown, "# B's")

        signIn(accountA, in: defaults)
        XCTAssertEqual(store.content(for: documentID)?.markdown, "# A's", "nothing was wiped or overwritten")
    }

    func testWithNoKnownAccountNothingIsReadOrWritten() {
        let defaults = makeDefaults(signedIn: accountA)
        let store = DocumentContentCacheStore(root: directory, userDefaults: defaults)
        store.save(makeEntry(id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!))

        signIn(nil, in: defaults)
        store.save(makeEntry())
        XCTAssertNil(store.content(for: documentID))
        XCTAssertTrue(store.allContents().isEmpty)
        XCTAssertTrue(store.allContentsReader()().isEmpty)

        signIn(accountA, in: defaults)
        XCTAssertNil(store.content(for: documentID), "the unknown-account save wrote nothing")
        XCTAssertEqual(store.allContents().count, 1)
    }

    func testRemoveAllRemovesEveryAccountsBodies() {
        let defaults = makeDefaults(signedIn: accountA)
        let store = DocumentContentCacheStore(root: directory, userDefaults: defaults)
        store.save(makeEntry())
        signIn(accountB, in: defaults)
        store.save(makeEntry())

        store.removeAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testEarlierFlatBodiesMoveIntoTheAccountSignedInAtTheFirstLaunchOnly() {
        DocumentContentCacheStore(directory: directory).save(makeEntry(markdown: "# Earlier"))
        let defaults = makeDefaults(signedIn: accountA)

        DocumentContentCacheStore.moveEarlierBodiesIntoAccountFolder(root: directory, userDefaults: defaults)

        let store = DocumentContentCacheStore(root: directory, userDefaults: defaults)
        XCTAssertEqual(store.content(for: documentID)?.markdown, "# Earlier")
        signIn(accountB, in: defaults)
        let olderBuild = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        DocumentContentCacheStore(directory: directory).save(makeEntry(id: olderBuild))
        DocumentContentCacheStore.moveEarlierBodiesIntoAccountFolder(root: directory, userDefaults: defaults)
        XCTAssertNil(store.content(for: documentID))
        XCTAssertNil(store.content(for: olderBuild), "moved once: a later flat file is never claimed")
    }

    func testEarlierFlatBodiesAreDeletedWhenNoAccountIsKnownAtTheFirstLaunch() {
        DocumentContentCacheStore(directory: directory).save(makeEntry())
        let defaults = makeDefaults(signedIn: nil)

        DocumentContentCacheStore.moveEarlierBodiesIntoAccountFolder(root: directory, userDefaults: defaults)

        signIn(accountA, in: defaults)
        XCTAssertNil(DocumentContentCacheStore(root: directory, userDefaults: defaults).content(for: documentID))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("\(documentID.uuidString.lowercased()).json").path))
    }

    /// A response that lands after the session changed is written nowhere.
    func testABodyFetchedUnderAnotherSessionIsNotWritten() {
        let defaults = makeDefaults(signedIn: accountA)
        let store = DocumentContentCacheStore(root: directory, userDefaults: defaults)
        let fetchedUnder = SignedInUserStore(userDefaults: defaults).session

        signIn(accountB, in: defaults)
        store.save(makeEntry(markdown: "# A's"), during: fetchedUnder)
        XCTAssertNil(store.content(for: documentID), "not into B's folder")

        signIn(accountA, in: defaults)
        store.save(makeEntry(markdown: "# A's"), during: fetchedUnder)
        XCTAssertNil(store.content(for: documentID), "nor back into A's after its sign-in changed")
        store.save(makeEntry(markdown: "# A's"), during: SignedInUserStore(userDefaults: defaults).session)
        XCTAssertEqual(store.content(for: documentID)?.markdown, "# A's")
    }

    func testTheRootIsExcludedFromBackupToo() throws {
        let defaults = makeDefaults(signedIn: accountA)
        DocumentContentCacheStore(root: directory, userDefaults: defaults).save(makeEntry())
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }
}
