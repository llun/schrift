import XCTest

@testable import Schrift

/// The create replay: POST a document this device made, move everything keyed by its
/// client-minted id onto the one the server assigned, and hand the content to the ordinary
/// draft replay. Dormant — nothing mints a record yet — so these drive the coordinator
/// directly.
@MainActor
final class DocumentSaveCoordinatorReplayTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let origin = "https://docs.example.org"
    private let user = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let serverID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private var cacheDirectory: URL!
    private var suiteNames: [String] = []

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplayTests-\(UUID().uuidString)", isDirectory: true)
        suiteNames = []
    }

    override func tearDown() {
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: cacheDirectory)
        for name in suiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        super.tearDown()
    }

    private struct Environment {
        let coordinator: DocumentSaveCoordinator
        let drafts: PendingDraftStore
        let creates: PendingDocumentCreateStore
        let lists: DocumentCacheStore
        let children: DocumentChildrenCacheStore
        let defaults: UserDefaults
    }

    private func makeEnvironment(sharing defaults: UserDefaults? = nil) -> Environment {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let defaults =
            defaults
            ?? {
                let name = "ReplayTests.\(UUID().uuidString)"
                suiteNames.append(name)
                return UserDefaults(suiteName: name)!
            }()
        let drafts = PendingDraftStore(userDefaults: defaults)
        let creates = PendingDocumentCreateStore(userDefaults: defaults)
        let lists = DocumentCacheStore(userDefaults: defaults)
        let children = DocumentChildrenCacheStore(userDefaults: defaults)
        return Environment(
            coordinator: DocumentSaveCoordinator(
                client: client, draftStore: drafts,
                contentCache: DocumentContentCacheStore(directory: cacheDirectory),
                createStore: creates, listCache: lists, childrenCache: children,
                serverOrigin: origin, backgroundTasks: .noop),
            drafts: drafts, creates: creates, lists: lists, children: children, defaults: defaults)
    }

    /// `/users/me/`, the create `POST`, the `formatted-content` GET the draft replay makes,
    /// and the two save PATCHes. `createdAt`/`updatedAt` on the create response is the
    /// baseline the migration stamps, and the GET echoes it so rule 2 sees a server that has
    /// not moved past it.
    private func stubReplayPipeline(
        log: RequestRecorder,
        serverUpdatedAt: String = "2026-03-01T12:00:00Z",
        createStatus: Int = 201,
        title: String = "Untitled document"
    ) {
        let userBody = Data(
            """
            {"id": "11111111-1111-4111-8111-111111111111", "email": "a@example.org"}
            """.utf8)
        let createdBody = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "\(title)",
             "abilities": {"destroy": true, "partial_update": true},
             "content": "", "created_at": "\(serverUpdatedAt)", "updated_at": "\(serverUpdatedAt)",
             "depth": 1, "numchild": 0, "path": "00000A", "link_reach": "restricted",
             "link_role": "reader", "user_role": "owner"}
            """.utf8)
        let formattedBody = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "\(title)", "content": "",
             "created_at": "\(serverUpdatedAt)", "updated_at": "\(serverUpdatedAt)"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            switch request.httpMethod {
            case "GET" where url.hasSuffix("users/me/"):
                return .init(statusCode: 200, headers: [:], body: userBody, error: nil)
            case "GET" where url.contains("formatted-content"):
                return .init(statusCode: 200, headers: [:], body: formattedBody, error: nil)
            case "GET":
                return .init(statusCode: 200, headers: [:], body: createdBody, error: nil)
            case "POST":
                return .init(statusCode: createStatus, headers: [:], body: createdBody, error: nil)
            default:
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
            }
        }
    }

    private func creates(_ log: RequestRecorder) -> Int {
        log.count(ofMethod: "POST", urlContaining: "documents/")
    }

    // MARK: - The happy path

    func testAReplayPostsTheDocumentAndMigratesEverythingOntoTheServerID() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        env.coordinator.enqueue(documentID: local.id, title: "Notes", markdown: "# Written offline")

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(creates(log), 1)
        XCTAssertNil(env.creates.create(for: local.id), "the record is gone once the server owns it")
        XCTAssertFalse(env.coordinator.isPendingCreate(documentID: local.id))
        XCTAssertNil(env.drafts.draft(for: local.id), "nothing is left under the local id")
        await waitUntil { env.coordinator.lastConfirmedPush(documentID: self.serverID) == "# Written offline" }
    }

    /// The body has to survive the id change. It lives in the *queued* slot at that moment
    /// (the enqueue hold parked it there), so a migration that only moved the draft would
    /// strand the user's newest keystrokes under an id nothing will ever push.
    func testTheQueuedBodyIsCarriedOntoTheServerID() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        env.coordinator.enqueue(documentID: local.id, title: "Notes", markdown: "# First")
        env.coordinator.enqueue(documentID: local.id, title: "Notes", markdown: "# Latest")

        await env.coordinator.syncPendingDrafts()

        await waitUntil { env.coordinator.lastConfirmedPush(documentID: self.serverID) == "# Latest" }
    }

    /// The stamped baseline is what stops the very next pass discarding the body: without it
    /// the migrated draft is baseline-less, rule 3's 120 s tolerance applies, and a document
    /// created hours ago offline loses to a server whose `updated_at` is the POST we just
    /// made.
    func testTheMigratedDraftCarriesTheCreateResponseAsItsBaseline() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log, createStatus: 201)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        // A body the save PATCH will fail on, so the draft survives for inspection.
        MockURLProtocol.stubHandler = { [serverID] request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "PATCH" {
                return .init(statusCode: 503, headers: [:], body: Data(), error: nil)
            }
            let created = Data(
                """
                {"id": "\(serverID.uuidString.lowercased())", "title": "Untitled document",
                 "abilities": {}, "content": "", "created_at": "2026-03-01T12:00:00Z",
                 "updated_at": "2026-03-01T12:00:00Z", "depth": 1, "numchild": 0, "path": "00000A",
                 "link_reach": "restricted", "link_role": "reader", "user_role": "owner"}
                """.utf8)
            let me = Data("{\"id\": \"11111111-1111-4111-8111-111111111111\"}".utf8)
            return .init(
                statusCode: 200, headers: [:], body: url.hasSuffix("users/me/") ? me : created, error: nil)
        }
        env.coordinator.enqueue(documentID: local.id, title: "Notes", markdown: "# Written offline")

        await env.coordinator.syncPendingDrafts()

        await waitUntil { env.drafts.draft(for: self.serverID) != nil }
        let migrated = env.drafts.draft(for: serverID)
        XCTAssertEqual(migrated?.baseline?.markdown, "", "the server document starts empty")
        XCTAssertEqual(
            migrated?.baseline?.serverUpdatedAt,
            ISO8601DateFormatter().date(from: "2026-03-01T12:00:00Z"),
            "and its timestamp is the create response's, not the client clock")
    }

    func testTheCreatedDocumentIsListedUnderItsServerIDBeforeAnyFetch() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        env.coordinator.createLocalDocument(title: "Untitled document", parentID: nil, ownerUserID: user)

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(
            env.lists.loadRecentDocuments()?.first?.id, serverID,
            "otherwise it vanishes from Home between the POST and the next list fetch")
    }

    /// A sub-page goes into its parent's cached level — but only one that has actually been
    /// fetched, so a create can never fabricate "this parent has exactly one child".
    func testASubpageJoinsAKnownParentLevelAndNeverInventsOne() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let knownParent = UUID()
        let unknownParent = UUID()
        let env = makeEnvironment()
        env.children.save([], for: knownParent)
        env.coordinator.createLocalDocument(title: "Child", parentID: knownParent, ownerUserID: user)

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(env.children.children(for: knownParent)?.map(\.id), [serverID])
        XCTAssertNil(env.children.children(for: unknownParent))
    }

    // MARK: - Idempotency

    /// The backend has no idempotency key, so the only defence against a duplicate is
    /// persisting the server id **before** anything else — a process death after the POST
    /// then resumes at migration instead of POSTing again.
    func testAReplayInterruptedAfterThePostResumesWithoutPostingAgain() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        // Simulate the checkpoint having landed and the process dying before migration.
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertEqual(creates(log), 0, "a checkpointed record never POSTs again")
        XCTAssertNil(relaunched.creates.create(for: local.id), "it resumes at migration and finishes")
    }

    /// Two triggers landing together must not both POST. They share the funnel's
    /// re-entrancy guard, which is why the create pass lives inside it rather than owning
    /// its own triggers.
    func testOverlappingTriggersPostExactlyOnce() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        env.coordinator.createLocalDocument(title: "Untitled document", parentID: nil, ownerUserID: user)

        // The first call suspends on `/users/me/`; the second then finds the re-entrancy
        // guard set and coalesces into another pass rather than starting its own POST.
        let coordinator = env.coordinator
        let first = Task { await coordinator.syncPendingDrafts() }
        await coordinator.syncPendingDrafts()
        await first.value

        XCTAssertEqual(creates(log), 1)
    }

    // MARK: - Deferring while a screen is open

    /// Migration re-keys the draft and the coordinator's maps, and an open editor captured
    /// the old id in a `let` — so it would keep writing under an id the holds no longer
    /// cover. Deferring makes mid-swap edit loss unrepresentable.
    func testAReplayDefersWhileAnEditorHoldsTheDocument() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        env.coordinator.retainOpenEditor(documentID: local.id)

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(creates(log), 0)
        XCTAssertTrue(env.coordinator.isPendingCreate(documentID: local.id), "still local, still protected")
    }

    func testReleasingTheLastEditorRunsTheDeferredReplay() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        env.coordinator.retainOpenEditor(documentID: local.id)
        await env.coordinator.syncPendingDrafts()

        env.coordinator.releaseOpenEditor(documentID: local.id)

        await waitUntil { self.creates(log) == 1 }
    }

    /// Two screens on the same document (iPad) — the replay waits for both.
    func testTheReplayWaitsForEveryHolder() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        env.coordinator.retainOpenEditor(documentID: local.id)
        env.coordinator.retainOpenEditor(documentID: local.id)

        env.coordinator.releaseOpenEditor(documentID: local.id)
        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(creates(log), 0, "one holder remains")
    }

    // MARK: - Failures

    /// A parent that is gone or no longer ours must not strand the content: the document
    /// becomes a root instead. Placement is recoverable by the user; a lost body is not.
    func testASubpageWhoseParentIsForbiddenRetriesAsARootDocument() async {
        let log = RequestRecorder()
        let parent = UUID()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(title: "Child", parentID: parent, ownerUserID: user)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("users/me/") {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data("{\"id\": \"11111111-1111-4111-8111-111111111111\"}".utf8), error: nil)
            }
            return .init(statusCode: 403, headers: [:], body: Data(), error: nil)
        }

        await env.coordinator.syncPendingDrafts()

        XCTAssertNil(env.creates.create(for: local.id)?.parentID, "promoted to a root, not stranded")
        XCTAssertNotNil(env.creates.create(for: local.id), "and still pending, so the next pass retries")
    }

    func testATransportFailureLeavesTheRecordForTheNextPass() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("users/me/") {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data("{\"id\": \"11111111-1111-4111-8111-111111111111\"}".utf8), error: nil)
            }
            return .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        await env.coordinator.syncPendingDrafts()

        XCTAssertNotNil(env.creates.create(for: local.id))
        XCTAssertTrue(env.coordinator.isPendingCreate(documentID: local.id))
        XCTAssertNil(env.creates.create(for: local.id)?.syncedServerID, "no checkpoint from a failed POST")
    }

    /// Offline, `/users/me/` fails — so no record is replayable, which is the right answer
    /// rather than a reason to guess at the account.
    func testNothingIsReplayedWhenTheCurrentUserIsUnknown() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        env.coordinator.createLocalDocument(title: "Untitled document", parentID: nil, ownerUserID: user)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(creates(log), 0)
    }

    /// Another account signed in on the same server must not POST this user's documents.
    func testAnotherUsersRecordIsNeverPosted() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        env.coordinator.createLocalDocument(title: "Someone else's", parentID: nil, ownerUserID: UUID())

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(creates(log), 0, "the stub's /users/me/ is a different user")
    }
}
