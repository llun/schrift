import XCTest

@testable import Schrift

@MainActor
final class SharedViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!

    private var cache: DocumentCacheStore!
    private var cacheSuiteName: String!
    private var preferences: UserDefaults!
    private var preferencesSuiteName: String!

    override func setUp() {
        super.setUp()
        cacheSuiteName = "SharedViewModelTests.\(UUID().uuidString)"
        cache = DocumentCacheStore(userDefaults: UserDefaults(suiteName: cacheSuiteName)!)
        preferencesSuiteName = "SharedViewModelTests.preferences.\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: preferencesSuiteName)!
    }

    override func tearDown() {
        MockURLProtocol.stubHandler = nil
        MockURLProtocol.lastRequest = nil
        UserDefaults(suiteName: cacheSuiteName)?.removePersistentDomain(forName: cacheSuiteName)
        preferences.removePersistentDomain(forName: preferencesSuiteName)
        super.tearDown()
    }

    private func makeViewModel() -> SharedViewModel {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        return SharedViewModel(client: client, cache: cache, userDefaults: preferences)
    }

    private static func paginatedFixture(id: String, title: String) -> Data {
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
                    "is_favorite": false
                }
            ]
        }
        """.data(using: .utf8)!
    }

    private func decodeDocument(id: String, title: String) -> Document {
        try! JSONDecoder.docsAPI
            .decode(PaginatedResponse<Document>.self, from: Self.paginatedFixture(id: id, title: title))
            .results[0]
    }

    func testLoadPopulatesBothScopes() async {
        let viewModel = makeViewModel()
        let withMeBody = Self.paginatedFixture(id: "11111111-1111-4111-8111-111111111111", title: "With Me Doc")
        let byMeBody = Self.paginatedFixture(id: "22222222-2222-4222-8222-222222222222", title: "By Me Doc")
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("is_creator_me=true") {
                return .init(statusCode: 200, headers: [:], body: byMeBody, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: withMeBody, error: nil)
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.sharedWithMe.map(\.title), ["With Me Doc"])
        XCTAssertEqual(viewModel.sharedByMe.map(\.title), ["By Me Doc"])
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isOffline)
    }

    func testDocumentsFollowsScope() async {
        let viewModel = makeViewModel()
        let withMeBody = Self.paginatedFixture(id: "33333333-3333-4333-8333-333333333333", title: "With Me Doc")
        let byMeBody = Self.paginatedFixture(id: "44444444-4444-4444-8444-444444444444", title: "By Me Doc")
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("is_creator_me=true") {
                return .init(statusCode: 200, headers: [:], body: byMeBody, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: withMeBody, error: nil)
        }

        await viewModel.load()

        viewModel.scope = .withMe
        XCTAssertEqual(viewModel.documents.map(\.title), ["With Me Doc"])
        viewModel.scope = .byMe
        XCTAssertEqual(viewModel.documents.map(\.title), ["By Me Doc"])
    }

    func testLoadFailureWithoutCacheSetsErrorMessage() async {
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.load()

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertTrue(viewModel.isOffline)
    }

    func testInitSeedsBothScopesFromCache() {
        cache.saveSharedWithMeDocuments([
            decodeDocument(id: "55555555-5555-4555-8555-555555555555", title: "Cached With Me")
        ])
        cache.saveSharedByMeDocuments([
            decodeDocument(id: "66666666-6666-4666-8666-666666666666", title: "Cached By Me")
        ])

        let viewModel = makeViewModel()

        XCTAssertEqual(viewModel.sharedWithMe.map(\.title), ["Cached With Me"])
        XCTAssertEqual(viewModel.sharedByMe.map(\.title), ["Cached By Me"])
    }

    func testLoadSuccessSavesBothScopesToCache() async {
        let viewModel = makeViewModel()
        let withMeBody = Self.paginatedFixture(id: "77777777-7777-4777-8777-777777777777", title: "With Me Doc")
        let byMeBody = Self.paginatedFixture(id: "88888888-8888-4888-8888-888888888888", title: "By Me Doc")
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("is_creator_me=true") {
                return .init(statusCode: 200, headers: [:], body: byMeBody, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: withMeBody, error: nil)
        }

        await viewModel.load()

        XCTAssertEqual(cache.loadSharedWithMeDocuments()?.map(\.title), ["With Me Doc"])
        XCTAssertEqual(cache.loadSharedByMeDocuments()?.map(\.title), ["By Me Doc"])
    }

    func testLoadFailureKeepsCachedDocumentsVisibleAndStaysSilent() async {
        // Both scopes cached: only then is a total failure silent — loudness
        // is per failing scope.
        cache.saveSharedWithMeDocuments([
            decodeDocument(id: "99999999-9999-4999-8999-999999999999", title: "Offline With Me")
        ])
        cache.saveSharedByMeDocuments([
            decodeDocument(id: "cccccccc-9999-4ccc-8ccc-cccccccccccc", title: "Offline By Me")
        ])
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.load()

        XCTAssertEqual(viewModel.sharedWithMe.map(\.title), ["Offline With Me"])
        XCTAssertEqual(viewModel.sharedByMe.map(\.title), ["Offline By Me"])
        // Passive revalidation failures stay silent behind cached rows.
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.isOffline)
    }

    func testPartialFailureKeepsFailingScopesCachedRowsSilently() async {
        cache.saveSharedByMeDocuments([
            decodeDocument(id: "dddddddd-9999-4ddd-8ddd-dddddddddddd", title: "Cached By Me")
        ])
        let viewModel = makeViewModel()
        let withMeBody = Self.paginatedFixture(id: "eeeeeeee-9999-4eee-8eee-eeeeeeeeeeee", title: "Fresh With Me")
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("is_creator_me=true") {
                return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: withMeBody, error: nil)
        }

        await viewModel.load()

        // The successful scope is applied and written through; the failing
        // scope keeps its cached rows, silently (it has a cache).
        XCTAssertEqual(viewModel.sharedWithMe.map(\.title), ["Fresh With Me"])
        XCTAssertEqual(cache.loadSharedWithMeDocuments()?.map(\.title), ["Fresh With Me"])
        XCTAssertEqual(viewModel.sharedByMe.map(\.title), ["Cached By Me"])
        XCTAssertTrue(viewModel.isOffline)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testFailureOfNeverCachedScopeIsLoudDespiteOtherScopesCache() async {
        cache.saveSharedWithMeDocuments([
            decodeDocument(id: "ffffffff-9999-4fff-8fff-ffffffffffff", title: "Cached With Me")
        ])
        let viewModel = makeViewModel()
        let withMeBody = Self.paginatedFixture(id: "11111111-8888-4111-8111-111111111111", title: "Fresh With Me")
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("is_creator_me=true") {
                return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: withMeBody, error: nil)
        }

        await viewModel.load()

        // "Shared by me" has never been fetched: its failure must not be
        // silenced by the other scope's cache, or the empty list masquerades
        // as a real result.
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.isOffline)
    }

    func testFirstRunLoadShowsLoadingPlaceholderWhileFetching() async {
        let viewModel = makeViewModel()
        let gate = DispatchSemaphore(value: 0)
        MockURLProtocol.stubHandler = { _ in
            gate.wait()  // hold the fetch open so the mid-flight state is observable
            return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }

        let load = Task { await viewModel.load() }
        await waitUntil { viewModel.showsLoadingPlaceholder }
        XCTAssertTrue(viewModel.showsLoadingPlaceholder, "first-ever load shows the placeholder while fetching")
        XCTAssertFalse(viewModel.showsDocumentList, "an unknown scope must not claim a document count")

        gate.signal()
        gate.signal()
        await load.value
        XCTAssertFalse(viewModel.showsLoadingPlaceholder)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testScopeSwitchMidFetchShowsPlaceholderForUnknownScope() async {
        // withMe is cached (revalidates silently); byMe was never fetched.
        cache.saveSharedWithMeDocuments(
            [decodeDocument(id: "66666666-8888-4666-8666-666666666666", title: "Cached With Me")])
        let viewModel = makeViewModel()
        let recorder = RequestRecorder()
        let gate = DispatchSemaphore(value: 0)
        MockURLProtocol.stubHandler = { request in
            recorder.record(request)
            gate.wait()
            return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }

        let load = Task { await viewModel.load() }
        await waitUntil { recorder.methods.count >= 1 }
        XCTAssertFalse(viewModel.showsLoadingPlaceholder, "cached withMe scope revalidates silently")

        // Flip the segment while the fetch is in flight: the unknown byMe
        // scope shows the placeholder, not a "0 documents" claim.
        viewModel.scope = .byMe
        XCTAssertTrue(viewModel.showsLoadingPlaceholder)
        XCTAssertFalse(viewModel.showsDocumentList)

        gate.signal()
        gate.signal()
        await load.value
        XCTAssertFalse(viewModel.showsLoadingPlaceholder)
    }

    func testUnknownScopeOfflineHidesDocumentListInsteadOfClaimingEmpty() async {
        // Only withMe is cached; Work Offline means byMe can never be fetched.
        cache.saveSharedWithMeDocuments(
            [decodeDocument(id: "77777777-8888-4777-8777-777777777777", title: "Cached With Me")])
        preferences.set(true, forKey: "schrift.workOffline")
        let viewModel = makeViewModel()

        await viewModel.load()

        viewModel.scope = .byMe
        XCTAssertFalse(viewModel.showsDocumentList, "a never-fetched scope must not render '0 documents'")
        XCTAssertFalse(viewModel.showsLoadingPlaceholder)
        viewModel.scope = .withMe
        XCTAssertTrue(viewModel.showsDocumentList)
    }

    func testRevalidationBehindCachedRowsNeverShowsLoadingPlaceholder() async {
        cache.saveSharedWithMeDocuments([
            decodeDocument(id: "22222222-8888-4222-8222-222222222222", title: "Cached With Me")
        ])
        let viewModel = makeViewModel()
        let recorder = RequestRecorder()
        let gate = DispatchSemaphore(value: 0)
        MockURLProtocol.stubHandler = { request in
            recorder.record(request)
            gate.wait()
            return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }

        let load = Task { await viewModel.load() }
        await waitUntil { recorder.methods.count >= 1 }
        XCTAssertFalse(
            viewModel.showsLoadingPlaceholder,
            "cached rows must never be replaced by a spinner mid-revalidation")

        gate.signal()
        gate.signal()
        await load.value
        XCTAssertFalse(viewModel.showsLoadingPlaceholder)
    }

    func testStaleLoadCannotOverwriteFresherLoad() async {
        // MockURLProtocol serializes startLoading per session, so the
        // superseding load must not need the network while the stale fetch is
        // held: the work-offline branch bumps the generation and serves the
        // cache without a request — same latest-wins arbitration as any
        // competing load.
        cache.saveSharedWithMeDocuments([
            decodeDocument(id: "44444444-8888-4444-8444-444444444444", title: "Cached With Me")
        ])
        let viewModel = makeViewModel()
        let staleBody = Self.paginatedFixture(id: "33333333-8888-4333-8333-333333333333", title: "Stale With Me")
        let recorder = RequestRecorder()
        let gate = DispatchSemaphore(value: 0)
        MockURLProtocol.stubHandler = { request in
            recorder.record(request)
            gate.wait()  // hold the stale fetch until the newer load has landed
            return .init(statusCode: 200, headers: [:], body: staleBody, error: nil)
        }

        let staleLoad = Task { await viewModel.load() }
        await waitUntil { recorder.methods.count >= 1 }  // the stale fetch is in flight

        preferences.set(true, forKey: "schrift.workOffline")
        await viewModel.load()
        XCTAssertEqual(viewModel.sharedWithMe.map(\.title), ["Cached With Me"])

        gate.signal()
        gate.signal()  // covers the byMe fetch, should the guard ever let it run
        await staleLoad.value

        // The superseded load's late response must be discarded, in memory
        // and in the write-through cache.
        XCTAssertEqual(viewModel.sharedWithMe.map(\.title), ["Cached With Me"])
        XCTAssertEqual(cache.loadSharedWithMeDocuments()?.map(\.title), ["Cached With Me"])
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testRefreshFailureWithCachedDocumentsSetsErrorMessage() async {
        cache.saveSharedWithMeDocuments([
            decodeDocument(id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", title: "Offline With Me")
        ])
        let viewModel = makeViewModel()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.refresh()

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.sharedWithMe.map(\.title), ["Offline With Me"])
    }

    func testWorkOfflinePreferenceServesCacheWithoutNetwork() async {
        cache.saveSharedWithMeDocuments([
            decodeDocument(id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", title: "Offline With Me")
        ])
        let viewModel = makeViewModel()
        preferences.set(true, forKey: "schrift.workOffline")
        let recorder = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            recorder.record(request)
            return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.sharedWithMe.map(\.title), ["Offline With Me"])
        XCTAssertTrue(viewModel.isOffline)
        XCTAssertEqual(recorder.methods.count, 0)
    }
}
