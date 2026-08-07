import XCTest

@testable import Schrift

final class AttachmentCacheStoreTests: XCTestCase {
    // MARK: - attachmentCacheEvictions (pure, filesystem-free)

    private func entry(_ name: String, bytes: Int, minutesAgo: Int) -> AttachmentCacheIndexEntry {
        AttachmentCacheIndexEntry(
            fileName: name,
            byteSize: bytes,
            lastUsedAt: Date(timeIntervalSince1970: 1_000_000 - TimeInterval(minutesAgo * 60)))
    }

    private func evictions(_ index: [AttachmentCacheIndexEntry], count: Int = 100, bytes: Int = 1_000_000) -> [String] {
        attachmentCacheEvictions(index: index, countLimit: count, byteLimit: bytes)
    }

    func testUnderBothCapsEvictsNothing() {
        XCTAssertEqual(evictions([]), [])
        XCTAssertEqual(evictions([entry("a", bytes: 10, minutesAgo: 0)]), [])
        XCTAssertEqual(
            evictions([entry("a", bytes: 10, minutesAgo: 0), entry("b", bytes: 10, minutesAgo: 5)]), [])
    }

    func testCountCapEvictsLeastRecentlyUsed() {
        let index = [
            entry("a", bytes: 1, minutesAgo: 10), entry("b", bytes: 1, minutesAgo: 0),
            entry("c", bytes: 1, minutesAgo: 20), entry("d", bytes: 1, minutesAgo: 5),
        ]
        // Keeps the 2 most recent (b, d).
        XCTAssertEqual(evictions(index, count: 2), ["a", "c"])
    }

    func testByteCapEvictsLeastRecentlyUsed() {
        let index = [
            entry("new", bytes: 60, minutesAgo: 0), entry("mid", bytes: 30, minutesAgo: 5),
            entry("old", bytes: 30, minutesAgo: 10),
        ]
        // 60 + 30 fits in 100; the third would make 120.
        XCTAssertEqual(evictions(index, bytes: 100), ["old"])
    }

    func testBothCapsApplyTogether() {
        let index = [
            entry("a", bytes: 10, minutesAgo: 0), entry("b", bytes: 10, minutesAgo: 1),
            entry("c", bytes: 10, minutesAgo: 2),
        ]
        XCTAssertEqual(evictions(index, count: 1, bytes: 1_000), ["b", "c"])
        XCTAssertEqual(evictions(index, count: 100, bytes: 15), ["b", "c"])
    }

    /// The store calls this straight after writing, so evicting the file just
    /// written would make the loader re-download it on every render, forever.
    func testTheMostRecentlyUsedEntryIsNeverEvicted() {
        let huge = entry("huge", bytes: 10_000, minutesAgo: 0)
        XCTAssertEqual(evictions([huge], count: 0, bytes: 1), [])
        XCTAssertEqual(
            evictions([huge, entry("small", bytes: 1, minutesAgo: 5)], bytes: 10), ["small"])
    }

    /// A large entry is skipped without taking older, smaller ones with it —
    /// utility over strict LRU ordering, as documented.
    func testAnOversizedEntryDoesNotEvictEverythingBehindIt() {
        let index = [
            entry("newest", bytes: 60, minutesAgo: 0), entry("big", bytes: 50, minutesAgo: 1),
            entry("small", bytes: 30, minutesAgo: 2),
        ]
        XCTAssertEqual(evictions(index, bytes: 100), ["big"])
    }

    func testEqualRecencyBreaksTiesDeterministically() {
        let index = [
            entry("b", bytes: 10, minutesAgo: 0), entry("a", bytes: 10, minutesAgo: 0),
            entry("c", bytes: 10, minutesAgo: 0),
        ]
        // Same mtime for all three: name order decides, so the answer is stable
        // across runs rather than dependent on directory enumeration order.
        XCTAssertEqual(evictions(index, count: 1), ["b", "c"])
    }

    // MARK: - AttachmentCacheStore

    private var directory: URL!
    private let serverOrigin = "https://docs.example.org"
    private let documentUUID = "11111111-1111-4111-8111-111111111111"

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachmentCacheStoreTests.\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    private func makeStore(countLimit: Int = 100, byteLimit: Int = 200 * 1024 * 1024) -> AttachmentCacheStore {
        AttachmentCacheStore(directory: directory, countLimit: countLimit, byteLimit: byteLimit)
    }

