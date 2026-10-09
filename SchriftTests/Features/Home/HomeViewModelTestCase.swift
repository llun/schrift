import XCTest

@testable import Schrift

/// Shared fixtures and wiring for the `HomeViewModel…Tests` classes (one per concern). Holds no tests.
@MainActor
class HomeViewModelTestCase: XCTestCase {
    let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!

    var preferences: UserDefaults!
    var preferencesSuiteName: String!

    override func setUp() {
        super.setUp()
        preferencesSuiteName = "HomeViewModelTests.preferences.\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: preferencesSuiteName)!
    }

    override func tearDown() {
        MockURLProtocol.reset()
        preferences.removePersistentDomain(forName: preferencesSuiteName)
        for name in coordinatorSuiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        coordinatorSuiteNames.removeAll()
        try? FileManager.default.removeItem(at: contentCacheDirectory)
        super.tearDown()
    }

    /// Every coordinator suite this test built, so its drafts and create records go with it.
    var coordinatorSuiteNames: [String] = []
    lazy var contentCacheDirectory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("HomeViewModelTests.\(UUID().uuidString)", isDirectory: true)

    /// An isolated `SignedInUserStore`, since `HomeViewModel` defaults to
    /// `UserDefaults.standard` and the mint path reads it.
    func makeSignedInUser(userID: UUID? = UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        -> SignedInUserStore
    {
        let name = "HomeViewModelTests.signedIn.\(UUID().uuidString)"
        coordinatorSuiteNames.append(name)
        let store = SignedInUserStore(userDefaults: UserDefaults(suiteName: name)!)
        store.remember(userID)
        return store
    }

    func makeCache() -> DocumentCacheStore {
        let suiteName = "HomeViewModelTests.\(UUID().uuidString)"
        // Registered for cleanup: an unregistered suite leaks a plist per test.
        coordinatorSuiteNames.append(suiteName)
        let userDefaults = UserDefaults(suiteName: suiteName)!
        return DocumentCacheStore(userDefaults: userDefaults)
    }

    func makeViewModel(
        cache: DocumentCacheStore? = nil,
        userDefaults: UserDefaults? = nil,
        signedInUser: SignedInUserStore? = nil,
        cachedUser: CurrentUserCacheStore? = nil,
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
        //
        // **And its create store, for the same reason and a worse consequence.** Once
        // `createDocument` can fall back to minting a local document, a test whose create stub
        // fails retryably writes a real record — and to `UserDefaults.standard` if this is
        // left defaulted, where it *persists on the simulator across runs*. Every later
        // `syncPendingDrafts` in any test then passes the replay's pre-flight gate and issues
        // requests nothing set up, recording phantom entries into that test's
        // `RequestRecorder`. A test unrelated to creation fails on a count it never caused.
        let suiteName = "HomeViewModelTests.coordinator.\(UUID().uuidString)"
        coordinatorSuiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        let draftStore = PendingDraftStore(userDefaults: defaults)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: draftStore,
            // Its own directory too, never the real Application Support one: since this PR a
            // delete routes through `purgeLocalTraces`, which removes cached document bodies.
            contentCache: DocumentContentCacheStore(directory: contentCacheDirectory),
            createStore: PendingDocumentCreateStore(userDefaults: defaults),
            deleteStore: PendingDocumentDeleteStore(userDefaults: defaults),
            // And the two list caches: this suite now drives real migrations, which reach
            // `insertIntoListCaches` (and `childrenCache.removeDocument` — Home
            // creates roots, so the children *write* is not on this path). Same hazard the comment above
            // describes for drafts and creates.
            listCache: DocumentCacheStore(userDefaults: defaults),
            childrenCache: DocumentChildrenCacheStore(userDefaults: defaults),
            serverOrigin: "https://docs.example.org", backgroundTasks: .noop)
        return HomeViewModel(
            client: client,
            cache: cache ?? makeCache(),
            saveCoordinator: coordinator,
            userDefaults: userDefaults ?? preferences,
            signedInUser: signedInUser ?? makeSignedInUser(userID: nil),
            cachedUser: cachedUser ?? CurrentUserCacheStore(userDefaults: defaults),
            diagnostics: diagnostics
        )
    }

    static func paginatedFixture(id: String, title: String, isFavorite: Bool) -> Data {
        paginatedFixture(entries: [(id: id, title: title, isFavorite: isFavorite)])
    }

    static func paginatedFixture(entries: [(id: String, title: String, isFavorite: Bool)]) -> Data {
        let results = entries.map { entry in
            """
                {
                    "id": "\(entry.id)",
                    "title": "\(entry.title)",
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
                    "is_favorite": \(entry.isFavorite)
                }
            """
        }.joined(separator: ",\n")
        return """
            {
                "count": \(entries.count),
                "next": null,
                "previous": null,
                "results": [
            \(results)
                ]
            }
            """.data(using: .utf8)!
    }

    static let emptyFixture: Data = #"{"count": 0, "next": null, "previous": null, "results": []}"#.data(
        using: .utf8)!

    func documentFixture(_ id: UUID) -> Document {
        Document(
            id: id, title: "Doomed", excerpt: nil, abilities: DocumentAbilities(),
            linkReach: .restricted, linkRole: .reader, isFavorite: false, depth: 1, numchild: 0,
            path: "0001", createdAt: Date(), updatedAt: Date(), userRole: nil, creator: nil)
    }
}
