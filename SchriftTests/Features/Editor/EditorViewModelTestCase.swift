import XCTest

@testable import Schrift

@MainActor
class EditorViewModelTestCase: XCTestCase {
    let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    let documentID = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!
    /// The `updated_at` every `formattedBody` fixture pins — the server-clock value
    /// a fetched baseline must record (never the client clock).
    let fetchedUpdatedAt = ISO8601DateFormatter().date(from: "2026-01-15T10:30:00Z")!

    var cacheDirectory: URL!
    var childrenSuiteName: String!
    /// Every suite `makeEnvironment` creates, so tearDown can remove each
    /// persistent domain instead of leaking a plist per environment.
    var draftSuiteNames: [String] = []

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorViewModelTests-\(UUID().uuidString)", isDirectory: true)
        childrenSuiteName = "EditorViewModelTests.children.\(UUID().uuidString)"
        draftSuiteNames = []
    }

    override func tearDown() {
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: cacheDirectory)
        UserDefaults(suiteName: childrenSuiteName)?.removePersistentDomain(forName: childrenSuiteName)
        for suiteName in draftSuiteNames {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    func makeEnvironment(
        title: String = "Untitled document",
        autosaveInterval: Duration = .seconds(10),
        remoteChangeDebounce: Duration = .milliseconds(600)
    ) -> (
        viewModel: EditorViewModel, coordinator: DocumentSaveCoordinator, draftStore: PendingDraftStore,
        contentCache: DocumentContentCacheStore
    ) {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let suiteName = "EditorViewModelTests.\(UUID().uuidString)"
        draftSuiteNames.append(suiteName)
        let draftStore = PendingDraftStore(userDefaults: UserDefaults(suiteName: suiteName)!)
        let contentCache = DocumentContentCacheStore(directory: cacheDirectory)
        // Isolated: load()/delete/404 paths touch the children cache, which
        // must never read from or write to UserDefaults.standard in tests.
        let childrenCache = DocumentChildrenCacheStore(userDefaults: UserDefaults(suiteName: childrenSuiteName)!)
        // Isolate the create store too. Defaulted it is `UserDefaults.standard`, and a test
        // whose create stub fails retryably now mints a *real* record there, which persists on
        // the simulator across runs and contaminates later tests — a coordinator built by an
        // unrelated suite finds a replayable record and issues requests nothing set up,
        // recording phantom entries into that test's `RequestRecorder`. Same fix as
        // `HomeViewModelTestCase.makeViewModel`.
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: draftStore, contentCache: contentCache,
            createStore: PendingDocumentCreateStore(userDefaults: UserDefaults(suiteName: suiteName)!),
            deleteStore: PendingDocumentDeleteStore(userDefaults: UserDefaults(suiteName: suiteName)!),
            serverOrigin: "https://docs.example.org", backgroundTasks: .noop)
        let viewModel = EditorViewModel(
            client: client,
            documentID: documentID,
            title: title,
            saveCoordinator: coordinator,
            contentCache: contentCache,
            childrenCache: childrenCache,
            autosaveInterval: autosaveInterval,
            remoteChangeDebounce: remoteChangeDebounce
        )
        return (viewModel, coordinator, draftStore, contentCache)
    }

    func makeSignedInUser(userID: UUID? = UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        -> SignedInUserStore
    {
        let name = "EditorViewModelTests.signedIn.\(UUID().uuidString)"
        draftSuiteNames.append(name)
        let store = SignedInUserStore(userDefaults: UserDefaults(suiteName: name)!)
        store.remember(userID)
        return store
    }

    /// A local document's editor: the coordinator holds a real create record, and the view
    /// model is keyed on the *minted* id rather than the suite's fixed one.
    /// `signedInUserID` is what the account-scoped paths read; pass nil for the shape where
    /// `/users/me/` has never answered on this install, which is the one that cannot mint.
    func makeLocalEnvironment(
        signedInUserID: UUID? = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    ) -> (
        viewModel: EditorViewModel, coordinator: DocumentSaveCoordinator, document: Document,
        draftStore: PendingDraftStore, children: DocumentChildrenCacheStore,
        createStore: PendingDocumentCreateStore
    ) {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let suiteName = "EditorViewModelTests.local.\(UUID().uuidString)"
        draftSuiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        let draftStore = PendingDraftStore(userDefaults: defaults)
        let contentCache = DocumentContentCacheStore(directory: cacheDirectory)
        let childrenCache = DocumentChildrenCacheStore(userDefaults: UserDefaults(suiteName: childrenSuiteName)!)
        let createStore = PendingDocumentCreateStore(userDefaults: defaults)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: draftStore, contentCache: contentCache,
            createStore: createStore,
            deleteStore: PendingDocumentDeleteStore(userDefaults: defaults),
            serverOrigin: "https://docs.example.com", backgroundTasks: .noop)
        let document = coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil,
            ownerUserID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
        let signedIn = SignedInUserStore(userDefaults: defaults)
        if let signedInUserID { signedIn.remember(signedInUserID) }
        let viewModel = EditorViewModel(
            client: client, documentID: document.id, title: document.title ?? "Untitled document",
            saveCoordinator: coordinator, signedInUser: signedIn,
            contentCache: contentCache, childrenCache: childrenCache,
            autosaveInterval: .seconds(10), remoteChangeDebounce: .milliseconds(600))
        return (viewModel, coordinator, document, draftStore, childrenCache, createStore)
    }

    func cachedEntry(markdown: String = "# Cached", syncedAt: Date = Date(timeIntervalSince1970: 1_000_000))
        -> CachedDocumentContent
    {
        CachedDocumentContent(documentID: documentID, title: "Cached Doc", markdown: markdown, syncedAt: syncedAt)
    }

    func formattedBody(
        content: String?, title: String = "Doc", updatedAt: String = "2026-01-15T10:30:00Z"
    ) -> Data {
        let contentJSON = content.map { "\"\($0)\"" } ?? "null"
        return Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "\(title)", "content": \(contentJSON), "created_at": "2026-01-15T10:30:00Z", "updated_at": "\(updatedAt)"}
            """.utf8)
    }

    /// A server `updated_at` after `formattedBody`'s default — i.e. the server has been written
    /// since the baseline a first load established, so the title rule's "no newer than the
    /// baseline" short-circuit does not fire.
    let laterServerUpdatedAt = "2027-01-01T00:00:00Z"

    /// The server `updated_at` in `formattedBody`'s default. A baseline older than this is one
    /// the server has moved past; a baseline at or after it is one the server hasn't been
    /// written since.
    var fixtureServerUpdatedAt: Date {
        ISO8601DateFormatter().date(from: "2026-01-15T10:30:00Z")!
    }

    func stubLoad(content: String?, log: RequestRecorder? = nil) {
        let body = formattedBody(content: content)
        MockURLProtocol.stubHandler = { request in
            log?.record(request)
            return .init(statusCode: 200, headers: [:], body: body, error: nil)
        }
    }

    /// A co-author's body: changed content **and a newer `updated_at`** than the shared fixture.
    func divergedServerBody(content: String) -> Data {
        Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "\(content)", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-02-20T10:30:00Z"}
            """.utf8)
    }

    /// A co-author's write: a changed body **and a newer `updated_at`**. The shared
    /// `formattedBody` fixture pins `updated_at` to 2026-01-15, so reusing it for a "server
    /// changed" scenario silently makes rule 2 say the server has *not* moved past the
    /// baseline — a test written that way passes for the wrong reason. Saves go through.
    func stubDivergedServer(content: String, log: RequestRecorder) {
        let body = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "\(content)", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-02-20T10:30:00Z"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: body, error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
    }

    /// Every request fails as if the device were offline — the way to reach an
    /// installed-from-cache screen whose revalidation never landed.
    /// `log` is optional because the offline-editing tests count the *failed* content
    /// PATCH as their before-reconnect baseline, so it has to reach the recorder.
    func stubOffline(log: RequestRecorder? = nil) {
        MockURLProtocol.stubHandler = { request in
            log?.record(request)
            return MockURLProtocol.Stub(
                statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
    }

    /// A cached copy whose `serverUpdatedAt` and title match `formattedBody`'s fixture.
    /// The date is what matters: nil would drop rule 2 off its date check onto its content
    /// tiebreak, quietly changing which rule a replay test exercises. The matching title is
    /// defensive — `draftTitleOutcome` short-circuits to `.keepDraft` while the server is no
    /// newer than the baseline, so it is inert today, and load-bearing only if the fixture's
    /// `updated_at` ever moves past it.
    func offlineCachedEntry(markdown: String) -> CachedDocumentContent {
        CachedDocumentContent(
            documentID: documentID, title: "Doc", markdown: markdown,
            syncedAt: Date(timeIntervalSince1970: 1_000_000), serverUpdatedAt: fixtureServerUpdatedAt)
    }

    /// A save is a content PATCH (base64 Yjs) followed by a title PATCH; each
    /// save is counted by its single content PATCH.
    func savesInFlight(_ log: RequestRecorder) -> Int {
        log.count(ofMethod: "PATCH", urlContaining: "/content/")
    }

    /// `getDelay` holds the formatted-content GET open (via `Stub.delay`, never
    /// `Thread.sleep`, which would stall the PATCH too) so its response lands
    /// *after* a concurrent save settled — the raced-fetch case. Nothing needs to
    /// stall the save: `enqueue` sets the pending save synchronously, which is all
    /// `restoreLocalContent` reads.
    func stubLoadAndSavePipeline(
        content: String?,
        log: RequestRecorder,
        contentStatus: Int = 204,
        getDelay: TimeInterval = 0
    ) {
        let body = formattedBody(content: content)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            switch request.httpMethod {
            case "GET" where url.contains("formatted-content"):
                return .init(statusCode: 200, headers: [:], body: body, error: nil, delay: getDelay)
            case "PATCH" where url.hasSuffix("/content/"):
                return .init(statusCode: contentStatus, headers: [:], body: Data(), error: nil)
            case "PATCH":
                return .init(statusCode: 200, headers: [:], body: Data(), error: nil)  // title
            default:
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
            }
        }
    }

    func stubStatus(_ code: Int) {
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: code, headers: [:], body: Data(), error: nil)
        }
    }
}
