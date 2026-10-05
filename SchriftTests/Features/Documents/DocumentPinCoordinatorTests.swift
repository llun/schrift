import XCTest

@testable import Schrift

@MainActor
final class DocumentPinCoordinatorTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private let owner = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let origin = "https://docs.example.org"

    override func setUp() {
        super.setUp()
        suite = "DocumentPinCoordinatorTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        SignedInUserStore(userDefaults: defaults).remember(owner)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func row(pinned: Bool = false) -> Document {
        Document(
            id: id, title: "Document", excerpt: nil, abilities: DocumentAbilities(),
            linkReach: .restricted, linkRole: .reader, isFavorite: pinned, depth: 1, numchild: 0,
            path: "0001", createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
            userRole: nil, creator: nil)
    }

    private func client(origin: String? = nil) -> DocsAPIClient {
        DocsAPIClient(
            baseURL: URL(string: (origin ?? self.origin) + "/api/v1.0/")!,
            session: MockURLProtocol.makeSession(), cookieProvider: { [] })
    }

    private func pins(origin: String? = nil) -> DocumentPinCoordinator {
        DocumentPinCoordinator(
            client: client(origin: origin), store: PendingDocumentPinStore(userDefaults: defaults),
            cache: DocumentCacheStore(userDefaults: defaults), serverOrigin: origin ?? self.origin,
            signedInUser: SignedInUserStore(userDefaults: defaults), userDefaults: defaults)
    }

    private func stub(
        status: Int = 204, error: Error? = nil, gate: MockURLProtocol.ResponseGate? = nil, user: UUID? = nil
    )
        -> RequestRecorder
    {
        let log = RequestRecorder()
        let userBody = Data("{\"id\":\"\((user ?? owner).uuidString)\"}".utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            if request.url?.absoluteString.hasSuffix("/users/me/") == true {
                return .init(statusCode: 200, headers: [:], body: userBody, error: nil)
            }
            return .init(
                statusCode: status, headers: ["Content-Type": "application/json"], body: Data(), error: error,
                releasedBy: gate)
        }
        return log
    }

    @discardableResult
    private func queue(_ pins: DocumentPinCoordinator, pinned: Bool, row: Document? = nil) -> Bool {
        pins.queue(documentID: id, isPinned: pinned, row: row ?? self.row(), ownerUserID: owner)
    }

    func testOfflinePinAndUnpinImmediatelyChangeMembershipWithoutChangingRawCaches() async {
        let log = stub(error: URLError(.notConnectedToInternet))
        let cache = DocumentCacheStore(userDefaults: defaults)
        cache.savePinnedDocuments([])
        cache.saveRecentDocuments([row()])
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: true))
        var shown = pins.resolve(pinned: [], recent: [row()], ownerUserID: owner, fetchedAt: -1)
        XCTAssertEqual(shown.pinned.map(\.id), [id])
        XCTAssertTrue(recentsExcludingPinned(recent: shown.recent, pinned: shown.pinned).isEmpty)
        await pins.sync(isBlocked: { _ in false })
        XCTAssertEqual(log.count(ofMethod: "POST", urlContaining: "/favorite/"), 1)
        XCTAssertEqual(cache.loadPinnedDocuments(), [], "pending intent must not leak through unscoped metadata")
        XCTAssertTrue(queue(pins, pinned: false))
        shown = pins.resolve(pinned: [], recent: [row()], ownerUserID: owner, fetchedAt: -1)
        XCTAssertTrue(shown.pinned.isEmpty)
        XCTAssertEqual(shown.recent.map(\.id), [id])
        XCTAssertFalse(shown.recent[0].isFavorite)
    }

    func testRepeatedTogglesCoalesceAndSurviveRelaunch() {
        let original = pins()
        for value in [true, false, true, false] { XCTAssertTrue(queue(original, pinned: value)) }
        let records = PendingDocumentPinStore(userDefaults: defaults).allPins()
        XCTAssertEqual(records.count, 1)
        XCTAssertFalse(records[0].isPinned)
        let relaunched = pins()
        let shown = relaunched.resolve(
            pinned: [row(pinned: true)], recent: [row(pinned: true)], ownerUserID: owner, fetchedAt: -1)
        XCTAssertTrue(shown.pinned.isEmpty)
        XCTAssertFalse(shown.recent[0].isFavorite)
    }

    func testAnAgreeingStaleFetchDoesNotConsumeUnsentIntent() {
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: true))
        _ = pins.resolve(
            pinned: [row(pinned: true)], recent: [row(pinned: true)], ownerUserID: owner, fetchedAt: pins.revision)
        XCTAssertEqual(PendingDocumentPinStore(userDefaults: defaults).allPins().count, 1)
        XCTAssertEqual(
            pins.resolve(pinned: [], recent: [], ownerUserID: owner, fetchedAt: pins.revision).pinned.map(\.id), [id])
    }

    func testReconnectSendsLatestIntentAndSettlesDurably() async {
        let log = stub()
        let pins = pins()
        for value in [true, false, true] { XCTAssertTrue(queue(pins, pinned: value)) }
        await pins.sync(isBlocked: { _ in false })
        XCTAssertEqual(log.count(ofMethod: "POST", urlContaining: "/favorite/"), 1)
        XCTAssertEqual(log.count(ofMethod: "DELETE", urlContaining: "/favorite/"), 0)
        XCTAssertTrue(PendingDocumentPinStore(userDefaults: defaults).allPins().isEmpty)
    }

    func testUnpinUsesDeleteAndKeepsRowAvailableInRecent() async {
        let log = stub()
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: false, row: row(pinned: true)))
        await pins.sync(isBlocked: { _ in false })
        XCTAssertEqual(log.count(ofMethod: "DELETE", urlContaining: "/favorite/"), 1)
        let shown = pins.resolve(pinned: [row(pinned: true)], recent: [], ownerUserID: owner, fetchedAt: -1)
        XCTAssertTrue(shown.pinned.isEmpty)
        XCTAssertEqual(shown.recent.map(\.id), [id], "an unpin hands a pinned-only row back immediately")
    }

    func testOldMutationSuccessCannotSettleANewerToggle() async {
        let gate = MockURLProtocol.ResponseGate()
        defer { gate.open() }
        let log = stub(gate: gate)
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: true))
        let syncing = Task { await pins.sync(isBlocked: { _ in false }) }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        XCTAssertTrue(queue(pins, pinned: false))
        gate.open()
        await syncing.value
        XCTAssertEqual(log.count(ofMethod: "DELETE", urlContaining: "/favorite/"), 1)
        XCTAssertTrue(PendingDocumentPinStore(userDefaults: defaults).allPins().isEmpty)
        XCTAssertTrue(
            pins.resolve(pinned: [row(pinned: true)], recent: [], ownerUserID: owner, fetchedAt: -1).pinned.isEmpty)
    }

    func testOldFetchAfterSuccessIsOverlaidButFreshServerChangesAreAllowed() async {
        _ = stub()
        let pins = pins()
        let oldFetch = pins.revision
        XCTAssertTrue(queue(pins, pinned: true))
        await pins.sync(isBlocked: { _ in false })
        XCTAssertEqual(
            pins.resolve(pinned: [], recent: [row()], ownerUserID: owner, fetchedAt: oldFetch).pinned.map(\.id), [id])
        XCTAssertTrue(
            pins.resolve(pinned: [], recent: [row()], ownerUserID: owner, fetchedAt: pins.revision).pinned.isEmpty)
    }

    func testWorkOfflineMakesNoRequestsAndKeepsIntent() async {
        let log = stub()
        defaults.set(true, forKey: "schrift.workOffline")
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: true))
        await pins.sync(isBlocked: { _ in false })
        XCTAssertTrue(log.methods.isEmpty)
        XCTAssertEqual(PendingDocumentPinStore(userDefaults: defaults).allPins().count, 1)
    }

    func testRetryableFailuresAndSessionExpiryRetainIntent() async {
        for status in [401, 429, 500, 503] {
            _ = stub(status: status)
            let pins = pins()
            XCTAssertTrue(queue(pins, pinned: true))
            await pins.sync(isBlocked: { _ in false })
            XCTAssertEqual(PendingDocumentPinStore(userDefaults: defaults).allPins().count, 1, "status \(status)")
        }
    }

    func testTerminalRejectionRestoresPriorStateAndReportsPinError() async {
        for status in [400, 403, 404, 405] {
            _ = stub(status: status)
            let pins = pins()
            XCTAssertTrue(queue(pins, pinned: true))
            await pins.sync(isBlocked: { _ in false })
            XCTAssertTrue(PendingDocumentPinStore(userDefaults: defaults).allPins().isEmpty)
            XCTAssertFalse(pins.value(for: id, fallback: false, ownerUserID: owner, fetchedAt: -1))
            XCTAssertEqual(pins.failure(for: id, ownerUserID: owner), .options_error_toggle_favorite)
        }
    }

    func testOtherAccountAndServerNeitherSeeNorReplayIntent() async {
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: true))
        let other = UUID()
        let log = stub(user: other)
        SignedInUserStore(userDefaults: defaults).remember(other)
        XCTAssertTrue(pins.resolve(pinned: [], recent: [row()], ownerUserID: other, fetchedAt: -1).pinned.isEmpty)
        await pins.sync(isBlocked: { _ in false })
        XCTAssertEqual(log.count(ofMethod: "POST"), 0)
        let otherServer = self.pins(origin: "https://other.example.org")
        XCTAssertTrue(
            otherServer.resolve(pinned: [], recent: [row()], ownerUserID: owner, fetchedAt: -1).pinned.isEmpty)
        await otherServer.sync(isBlocked: { _ in false })
        XCTAssertEqual(log.count(ofMethod: "POST"), 0)
        XCTAssertEqual(PendingDocumentPinStore(userDefaults: defaults).allPins().count, 1)
    }

    func testServerAccountMustAgreeWithRememberedAccountBeforeReplay() async {
        let log = stub(user: UUID())
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: true))
        await pins.sync(isBlocked: { _ in false })
        XCTAssertEqual(log.count(ofMethod: "POST"), 0)
        XCTAssertEqual(PendingDocumentPinStore(userDefaults: defaults).allPins().count, 1)
    }

    func testAccountChangeDuringReplayCannotSettleOrPublishOldIntent() async {
        let gate = MockURLProtocol.ResponseGate()
        defer { gate.open() }
        let log = stub(gate: gate)
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: true))
        let syncing = Task { await pins.sync(isBlocked: { _ in false }) }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        let other = UUID()
        SignedInUserStore(userDefaults: defaults).remember(other)
        gate.open()
        await syncing.value
        XCTAssertEqual(PendingDocumentPinStore(userDefaults: defaults).allPins().count, 1)
        XCTAssertTrue(pins.resolve(pinned: [], recent: [row()], ownerUserID: other, fetchedAt: -1).pinned.isEmpty)
        XCTAssertTrue(DocumentCacheStore(userDefaults: defaults).loadPinnedDocuments().isEmpty)
    }

    func testDeletionHoldsPinReplayAndUndoReleasesIt() async {
        let log = stub()
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: true))
        await pins.sync(isBlocked: { _ in true })
        XCTAssertEqual(log.count(ofMethod: "POST"), 0)
        XCTAssertEqual(PendingDocumentPinStore(userDefaults: defaults).allPins().count, 1)
        await pins.sync(isBlocked: { _ in false })
        XCTAssertEqual(log.count(ofMethod: "POST"), 1)
    }

    func testCompletedDeletionDropsIntentAndAnySettledOverlay() async {
        _ = stub()
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: true))
        await pins.sync(isBlocked: { _ in false })
        XCTAssertTrue(queue(pins, pinned: false))
        pins.remove(documentID: id)
        XCTAssertTrue(PendingDocumentPinStore(userDefaults: defaults).allPins().isEmpty)
        XCTAssertTrue(pins.resolve(pinned: [], recent: [], ownerUserID: owner, fetchedAt: -1).pinned.isEmpty)
    }
    private func environment() -> (
        DocumentSaveCoordinator, HomeViewModel, OptionsViewModel, SharedViewModel, SearchViewModel
    ) {
        let client = client()
        let cache = DocumentCacheStore(userDefaults: defaults)
        let signedIn = SignedInUserStore(userDefaults: defaults)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: PendingDraftStore(userDefaults: defaults),
            createStore: PendingDocumentCreateStore(userDefaults: defaults),
            deleteStore: PendingDocumentDeleteStore(userDefaults: defaults),
            pinStore: PendingDocumentPinStore(userDefaults: defaults),
            attachmentStore: PendingAttachmentStore(userDefaults: defaults), listCache: cache,
            childrenCache: DocumentChildrenCacheStore(userDefaults: defaults), serverOrigin: origin,
            backgroundTasks: .noop)
        let home = HomeViewModel(
            client: client, cache: cache, saveCoordinator: coordinator, userDefaults: defaults, signedInUser: signedIn)
        let options = OptionsViewModel(
            client: client, documentID: id, isFavorite: false, saveCoordinator: coordinator, signedInUser: signedIn)
        let shared = SharedViewModel(
            client: client, cache: cache, userDefaults: defaults, saveCoordinator: coordinator, signedInUser: signedIn)
        let search = SearchViewModel(
            client: client, store: RecentSearchesStore(userDefaults: defaults), saveCoordinator: coordinator,
            signedInUser: signedIn)
        return (coordinator, home, options, shared, search)
    }

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

    func testActionsNeverAddressLocalUUIDOrPendingDeletion() async {
        let log = stub()
        let (coordinator, _, _, _, _) = environment()
        let actions = DocumentActions(
            client: client(), saveCoordinator: coordinator, signedInUser: SignedInUserStore(userDefaults: defaults))
        let local = coordinator.createLocalDocument(title: "Local", parentID: nil, ownerUserID: owner)
        let localResult = await actions.setFavorite(documentID: local.id, isFavorite: true)
        XCTAssertEqual(localResult, .failed)
        coordinator.recordPendingDelete(documentID: id, ownerUserID: owner)
        let deletedResult = await actions.setFavorite(documentID: id, isFavorite: true)
        XCTAssertEqual(deletedResult, .failed)
        XCTAssertTrue(log.methods.isEmpty)
        XCTAssertTrue(PendingDocumentPinStore(userDefaults: defaults).allPins().isEmpty)
    }

    func testRealCoordinatorDeletionHoldUndoAndCompletionProtectPinIntent() async {
        defaults.set(true, forKey: "schrift.workOffline")
        let log = stub()
        let (coordinator, home, _, _, _) = environment()
        await home.toggleFavorite(row())
        coordinator.recordPendingDelete(documentID: id, ownerUserID: owner)
        defaults.set(false, forKey: "schrift.workOffline")
        await coordinator.syncPendingPins()
        XCTAssertEqual(log.count(ofMethod: "POST"), 0)
        XCTAssertEqual(PendingDocumentPinStore(userDefaults: defaults).allPins().count, 1)
        coordinator.cancelPendingDelete(documentID: id)
        await coordinator.syncPendingPins()
        XCTAssertEqual(log.count(ofMethod: "POST"), 1)
        defaults.set(true, forKey: "schrift.workOffline")
        await home.toggleFavorite(home.pinnedDocuments[0])
        coordinator.completeImmediateDelete(documentID: id)
        XCTAssertTrue(PendingDocumentPinStore(userDefaults: defaults).allPins().isEmpty)
        XCTAssertTrue(PendingDocumentPinStore(userDefaults: defaults).allSettled().isEmpty)
        XCTAssertTrue(home.pinnedDocuments.isEmpty)
        XCTAssertTrue(home.recentDocuments.isEmpty)
    }

    func testSuccessThenStaleCacheAndRelaunchKeepsScopedSettledProjection() async {
        _ = stub()
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: true))
        await pins.sync(isBlocked: { _ in false })
        let cache = DocumentCacheStore(userDefaults: defaults)
        cache.savePinnedDocuments([])
        cache.saveRecentDocuments([row()])
        let restored = self.pins()
        XCTAssertEqual(
            restored.resolve(pinned: [], recent: [row()], ownerUserID: owner, fetchedAt: -1).pinned.map(\.id), [id])
        XCTAssertTrue(restored.resolve(pinned: [], recent: [row()], ownerUserID: UUID(), fetchedAt: -1).pinned.isEmpty)
        restored.didCacheFreshLists(pinned: [], recent: [row()], ownerUserID: owner, fetchedAt: restored.revision)
        XCTAssertTrue(PendingDocumentPinStore(userDefaults: defaults).allSettled().isEmpty)
        XCTAssertFalse(
            restored.value(for: id, fallback: true, ownerUserID: owner, fetchedAt: -1),
            "a fresh web unpin reaches older screens")
    }

    func testSupersededSuccessThenLatestRejectionRestoresWhatActuallyLanded() async {
        let gate = MockURLProtocol.ResponseGate()
        defer { gate.open() }
        let log = RequestRecorder()
        let userBody = Data("{\"id\":\"\(owner.uuidString)\"}".utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            if request.httpMethod == "GET" { return .init(statusCode: 200, headers: [:], body: userBody, error: nil) }
            return .init(
                statusCode: request.httpMethod == "POST" ? 204 : 403, headers: [:], body: Data(), error: nil,
                releasedBy: gate
            )
        }
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: true))
        let syncing = Task { await pins.sync(isBlocked: { _ in false }) }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        XCTAssertTrue(queue(pins, pinned: false))
        gate.open()
        await syncing.value
        XCTAssertTrue(pins.value(for: id, fallback: false, ownerUserID: owner, fetchedAt: -1))
        XCTAssertEqual(pins.failure(for: id, ownerUserID: owner), .options_error_toggle_favorite)
        XCTAssertTrue(PendingDocumentPinStore(userDefaults: defaults).allPins().isEmpty)
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

    func testDeleteCompletingDuringPinRequestCannotResurrectTheRowOrIntent() async {
        let gate = MockURLProtocol.ResponseGate()
        defer { gate.open() }
        let log = stub(gate: gate)
        let (coordinator, home, _, _, _) = environment()
        await home.toggleFavorite(row())
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        coordinator.completeImmediateDelete(documentID: id)
        gate.open()
        await coordinator.syncPendingPins()
        await waitUntil { !coordinator.pins.isSyncing }
        XCTAssertTrue(home.pinnedDocuments.isEmpty)
        XCTAssertTrue(home.recentDocuments.isEmpty)
        XCTAssertTrue(PendingDocumentPinStore(userDefaults: defaults).allSettled().isEmpty)
    }

    private nonisolated static func page(_ rows: [Document]) -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        let data = try! encoder.encode(rows)
        return Data(
            "{\"count\":\(rows.count),\"next\":null,\"previous\":null,\"results\":\(String(decoding: data, as: UTF8.self))}"
                .utf8)
    }

    func testPendingPinSurvivesAnActualStaleHomeFetchAndAnAgreeingFetchCannotSettleIt() async {
        let gate = MockURLProtocol.ResponseGate()
        defer { gate.open() }
        defaults.set(true, forKey: "schrift.workOffline")
        let (coordinator, home, _, _, _) = environment()
        home.fetchedRecentDocuments = [row()]
        let oldPage = Self.page([row()])
        let empty = Self.page([])
        let log = RequestRecorder()
        let user = Data("{\"id\":\"\(owner.uuidString)\"}".utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("users/me/") { return .init(statusCode: 200, headers: [:], body: user, error: nil) }
            if request.httpMethod == "POST" { return .init(statusCode: 503, headers: [:], body: Data(), error: nil) }
            return .init(
                statusCode: 200, headers: [:], body: url.contains("favorite") ? empty : oldPage, error: nil,
                releasedBy: url.contains("/documents/") ? gate : nil
            )
        }
        defaults.set(false, forKey: "schrift.workOffline")
        let loading = Task { await home.load() }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 2 }
        let actions = DocumentActions(
            client: client(), saveCoordinator: coordinator, signedInUser: SignedInUserStore(userDefaults: defaults))
        _ = await actions.setFavorite(documentID: id, isFavorite: true, row: row(), isOffline: true)
        gate.open()
        await loading.value
        XCTAssertEqual(home.pinnedDocuments.map(\.id), [id])
        XCTAssertTrue(home.recentDocuments.isEmpty)
        XCTAssertEqual(PendingDocumentPinStore(userDefaults: defaults).allPins().count, 1)
        XCTAssertFalse(home.isLoading)
        let agreeing = Self.page([row(pinned: true)])
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: agreeing, error: nil) }
        await home.load()
        XCTAssertEqual(PendingDocumentPinStore(userDefaults: defaults).allPins().count, 1)
    }

    func testSettledValueWinsOverStaleMetadataForTerminalRollback() async {
        _ = stub()
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: true))
        await pins.sync(isBlocked: { _ in false })
        _ = stub(status: 403)
        XCTAssertTrue(queue(pins, pinned: false, row: row(pinned: false)))
        await pins.sync(isBlocked: { _ in false })
        XCTAssertTrue(pins.value(for: id, fallback: false, ownerUserID: owner, fetchedAt: -1))
    }

    func testFreshMembershipIsIndependentOfRecentFlagsInBothDirections() async {
        for included in [true, false] {
            _ = stub()
            let pins = pins()
            XCTAssertTrue(queue(pins, pinned: true))
            await pins.sync(isBlocked: { _ in false })
            let revision = pins.revision
            let favorites = included ? [row(pinned: true)] : []
            let recent = [row(pinned: !included)]
            pins.didCacheFreshLists(pinned: favorites, recent: recent, ownerUserID: owner, fetchedAt: revision)
            let shown = pins.resolve(pinned: favorites, recent: recent, ownerUserID: owner, fetchedAt: revision)
            XCTAssertEqual(shown.pinned.map(\.id), included ? [id] : [])
            XCTAssertEqual(
                recentsExcludingPinned(recent: shown.recent, pinned: shown.pinned).map(\.id), included ? [] : [id])
            XCTAssertTrue(pins.value(for: id, fallback: false, ownerUserID: owner, fetchedAt: -1))
        }
    }

    func testAbsenceFromBothFirstPagesDoesNotUnpinOlderScreens() async {
        _ = stub()
        let pins = pins()
        XCTAssertTrue(queue(pins, pinned: true))
        await pins.sync(isBlocked: { _ in false })
        let revision = pins.revision
        pins.didCacheFreshLists(pinned: [], recent: [], ownerUserID: owner, fetchedAt: revision)
        XCTAssertTrue(pins.value(for: id, fallback: false, ownerUserID: owner, fetchedAt: -1))
        XCTAssertTrue(pins.resolve(pinned: [], recent: [], ownerUserID: owner, fetchedAt: revision).pinned.isEmpty)
    }

    func testDeletionDoesNotClearAnotherServersSameUUIDSettlement() async {
        _ = stub()
        let other = self.pins(origin: "https://other.example.org")
        XCTAssertTrue(queue(other, pinned: true))
        await other.sync(isBlocked: { _ in false })
        let local = pins()
        XCTAssertTrue(queue(local, pinned: true))
        await local.sync(isBlocked: { _ in false })
        local.remove(documentID: id)
        XCTAssertEqual(
            PendingDocumentPinStore(userDefaults: defaults).allSettled().map(\.serverOrigin),
            ["https://other.example.org"])
        XCTAssertTrue(
            self.pins(origin: "https://other.example.org").value(
                for: id, fallback: false, ownerUserID: owner, fetchedAt: -1))
    }

    func testUnknownIdentityRecoveryResumesPendingReplayOnLaunchAndReconnect() async {
        for reconnect in [false, true] {
            defaults.set(true, forKey: "schrift.workOffline")
            let (_, home, _, _, _) = environment()
            await home.toggleFavorite(row())
            SignedInUserStore(userDefaults: defaults).clear()
            let log = stub()
            defaults.set(false, forKey: "schrift.workOffline")
            if reconnect { await home.syncPendingDrafts() } else { await home.refreshSignedInUser() }
            XCTAssertEqual(log.count(ofMethod: "POST", urlContaining: "/favorite/"), 1)
            XCTAssertTrue(PendingDocumentPinStore(userDefaults: defaults).allPins().isEmpty)
        }
    }

    func testPendingAndSettledUnpinCannotUndoLandedMoveEvenAfterRelaunch() async {
        for settled in [false, true] {
            defaults.set(true, forKey: "schrift.workOffline")
            let (coordinator, home, _, _, _) = environment()
            home.pinnedDocuments = [row(pinned: true)]
            await home.toggleFavorite(row(pinned: true))
            if settled {
                _ = stub()
                defaults.set(false, forKey: "schrift.workOffline")
                await coordinator.syncPendingPins()
                defaults.set(true, forKey: "schrift.workOffline")
            }
            coordinator.completeDocumentMove(documentID: id, row: row(), newParentID: UUID())
            XCTAssertTrue(home.recentDocuments.isEmpty)
            let (_, relaunched, _, _, _) = environment()
            XCTAssertTrue(relaunched.recentDocuments.isEmpty)
            coordinator.completeDocumentMove(documentID: id, row: row(), newParentID: nil)
            XCTAssertEqual(home.recentDocuments.map(\.id), [id])
            coordinator.completeImmediateDelete(documentID: id)
        }
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

    func testMoveDuringUnpinRequestSurvivesSettlementAndRelaunch() async {
        let gate = MockURLProtocol.ResponseGate()
        defer { gate.open() }
        _ = stub(gate: gate)
        defaults.set(true, forKey: "schrift.workOffline")
        let (coordinator, home, _, _, _) = environment()
        home.pinnedDocuments = [row(pinned: true)]
        await home.toggleFavorite(row(pinned: true))
        defaults.set(false, forKey: "schrift.workOffline")
        let syncing = Task { await coordinator.syncPendingPins() }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        coordinator.completeDocumentMove(documentID: id, row: row(), newParentID: UUID())
        gate.open()
        await syncing.value
        XCTAssertTrue(home.recentDocuments.isEmpty)
        let (_, restored, _, _, _) = environment()
        XCTAssertTrue(restored.recentDocuments.isEmpty)
        XCTAssertTrue(PendingDocumentPinStore(userDefaults: defaults).allPins().isEmpty)
    }

    func testLaterServerFeedCanIncludeFiledUnpinnedDocument() async {
        defaults.set(true, forKey: "schrift.workOffline")
        let (coordinator, home, _, _, _) = environment()
        home.pinnedDocuments = [row(pinned: true)]
        await home.toggleFavorite(row(pinned: true))
        coordinator.completeDocumentMove(documentID: id, row: row(), newParentID: UUID())
        // Placement only prohibits synthetic fallback. A future server may include subpages.
        home.fetchedRecentDocuments = [row()]
        XCTAssertEqual(home.recentDocuments.map(\.id), [id])
    }

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

    func testLearningIdentityInvalidatesProjectionEvenWhenReplayRemainsOffline() async {
        defaults.set(true, forKey: "schrift.workOffline")
        let (coordinator, home, _, _, _) = environment()
        await home.toggleFavorite(row())
        SignedInUserStore(userDefaults: defaults).clear()
        XCTAssertTrue(home.pinnedDocuments.isEmpty)
        let revision = coordinator.pins.revision
        _ = stub(status: 503)
        defaults.set(false, forKey: "schrift.workOffline")
        await home.refreshSignedInUser()
        XCTAssertGreaterThan(coordinator.pins.revision, revision, "identity must invalidate observable list membership")
        XCTAssertEqual(home.pinnedDocuments.map(\.id), [id])
        XCTAssertEqual(PendingDocumentPinStore(userDefaults: defaults).allPins().count, 1)
    }

}