    /// Built through the real classifier so the tests can never disagree with it
    /// about what a cache file is named.
    private func makeDisplay(
        fileUUID: String = "22222222-2222-4222-8222-222222222222",
        suffix: String = "",
        ext: String = "pdf",
        label: String = "Report.pdf"
    ) throws -> AttachmentDisplay {
        let url = "\(serverOrigin)/media/\(documentUUID)/attachments/\(fileUUID)\(suffix).\(ext)"
        return try XCTUnwrap(parseAttachmentLink("[\(label)](\(url))", serverOrigin: serverOrigin))
    }

    private func contents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    // MARK: CRUD

    func testStoreThenLookupRoundTripsTheExactBytes() throws {
        let store = makeStore()
        let display = try makeDisplay()
        let payload = Data([0x25, 0x50, 0x44, 0x46, 0x00, 0xFF])

        XCTAssertNotNil(store.store(payload, for: display))

        let url = try XCTUnwrap(store.cachedFileURL(for: display))
        XCTAssertEqual(try Data(contentsOf: url), payload)
    }

    func testLookupOfAnUncachedAttachmentReturnsNil() throws {
        XCTAssertNil(makeStore().cachedFileURL(for: try makeDisplay()))
    }

    func testASeparatelyConstructedStoreSeesTheSameEntry() throws {
        // Stateless over its directory, like the content cache: the loader and a
        // sign-out clear may hold different instances.
        let display = try makeDisplay()
        _ = makeStore().store(Data([1, 2, 3]), for: display)
        XCTAssertNotNil(makeStore().cachedFileURL(for: display))
    }

