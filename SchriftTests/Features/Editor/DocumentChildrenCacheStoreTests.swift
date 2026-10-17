import XCTest

@testable import Schrift

final class DocumentChildrenCacheStoreTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "DocumentChildrenCacheStoreTests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore(limit: Int = 100, now: @escaping () -> Date = Date.init) -> DocumentChildrenCacheStore {
        DocumentChildrenCacheStore(userDefaults: userDefaults, limit: limit, now: now)
    }

    private func makeDocument(id: String, title: String) -> Document {
        Document(
            id: UUID(uuidString: id)!,
            title: title,
            excerpt: nil,
            abilities: DocumentAbilities(),
            linkReach: .restricted,
            linkRole: .reader,
            computedLinkReach: nil,
            computedLinkRole: nil,
            isFavorite: false,
            depth: 2,
            numchild: 0,
            path: "00010001",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            userRole: .owner,
            creator: nil
        )
    }

    func testChildrenReturnsNilWhenParentNeverCached() {
        let store = makeStore()

        XCTAssertNil(store.children(for: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!))
    }

    func testCachedEmptyListIsDistinctFromNeverCached() {
        let store = makeStore()
        let parentID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

        store.save([], for: parentID)

        XCTAssertEqual(store.children(for: parentID), [])
    }

    func testSaveAndChildrenRoundTrips() {
        let store = makeStore()
        let parentID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let child = makeDocument(id: "44444444-4444-4444-8444-444444444444", title: "Child page")

        store.save([child], for: parentID)

        XCTAssertEqual(store.children(for: parentID), [child])
    }

    func testSaveReplacesPreviousEntryForSameParent() {
        let store = makeStore()
        let parentID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let first = makeDocument(id: "66666666-6666-4666-8666-666666666666", title: "First")
        let second = makeDocument(id: "77777777-7777-4777-8777-777777777777", title: "Second")

        store.save([first], for: parentID)
        store.save([second], for: parentID)

        XCTAssertEqual(store.children(for: parentID)?.map(\.title), ["Second"])
    }

    func testParentsAreCachedIndependently() {
        let store = makeStore()
        let firstParent = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
        let secondParent = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
        let child = makeDocument(id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", title: "Child")

        store.save([child], for: firstParent)
        store.save([], for: secondParent)

        XCTAssertEqual(store.children(for: firstParent)?.map(\.title), ["Child"])
        XCTAssertEqual(store.children(for: secondParent), [])
    }

    func testRemoveDeletesOnlyThatParent() {
        let store = makeStore()
        let removed = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let kept = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
        let child = makeDocument(id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd", title: "Child")

        store.save([child], for: removed)
        store.save([child], for: kept)
        store.remove(parentID: removed)

        XCTAssertNil(store.children(for: removed))
        XCTAssertEqual(store.children(for: kept), [child])
    }

    func testRemoveDocumentStripsItFromEveryParentsList() {
        let store = makeStore()
        let firstParent = UUID(uuidString: "11111111-bbbb-4111-8111-111111111111")!
        let secondParent = UUID(uuidString: "22222222-bbbb-4222-8222-222222222222")!
        let doomed = makeDocument(id: "33333333-bbbb-4333-8333-333333333333", title: "Doomed")
        let kept = makeDocument(id: "44444444-bbbb-4444-8444-444444444444", title: "Kept")
        store.save([doomed, kept], for: firstParent)
        store.save([doomed], for: secondParent)

        store.removeDocument(doomed.id)

        XCTAssertEqual(store.children(for: firstParent)?.map(\.title), ["Kept"])
        XCTAssertEqual(store.children(for: secondParent), [])
    }

    func testRemoveDocumentLeavesUnrelatedListsUntouched() {
        let store = makeStore()
        let parentID = UUID(uuidString: "55555555-bbbb-4555-8555-555555555555")!
        let child = makeDocument(id: "66666666-bbbb-4666-8666-666666666666", title: "Child")
        store.save([child], for: parentID)

        store.removeDocument(UUID(uuidString: "77777777-bbbb-4777-8777-777777777777")!)

        XCTAssertEqual(store.children(for: parentID), [child])
    }

    func testRemoveAllClearsEveryEntry() {
        let store = makeStore()
        let parentID = UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!
        store.save([], for: parentID)

        store.removeAll()

        XCTAssertNil(store.children(for: parentID))
    }

    /// Eviction keeps the `limit` parents with the newest `syncedAt` — the
    /// selection itself is `contentCacheEvictions`, covered by
    /// `DocumentContentCacheStoreTests`; this pins the store's wiring of it.
    func testSaveEvictsOldestParentsBeyondLimit() {
        // Deterministic clock: each save is one second newer than the last.
        var tick = 0.0
        let store = makeStore(
            limit: 2,
            now: {
                tick += 1
                return Date(timeIntervalSince1970: tick)
            })
        let oldest = UUID(uuidString: "11111111-aaaa-4111-8111-111111111111")!
        let middle = UUID(uuidString: "22222222-aaaa-4222-8222-222222222222")!
        let newest = UUID(uuidString: "33333333-aaaa-4333-8333-333333333333")!

        store.save([], for: oldest)
        store.save([], for: middle)
        store.save([], for: newest)

        XCTAssertNil(store.children(for: oldest))
        XCTAssertEqual(store.children(for: middle), [])
        XCTAssertEqual(store.children(for: newest), [])
    }

    // MARK: - Memoized decode

    /// The save coordinator, the editor and the Pages drawer each build a store over
    /// `.standard`; the decode is memoized, so every write — save, purge, wipe — through one
    /// must be what the others read next.
    func testTwoInstancesOnTheSameDefaultsSeeEachOthersWrites() {
        let first = makeStore()
        let second = makeStore()
        let parentID = UUID(uuidString: "12121212-1212-4212-8212-121212121212")!
        let child = makeDocument(id: "34343434-3434-4434-8434-343434343434", title: "Child")
        XCTAssertNil(second.children(for: parentID), "primes the second instance's read")

        first.save([child], for: parentID)
        XCTAssertEqual(second.children(for: parentID), [child])
        XCTAssertEqual(second.document(for: child.id), child)

        second.removeDocument(child.id)
        XCTAssertEqual(first.children(for: parentID), [])
        XCTAssertNil(first.document(for: child.id))

        first.removeAll()
        XCTAssertNil(second.children(for: parentID))
    }

    func testStoresOnDifferentDefaultsDoNotShareEntries() {
        let otherSuite = "DocumentChildrenCacheStoreTests.\(UUID().uuidString)"
        let otherDefaults = UserDefaults(suiteName: otherSuite)!
        defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
        let store = makeStore()
        let other = DocumentChildrenCacheStore(userDefaults: otherDefaults)
        let parentID = UUID(uuidString: "56565656-5656-4656-8656-565656565656")!

        store.save([], for: parentID)

        XCTAssertEqual(store.children(for: parentID), [])
        XCTAssertNil(other.children(for: parentID))
        XCTAssertEqual(store.children(for: parentID), [], "reading the other suite evicts nothing")
    }

    /// Bytes replaced behind the store's back after a memoized read are seen at once: undecodable
    /// data still reads as an empty cache, and the next save starts over from it as before.
    func testCorruptionAfterAMemoizedReadReadsAsEmpty() {
        let store = makeStore()
        let parentID = UUID(uuidString: "78787878-7878-4878-8878-787878787878")!
        let child = makeDocument(id: "9a9a9a9a-9a9a-4a9a-8a9a-9a9a9a9a9a9a", title: "Child")
        store.save([child], for: parentID)
        XCTAssertEqual(store.children(for: parentID), [child])

        userDefaults.set(Data("not json".utf8), forKey: "dev.llun.Schrift.cachedDocumentChildren")

        XCTAssertNil(store.children(for: parentID))
        XCTAssertNil(store.document(for: child.id))

        let otherParent = UUID(uuidString: "bcbcbcbc-bcbc-4cbc-8cbc-bcbcbcbcbcbc")!
        store.save([], for: otherParent)
        XCTAssertEqual(store.children(for: otherParent), [])
        XCTAssertNil(store.children(for: parentID))
    }
}
