import XCTest
@testable import DocsIOS

final class DocumentCacheStoreTests: XCTestCase {
    private func makeStore() -> DocumentCacheStore {
        let suiteName = "DocumentCacheStoreTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        return DocumentCacheStore(userDefaults: userDefaults)
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

    func testLoadRecentDocumentsReturnsEmptyArrayWhenNoCacheExists() {
        let store = makeStore()

        XCTAssertTrue(store.loadRecentDocuments().isEmpty)
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

    func testPinnedAndRecentCachesAreIndependent() {
        let store = makeStore()
        let pinned = makeDocument(id: "33333333-3333-4333-8333-333333333333", title: "Pinned")
        let recent = makeDocument(id: "44444444-4444-4444-8444-444444444444", title: "Recent")

        store.savePinnedDocuments([pinned])
        store.saveRecentDocuments([recent])

        XCTAssertEqual(store.loadPinnedDocuments(), [pinned])
        XCTAssertEqual(store.loadRecentDocuments(), [recent])
    }
}