    func testRemoveAllClearsEverything() throws {
        let store = makeStore()
        let display = try makeDisplay()
        _ = store.store(Data([1]), for: display)

        store.removeAll()

        XCTAssertNil(store.cachedFileURL(for: display))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testStoringAgainReplacesTheBytes() throws {
        let store = makeStore()
        let display = try makeDisplay()
        _ = store.store(Data([1, 2, 3]), for: display)
        _ = store.store(Data([9]), for: display)

        let url = try XCTUnwrap(store.cachedFileURL(for: display))
        XCTAssertEqual(try Data(contentsOf: url), Data([9]))
        XCTAssertEqual(try contents().count, 1)
    }

    // MARK: File naming

    func testFileIsNamedForTheServerKeyNotTheAuthorsLabel() throws {
        let store = makeStore()
        let display = try makeDisplay(label: "../../etc/passwd")
        _ = store.store(Data([1]), for: display)

        XCTAssertEqual(try contents(), ["\(documentUUID)_22222222-2222-4222-8222-222222222222.pdf"])
    }

    /// The store's own separator/`..` guard, reached the only way it can be: a
    /// hand-built value. Every other test goes through `parseAttachmentLink`,
    /// which can only produce validated UUIDs — so without this the guard is
    /// unreachable and deleting it would break nothing.
    func testAHandBuiltDisplayCannotEscapeTheCacheDirectory() throws {
        let store = makeStore()
        let hostile = AttachmentDisplay(
            name: "x",
            urlString: "https://docs.example.org/x",
            url: URL(string: "https://docs.example.org/x")!,
            documentUUID: "../../..",
            fileUUID: "../../../../tmp/pwned",
            isUnsafeKey: false,
            fileExtension: "pdf")

        XCTAssertNil(store.store(Data([1]), for: hostile))
        XCTAssertNil(store.cachedFileURL(for: hostile))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/pwned.pdf"))
    }

    /// Same guard, and also the reason the cache name carries the document id:
    /// two documents naming one file id must not share an entry.
    func testTwoDocumentsNamingTheSameFileIDGetSeparateFiles() throws {
        let store = makeStore()
        let first = try makeDisplay()
        let second = try XCTUnwrap(
            parseAttachmentLink(
                "[f](\(serverOrigin)/media/99999999-9999-4999-8999-999999999999/attachments/"
                    + "22222222-2222-4222-8222-222222222222.pdf)",
                serverOrigin: serverOrigin))

        _ = store.store(Data([1]), for: first)
        _ = store.store(Data([2]), for: second)

        XCTAssertEqual(try contents().count, 2)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(store.cachedFileURL(for: first))), Data([1]))
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(store.cachedFileURL(for: second))), Data([2]))
    }

    func testUnsafeKeysGetTheirOwnFile() throws {
        let store = makeStore()
        _ = store.store(Data([1]), for: try makeDisplay(ext: "docx"))
        _ = store.store(Data([2]), for: try makeDisplay(suffix: "-unsafe", ext: "docx"))

        XCTAssertEqual(
            try contents(),
            [
                "\(documentUUID)_22222222-2222-4222-8222-222222222222-unsafe.docx",
                "\(documentUUID)_22222222-2222-4222-8222-222222222222.docx",
            ])
    }

    func testTwoAttachmentsGetTwoFiles() throws {
        let store = makeStore()
        _ = store.store(Data([1]), for: try makeDisplay())
        _ = store.store(Data([2]), for: try makeDisplay(fileUUID: "33333333-3333-4333-8333-333333333333"))

        XCTAssertEqual(try contents().count, 2)
    }

    // MARK: Eviction and recency

    func testStoringBeyondTheCountCapEvictsTheLeastRecentlyStored() throws {
        let store = makeStore(countLimit: 2)
        let first = try makeDisplay(fileUUID: "33333333-3333-4333-8333-333333333333")
        let second = try makeDisplay(fileUUID: "44444444-4444-4444-8444-444444444444")
        let third = try makeDisplay(fileUUID: "55555555-5555-4555-8555-555555555555")

        _ = store.store(Data([1]), for: first)
        try touch(first, secondsAgo: 300)
        _ = store.store(Data([2]), for: second)
        try touch(second, secondsAgo: 200)
        _ = store.store(Data([3]), for: third)

        XCTAssertNil(store.cachedFileURL(for: first))
        XCTAssertNotNil(store.cachedFileURL(for: second))
        XCTAssertNotNil(store.cachedFileURL(for: third))
    }

    func testStoringBeyondTheByteCapEvictsTheLeastRecentlyStored() throws {
        let store = makeStore(byteLimit: 20)
        let first = try makeDisplay(fileUUID: "33333333-3333-4333-8333-333333333333")
        let second = try makeDisplay(fileUUID: "44444444-4444-4444-8444-444444444444")

        _ = store.store(Data(repeating: 0, count: 15), for: first)
        try touch(first, secondsAgo: 300)
        _ = store.store(Data(repeating: 0, count: 15), for: second)

        XCTAssertNil(store.cachedFileURL(for: first))
        XCTAssertNotNil(store.cachedFileURL(for: second))
    }

    /// The whole reason recency is last-*use*: reopening an attachment must save
    /// it from the next eviction pass, which write-recency could not express.
    func testReadingAnEntryProtectsItFromTheNextEviction() throws {
        let store = makeStore(countLimit: 2)
        let reopened = try makeDisplay(fileUUID: "33333333-3333-4333-8333-333333333333")
        let idle = try makeDisplay(fileUUID: "44444444-4444-4444-8444-444444444444")
        let fresh = try makeDisplay(fileUUID: "55555555-5555-4555-8555-555555555555")

        _ = store.store(Data([1]), for: reopened)
        try touch(reopened, secondsAgo: 300)
        _ = store.store(Data([2]), for: idle)
        try touch(idle, secondsAgo: 200)

        // The user reopens the older one, then a third attachment arrives.
        XCTAssertNotNil(store.cachedFileURL(for: reopened))
        _ = store.store(Data([3]), for: fresh)

        XCTAssertNotNil(store.cachedFileURL(for: reopened), "a re-read entry must outrank an idle newer one")
        XCTAssertNil(store.cachedFileURL(for: idle))
    }

    // MARK: Backup exclusion

    func testTheCacheDirectoryIsExcludedFromBackup() throws {
        let store = makeStore()
        _ = store.store(Data([1]), for: try makeDisplay())

        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    // MARK: - Helpers

    /// Backdates a cached file so recency ordering is deterministic instead of
    /// depending on how fast the test ran.
    private func touch(_ display: AttachmentDisplay, secondsAgo: TimeInterval) throws {
        let url = directory.appendingPathComponent(attachmentCacheFileName(for: display), isDirectory: false)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-secondsAgo)], ofItemAtPath: url.path)
    }
}
