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
        let store = makeStore(limit: 2, now: {
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
}
