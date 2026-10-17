import XCTest

@testable import Schrift

@MainActor
final class ProfileViewModelFreshnessTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private var suiteName: String!
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "ProfileFreshness.\(UUID().uuidString)"
    }

    override func tearDown() {
        MockURLProtocol.reset()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeViewModel() -> ProfileViewModel {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let defaults = UserDefaults(suiteName: suiteName)!
        return ProfileViewModel(
            client: client,
            signedInUser: SignedInUserStore(userDefaults: defaults),
            cachedUser: CurrentUserCacheStore(userDefaults: defaults),
            now: { [unowned self] in self.clock })
    }

    func testRevisitInsideTheWindowSkipsTheFetchesUnlessTheSessionChanged() async {
        let recorder = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            recorder.record(request)
            if request.url?.path.contains("config") == true {
                return .init(
                    statusCode: 200, headers: [:], body: Data(#"{"RELEASE_VERSION":"5.4.1"}"#.utf8), error: nil)
            }
            return .init(
                statusCode: 200, headers: [:],
                body: Data(#"{"id": "11111111-1111-4111-8111-111111111111", "email": "ada@example.org"}"#.utf8),
                error: nil)
        }
        let viewModel = makeViewModel()

        await viewModel.loadIfStale(sessionGeneration: 0)
        XCTAssertEqual(recorder.count(ofMethod: "GET"), 2)

        clock = clock.addingTimeInterval(10)
        await viewModel.loadIfStale(sessionGeneration: 0)
        XCTAssertEqual(recorder.count(ofMethod: "GET"), 2, "same session, fresh: no refetch")

        await viewModel.loadIfStale(sessionGeneration: 1)
        XCTAssertEqual(recorder.count(ofMethod: "GET"), 4, "a new session generation always reloads")

        clock = clock.addingTimeInterval(31)
        await viewModel.loadIfStale(sessionGeneration: 1)
        XCTAssertEqual(recorder.count(ofMethod: "GET"), 6, "stale after the window")
    }
}
