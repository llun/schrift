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

    private func makeEnvironment(sharing defaults: UserDefaults? = nil, appBuild: String = "1") -> Environment {
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
                serverOrigin: origin, appBuild: appBuild, backgroundTasks: .noop),
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
        title: String = "Untitled document",
        postDelay: TimeInterval = 0
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
                return .init(
                    statusCode: createStatus, headers: [:], body: createdBody, error: nil, delay: postDelay)
            default:
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
            }
        }
    }

    private func creates(_ log: RequestRecorder) -> Int {
        log.count(ofMethod: "POST", urlContaining: "documents/")
    }

    private func savesInFlight(_ log: RequestRecorder) -> Int {
        log.count(ofMethod: "PATCH", urlContaining: "/content/")
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

    func testTheCreatedDocumentJoinsAnAlreadyFetchedRecentsList() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        env.lists.saveRecentDocuments([])  // a list that *has* been fetched, and is empty
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

    /// The content must end up on disk under the server id even when the save never lands.
    /// Note this pins the *outcome*, not the write ordering that protects it: the window
    /// where the body lives only in a local binding is a process-death instant no test can
    /// take, so the reason the draft is written before the old one is removed is argued in
    /// the code rather than asserted here.
    func testTheBodyIsOnDiskUnderTheServerIDEvenIfTheSaveNeverLands() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        env.coordinator.enqueue(documentID: local.id, title: "Notes", markdown: "# Written offline")
        MockURLProtocol.stubHandler = { [serverID] request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "PATCH" {
                return .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
            }
            if url.hasSuffix("users/me/") {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data("{\"id\": \"11111111-1111-4111-8111-111111111111\"}".utf8), error: nil)
            }
            let created = Data(
                """
                {"id": "\(serverID.uuidString.lowercased())", "title": "Untitled document",
                 "abilities": {}, "content": "", "created_at": "2026-03-01T12:00:00Z",
                 "updated_at": "2026-03-01T12:00:00Z", "depth": 1, "numchild": 0, "path": "00000A",
                 "link_reach": "restricted", "link_role": "reader", "user_role": "owner"}
                """.utf8)
            return .init(statusCode: 200, headers: [:], body: created, error: nil)
        }

        await env.coordinator.syncPendingDrafts()

        await waitUntil { env.drafts.draft(for: self.serverID)?.markdown == "# Written offline" }
        XCTAssertNil(env.drafts.draft(for: local.id), "and nothing is left behind under the local id")
    }

    /// A sub-page belongs to its parent's level. Whether Home's unfiltered list also
    /// returns it is the server's answer to give — caching a row the next fetch might not
    /// return is a worse error than a row arriving one fetch late.
    func testASubpageIsNotInsertedIntoTheRootRecentsList() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let parent = UUID()
        let env = makeEnvironment()
        env.lists.saveRecentDocuments([])
        env.children.save([], for: parent)
        env.coordinator.createLocalDocument(title: "Child", parentID: parent, ownerUserID: user)

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(env.children.children(for: parent)?.map(\.id), [serverID], "it joins its parent's level")
        XCTAssertTrue(env.lists.loadRecentDocuments()?.isEmpty ?? false, "and not Home's root list")
    }

    /// A parent that is reachable but no longer allows children has to reach a terminal
    /// state: before the abilities check it never promoted, never failed, and paid a POST
    /// plus a probe on every trigger, forever.
    func testAParentThatNoLongerAllowsChildrenPromotesToARoot() async {
        let log = RequestRecorder()
        let parent = UUID()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(title: "Child", parentID: parent, ownerUserID: user)
        MockURLProtocol.stubHandler = { [parent] request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("users/me/") {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data("{\"id\": \"11111111-1111-4111-8111-111111111111\"}".utf8), error: nil)
            }
            if request.httpMethod == "GET", url.contains(parent.uuidString.lowercased()) {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data(
                        """
                        {"id": "\(parent.uuidString.lowercased())", "title": "Parent",
                         "abilities": {"children_create": false},
                         "content": "", "created_at": "2026-03-01T12:00:00Z",
                         "updated_at": "2026-03-01T12:00:00Z", "depth": 1, "numchild": 0, "path": "00000A",
                         "link_reach": "restricted", "link_role": "reader", "user_role": "reader"}
                        """.utf8), error: nil)
            }
            return .init(statusCode: 403, headers: [:], body: Data(), error: nil)
        }

        await env.coordinator.syncPendingDrafts()

        XCTAssertNotNil(env.creates.create(for: local.id), "the document is still ours to send")
        XCTAssertNil(env.creates.create(for: local.id)?.parentID, "promoted rather than retrying forever")
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

        // Note the order: `Task {}` on the main actor is *enqueued*, while the directly
        // awaited call to a same-actor method runs inline with no hop — so the second
        // statement enters `syncPendingDrafts` first, sets the re-entrancy guard and suspends
        // on `/users/me/`. Only then does `queued` run, find the guard set, and coalesce into
        // another pass rather than starting its own POST. Either way round exactly one POST is
        // the whole point, which is what the assertion pins.
        let coordinator = env.coordinator
        let queued = Task { await coordinator.syncPendingDrafts() }
        await coordinator.syncPendingDrafts()
        await queued.value

        XCTAssertEqual(creates(log), 1)
    }

    /// The whole reason a resume reads `formattedContent` rather than `document`: the latter
    /// carries no body, so the baseline claimed the server was empty. With a real body on the
    /// server the baseline must reflect it — **and** the push must not go through unasked,
    /// since between the checkpoint and the resume the document is live and editable on the
    /// web. Every other resume test runs against an empty server body, so nothing else here
    /// distinguishes the two calls.
    func testAResumeWhoseServerCopyHasABodyRecordsAConflictInsteadOfOverwriting() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        env.coordinator.enqueue(documentID: local.id, title: "Notes", markdown: "# Written offline")
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        MockURLProtocol.stubHandler = { [serverID] request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("users/me/") {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data("{\"id\": \"11111111-1111-4111-8111-111111111111\"}".utf8), error: nil)
            }
            if url.contains("formatted-content") {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data(
                        """
                        {"id": "\(serverID.uuidString.lowercased())", "title": "Untitled document",
                         "content": "# Typed on the web", "created_at": "2026-03-01T12:00:00Z",
                         "updated_at": "2026-03-02T09:00:00Z"}
                        """.utf8), error: nil)
            }
            return .init(
                statusCode: 200, headers: [:],
                body: Data(
                    """
                    {"id": "\(serverID.uuidString.lowercased())", "title": "Untitled document",
                     "abilities": {}, "content": "", "created_at": "2026-03-01T12:00:00Z",
                     "updated_at": "2026-03-02T09:00:00Z", "depth": 1, "numchild": 0, "path": "00000A",
                     "link_reach": "restricted", "link_role": "reader", "user_role": "owner"}
                    """.utf8), error: nil)
        }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertEqual(
            relaunched.drafts.draft(for: serverID)?.baseline?.markdown, "# Typed on the web",
            "the baseline is what the server actually holds, not an assumed empty document")
        XCTAssertNotNil(
            relaunched.coordinator.conflict(for: serverID),
            "and the co-author's body is not silently full-overwritten")
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }
        XCTAssertEqual(
            relaunched.drafts.draft(for: serverID)?.markdown, "# Written offline",
            "while the offline body is kept for the user to choose")
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

    // MARK: - What can change while the POST is in flight

    /// The deferral is only a guarantee if it is re-checked *after* the await. An editor
    /// opening during the POST used to be migrated out from under: the screen's id is a
    /// `let`, so it kept enqueueing under an id the holds no longer covered, the save 404ed
    /// to `.failed`, and the next launch's sync pass deleted that draft — the user's only
    /// copy.
    func testAnEditorOpeningDuringThePostDefersTheMigration() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        env.coordinator.enqueue(documentID: local.id, title: "Notes", markdown: "# Written offline")
        stubReplayPipeline(log: log, postDelay: 0.2)

        let coordinator = env.coordinator
        let pass = Task { await coordinator.syncPendingDrafts() }
        // Open the screen while the POST is on the wire.
        await waitUntil { self.creates(log) == 1 }
        coordinator.retainOpenEditor(documentID: local.id)
        await pass.value

        XCTAssertTrue(coordinator.isPendingCreate(documentID: local.id), "migration deferred")
        XCTAssertEqual(
            env.drafts.draft(for: local.id)?.markdown, "# Written offline",
            "and the content is still under the id the open screen is writing to")
        XCTAssertNotNil(env.creates.create(for: local.id)?.syncedServerID, "but the checkpoint stands")
    }

    /// Deleting the document while its POST is in flight must not re-materialise it. The
    /// record snapshot is stale by then, and writing it back would resurrect the very record
    /// the delete removed — with a checkpoint attached.
    func testDeletingDuringThePostNeitherResurrectsTheRecordNorMigrates() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        env.coordinator.enqueue(documentID: local.id, title: "Notes", markdown: "# Written offline")
        stubReplayPipeline(log: log, postDelay: 0.2)

        let coordinator = env.coordinator
        let pass = Task { await coordinator.syncPendingDrafts() }
        await waitUntil { self.creates(log) == 1 }
        coordinator.discardPendingWork(documentID: local.id)
        await pass.value

        XCTAssertNil(env.creates.create(for: local.id), "the record stays deleted")
        XCTAssertNil(env.drafts.draft(for: self.serverID), "and no draft is materialised under the server id")
    }

    /// A checkpointed document deleted server-side can never be resumed. Retrying that GET
    /// forever left it in no list (a checkpointed record is withheld) and never pushed —
    /// unreachable by every route the app offers. Dropping the checkpoint lets it start over.
    func testAResumeWhoseDocumentIsGoneStartsOverInsteadOfLoopingForever() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("users/me/") {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data("{\"id\": \"11111111-1111-4111-8111-111111111111\"}".utf8), error: nil)
            }
            return .init(statusCode: 404, headers: [:], body: Data(), error: nil)
        }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNil(
            relaunched.creates.create(for: local.id)?.syncedServerID,
            "the dead checkpoint is dropped so the next pass can create it afresh")
        XCTAssertNotNil(relaunched.creates.create(for: local.id), "and the document is still ours to send")
    }

    /// A rename made between the checkpoint and the resume must survive. The server's title
    /// is the pre-death one, and since the baseline is stamped from it, `draftTitleOutcome`
    /// would see draft == baseline and silently keep the old name.
    func testAResumeKeepsARenameMadeAfterTheCheckpoint() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log, title: "Untitled document")
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // The rename lands in the draft during the intervening launch.
        env.coordinator.enqueue(documentID: local.id, title: "Renamed after the crash", markdown: "# Body")

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        // The draft written under the server id is what the save PATCHes, so the rename has
        // to be there. (`knownServerTitle` correctly keeps the server's stale title — that
        // map records what the server *holds*, not what we are about to send it.)
        await waitUntil { relaunched.drafts.draft(for: self.serverID) != nil }
        XCTAssertEqual(
            relaunched.drafts.draft(for: self.serverID)?.title, "Renamed after the crash",
            "the local rename is not reverted to the server's stale title")
    }

    /// `nil` (never fetched) and `[]` (fetched, empty) are deliberately different for the
    /// recents cache — `HomeViewModel` reads exactly that to decide whether to show the
    /// first-run skeleton. Fabricating one would make a failed first fetch render a single
    /// row as though the server held one document.
    func testTheRecentsCacheIsNeverFabricatedByAReplay() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        env.coordinator.createLocalDocument(title: "Untitled document", parentID: nil, ownerUserID: user)
        XCTAssertNil(env.lists.loadRecentDocuments(), "no list has ever been fetched")

        await env.coordinator.syncPendingDrafts()

        XCTAssertNil(env.lists.loadRecentDocuments(), "and the replay must not invent one")
    }

    /// A CSRF-shaped 403 (the documented capitalised-host bug) must not silently promote
    /// every sub-page to a root: the promotion is irreversible, so it needs evidence about
    /// the parent specifically.
    func testAForbiddenThatIsNotAboutTheParentDoesNotPromote() async {
        let log = RequestRecorder()
        let parent = UUID()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(title: "Child", parentID: parent, ownerUserID: user)
        MockURLProtocol.stubHandler = { [parent] request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("users/me/") {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data("{\"id\": \"11111111-1111-4111-8111-111111111111\"}".utf8), error: nil)
            }
            // The parent is perfectly healthy; only the POST is rejected.
            if request.httpMethod == "GET", url.contains(parent.uuidString.lowercased()) {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data(
                        """
                        {"id": "\(parent.uuidString.lowercased())", "title": "Parent",
                         "abilities": {"children_create": true},
                         "content": "", "created_at": "2026-03-01T12:00:00Z",
                         "updated_at": "2026-03-01T12:00:00Z", "depth": 1, "numchild": 0, "path": "00000A",
                         "link_reach": "restricted", "link_role": "reader", "user_role": "owner"}
                        """.utf8), error: nil)
            }
            return .init(statusCode: 403, headers: [:], body: Data(), error: nil)
        }

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(
            env.creates.create(for: local.id)?.parentID, parent,
            "the sub-page keeps its parent when the 403 was not about the parent")
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

    /// A record nothing here could ever send must not even cost the `/users/me/` round trip —
    /// otherwise every reconnect, foreground and launch pays a request that cannot produce
    /// work, forever. Distinct from `testAnotherUsersRecordIsNeverPosted`, whose record
    /// *passes* the cheap gate and is declined afterwards.
    func testARecordThatCanNeverBeSentCostsNoRequestAtAll() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        env.creates.save(
            PendingDocumentCreate(
                localID: UUID(), title: "From another server", createdAt: Date(),
                serverOrigin: "https://elsewhere.example.org", ownerUserID: user))

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertEqual(log.methods.count, 0, "not even /users/me/")
    }

    /// A session expiry is not a merits rejection: the shared client's hook has already raised
    /// the re-login sheet, so the record must stay replayable for the next trigger rather than
    /// parking at `.failed` for the rest of the process.
    func testASessionExpiryLeavesTheRecordReplayable() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        stubUsersMeThen(log: log) { _ in .init(statusCode: 401, headers: [:], body: Data(), error: nil) }

        await env.coordinator.syncPendingDrafts()

        XCTAssertNotNil(env.creates.create(for: local.id))
        guard case .failed = env.coordinator.state(for: local.id) else { return }
        XCTFail("a 401 must not become the terminal state the pass then skips")
    }

    /// A create the server rejected on the merits must stop retrying on every trigger.
    func testAMeritsRejectionStopsRetryingWithinTheProcess() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        stubUsersMeThen(log: log) { _ in .init(statusCode: 400, headers: [:], body: Data(), error: nil) }

        await env.coordinator.syncPendingDrafts()
        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(creates(log), 1, "the second pass skips the .failed record")
        guard case .failed = env.coordinator.state(for: local.id) else {
            return XCTFail("a merits rejection is terminal for this process")
        }
        XCTAssertNil(env.creates.create(for: local.id)?.replayBlockedAt, "but a relaunch may still retry a 400")
    }

    /// The one rejection where "the POST failed" is the wrong inference: a decode failure
    /// arrives *after* a 201, so the server built the document. Retrying on the next launch
    /// would abandon it and build another — one orphan per launch, forever.
    func testAnUnreadableCreateResponseIsNotRetriedOnTheNextLaunch() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        // A 201 whose body cannot be decoded into a `Document`.
        stubUsersMeThen(log: log) { _ in
            .init(statusCode: 201, headers: [:], body: Data("{\"unexpected\": true}".utf8), error: nil)
        }

        await env.coordinator.syncPendingDrafts()
        XCTAssertEqual(creates(log), 1)
        XCTAssertNotNil(
            env.creates.create(for: local.id)?.replayBlockedAt,
            "the block has to survive the process, unlike the in-memory .failed state")

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertEqual(creates(log), 1, "a relaunch must not POST a second document")
        XCTAssertTrue(
            relaunched.coordinator.isPendingCreate(documentID: local.id),
            "and the document stays protected — inert, not abandoned")
    }

    /// The block says "*this build* could not read the response", not "never try again". A
    /// blanket block would make the very incident it cites — a decode bug shipped in the app —
    /// unrecoverable by shipping the fix, which is worse than the littering it prevents.
    func testAShippedFixRecoversARecordTheOldBuildCouldNotRead() async {
        let log = RequestRecorder()
        let env = makeEnvironment(appBuild: "100")
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        stubUsersMeThen(log: log) { _ in
            .init(statusCode: 201, headers: [:], body: Data("{\"unexpected\": true}".utf8), error: nil)
        }
        await env.coordinator.syncPendingDrafts()
        XCTAssertEqual(creates(log), 1)

        // The decode fix ships: same records on disk, a new build, and a server the app can
        // now read.
        stubReplayPipeline(log: log)
        let updated = makeEnvironment(sharing: env.defaults, appBuild: "101")
        await updated.coordinator.syncPendingDrafts()

        XCTAssertEqual(creates(log), 2, "the new build retries exactly once")
        XCTAssertNil(updated.creates.create(for: local.id), "and the document finally syncs")
    }

    /// The pre-flight gate's own rule — never pay `/users/me/` for work that cannot happen —
    /// has to hold for a blocked record too, or it reintroduces the cost it exists to prevent.
    func testABlockedRecordCostsNoRequestOnLaterTriggers() async {
        let log = RequestRecorder()
        let env = makeEnvironment(appBuild: "100")
        env.coordinator.createLocalDocument(title: "Untitled document", parentID: nil, ownerUserID: user)
        stubUsersMeThen(log: log) { _ in
            .init(statusCode: 201, headers: [:], body: Data("{\"unexpected\": true}".utf8), error: nil)
        }
        await env.coordinator.syncPendingDrafts()

        let relaunched = makeEnvironment(sharing: env.defaults, appBuild: "100")
        let before = log.methods.count
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertEqual(log.methods.count, before, "not even /users/me/")
    }

    /// A transient failure on the resume must never discard the checkpoint: that is the only
    /// thing standing between the app and a duplicate, since the backend has no idempotency
    /// key.
    func testATransientResumeFailureKeepsTheCheckpoint() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        stubUsersMeThen(log: log) { _ in .init(statusCode: 503, headers: [:], body: Data(), error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertEqual(
            relaunched.creates.create(for: local.id)?.syncedServerID, serverID,
            "a 5xx proves nothing about the document")
        XCTAssertEqual(creates(log), 0)
    }

    /// A bare 403 is not evidence a document is gone — Django answers a bad `Origin` with
    /// one. Dropping the checkpoint on it would POST a duplicate and orphan the original.
    func testAForbiddenResumeKeepsTheCheckpointRatherThanDuplicating() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        stubUsersMeThen(log: log) { _ in .init(statusCode: 403, headers: [:], body: Data(), error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertEqual(relaunched.creates.create(for: local.id)?.syncedServerID, serverID)
        XCTAssertEqual(creates(log), 0, "never a second document on a bare 403")
    }

    /// The `document()` fetch is cosmetic — it only feeds the list caches. `formattedContent`
    /// answering 200 is direct evidence the document exists, so a failure of the cosmetic call
    /// must neither discard the checkpoint nor stop the migration.
    func testACosmeticFetchFailureStillMigrates() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        env.coordinator.enqueue(documentID: local.id, title: "Notes", markdown: "# Written offline")
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        let formatted = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Notes", "content": "",
             "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-01T12:00:00Z"}
            """.utf8)
        stubUsersMeThen(log: log) { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: formatted, error: nil)
            }
            if request.httpMethod == "GET" {
                return .init(statusCode: 403, headers: [:], body: Data(), error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: Data(), error: nil)
        }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNil(relaunched.creates.create(for: local.id), "the migration completed")
        XCTAssertEqual(creates(log), 0, "and the checkpoint was never discarded")
        XCTAssertEqual(relaunched.drafts.draft(for: serverID)?.markdown, "# Written offline")
    }

    /// "I couldn't ask" must never read as "it isn't there". Promotion re-parents the document
    /// irreversibly, so a probe that fails to answer must leave the record alone.
    func testAParentProbeThatCannotAnswerDoesNotPromote() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let parent = UUID()
        let local = env.coordinator.createLocalDocument(
            title: "Child", parentID: parent, ownerUserID: user)
        stubUsersMeThen(log: log) { request in
            if request.httpMethod == "POST" {
                return .init(statusCode: 403, headers: [:], body: Data(), error: nil)
            }
            return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
        }

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(
            env.creates.create(for: local.id)?.parentID, parent,
            "an unanswerable probe leaves the placement alone")
    }

    // MARK: - The server id can be live too

    /// Once a record is checkpointed the local row is withheld and the *server* document comes
    /// back in an ordinary list fetch — so the user can be editing it under `serverID` while
    /// the migration still guards only `localID`. Migrating then would overwrite that screen's
    /// draft and replace its queued keystrokes.
    func testAMigrationDefersWhileAnEditorHoldsTheServerID() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)

        // No competing save: the retain is the *only* thing that can defer this, so the
        // assertion cannot be satisfied by one of the sibling guards instead.
        let relaunched = makeEnvironment(sharing: env.defaults)
        relaunched.coordinator.retainOpenEditor(documentID: serverID)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNotNil(relaunched.creates.create(for: local.id), "the migration deferred")
        XCTAssertNil(relaunched.drafts.draft(for: serverID), "and wrote nothing under the server id")
    }

    /// The same hazard without a registered editor: a save for the server id sitting in the
    /// *queued* slot with nothing in flight — the shape the conflict hold produces. Migrating
    /// would replace that slot, and releasing the hold would then PATCH the offline body over
    /// the text the user typed.
    func testAMigrationDefersWhileASaveForTheServerIDIsQueued() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)

        // The local draft has to go, or the both-drafts discriminator defers first and this
        // test passes without ever reaching the guard it names.
        env.drafts.remove(documentID: local.id)

        let relaunched = makeEnvironment(sharing: env.defaults)
        // The enqueue-hold parks the save in `queued` and starts nothing, so `inFlight` is
        // provably nil and only the `queued` half of the guard can be what defers.
        relaunched.coordinator.recordConflict(documentID: serverID, serverUpdatedAt: Date())
        relaunched.coordinator.enqueue(documentID: serverID, title: "Notes", markdown: "# Typed on the real doc")
        XCTAssertEqual(savesInFlight(log), 0, "held, not sent — so `inFlight` is nil")

        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNotNil(relaunched.creates.create(for: local.id), "the migration deferred")
        XCTAssertEqual(
            relaunched.drafts.draft(for: serverID)?.markdown, "# Typed on the real doc",
            "the held work is untouched")
    }

    /// The other half of the same guard: a save actually on the wire for the server id.
    /// Migrating would replace the queued slot behind it, and `finish` would then PATCH the
    /// offline body over the text the user just typed.
    func testAMigrationDefersWhileASaveForTheServerIDIsInFlight() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        env.drafts.remove(documentID: local.id)

        let relaunched = makeEnvironment(sharing: env.defaults)
        // The resume GETs must SUCCEED, or the pass never reaches the migration and the test
        // passes for the wrong reason. Only the PATCH is held open, so the save is provably
        // still in flight when the migration runs its guards.
        let formatted = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Notes", "content": "",
             "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-01T12:00:00Z"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("users/me/") {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data("{\"id\": \"11111111-1111-4111-8111-111111111111\"}".utf8), error: nil)
            }
            if request.httpMethod == "PATCH" {
                return .init(statusCode: 200, headers: [:], body: Data(), error: nil, delay: 2.0)
            }
            return .init(statusCode: 200, headers: [:], body: formatted, error: nil)
        }
        relaunched.coordinator.enqueue(documentID: serverID, title: "Notes", markdown: "# On the wire")
        await waitUntil { self.savesInFlight(log) == 1 }

        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNotNil(relaunched.creates.create(for: local.id), "the migration deferred")
        // Prove it deferred at the *guards* rather than never getting there: a resume that
        // failed its fetch would also leave the record, and would satisfy the assertion above
        // for the wrong reason. (`syncedServerID` cannot do this job — the test sets it, and
        // only the `.notFound` branch clears it, which this stub never returns.)
        XCTAssertEqual(
            log.count(ofMethod: "GET", urlContaining: "formatted-content"), 1,
            "the resume read the server copy, so the migration really ran its guards")
    }

    /// A death *between* the migration's two draft writes leaves **both** drafts present. The
    /// discriminator reads that as the user's, so the migration defers rather than migrating —
    /// safe, and it recovers, because `runSyncPass` pushes the server-id draft and a later
    /// trigger then migrates.
    func testADeathBetweenTheTwoDraftWritesDefersRatherThanGuessing() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        env.coordinator.enqueue(documentID: local.id, title: "Notes", markdown: "# Offline body")
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // Both drafts on disk — the server-id one written, the local one not yet removed.
        env.drafts.save(
            PendingDraft(
                documentID: serverID, title: "Notes", markdown: "# Offline body",
                updatedAt: Date(), baseline: nil))

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNotNil(relaunched.creates.create(for: local.id), "deferred rather than migrated")
        await waitUntil {
            relaunched.coordinator.lastConfirmedPush(documentID: self.serverID) == "# Offline body"
        }
    }

    /// A draft under the server id belongs to the user unless the local draft is already gone
    /// (which is what defines the partial-migration window). With both present, overwriting
    /// the server-id one would destroy work.
    func testAMigrationNeverOverwritesAUserDraftUnderTheServerID() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        env.drafts.save(
            PendingDraft(
                documentID: serverID, title: "Real doc", markdown: "# Authored against the server",
                updatedAt: Date(), baseline: nil))

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertEqual(
            relaunched.drafts.draft(for: serverID)?.markdown, "# Authored against the server",
            "the user's draft survives")
    }

    /// The partial-migration window itself — the local draft already removed, the server-id
    /// one written. The body must come from there, not fall through to `""`.
    func testAPartiallyMigratedDraftIsAdoptedRatherThanEmptied() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // Exactly the shape a death between the two draft writes leaves behind.
        env.drafts.remove(documentID: local.id)
        env.drafts.save(
            PendingDraft(
                documentID: serverID, title: "Notes", markdown: "# Survived the crash",
                updatedAt: Date(), baseline: nil))

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNil(relaunched.creates.create(for: local.id), "the migration finished")
        await waitUntil {
            relaunched.coordinator.lastConfirmedPush(documentID: self.serverID) == "# Survived the crash"
        }
    }

    /// An empty local body must never be offered as a conflict candidate: "Keep my version"
    /// would PATCH `""` and wipe the document. With nothing local to contribute, adopt the
    /// server.
    func testAnEmptyLocalBodyAdoptsTheServerInsteadOfArmingAWipe() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // No body anywhere on this device — the seed draft is gone too.
        env.drafts.remove(documentID: local.id)
        let formatted = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Notes",
             "content": "# Written on the web",
             "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-02T12:00:00Z"}
            """.utf8)
        stubUsersMeThen(log: log) { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: formatted, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: formatted, error: nil)
        }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNil(relaunched.coordinator.conflict(for: serverID), "nothing to ask about")
        XCTAssertNil(relaunched.drafts.draft(for: serverID), "and no empty draft left to push")
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }
    }

    /// Adopting the server means adopting its **title** as well as its body: this branch has
    /// no evidence its own title is the newer one (it falls back to the mint title, and it
    /// only fires once the server has acquired a body, i.e. after real elapsed time during
    /// which a web rename is at least as likely). So it writes nothing at all — not the body,
    /// which would flatten a co-author's table through `MarkdownYjs`, and not the title, which
    /// would silently revert their rename.
    func testAdoptingTheServerWritesNothingBackAtAll() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // Renamed on this device, never typed into.
        env.drafts.save(
            PendingDraft(
                documentID: local.id, title: "My renamed page", markdown: "", updatedAt: Date(),
                baseline: nil))
        // The co-author's body is a table — an `.unknown` block that cannot round-trip.
        let formatted = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Untitled document",
             "content": "| a | b |\\n| - | - |\\n| 1 | 2 |",
             "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-02T12:00:00Z"}
            """.utf8)
        stubUsersMeThen(log: log) { _ in
            .init(statusCode: 200, headers: [:], body: formatted, error: nil)
        }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNil(relaunched.creates.create(for: local.id), "the migration completed")
        XCTAssertNil(relaunched.drafts.draft(for: serverID), "no draft left behind")
        // Nothing is written back: not a content PATCH that would flatten the table, and not a
        // title PATCH that would revert a rename this branch cannot prove is stale. The window
        // is widened past the 0.3 s default because a regression here would most likely be a
        // fire-and-forget `Task`, which the default could outrun.
        await waitAndConfirmNever(timeout: 2) {
            log.count(ofMethod: "PATCH", urlContaining: "documents/") > 0
        }
    }

    /// Adopting the server removes every trace of local work for that id, so a conflict record
    /// rehydrated from a persisted stamp is now moot — and a record outliving the work it
    /// protects parks every future save for that document behind a pill with nothing to ask.
    func testAdoptingTheServerReleasesAConflictThatIsNowMoot() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        env.drafts.remove(documentID: local.id)
        // A server-id draft with an empty body carrying a conflict stamp — what `init`
        // rehydrates `conflicts` from.
        env.drafts.save(
            PendingDraft(
                documentID: serverID, title: "Notes", markdown: "", updatedAt: Date(), baseline: nil,
                lastPushedMarkdown: nil, conflictServerUpdatedAt: Date(timeIntervalSince1970: 1)))
        let formatted = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Notes",
             "content": "# Written on the web",
             "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-02T12:00:00Z"}
            """.utf8)
        stubUsersMeThen(log: log) { _ in .init(statusCode: 200, headers: [:], body: formatted, error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        XCTAssertNotNil(relaunched.coordinator.conflict(for: serverID), "rehydrated from the draft")

        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNil(
            relaunched.coordinator.conflict(for: serverID),
            "released — otherwise every later save for this document is parked behind it")
    }

    /// A missing *route* is a fact about the server, not about this document — so a root create
    /// retries rather than parking, matching what the resume path does with the same error.
    func testARouteNotFoundOnARootCreateRetriesRatherThanParking() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        // Django's own missing-route page: an HTML 404, which maps to `.routeNotFound`.
        stubUsersMeThen(log: log) { _ in
            .init(
                statusCode: 404, headers: ["Content-Type": "text/html; charset=utf-8"],
                body: Data("<html><body>Not Found</body></html>".utf8), error: nil)
        }

        await env.coordinator.syncPendingDrafts()
        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(creates(log), 2, "not parked at .failed after the first attempt")
    }

    /// Releasing the editor that held the *server* id must kick the funnel too, or the
    /// deferred migration waits for an unrelated foreground or reconnect.
    func testReleasingAnEditorOnTheServerIDRunsTheDeferredMigration() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)

        let relaunched = makeEnvironment(sharing: env.defaults)
        relaunched.coordinator.retainOpenEditor(documentID: serverID)
        await relaunched.coordinator.syncPendingDrafts()
        XCTAssertNotNil(relaunched.creates.create(for: local.id), "deferred while held")

        relaunched.coordinator.releaseOpenEditor(documentID: serverID)

        await waitUntil { relaunched.creates.create(for: local.id) == nil }
    }

    // MARK: - More than one record

    /// Every skip in the record loop is a `continue`, not a `return`. One old un-replayable
    /// record must not block every later one from ever replaying.
    func testAnUnreplayableRecordDoesNotBlockTheOnesBehindIt() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        // Older, and owned by somebody else — skipped.
        env.creates.save(
            PendingDocumentCreate(
                localID: UUID(), title: "Theirs", createdAt: Date(timeIntervalSince1970: 1),
                serverOrigin: origin, ownerUserID: UUID()))
        let mine = env.coordinator.createLocalDocument(
            title: "Mine", parentID: nil, ownerUserID: user)

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertEqual(creates(log), 1)
        XCTAssertNil(relaunched.creates.create(for: mine.id), "the replayable one behind it still went")
    }

    // MARK: - Helpers

    /// `/users/me/` answers this user; everything else is the caller's to decide.
    private func stubUsersMeThen(
        log: RequestRecorder, _ handler: @escaping @Sendable (URLRequest) -> MockURLProtocol.Stub
    ) {
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            if request.url?.absoluteString.hasSuffix("users/me/") == true {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data("{\"id\": \"11111111-1111-4111-8111-111111111111\"}".utf8), error: nil)
            }
            return handler(request)
        }
    }
}
