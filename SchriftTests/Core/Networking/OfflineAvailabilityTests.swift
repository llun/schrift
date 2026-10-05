import XCTest

@testable import Schrift

@MainActor
final class OfflineAvailabilityTests: XCTestCase {
    private let documentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private var suite: String!
    private var defaults: UserDefaults!
    private var directory: URL!
    private var path: FakePath!
    private var connectivity: ConnectivityMonitor!
    private var availability: OnlineAvailability!
    private var client: DocsAPIClient!
    private var cache: DocumentContentCacheStore!
    private var drafts: PendingDraftStore!
    private var coordinator: DocumentSaveCoordinator!

    private final class FakePath: @unchecked Sendable {
        var update: (@Sendable (Bool) -> Void)?
    }

    override func setUp() {
        super.setUp()
        suite = "OfflineAvailabilityTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let fake = FakePath()
        path = fake
        connectivity = ConnectivityMonitor(
            monitoring: NetworkPathMonitoring { update in
                fake.update = update
                return {}
            })
        availability = OnlineAvailability(connectivity: connectivity, userDefaults: defaults)
        client = DocsAPIClient(
            baseURL: URL(string: "https://docs.example.org/api/v1.0/")!,
            session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        cache = DocumentContentCacheStore(directory: directory)
        drafts = PendingDraftStore(userDefaults: defaults)
        coordinator = DocumentSaveCoordinator(
            client: client, draftStore: drafts, contentCache: cache,
            createStore: PendingDocumentCreateStore(userDefaults: defaults),
            deleteStore: PendingDocumentDeleteStore(userDefaults: defaults),
            listCache: DocumentCacheStore(userDefaults: defaults),
            childrenCache: DocumentChildrenCacheStore(userDefaults: defaults),
            serverOrigin: "https://docs.example.org", backgroundTasks: .noop)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        coordinator = nil
        client = nil
        availability = nil
        connectivity = nil
        super.tearDown()
    }

    private func workOffline(_ value: Bool) {
        defaults.set(value, forKey: "schrift.workOffline")
        availability.preferencesChanged()
    }

    private func disconnect() async {
        path.update?(false)
        await waitUntil { self.availability.isOffline }
    }

    private func reconnect() async {
        path.update?(true)
        await waitUntil { !self.availability.isOffline }
    }

    private func editor() -> EditorViewModel {
        EditorViewModel(
            client: client, documentID: documentID, title: "Doc", saveCoordinator: coordinator,
            contentCache: cache, childrenCache: DocumentChildrenCacheStore(userDefaults: defaults),
            availability: availability)
    }

    private func search() -> SearchViewModel {
        SearchViewModel(client: client, store: RecentSearchesStore(userDefaults: defaults), availability: availability)
    }

    private func home() -> HomeViewModel {
        HomeViewModel(
            client: client, cache: DocumentCacheStore(userDefaults: defaults), saveCoordinator: coordinator,
            userDefaults: defaults, availability: availability)
    }

    private func cached(_ markdown: String = "Cached body") {
        cache.save(CachedDocumentContent(documentID: documentID, title: "Cached", markdown: markdown, syncedAt: Date()))
    }

    private var formatted: Data {
        Data(
            """
            {"id":"11111111-1111-4111-8111-111111111111","title":"Doc","content":"Online body",
             "created_at":"2026-01-15T10:30:00Z","updated_at":"2026-01-15T10:30:00Z"}
            """.utf8)
    }

    private var page: Data {
        Data(
            """
            {"count":1,"results":[{"id":"11111111-1111-4111-8111-111111111111","title":"Result",
             "abilities":{},"link_reach":"restricted","link_role":"reader","is_favorite":false,
             "depth":1,"numchild":0,"path":"0001","created_at":"2026-01-15T10:30:00Z",
             "updated_at":"2026-01-15T10:30:00Z"}]}
            """.utf8)
    }

    func testOfflineCachedAndDraftDocumentsRemainReadableAndEditableWithoutRequests() async {
        cached()
        workOffline(true)
        let model = editor()
        await model.load()
        await model.refresh()
        await model.loadChildren()
        XCTAssertEqual(model.currentMarkdown(), "Cached body")
        XCTAssertTrue(model.canStartEditing)
        XCTAssertFalse(model.needsOnlineContent)
        XCTAssertNil(model.errorKey)
        XCTAssertNil(MockURLProtocol.lastRequest)

        drafts.save(PendingDraft(documentID: documentID, title: "Draft", markdown: "My draft", updatedAt: Date()))
        cache.remove(documentID: documentID)
        let draftModel = editor()
        await draftModel.load()
        XCTAssertEqual(draftModel.currentMarkdown(), "My draft")
        XCTAssertTrue(draftModel.canStartEditing)
        XCTAssertNil(draftModel.errorKey)
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testUncachedOfflineDocumentExplainsOnlineRequirementAndCannotCreateAnEmptyDraft() async {
        await disconnect()
        let model = editor()
        await model.load()
        model.startEditing()
        model.flushPendingChanges()
        XCTAssertTrue(model.needsOnlineContent)
        XCTAssertFalse(model.hasLoadedContent)
        XCTAssertFalse(model.canStartEditing)
        XCTAssertFalse(model.isEditing)
        XCTAssertNil(model.errorKey)
        XCTAssertNil(drafts.draft(for: documentID))
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testCachedEmptyDocumentCanStillBeEditedOffline() async {
        cached("")
        await disconnect()
        let model = editor()
        await model.load()
        XCTAssertTrue(model.hasLoadedContent)
        XCTAssertFalse(model.needsOnlineContent)
        model.startEditing()
        XCTAssertTrue(model.isEditing)
    }

    func testUncachedDocumentLoadsAfterReconnectWithoutRecreatingItsModel() async {
        await disconnect()
        let model = editor()
        await model.load()
        XCTAssertTrue(model.needsOnlineContent)
        let body = formatted
        MockURLProtocol.stubHandler = { request in
            .init(
                statusCode: 200, headers: [:],
                body: request.url!.path.contains("children") ? Data("{\"results\":[]}".utf8) : body, error: nil)
        }
        await reconnect()
        await model.reloadAfterReconnect()
        XCTAssertTrue(model.hasLoadedContent)
        XCTAssertFalse(model.needsOnlineContent)
        XCTAssertEqual(model.currentMarkdown(), "Online body")
        XCTAssertNil(model.errorKey)
    }

    func testOfflineTransitionStopsSpinnerAndOldLoadCannotClearReconnectSpinner() async {
        let body = formatted
        let oldGate = MockURLProtocol.ResponseGate()
        let newGate = MockURLProtocol.ResponseGate()
        let counter = Counter()
        MockURLProtocol.stubHandler = { _ in
            .init(
                statusCode: 200, headers: [:], body: body, error: nil,
                releasedBy: counter.next() == 1 ? oldGate : newGate)
        }
        let model = editor()
        let old = Task { await model.load() }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        await disconnect()
        model.pauseLoadingWhileOffline()
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.needsOnlineContent)
        await reconnect()
        let fresh = Task { await model.reloadAfterReconnect() }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 2 }
        XCTAssertTrue(model.isLoading)
        oldGate.open()
        await old.value
        XCTAssertTrue(model.isLoading, "old load must not end the reconnect spinner")
        XCTAssertFalse(model.hasLoadedContent)
        newGate.open()
        await fresh.value
        XCTAssertTrue(model.hasLoadedContent)
        XCTAssertFalse(model.isLoading)
    }

    func testUnavailableSearchAndQuickAccessAndVersionsIssueNoRequestsAndRecover() async {
        workOffline(true)
        let model = search()
        let inline = home()
        let versions = VersionHistoryViewModel(client: client, documentID: documentID, availability: availability)
        model.query = "Roadmap"
        inline.searchQuery = "Roadmap"
        await model.search()
        await model.loadQuickAccess()
        await inline.search()
        await versions.load()
        XCTAssertNil(MockURLProtocol.lastRequest)
        XCTAssertFalse(model.isSearching)
        XCTAssertFalse(versions.isLoading)
        XCTAssertNil(model.errorKey)
        XCTAssertNil(inline.errorKey)
        XCTAssertNil(versions.errorKey)
        workOffline(false)
        let body = page
        MockURLProtocol.stubHandler = { request in
            .init(
                statusCode: 200, headers: [:],
                body: request.url!.path.contains("versions") ? Data("{\"versions\":[]}".utf8) : body, error: nil)
        }
        await model.search()
        await inline.search()
        await model.loadQuickAccess()
        await versions.load()
        XCTAssertEqual(model.results.map(\.title), ["Result"])
        XCTAssertEqual(inline.searchResults.map(\.title), ["Result"])
        XCTAssertEqual(model.quickAccess.map(\.title), ["Result"])
        XCTAssertFalse(model.isSearching)
    }

    func testPathFlapInvalidatesSearchResponseEvenAfterReconnect() async {
        let model = search()
        model.query = "Roadmap"
        let gate = MockURLProtocol.ResponseGate()
        let body = page
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: body, error: nil, releasedBy: gate)
        }
        let task = Task { await model.search() }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        await disconnect()
        await reconnect()
        gate.open()
        await task.value
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(model.errorKey)
        XCTAssertFalse(model.isSearching)
    }

    func testWorkOfflineFlapInvalidatesQuickAccessAndInlineAndVersionResponses() async {
        let quick = search()
        let inline = home()
        inline.searchQuery = "Roadmap"
        let versions = VersionHistoryViewModel(client: client, documentID: documentID, availability: availability)
        let body = page
        let gate = MockURLProtocol.ResponseGate()
        MockURLProtocol.stubHandler = { request in
            .init(
                statusCode: 200, headers: [:],
                body: request.url!.path.contains("versions")
                    ? Data(
                        "{\"versions\":[{\"version_id\":\"stale\",\"last_modified\":\"2026-01-15T10:30:00Z\"}]}".utf8)
                    : body, error: nil, releasedBy: gate)
        }
        let a = Task { await quick.loadQuickAccess() }
        let b = Task { await inline.search() }
        let c = Task { await versions.load() }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 3 }
        workOffline(true)
        workOffline(false)
        gate.open()
        await a.value
        await b.value
        await c.value
        XCTAssertTrue(quick.quickAccess.isEmpty)
        XCTAssertTrue(inline.searchResults.isEmpty)
        XCTAssertTrue(versions.versions.isEmpty)
        XCTAssertFalse(versions.isLoading)
    }

    func testServerAndAuthenticationErrorsDoNotClaimMissingOfflineContent() async {
        for status in [401, 403, 404, 429, 500] {
            let model = editor()
            MockURLProtocol.stubHandler = { _ in .init(statusCode: status, headers: [:], body: Data(), error: nil) }
            await model.load()
            XCTAssertFalse(model.needsOnlineContent, "HTTP \(status) is not offline")
            XCTAssertNotNil(model.errorKey)
            XCTAssertFalse(availability.isOffline)
            let errorKey = model.errorKey
            workOffline(true)
            model.pauseLoadingWhileOffline()
            await model.load()
            XCTAssertEqual(model.errorKey, errorKey, "Offline must not erase HTTP \(status) errors")
            workOffline(false)
        }
    }

    func testReconnectDoesNotEraseAnUnrelatedEditorActionError() async {
        cached()
        workOffline(true)
        let model = editor()
        await model.load()
        model.errorKey = .options_error_delete
        model.pauseLoadingWhileOffline()
        XCTAssertEqual(model.errorKey, .options_error_delete)
        workOffline(false)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }
        await model.reloadAfterReconnect()
        XCTAssertEqual(model.errorKey, .options_error_delete)
        XCTAssertEqual(model.currentMarkdown(), "Cached body")
    }

    func testOfflineShareDoesNotRemoveEditingOrOptionsActions() {
        XCTAssertEqual(editorToolbarActions(isEditing: false, isOffline: true), [.edit, .options])
        XCTAssertEqual(editorToolbarActions(isEditing: true, isOffline: true), [.done, .options])
        XCTAssertEqual(editorToolbarActions(isEditing: false, isOffline: false), [.edit, .share, .options])
    }
}
