import Observation
import XCTest

@testable import Schrift

@MainActor
final class DocumentPinFlagObservationTests: DocumentPinTestCase {
    func testFreshWebUnpinUpdatesOlderQuickAccessMembership() async {
        _ = stub()
        let (coordinator, home, _, _, search) = environment()
        await home.toggleFavorite(row())
        await waitUntil {
            !coordinator.pins.isSyncing && PendingDocumentPinStore(userDefaults: self.defaults).allPins().isEmpty
        }
        search.quickAccess = [row(pinned: true)]
        let revision = coordinator.pins.revision
        coordinator.pins.didCacheFreshLists(pinned: [], recent: [row()], ownerUserID: owner, fetchedAt: revision)
        XCTAssertTrue(search.quickAccess.isEmpty)
        XCTAssertFalse(search.results.contains { $0.isFavorite })
    }

    func testFreshSearchAndSharedFlagsReachOptionsAndTerminalRollback() async {
        for surface in ["Search", "Home search", "Shared", "Subpages", "Pages drawer"] {
            _ = stub()
            let (coordinator, home, _, shared, search) = environment()
            XCTAssertTrue(queue(coordinator.pins, pinned: true))
            await coordinator.syncPendingPins()
            let body = Self.page([row()])
            let user = Data("{\"id\":\"\(owner.uuidString)\"}".utf8)
            MockURLProtocol.stubHandler = { request in
                if request.url?.absoluteString.hasSuffix("users/me/") == true {
                    return .init(statusCode: 200, headers: [:], body: user, error: nil)
                }
                return .init(
                    statusCode: request.httpMethod == "GET" ? 200 : 403,
                    headers: [:], body: body, error: nil)
            }
            let fresh: Document
            switch surface {
            case "Search":
                search.query = "Document"
                await search.search()
                fresh = search.results[0]
            case "Home search":
                home.searchQuery = "Document"
                await home.search()
                fresh = home.searchResults[0]
            case "Shared":
                await shared.load()
                fresh = shared.documents[0]
            case "Subpages":
                let editor = EditorViewModel(
                    client: client(), documentID: UUID(), title: "Parent",
                    saveCoordinator: coordinator, signedInUser: SignedInUserStore(userDefaults: defaults),
                    childrenCache: DocumentChildrenCacheStore(userDefaults: defaults))
                await editor.loadChildren()
                fresh = editor.subpages![0]
            default:
                let parent = UUID()
                let tree = PagesTreeViewModel(
                    rootID: parent, client: client(),
                    cache: DocumentChildrenCacheStore(userDefaults: defaults), userDefaults: defaults,
                    saveCoordinator: coordinator, signedInUser: SignedInUserStore(userDefaults: defaults))
                await tree.loadRoot()
                fresh = tree.children[parent]![0]
            }
            XCTAssertFalse(fresh.isFavorite, surface)
            let options = OptionsViewModel(
                client: client(), documentID: id, isFavorite: fresh.isFavorite,
                saveCoordinator: coordinator, signedInUser: SignedInUserStore(userDefaults: defaults), pinRow: fresh)
            XCTAssertFalse(options.isFavorite, surface)
            await home.toggleFavorite(fresh)
            await waitUntil {
                !coordinator.pins.isSyncing && PendingDocumentPinStore(userDefaults: self.defaults).allPins().isEmpty
            }
            XCTAssertFalse(options.isFavorite, surface)
            XCTAssertTrue(home.pinnedDocuments.isEmpty, surface)
            XCTAssertEqual(options.errorKey, .options_error_toggle_favorite, surface)
            coordinator.completeImmediateDelete(documentID: id)
        }
    }

