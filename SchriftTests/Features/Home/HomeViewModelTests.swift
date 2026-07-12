import XCTest

@testable import Schrift

@MainActor
final class HomeViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!

    private var preferences: UserDefaults!
    private var preferencesSuiteName: String!

    override func setUp() {
        super.setUp()
        preferencesSuiteName = "HomeViewModelTests.preferences.\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: preferencesSuiteName)!
    }

    override func tearDown() {
        MockURLProtocol.reset()
        preferences.removePersistentDomain(forName: preferencesSuiteName)
        super.tearDown()
    }

    private func makeCache() -> DocumentCacheStore {
        let suiteName = "HomeViewModelTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        return DocumentCacheStore(userDefaults: userDefaults)
    }

    private func makeViewModel(
        cache: DocumentCacheStore? = nil,
        userDefaults: UserDefaults? = nil,
        diagnostics: APIDiagnosticsLog? = nil
    ) -> HomeViewModel {
        // The client records into the same log the view model reads, exactly as RootView
        // wires them — a separate log would silently never produce a detail.
        let client = DocsAPIClient(
            baseURL: baseURL,
            session: MockURLProtocol.makeSession(),
            cookieProvider: { [] },
            onRequestFailure: { failure in diagnostics?.record(failure) }
        )
        // Isolate the save coordinator's draft store so `load()`'s draft recovery
        // can't replay drafts left in UserDefaults.standard by other tests (which
        // would fire an extra formatted-content GET and pollute recorded URLs).
        let suiteName = "HomeViewModelTests.coordinator.\(UUID().uuidString)"
        let draftStore = PendingDraftStore(userDefaults: UserDefaults(suiteName: suiteName)!)
        let coordinator = DocumentSaveCoordinator(client: client, draftStore: draftStore, backgroundTasks: .noop)
        return HomeViewModel(
            client: client,
            cache: cache ?? makeCache(),
            saveCoordinator: coordinator,
            userDefaults: userDefaults ?? preferences,
            diagnostics: diagnostics
        )
    }

    private static func paginatedFixture(id: String, title: String, isFavorite: Bool) -> Data {
        """
        {
            "count": 1,
            "next": null,
            "previous": null,
            "results": [
                {
                    "id": "\(id)",
                    "title": "\(title)",
                    "excerpt": null,
                    "abilities": {},
                    "computed_link_reach": "restricted",
                    "computed_link_role": null,
                    "created_at": "2026-01-15T10:30:00Z",
                    "creator": null,
                    "depth": 1,
                    "link_role": "reader",
                    "link_reach": "restricted",
                    "numchild": 0,
                    "path": "0001",
                    "updated_at": "2026-01-15T10:30:00Z",
                    "user_role": "owner",
                    "is_favorite": \(isFavorite)
                }
            ]
        }
        """.data(using: .utf8)!
    }

    private static let emptyFixture: Data = #"{"count": 0, "next": null, "previous": null, "results": []}"#.data(
        using: .utf8)!

    func testLoadPopulatesPinnedAndRecentDocuments() async {
        let viewModel = makeViewModel()
        let pinnedBody = Self.paginatedFixture(
            id: "11111111-1111-4111-8111-111111111111", title: "Pinned Doc", isFavorite: true)
        let recentBody = Self.paginatedFixture(
            id: "22222222-2222-4222-8222-222222222222", title: "Recent Doc", isFavorite: false)
        MockURLProtocol.stubHandler = { request in
            let path = request.url?.path ?? ""
            if path.contains("favorite_list") {
                return .init(statusCode: 200, headers: [:], body: pinnedBody, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: recentBody, error: nil)
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.pinnedDocuments.map(\.title), ["Pinned Doc"])
        XCTAssertEqual(viewModel.recentDocuments.map(\.title), ["Recent Doc"])
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.errorKey)
    }

    func testLoadRequestsTheUnfilteredRecentList() async {
        // With the filter sub-tabs removed, the recent list is always the
        // unfiltered feed — no is_favorite / is_creator_me query params.
        let viewModel = makeViewModel()
        let recorder = RequestRecorder()
        let empty = Self.emptyFixture
        MockURLProtocol.stubHandler = { request in
            recorder.record(request)
            return .init(statusCode: 200, headers: [:], body: empty, error: nil)
        }

        await viewModel.load()

        // No request carries a filter query param: the recent list is the
        // unfiltered feed and the pinned list uses its own favorite endpoint.
        XCTAssertEqual(recorder.count(ofMethod: "GET", urlContaining: "is_creator_me"), 0)
        XCTAssertEqual(recorder.count(ofMethod: "GET", urlContaining: "is_favorite"), 0)
    }

    func testShowsPinnedSectionReflectsWhetherPinnedDocumentsExist() {
        let viewModel = makeViewModel()
        XCTAssertFalse(viewModel.showsPinnedSection)

        let pinnedBody = Self.paginatedFixture(
            id: "24242424-2424-4242-8242-242424242424", title: "Pinned", isFavorite: true)
        viewModel.pinnedDocuments = [
            try! JSONDecoder.docsAPI.decode(PaginatedResponse<Document>.self, from: pinnedBody).results[0]
        ]
        XCTAssertTrue(viewModel.showsPinnedSection)
    }

    func testFirstRunWithNoLocalListShowsTheLoadingPlaceholder() async {
        // Nothing cached and no pinned rows: the one first-run spinner shows
        // while the fetch is in flight.
        let viewModel = makeViewModel()
        let recorder = RequestRecorder()
        let gate = DispatchSemaphore(value: 0)
        MockURLProtocol.stubHandler = { request in
            recorder.record(request)
            gate.wait()  // hold the fetch open so the mid-flight state is observable
            return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }

        let load = Task { await viewModel.load() }
        await waitUntil { recorder.count(ofMethod: "GET") >= 1 }  // load() is now in its network phase

        XCTAssertTrue(viewModel.isLoading, "a true first run with nothing local must show the spinner")

        gate.signal()
        gate.signal()
        await load.value
        XCTAssertFalse(viewModel.isLoading)
    }

    func testFirstRunWithCachedPinnedRowsSuppressesTheLoadingPlaceholder() async {
        // Pinned rows are always visible now (no filter can hide their
        // section), so they count as rows on screen and suppress the first-run
        // spinner even when the recent list was never cached.
        let cache = makeCache()
        let pinnedBody = Self.paginatedFixture(
            id: "25252525-2525-4252-8252-252525252525", title: "Cached Pinned", isFavorite: true)
        cache.savePinnedDocuments(
            [try! JSONDecoder.docsAPI.decode(PaginatedResponse<Document>.self, from: pinnedBody).results[0]])
        let viewModel = makeViewModel(cache: cache)
        let recorder = RequestRecorder()
        let gate = DispatchSemaphore(value: 0)
        MockURLProtocol.stubHandler = { request in
            recorder.record(request)
            gate.wait()
            return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }

        let load = Task { await viewModel.load() }
        await waitUntil { recorder.count(ofMethod: "GET") >= 1 }

        XCTAssertFalse(viewModel.isLoading, "visible pinned rows are no first-run spinner")

        gate.signal()
        gate.signal()
        await load.value
    }

    func testSearchWithEmptyQueryClearsResults() async {
        let viewModel = makeViewModel()
        viewModel.searchResults = []
        viewModel.searchQuery = "   "

        await viewModel.search()

        XCTAssertTrue(viewModel.searchResults.isEmpty)
    }

    func testSearchWithQueryPopulatesResults() async {
        let viewModel = makeViewModel()
        viewModel.searchQuery = "Q3"
        let body = Self.paginatedFixture(
            id: "33333333-3333-4333-8333-333333333333", title: "Q3 Planning", isFavorite: false)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }

        await viewModel.search()

        XCTAssertEqual(viewModel.searchResults.map(\.title), ["Q3 Planning"])
    }

    func testLoadFailureSetsErrorMessage() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.load()

        XCTAssertNotNil(viewModel.errorKey)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testInitSeedsPinnedAndRecentDocumentsFromCache() {
        let cache = makeCache()
        let pinnedBody = Self.paginatedFixture(
            id: "55555555-5555-4555-8555-555555555555", title: "Cached Pinned", isFavorite: true)
        let recentBody = Self.paginatedFixture(
            id: "66666666-6666-4666-8666-666666666666", title: "Cached Recent", isFavorite: false)
        let pinnedDocument = try! JSONDecoder.docsAPI.decode(PaginatedResponse<Document>.self, from: pinnedBody)
            .results[0]
        let recentDocument = try! JSONDecoder.docsAPI.decode(PaginatedResponse<Document>.self, from: recentBody)
            .results[0]
        cache.savePinnedDocuments([pinnedDocument])
        cache.saveRecentDocuments([recentDocument])

        let viewModel = makeViewModel(cache: cache)

        XCTAssertEqual(viewModel.pinnedDocuments.map(\.title), ["Cached Pinned"])
        XCTAssertEqual(viewModel.recentDocuments.map(\.title), ["Cached Recent"])
    }

    func testLoadSavesResultsToCache() async {
        let cache = makeCache()
        let viewModel = makeViewModel(cache: cache)
        let pinnedBody = Self.paginatedFixture(
            id: "77777777-7777-4777-8777-777777777777", title: "Pinned Doc", isFavorite: true)
        let recentBody = Self.paginatedFixture(
            id: "88888888-8888-4888-8888-888888888888", title: "Recent Doc", isFavorite: false)
        MockURLProtocol.stubHandler = { request in
            let path = request.url?.path ?? ""
            if path.contains("favorite_list") {
                return .init(statusCode: 200, headers: [:], body: pinnedBody, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: recentBody, error: nil)
        }

        await viewModel.load()

        XCTAssertEqual(cache.loadPinnedDocuments().map(\.title), ["Pinned Doc"])
        XCTAssertEqual(cache.loadRecentDocuments()?.map(\.title), ["Recent Doc"])
    }

    func testLoadFailureKeepsCachedDocumentsVisibleAndStaysSilent() async {
        let cache = makeCache()
        let cachedPinnedBody = Self.paginatedFixture(
            id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", title: "Offline Pinned", isFavorite: true)
        let cachedRecentBody = Self.paginatedFixture(
            id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc", title: "Offline Recent", isFavorite: false)
        let cachedPinnedDocument = try! JSONDecoder.docsAPI.decode(
            PaginatedResponse<Document>.self, from: cachedPinnedBody
        ).results[0]
        let cachedRecentDocument = try! JSONDecoder.docsAPI.decode(
            PaginatedResponse<Document>.self, from: cachedRecentBody
        ).results[0]
        cache.savePinnedDocuments([cachedPinnedDocument])
        cache.saveRecentDocuments([cachedRecentDocument])
        let viewModel = makeViewModel(cache: cache)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.load()

        XCTAssertEqual(viewModel.pinnedDocuments.map(\.title), ["Offline Pinned"])
        XCTAssertEqual(viewModel.recentDocuments.map(\.title), ["Offline Recent"])
        // Passive revalidation failures stay silent behind cached rows.
        XCTAssertNil(viewModel.errorKey)
        XCTAssertTrue(viewModel.isOffline)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testRefreshFailureWithCachedDocumentsSetsErrorMessage() async {
        let cache = makeCache()
        let cachedRecentBody = Self.paginatedFixture(
            id: "13131313-1313-4131-8131-131313131313", title: "Offline Recent", isFavorite: false)
        let cachedRecentDocument = try! JSONDecoder.docsAPI.decode(
            PaginatedResponse<Document>.self, from: cachedRecentBody
        ).results[0]
        cache.saveRecentDocuments([cachedRecentDocument])
        let viewModel = makeViewModel(cache: cache)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.refresh()

        // Pull-to-refresh is the explicit "give me fresh data" path — failures
        // surface even though cached rows stay visible.
        XCTAssertNotNil(viewModel.errorKey)
        XCTAssertEqual(viewModel.recentDocuments.map(\.title), ["Offline Recent"])
    }

    func testLoadFailureSetsIsOffline() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.load()

        XCTAssertTrue(viewModel.isOffline)
    }

    func testSessionExpiredLoadIsNotOfflineAndKeepsCachedRows() async {
        // A real 401 raises the app-level re-login sheet (via the client's
        // onSessionExpired hook) — it must not masquerade as offline.
        let cache = makeCache()
        let cachedBody = Self.paginatedFixture(
            id: "17171717-1717-4171-8171-171717171717", title: "Cached Doc", isFavorite: false)
        let cachedDocument = try! JSONDecoder.docsAPI.decode(PaginatedResponse<Document>.self, from: cachedBody)
            .results[0]
        cache.saveRecentDocuments([cachedDocument])
        let viewModel = makeViewModel(cache: cache)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 401, headers: [:], body: Data(), error: nil) }

        await viewModel.load()

        XCTAssertFalse(viewModel.isOffline)
        XCTAssertNil(viewModel.errorKey)
        XCTAssertEqual(viewModel.recentDocuments.map(\.title), ["Cached Doc"])
    }

    func testSessionExpiredLoadClearsStaleOfflineFromEarlierFailure() async {
        // Device offline → back online but the server session has since died:
        // the 401 must clear the stale offline flag, not leave it stuck true
        // while the user waits on the re-login sheet.
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }
        await viewModel.load()
        XCTAssertTrue(viewModel.isOffline)

        MockURLProtocol.stubHandler = { _ in .init(statusCode: 401, headers: [:], body: Data(), error: nil) }
        await viewModel.load()

        XCTAssertFalse(viewModel.isOffline)
    }

    func testSessionExpiredLoadShowsNoErrorEvenWhenUserInitiated() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 401, headers: [:], body: Data(), error: nil) }

        await viewModel.refresh()

        XCTAssertFalse(viewModel.isOffline)
        XCTAssertNil(viewModel.errorKey)
    }

    func testLoadSuccessKeepsIsOfflineFalse() async {
        let viewModel = makeViewModel()
        let pinnedBody = Self.paginatedFixture(
            id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd", title: "Pinned Doc", isFavorite: true)
        let recentBody = Self.paginatedFixture(
            id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", title: "Recent Doc", isFavorite: false)
        MockURLProtocol.stubHandler = { request in
            let path = request.url?.path ?? ""
            if path.contains("favorite_list") {
                return .init(statusCode: 200, headers: [:], body: pinnedBody, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: recentBody, error: nil)
        }

        await viewModel.load()

        XCTAssertFalse(viewModel.isOffline)
    }

    func testLoadSuccessAfterFailureClearsIsOffline() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }
        await viewModel.load()
        XCTAssertTrue(viewModel.isOffline)

        let empty = Self.emptyFixture
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: empty, error: nil) }
        await viewModel.load()

        XCTAssertFalse(viewModel.isOffline)
    }

    func testFirstRunFailureShowsErrorDespitePinnedRows() async {
        let cache = makeCache()
        let pinnedBody = Self.paginatedFixture(
            id: "16161616-1616-4161-8161-161616161616", title: "Cached Pinned", isFavorite: true)
        let pinnedDocument = try! JSONDecoder.docsAPI.decode(PaginatedResponse<Document>.self, from: pinnedBody)
            .results[0]
        cache.savePinnedDocuments([pinnedDocument])
        let viewModel = makeViewModel(cache: cache)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        // First-ever load with no cached recent list: cached pinned rows are no
        // evidence the recent feed loaded, so a total failure must not be silent.
        await viewModel.load()

        XCTAssertNotNil(viewModel.errorKey)
        XCTAssertTrue(viewModel.isOffline)
    }

    func testCreateDocumentOfflinePersistsIntoRecentCache() async {
        let cache = makeCache()
        preferences.set(true, forKey: "schrift.workOffline")
        let viewModel = makeViewModel(cache: cache)
        await viewModel.load()
        MockURLProtocol.stubHandler = { _ in
            .init(
                statusCode: 201, headers: [:],
                body: """
                    {
                        "id": "17171717-1717-4171-8171-171717171717",
                        "title": "New Doc",
                        "excerpt": null,
                        "abilities": {},
                        "computed_link_reach": "restricted",
                        "computed_link_role": null,
                        "created_at": "2026-01-15T10:30:00Z",
                        "creator": null,
                        "depth": 1,
                        "link_role": "reader",
                        "link_reach": "restricted",
                        "numchild": 0,
                        "path": "0002",
                        "updated_at": "2026-01-15T10:30:00Z",
                        "user_role": "owner",
                        "is_favorite": false
                    }
                    """.data(using: .utf8)!, error: nil)
        }

        let document = await viewModel.createDocument()

        // Offline, load() never hits the network, so the new document is
        // reflected directly into the on-screen list and the recent cache.
        XCTAssertEqual(document?.title, "New Doc")
        XCTAssertEqual(viewModel.recentDocuments.map(\.title), ["New Doc"])
        XCTAssertEqual(cache.loadRecentDocuments()?.map(\.title), ["New Doc"])
    }

    func testWorkOfflinePreferenceServesCacheWithoutNetwork() async {
        let cache = makeCache()
        let pinnedBody = Self.paginatedFixture(
            id: "18181818-1818-4181-8181-181818181818", title: "Offline Pinned", isFavorite: true)
        let recentBody = Self.paginatedFixture(
            id: "19191919-1919-4191-8191-191919191919", title: "Offline Recent", isFavorite: false)
        cache.savePinnedDocuments([
            try! JSONDecoder.docsAPI.decode(PaginatedResponse<Document>.self, from: pinnedBody).results[0]
        ])
        cache.saveRecentDocuments(
            [try! JSONDecoder.docsAPI.decode(PaginatedResponse<Document>.self, from: recentBody).results[0]])
        preferences.set(true, forKey: "schrift.workOffline")
        let viewModel = makeViewModel(cache: cache)
        let recorder = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            recorder.record(request)
            return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }

        await viewModel.load()

        XCTAssertEqual(recorder.methods.count, 0, "work offline must never hit the network")
        XCTAssertEqual(viewModel.pinnedDocuments.map(\.title), ["Offline Pinned"])
        XCTAssertEqual(viewModel.recentDocuments.map(\.title), ["Offline Recent"])
        XCTAssertTrue(viewModel.isOffline)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testWorkOfflineWithNoCacheDoesNotClaimEmpty() async {
        // Fresh install under Work Offline with nothing cached: the list is
        // unknown, so it must not read as a real empty result.
        let cache = makeCache()
        preferences.set(true, forKey: "schrift.workOffline")
        let viewModel = makeViewModel(cache: cache)

        await viewModel.load()

        XCTAssertFalse(viewModel.isCurrentListKnown, "a never-fetched list must not masquerade as empty")
        XCTAssertTrue(viewModel.recentDocuments.isEmpty)
        XCTAssertNil(viewModel.errorKey)
        XCTAssertTrue(viewModel.isOffline)
    }

    // MARK: - Create-document failure reporting

    func testFailedCreateDocumentSurfacesTheServersOwnReason() async {
        let diagnostics = APIDiagnosticsLog()
        let viewModel = makeViewModel(diagnostics: diagnostics)
        MockURLProtocol.stubHandler = { _ in
            .init(
                statusCode: 403, headers: [:],
                body: #"{"detail":"CSRF Failed: CSRF token missing."}"#.data(using: .utf8)!, error: nil)
        }

        let document = await viewModel.createDocument()

        XCTAssertNil(document)
        XCTAssertEqual(viewModel.errorKey, .home_error_create)
        XCTAssertEqual(viewModel.errorDetail, "HTTP 403: CSRF Failed: CSRF token missing.")
    }

    /// Offline, there is no HTTP response to quote. Without the marker the catch would show
    /// the detail of whatever unrelated request failed last.
    func testFailedCreateDocumentOffersNoDetailForATransportError() async {
        let diagnostics = APIDiagnosticsLog()
        diagnostics.record(RequestFailure(method: "GET", path: "documents/", statusCode: 500, body: Data()))
        let viewModel = makeViewModel(diagnostics: diagnostics)
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        _ = await viewModel.createDocument()

        XCTAssertNotNil(viewModel.errorKey)
        XCTAssertNil(viewModel.errorDetail)
    }

    /// The reported bug: the message had no way out. `createDocument`'s failure path never
    /// reaches `load()`, which was the only thing that cleared it.
    func testDismissErrorClearsTheCreateFailureMessage() async {
        let diagnostics = APIDiagnosticsLog()
        let viewModel = makeViewModel(diagnostics: diagnostics)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 403, headers: [:], body: Data(), error: nil) }
        _ = await viewModel.createDocument()
        XCTAssertNotNil(viewModel.errorKey)

        viewModel.dismissError()

        XCTAssertNil(viewModel.errorKey)
        XCTAssertNil(viewModel.errorDetail)
    }

    func testRetryingCreateDocumentClearsThePreviousMessageBeforeSucceeding() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 403, headers: [:], body: Data(), error: nil) }
        _ = await viewModel.createDocument()
        XCTAssertNotNil(viewModel.errorKey)

        // Now the create succeeds, and the load() it triggers answers with an empty page.
        MockURLProtocol.stubHandler = { request in
            let isCreate = request.httpMethod == "POST"
            let body = isCreate ? Self.documentFixture() : Self.emptyPageFixture()
            return .init(statusCode: isCreate ? 201 : 200, headers: [:], body: body, error: nil)
        }

        let document = await viewModel.createDocument()

        XCTAssertNotNil(document)
        XCTAssertNil(viewModel.errorKey)
        XCTAssertNil(viewModel.errorDetail)
    }

    // `nonisolated`: both are read from inside the `@Sendable` stub handler, which does not
    // run on the main actor this test class is isolated to.
    private nonisolated static func emptyPageFixture() -> Data {
        #"{"count":0,"next":null,"previous":null,"results":[]}"#.data(using: .utf8)!
    }

    private nonisolated static func documentFixture() -> Data {
        """
        {
            "id": "17171717-1717-4171-8171-171717171717",
            "title": "Untitled document",
            "excerpt": null,
            "abilities": {},
            "computed_link_reach": "restricted",
            "computed_link_role": null,
            "created_at": "2026-01-15T10:30:00Z",
            "creator": null,
            "depth": 1,
            "link_role": "reader",
            "link_reach": "restricted",
            "numchild": 0,
            "path": "0002",
            "updated_at": "2026-01-15T10:30:00Z",
            "user_role": "owner",
            "is_favorite": false
        }
        """.data(using: .utf8)!
    }

    /// The reconnect/foreground triggers call `viewModel.syncPendingDrafts()`; it
    /// must forward to the save coordinator (which does the actual replay).
    func testSyncPendingDraftsForwardsToTheCoordinator() async {
        let documentID = UUID(uuidString: "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b")!
        let suiteName = "HomeViewModelTests.forwarding.\(UUID().uuidString)"
        let draftStore = PendingDraftStore(userDefaults: UserDefaults(suiteName: suiteName)!)
        // Isolated content cache so the successful replay's write-through doesn't
        // leak a JSON file into the real Application Support directory.
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HomeViewModelTests.forwarding.\(UUID().uuidString)", isDirectory: true)
        defer {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: cacheDir)
        }
        // A draft "now" is newer than the 2026-01-15 fixture → tolerance replay.
        draftStore.save(PendingDraft(documentID: documentID, title: "Doc", markdown: "# Draft", updatedAt: Date()))
        let log = RequestRecorder()
        let contentBody = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "# Server", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: contentBody, error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)  // PATCH
        }
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: draftStore,
            contentCache: DocumentContentCacheStore(directory: cacheDir), backgroundTasks: .noop)
        let viewModel = HomeViewModel(
            client: client, cache: makeCache(), saveCoordinator: coordinator, userDefaults: preferences)

        await viewModel.syncPendingDrafts()

        // Forwarded: the draft was replayed and cleared, and a content PATCH fired.
        await waitUntil { draftStore.draft(for: documentID) == nil }
        XCTAssertGreaterThanOrEqual(log.count(ofMethod: "PATCH", urlContaining: "/content/"), 1)
    }
}
