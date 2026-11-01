import XCTest

@testable import Schrift

@MainActor
final class SharedViewModelFreshnessTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private var cacheSuiteName: String!
    private var preferencesSuiteName: String!
    private var cache: DocumentCacheStore!
    private var preferences: UserDefaults!
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() {
        super.setUp()
        cacheSuiteName = "SharedFreshness.\(UUID().uuidString)"
        preferencesSuiteName = "SharedFreshness.prefs.\(UUID().uuidString)"
        cache = DocumentCacheStore(userDefaults: UserDefaults(suiteName: cacheSuiteName)!)
        preferences = UserDefaults(suiteName: preferencesSuiteName)!
    }

    override func tearDown() {
        MockURLProtocol.reset()
        UserDefaults(suiteName: cacheSuiteName)?.removePersistentDomain(forName: cacheSuiteName)
        preferences.removePersistentDomain(forName: preferencesSuiteName)
        super.tearDown()
    }

    private func makeViewModel() -> SharedViewModel {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        return SharedViewModel(
            client: client, cache: cache, userDefaults: preferences, now: { [unowned self] in self.clock })
    }

    private func stubEmptyList(_ recorder: RequestRecorder) {
        MockURLProtocol.stubHandler = { request in
            recorder.record(request)
            return .init(
                statusCode: 200, headers: [:],
                body: Data(#"{"count": 0, "next": null, "previous": null, "results": []}"#.utf8), error: nil)
        }
    }

    func testPassiveReloadInsideTheWindowSkipsTheFetchButRefreshAndLoadStillFetch() async {
        let recorder = RequestRecorder()
        stubEmptyList(recorder)
        let viewModel = makeViewModel()

        await viewModel.loadIfStale(sessionGeneration: 0)
        XCTAssertEqual(recorder.count(ofMethod: "GET"), 1)

        clock = clock.addingTimeInterval(10)
        await viewModel.loadIfStale(sessionGeneration: 0)
        XCTAssertEqual(recorder.count(ofMethod: "GET"), 1, "fresh: no second fetch")

        await viewModel.refresh()
        XCTAssertEqual(recorder.count(ofMethod: "GET"), 2, "pull-to-refresh always fetches")

        await viewModel.load()
        XCTAssertEqual(recorder.count(ofMethod: "GET"), 3, "direct loads (replay, migration) always fetch")
    }

    func testPassiveReloadAfterTheWindowFetches() async {
        let recorder = RequestRecorder()
        stubEmptyList(recorder)
        let viewModel = makeViewModel()

        await viewModel.loadIfStale(sessionGeneration: 0)
        clock = clock.addingTimeInterval(31)
        await viewModel.loadIfStale(sessionGeneration: 0)

        XCTAssertEqual(recorder.count(ofMethod: "GET"), 2)
    }

    func testANewSignInGenerationReloadsInsideTheWindow() async {
        let recorder = RequestRecorder()
        stubEmptyList(recorder)
        let viewModel = makeViewModel()

        await viewModel.loadIfStale(sessionGeneration: 0)
        clock = clock.addingTimeInterval(5)
        await viewModel.loadIfStale(sessionGeneration: 0)
        XCTAssertEqual(recorder.count(ofMethod: "GET"), 1)

        await viewModel.loadIfStale(sessionGeneration: 1)
        XCTAssertEqual(recorder.count(ofMethod: "GET"), 2, "a re-login must not show the previous account's list")

        await viewModel.loadIfStale(sessionGeneration: 1)
        XCTAssertEqual(recorder.count(ofMethod: "GET"), 2)
    }

    /// A fetch that ran before the signed-in id was known cached its rows unstamped, so the `[[`
    /// picker offers none of them. Once the id arrives that fetch is no longer fresh for this
    /// account, however recent — the next passive entry refetches and re-stamps.
    func testLearningTheSignedInIdMakesAnEarlierFetchStaleEvenInsideTheWindow() async {
        let recorder = RequestRecorder()
        stubEmptyList(recorder)
        let signedIn = SignedInUserStore(userDefaults: preferences)
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let viewModel = SharedViewModel(
            client: client, cache: cache, userDefaults: preferences, signedInUser: signedIn,
            now: { [unowned self] in self.clock })

        await viewModel.loadIfStale(sessionGeneration: 0)
        clock = clock.addingTimeInterval(5)
        await viewModel.loadIfStale(sessionGeneration: 0)
        XCTAssertEqual(recorder.count(ofMethod: "GET"), 1, "precondition: nothing changed, still fresh")

        let owner = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        signedIn.remember(owner)
        await viewModel.loadIfStale(sessionGeneration: 0)
        XCTAssertEqual(recorder.count(ofMethod: "GET"), 2, "the id arriving invalidates the unstamped fetch")
        XCTAssertNotNil(cache.loadSharedWithMeDocuments())

        await viewModel.loadIfStale(sessionGeneration: 0)
        XCTAssertEqual(recorder.count(ofMethod: "GET"), 2, "and the re-stamped fetch is fresh again")
    }
}
