import Observation
import XCTest

@testable import Schrift

@MainActor
final class DocumentPinSurfacesTests: DocumentPinTestCase {
    func testHomeOptionsSharedAndSearchUseOneOfflineIntentAndRelaunchPreservesIt() async {
        defaults.set(true, forKey: "schrift.workOffline")
        let cache = DocumentCacheStore(userDefaults: defaults)
        cache.savePinnedDocuments([])
        cache.saveRecentDocuments([row()])
        cache.saveSharedWithMeDocuments([row()])
        let (_, home, options, shared, search) = environment()
        home.searchResults = [row()]
        search.results = [row()]
        await home.toggleFavorite(row())
        XCTAssertEqual(home.pinnedDocuments.map(\.id), [id])
        XCTAssertTrue(home.recentDocuments.isEmpty)
        XCTAssertTrue(options.isFavorite)
        XCTAssertTrue(shared.documents[0].isFavorite)
        XCTAssertTrue(search.results[0].isFavorite)
        XCTAssertEqual(search.quickAccess.map(\.id), [id])
        let (_, relaunched, restoredOptions, _, _) = environment()
        XCTAssertEqual(relaunched.pinnedDocuments.map(\.id), [id])
        XCTAssertTrue(restoredOptions.isFavorite)
        await options.toggleFavorite(isOffline: true)
        XCTAssertTrue(home.pinnedDocuments.isEmpty)
        XCTAssertEqual(home.recentDocuments.map(\.id), [id])
        XCTAssertFalse(shared.documents[0].isFavorite)
        XCTAssertFalse(search.results[0].isFavorite)
        XCTAssertTrue(search.quickAccess.isEmpty)
    }

    func testTerminalRejectionAppearsOnHomeAndOptions() async {
        let log = stub(status: 403)
        let (_, home, options, _, _) = environment()
        await home.toggleFavorite(row())
        await waitUntil { log.count(ofMethod: "POST") == 1 && home.errorKey != nil }
        XCTAssertTrue(home.pinnedDocuments.isEmpty)
        XCTAssertFalse(options.isFavorite)
        XCTAssertEqual(home.errorKey, .options_error_toggle_favorite)
        XCTAssertEqual(options.errorKey, .options_error_toggle_favorite)
    }

    func testReconnectUsesExistingHomeSyncFunnel() async {
        let log = stub()
        defaults.set(true, forKey: "schrift.workOffline")
        let (_, home, _, _, _) = environment()
        await home.toggleFavorite(row())
        XCTAssertTrue(log.methods.isEmpty)
        defaults.set(false, forKey: "schrift.workOffline")
        await home.syncPendingDrafts()
        XCTAssertEqual(log.count(ofMethod: "POST", urlContaining: "/favorite/"), 1)
        XCTAssertTrue(PendingDocumentPinStore(userDefaults: defaults).allPins().isEmpty)
    }

    func testOptionsCarriesUncachedSearchMetadataIntoHomeAndQuickAccess() async {
        defaults.set(true, forKey: "schrift.workOffline")
        let (coordinator, home, _, _, search) = environment()
        let options = OptionsViewModel(
            client: client(), documentID: id, isFavorite: false,
            saveCoordinator: coordinator, signedInUser: SignedInUserStore(userDefaults: defaults), pinRow: row())
        await options.toggleFavorite(isOffline: true)
        XCTAssertTrue(options.isFavorite)
        XCTAssertEqual(home.pinnedDocuments.map(\.id), [id])
        XCTAssertEqual(search.quickAccess.map(\.id), [id])
        XCTAssertEqual(PendingDocumentPinStore(userDefaults: defaults).allPins().first?.row?.title, "Document")
        XCTAssertNil(DocumentCacheStore(userDefaults: defaults).loadRecentDocuments())
        let (_, restored, _, _, _) = environment()
        XCTAssertEqual(restored.pinnedDocuments.map(\.id), [id])
    }
}
