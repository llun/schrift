import XCTest

@testable import Schrift

final class DocumentCacheStoreTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "DocumentCacheStoreTests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore() -> DocumentCacheStore {
        DocumentCacheStore(userDefaults: userDefaults)
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
            depth: 1,
            numchild: 0,
            path: "0001",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            userRole: .owner,
            creator: nil
        )
    }

    func testLoadPinnedDocumentsReturnsEmptyArrayWhenNoCacheExists() {
        let store = makeStore()

        XCTAssertTrue(store.loadPinnedDocuments().isEmpty)
    }

    func testLoadRecentDocumentsReturnsNilWhenNeverCached() {
        let store = makeStore()

        XCTAssertNil(store.loadRecentDocuments())
    }

    func testSaveAndLoadPinnedDocumentsRoundTrips() {
        let store = makeStore()
        let document = makeDocument(id: "11111111-1111-4111-8111-111111111111", title: "Pinned Doc")

        store.savePinnedDocuments([document])

        XCTAssertEqual(store.loadPinnedDocuments(), [document])
    }

    func testSaveAndLoadRecentDocumentsRoundTrips() {
        let store = makeStore()
        let document = makeDocument(id: "22222222-2222-4222-8222-222222222222", title: "Recent Doc")

        store.saveRecentDocuments([document])

        XCTAssertEqual(store.loadRecentDocuments(), [document])
    }

    func testCachedEmptyListIsDistinctFromNeverCached() {
        // A never-cached list reads nil; a cached empty list (a real fetch
        // result) reads []. The UI's one first-run spinner keys off that split.
        XCTAssertNil(makeStore().loadRecentDocuments())

        let store = makeStore()
        store.saveRecentDocuments([])
        XCTAssertEqual(store.loadRecentDocuments(), [])
    }

    func testPinnedAndRecentCachesAreIndependent() {
        let store = makeStore()
        let pinned = makeDocument(id: "55555555-5555-4555-8555-555555555555", title: "Pinned")
        let recent = makeDocument(id: "66666666-6666-4666-8666-666666666666", title: "Recent")

        store.savePinnedDocuments([pinned])
        store.saveRecentDocuments([recent])

        XCTAssertEqual(store.loadPinnedDocuments(), [pinned])
        XCTAssertEqual(store.loadRecentDocuments(), [recent])
    }

    /// Pins the durable key so caches written by earlier builds (including the
    /// pre-filter and per-filter eras, which both used this same `.all` key)
    /// migrate for free.
    func testRecentDocumentsReadsTheStableCacheKey() {
        let document = makeDocument(id: "77777777-7777-4777-8777-777777777777", title: "Legacy Doc")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        userDefaults.set(try! encoder.encode([document]), forKey: "dev.llun.Schrift.cachedRecentDocuments")

        let store = makeStore()

        XCTAssertEqual(store.loadRecentDocuments(), [document])
    }

    func testLoadSharedWithMeDocumentsReturnsNilWhenNeverCached() {
        let store = makeStore()

        XCTAssertNil(store.loadSharedWithMeDocuments())
    }

    func testSharedWithMeCacheRoundTrips() {
        let store = makeStore()
        let withMe = makeDocument(id: "88888888-8888-4888-8888-888888888888", title: "With Me")

        store.saveSharedWithMeDocuments([withMe])

        XCTAssertEqual(store.loadSharedWithMeDocuments(), [withMe])
    }

    func testInitClearsStrandedSharedByMeCache() {
        // A previous app version cached a shared-by-me list; a new store must
        // drop that now-unread key on init.
        userDefaults.set(Data("stale".utf8), forKey: "dev.llun.Schrift.cachedSharedByMeDocuments")

        _ = makeStore()

        XCTAssertNil(userDefaults.data(forKey: "dev.llun.Schrift.cachedSharedByMeDocuments"))
    }
}
