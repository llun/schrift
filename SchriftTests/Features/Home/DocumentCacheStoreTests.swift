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

    func testLoadRecentDocumentsReturnsNilWhenFilterNeverCached() {
        let store = makeStore()

        for filter in HomeFilter.allCases {
            XCTAssertNil(store.loadRecentDocuments(filter: filter))
        }
    }

    func testSaveAndLoadPinnedDocumentsRoundTrips() {
        let store = makeStore()
        let document = makeDocument(id: "11111111-1111-4111-8111-111111111111", title: "Pinned Doc")

        store.savePinnedDocuments([document])

        XCTAssertEqual(store.loadPinnedDocuments(), [document])
    }

    func testSaveAndLoadRecentDocumentsRoundTripsPerFilter() {
        let store = makeStore()
        let document = makeDocument(id: "22222222-2222-4222-8222-222222222222", title: "Recent Doc")

        for filter in HomeFilter.allCases {
            store.saveRecentDocuments([document], filter: filter)
            XCTAssertEqual(store.loadRecentDocuments(filter: filter), [document])
        }
    }

    func testCachedEmptyListIsDistinctFromNeverCached() {
        let store = makeStore()

        store.saveRecentDocuments([], filter: .shared)

        XCTAssertEqual(store.loadRecentDocuments(filter: .shared), [])
        XCTAssertNil(store.loadRecentDocuments(filter: .pinned))
    }

    func testRecentFiltersAreCachedIndependently() {
        let store = makeStore()
        let allDoc = makeDocument(id: "33333333-3333-4333-8333-333333333333", title: "All Doc")
        let sharedDoc = makeDocument(id: "44444444-4444-4444-8444-444444444444", title: "Shared Doc")

        store.saveRecentDocuments([allDoc], filter: .all)
        store.saveRecentDocuments([sharedDoc], filter: .shared)

        XCTAssertEqual(store.loadRecentDocuments(filter: .all), [allDoc])
        XCTAssertEqual(store.loadRecentDocuments(filter: .shared), [sharedDoc])
        XCTAssertNil(store.loadRecentDocuments(filter: .pinned))
    }

    func testPinnedAndRecentCachesAreIndependent() {
        let store = makeStore()
        let pinned = makeDocument(id: "55555555-5555-4555-8555-555555555555", title: "Pinned")
        let recent = makeDocument(id: "66666666-6666-4666-8666-666666666666", title: "Recent")

        store.savePinnedDocuments([pinned])
        store.saveRecentDocuments([recent], filter: .all)

        XCTAssertEqual(store.loadPinnedDocuments(), [pinned])
        XCTAssertEqual(store.loadRecentDocuments(filter: .all), [recent])
    }

    /// The `.all` filter must keep reading the original pre-per-filter key so
    /// caches written before the split migrate for free.
    func testAllFilterReadsLegacyRecentDocumentsKey() {
        let document = makeDocument(id: "77777777-7777-4777-8777-777777777777", title: "Legacy Doc")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        userDefaults.set(try! encoder.encode([document]), forKey: "dev.llun.Schrift.cachedRecentDocuments")

        let store = makeStore()

        XCTAssertEqual(store.loadRecentDocuments(filter: .all), [document])
    }

    func testRecentDocumentsCacheKeyValuesAreStable() {
        XCTAssertEqual(recentDocumentsCacheKey(.all), "dev.llun.Schrift.cachedRecentDocuments")
        XCTAssertEqual(recentDocumentsCacheKey(.shared), "dev.llun.Schrift.cachedRecentDocuments.shared")
        XCTAssertEqual(recentDocumentsCacheKey(.pinned), "dev.llun.Schrift.cachedRecentDocuments.pinned")
    }

    func testLoadSharedDocumentsReturnsNilWhenNeverCached() {
        let store = makeStore()

        XCTAssertNil(store.loadSharedWithMeDocuments())
        XCTAssertNil(store.loadSharedByMeDocuments())
    }

    func testSharedWithMeAndByMeCachesAreIndependent() {
        let store = makeStore()
        let withMe = makeDocument(id: "88888888-8888-4888-8888-888888888888", title: "With Me")
        let byMe = makeDocument(id: "99999999-9999-4999-8999-999999999999", title: "By Me")

        store.saveSharedWithMeDocuments([withMe])
        store.saveSharedByMeDocuments([byMe])

        XCTAssertEqual(store.loadSharedWithMeDocuments(), [withMe])
        XCTAssertEqual(store.loadSharedByMeDocuments(), [byMe])
    }
}