    func testFreshFlagObservationIsDurableAndFilingRetainsItsPlacement() async {
        _ = stub()
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: true))
        await pins.sync(isBlocked: { _ in false })
        pins.didReadFlags([row()], ownerUserID: owner, fetchedAt: pins.revision)
        XCTAssertFalse(self.pins().value(for: id, fallback: true, ownerUserID: owner, fetchedAt: -1))
        pins.documentMoved(documentID: id, newParentID: UUID())
        XCTAssertTrue(self.pins().resolve(pinned: [], recent: [], ownerUserID: owner, fetchedAt: -1).recent.isEmpty)
    }

    func testFlagObservationsCannotConsumePendingIntentOrUndoNewerSettlement() async {
        _ = stub()
        let pins = pins()
        let oldRead = pins.revision
        XCTAssertTrue(queue(pins, pinned: true))
        pins.didReadFlags([row()], ownerUserID: owner, fetchedAt: pins.revision)
        XCTAssertTrue(pins.value(for: id, fallback: false, ownerUserID: owner, fetchedAt: -1))
        XCTAssertEqual(PendingDocumentPinStore(userDefaults: defaults).allPins().count, 1)
        await pins.sync(isBlocked: { _ in false })
        pins.didReadFlags([row()], ownerUserID: owner, fetchedAt: oldRead)
        XCTAssertTrue(pins.value(for: id, fallback: false, ownerUserID: owner, fetchedAt: -1))
        SignedInUserStore(userDefaults: defaults).remember(UUID())
        pins.didReadFlags([row()], ownerUserID: owner, fetchedAt: pins.revision)
        XCTAssertTrue(self.pins().value(for: id, fallback: false, ownerUserID: owner, fetchedAt: -1))
    }

    func testHomePartialPagesPreserveKnownStateAndRollbackAfterRelaunch() async {
        for known in [true, false] {
            _ = stub()
            let pins = pins()
            XCTAssertTrue(queue(pins, pinned: known, row: row(pinned: !known)))
            await pins.sync(isBlocked: { _ in false })
            pins.didCacheFreshLists(pinned: [], recent: [], ownerUserID: owner, fetchedAt: pins.revision)
            let restored = self.pins()
            XCTAssertEqual(restored.value(for: id, fallback: !known, ownerUserID: owner, fetchedAt: -1), known)
            let shown = restored.resolve(pinned: [], recent: [], ownerUserID: owner, fetchedAt: -1, fromCache: true)
            XCTAssertTrue(shown.pinned.isEmpty, "cached first-page membership remains authoritative")
            XCTAssertTrue(shown.recent.isEmpty)
            _ = stub(status: 403)
            XCTAssertTrue(queue(restored, pinned: !known, row: row(pinned: !known)))
            await restored.sync(isBlocked: { _ in false })
            XCTAssertEqual(restored.value(for: id, fallback: !known, ownerUserID: owner, fetchedAt: -1), known)
            restored.remove(documentID: id)
        }
    }

    func testHomeKnownRowStillProtectsOlderSubpageMetadataOnRelaunch() async {
        _ = stub()
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: true))
        await pins.sync(isBlocked: { _ in false })
        pins.didCacheFreshLists(pinned: [row(pinned: true)], recent: [], ownerUserID: owner, fetchedAt: pins.revision)
        XCTAssertTrue(self.pins().value(for: id, fallback: false, ownerUserID: owner, fetchedAt: -1))
    }

    func testWorkOfflineKeepsFreshPartialPageMembershipAndMatchesRelaunch() async {
        _ = stub()
        let (coordinator, home, _, _, _) = environment()
        XCTAssertTrue(queue(coordinator.pins, pinned: true))
        await coordinator.syncPendingPins()
        let recent = Self.page([row(pinned: true)])
        let empty = Self.page([])
        let user = Data("{\"id\":\"\(owner.uuidString)\"}".utf8)
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            let body = url.hasSuffix("users/me/") ? user : (url.contains("favorite") ? empty : recent)
            return .init(statusCode: 200, headers: [:], body: body, error: nil)
        }
        await home.load()
        XCTAssertTrue(home.pinnedDocuments.isEmpty)
        XCTAssertEqual(home.recentDocuments.map(\.id), [id])
        defaults.set(true, forKey: "schrift.workOffline")
        await home.load()
        XCTAssertTrue(home.pinnedDocuments.isEmpty)
        XCTAssertEqual(home.recentDocuments.map(\.id), [id])
        let (_, relaunched, options, _, _) = environment()
        XCTAssertEqual(home.pinnedDocuments, relaunched.pinnedDocuments)
        XCTAssertEqual(home.recentDocuments, relaunched.recentDocuments)
        XCTAssertTrue(options.isFavorite)
    }
}
