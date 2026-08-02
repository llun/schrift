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

    /// The body has to survive the id change. Note what this does **not** prove: for a pending
    /// create the draft and the queued slot always agree, because `enqueue` write-ahead-saves
    /// the draft from the same `save` it then parks — no save is ever in flight to make them
    /// diverge. So this pins that the body arrives under the server id, not that the *queued
    /// slot* is the source it came from. Clearing `queued[localID]` at the migration is
    /// hygiene, not a rescue.
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
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        // This test installs its own handler below rather than using `stubReplayPipeline`,
        // because it needs the save PATCH to fail so the draft survives for inspection.
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
    func testASubpageJoinsAKnownParentLevel() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let knownParent = UUID()
        let env = makeEnvironment()
        env.children.save([], for: knownParent)
        env.coordinator.createLocalDocument(title: "Child", parentID: knownParent, ownerUserID: user)

        await env.coordinator.syncPendingDrafts()

        // The never-invents-one half lives in `testASubpageNeverFabricatesAnUnfetchedParentLevel`
        // — it needs a parent whose level was *not* pre-fetched, which this test's setup rules
        // out, so asserting it here could only ever be vacuous.
        XCTAssertEqual(env.children.children(for: knownParent)?.map(\.id), [serverID])
        // And it must go to the **children** route. The suite's POST counter matches both
        // `documents/` and `documents/{parent}/children/`, so without this a refactor dropping
        // `replayCreate`'s `if let parentID` branch would create every offline sub-page at the
        // root and leave the whole suite green.
        XCTAssertEqual(
            log.count(ofMethod: "POST", urlContaining: "documents/\(knownParent.uuidString.lowercased())/children/"),
            1, "a sub-page is POSTed to its parent's children route, not to documents/")
    }

    /// The content must end up on disk under the server id even when the save never lands.
    /// Note this pins the *outcome*, not the write ordering that protects it: the ordering
    /// is only observable across a process death (in between, the body is on disk twice —
    /// which is the point), so the reason the draft is written before the old one is removed
    /// is argued in the code rather than asserted here.
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

    /// A missing **route** is a fact about the server, not this document — so a sub-page
    /// retries exactly as a root create does. Scoping the early return to roots parked every
    /// offline sub-page for the session whenever a proxy swallowed the children route during a
    /// deploy, while an identically-affected root recovered on the next trigger. The probe
    /// cannot speak to it either: it tests `documents/{p}/`, a different path.
    func testARouteNotFoundOnASubpageCreateRetriesLikeARoot() async {
        let log = RequestRecorder()
        let parent = UUID()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(title: "Child", parentID: parent, ownerUserID: user)
        // Django's own missing-route page on the create — an HTML 404, mapping to
        // `.routeNotFound` — while the parent itself is perfectly healthy. That combination is
        // what discriminates: stubbing the *probe* 404 too would let the pre-fix code reach its
        // generic catch and retry for the wrong reason, so this test would pass either way.
        let parentBody = Data(
            """
            {"id": "\(parent.uuidString.lowercased())", "title": "Parent",
             "abilities": {"children_create": true},
             "content": "", "created_at": "2026-03-01T12:00:00Z",
             "updated_at": "2026-03-01T12:00:00Z", "depth": 1, "numchild": 0, "path": "00000A",
             "link_reach": "restricted", "link_role": "reader", "user_role": "owner"}
            """.utf8)
        stubUsersMeThen(log: log) { request in
            if request.httpMethod == "POST" {
                return .init(
                    statusCode: 404, headers: ["Content-Type": "text/html; charset=utf-8"],
                    body: Data("<html><body>Not Found</body></html>".utf8), error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: parentBody, error: nil)
        }

        await env.coordinator.syncPendingDrafts()
        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(creates(log), 2, "not parked after the first attempt")
        XCTAssertEqual(env.creates.create(for: local.id)?.parentID, parent, "and never re-parented")
        // The probe must never even be reached — `.routeNotFound` returns before it, since the
        // probe tests a different path and can say nothing about the one that 404'd.
        XCTAssertEqual(
            log.count(ofMethod: "GET", urlContaining: parent.uuidString.lowercased()), 0,
            "and the parent was never probed")
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
    /// carries no body, so the baseline claimed the server was empty when nothing had checked.
    /// With a real body on the server the push must not go through unasked — and the baseline
    /// must not *prove* that push either,
    /// since between the checkpoint and the resume the document is live and editable on the
    /// web. The other resume tests that do supply a body answer both GETs from one stub, so
    /// this is the only one where the two calls are distinguishable — nothing else here
    /// distinguishes the two calls.
    func testAResumeWhoseServerCopyHasABodyRecordsAConflictInsteadOfOverwriting() async throws {
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

        XCTAssertNotNil(
            relaunched.coordinator.conflict(for: serverID),
            "the co-author's body is not silently full-overwritten")
        // **And the baseline must not prove the push the conflict is holding.** Stamping the
        // observed server state here is self-defeating: `draftSyncBodyDecision` rule 2 finds
        // `serverUpdatedAt <= baselineDate` trivially true of the state it was copied from, so
        // the next revalidation answers `.push(.descendsFromBaseline)`,
        // `releaseConflictIfProven` clears the conflict, and the held save goes out over the
        // co-author. Re-running the decision is the property; the two structural assertions
        // below say *why* it holds.
        let draft = try XCTUnwrap(relaunched.drafts.draft(for: serverID))
        XCTAssertNil(draft.baseline?.serverUpdatedAt, "no claim about the server clock")
        XCTAssertEqual(draft.baseline?.markdown, "", "our body descends from the empty document we made")
        let decision = draftSyncDecision(
            baseline: draft.baseline, lastPushedMarkdown: draft.lastPushedMarkdown,
            localMarkdown: draft.markdown, draftTitle: draft.title, draftUpdatedAt: draft.updatedAt,
            serverTitle: "Untitled document",
            serverUpdatedAt: ISO8601DateFormatter().date(from: "2026-03-02T09:00:00Z")!,
            serverMarkdown: "# Typed on the web")
        guard case .conflict = decision else {
            return XCTFail("a re-evaluation must still answer .conflict, not release it — got \(decision)")
        }
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
    /// is the pre-death one, and since the baseline carries it, `draftTitleOutcome`
    /// short-circuits to `.keepDraft` on `serverUpdatedAt <= baselineDate` before comparing
    /// anything, and the rename would be silently lost.
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
        // And goes **terminal**, exactly as a root create does for this same non-retryable
        // error. Leaving it retryable was an asymmetry: a capitalised host 403s the POST while
        // the probe (a GET, which carries no `Origin`) succeeds, so a root create parked while
        // a sub-page paid a POST plus a probe on every trigger forever.
        guard case .failed = env.coordinator.state(for: local.id) else {
            return XCTFail("a willing parent means the create itself was rejected — that is terminal")
        }
    }

    // MARK: - Failures

    /// A parent that is **gone** must not strand the content: the document
    /// becomes a root instead. Placement is recoverable by the user; a lost body is not.
    func testASubpageWhoseParentIsGoneRetriesAsARootDocument() async {
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
            // The POST is forbidden; the probe then finds the parent **gone**, which is the
            // only evidence that promotes. A bare 403 on the probe does not — an
            // ancestor-access recompute 403s transiently, and promotion is irreversible.
            if request.httpMethod == "POST" {
                return .init(statusCode: 403, headers: [:], body: Data(), error: nil)
            }
            return .init(statusCode: 404, headers: [:], body: Data(), error: nil)
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
        // The property the name actually claims. Without the retryable arm this lands on
        // `.failed`, which `runCreatePass` skips for the rest of the process — the record
        // survives either way, so the three assertions above cannot tell the two apart.
        if case .failed = env.coordinator.state(for: local.id) {
            XCTFail("offline is retryable — parking at .failed strands it until relaunch")
        }
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
    /// arrives *after a 2xx*, so the server very likely built the document. Retrying on the next launch
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
        // And leaves it *retryable*: every probe outcome but a 404 keeps `parentID`, so
        // the state is the only discriminator. Without this, "every reachable parent is
        // terminal" passes.
        if case .failed = env.coordinator.state(for: local.id) {
            XCTFail("\"I couldn't ask\" must not park the record — the next trigger retries")
        }
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
        // Assert the *conflict stamp*, not the body: with the guard deleted the migration
        // rewrites this draft from `migrated?.markdown` — the same bytes — so a body assertion
        // passes either way. The stamp is what it would actually destroy (the rewritten draft
        // carries `conflictServerUpdatedAt: nil`), along with the queued slot.
        XCTAssertNotNil(
            relaunched.drafts.draft(for: serverID)?.conflictServerUpdatedAt,
            "the held work keeps its conflict stamp — the migration did not rewrite it")
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
        // Exclude the never-got-there false pass: the record would also survive a resume that
        // never issued its fetch. (`syncedServerID` cannot do this job — the test sets it, and
        // only the `.notFound` branch clears it, which this stub never returns.) Note the
        // recorder logs before the response is chosen, so this proves the fetch was *issued*,
        // not that it succeeded; the stub always answers it with a valid body.
        XCTAssertEqual(
            log.count(ofMethod: "GET", urlContaining: "formatted-content"), 1,
            "the resume issued its fetch, so the pass reached the migration")
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
        // One body answers both GETs (the cosmetic `document` fetch and `formatted-content`).
        stubUsersMeThen(log: log) { _ in .init(statusCode: 200, headers: [:], body: formatted, error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNil(relaunched.creates.create(for: local.id), "the migration completed")
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

    /// A death inside the migration can leave the only copy of the body under `serverID`.
    /// Dropping the checkpoint severs the last thing tying it to the record, **orphaning** the
    /// body: the re-POST mints a different server id and its body chain looks under the local
    /// id and the new one, never the old, so it builds an *empty* document in place of the
    /// text — and the stranded draft is separately reaped by `runSyncPass`'s 404 rule. (That
    /// draft is never covered by the pending-create hold in either ordering; the hold is keyed
    /// on the local id.)
    func testAStartOverTakesTheOrphanedBodyBackToTheLocalID() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // Exactly the partial-migration window: server-id draft written, local one removed.
        env.drafts.remove(documentID: local.id)
        env.drafts.save(
            PendingDraft(
                documentID: serverID, title: "Notes", markdown: "# Only copy", updatedAt: Date(),
                baseline: nil))
        // The checkpointed document is gone, and so the draft's own GET would 404 too.
        stubUsersMeThen(log: log) { _ in .init(statusCode: 404, headers: [:], body: Data(), error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNotNil(relaunched.creates.create(for: local.id), "the record survives to be retried")
        XCTAssertNil(relaunched.creates.create(for: local.id)?.syncedServerID, "the checkpoint dropped")
        XCTAssertEqual(
            relaunched.drafts.draft(for: local.id)?.markdown, "# Only copy",
            "and the body came back to the id a fresh create will look for")
        // Deliberately *not* asserting the server-id draft is gone. It would be — but not
        // necessarily because the take-back removed it: `runSyncPass` runs next in this same
        // pass, is not gated by the pending-create hold (keyed on the local id), GETs that
        // draft, meets the same 404 and reaps it. So the assertion passes even with the
        // take-back's `remove` deleted, which makes it a claim the test cannot establish.
        // Pinning move-versus-copy here would need that draft's own GET to succeed, and it
        // cannot: it names the id that just 404'd.
    }

    /// With a local draft still present this is *not* the partial-migration window, so a draft
    /// under the server id is the user's own separate work — the take-back must not overwrite
    /// the local body with it. Note what this does *not* claim: that draft is not preserved.
    /// `runSyncPass`, next in the same pass, GETs it, takes the same 404 and removes it. The
    /// branch's job is only to leave the local body alone.
    func testAStartOverLeavesAUserDraftUnderTheServerIDAlone() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // Both present: the local seed draft (rewritten with a body) and a server-id draft.
        env.drafts.save(
            PendingDraft(
                documentID: local.id, title: "Mine", markdown: "# Local body", updatedAt: Date(),
                baseline: nil))
        env.drafts.save(
            PendingDraft(
                documentID: serverID, title: "Theirs", markdown: "# Against the real document",
                updatedAt: Date(), baseline: nil))
        stubUsersMeThen(log: log) { _ in .init(statusCode: 404, headers: [:], body: Data(), error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertEqual(
            relaunched.drafts.draft(for: local.id)?.markdown, "# Local body",
            "the local body is not overwritten by the server-id draft")
    }

    /// **A delete arriving under the server id must clear the record too.** Once checkpointed,
    /// that is the only id the user is offered — the local row is withheld — so this is the
    /// ordinary way such a document gets deleted. `isPendingCreate` is keyed on the *local* id
    /// and answers false, so without the branch the record and the local draft both survive a
    /// successful DELETE, the resume 404s, the checkpoint clears, and the next pass re-POSTs
    /// the document from that draft.
    func testDeletingUnderTheServerIDDoesNotResurrectTheDocument() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        env.coordinator.enqueue(documentID: local.id, title: "Notes", markdown: "# Written offline")
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)

        let relaunched = makeEnvironment(sharing: env.defaults)
        // What `EditorViewModel.handleDidDelete` does after the server DELETE succeeds — and
        // the id it has is the server one.
        relaunched.coordinator.discardPendingWork(documentID: serverID)

        XCTAssertNil(relaunched.creates.create(for: local.id), "the record went with the delete")
        XCTAssertNil(relaunched.drafts.draft(for: local.id), "and so did the body it would rebuild from")

        // The server now 404s it, as it would after a real delete. Two passes, because one is
        // not enough to distinguish the fix from its absence: without the branch the first
        // pass only clears the checkpoint, and it is the *second* that re-POSTs.
        stubUsersMeThen(log: log) { _ in .init(statusCode: 404, headers: [:], body: Data(), error: nil) }
        await relaunched.coordinator.syncPendingDrafts()
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertEqual(creates(log), 0, "nothing re-POSTs a document the user deleted")
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

    /// The promote path's own write-back guard — the last of the three that guard a *stale*
    /// `record` copy behind a separately-deletable line (the `.decoding` stamp has a fourth,
    /// but there the re-read **is** the binding that produces the value, so it cannot be
    /// deleted without breaking the build). This is the one with two
    /// awaits in front of it (the POST *and* the parent probe). A delete landing in either
    /// window has already removed the record, and `updatePendingCreate` writes through to
    /// disk, so without the guard the record comes back with `parentID` rewritten to nil and
    /// the next pass POSTs a document the user threw away.
    func testADeleteDuringTheParentProbeDoesNotResurrectTheRecord() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let parent = UUID()
        let local = env.coordinator.createLocalDocument(
            title: "Child", parentID: parent, ownerUserID: user)
        // The POST is forbidden, and the probe that follows is held open so the delete can
        // land inside its window.
        stubUsersMeThen(log: log) { request in
            if request.httpMethod == "POST" {
                return .init(statusCode: 403, headers: [:], body: Data(), error: nil)
            }
            return .init(statusCode: 404, headers: [:], body: Data(), error: nil, delay: 0.3)
        }

        let coordinator = env.coordinator
        let pass = Task { await coordinator.syncPendingDrafts() }
        await waitUntil { log.count(ofMethod: "GET", urlContaining: parent.uuidString.lowercased()) == 1 }
        coordinator.discardPendingWork(documentID: local.id)
        await pass.value

        XCTAssertNil(env.creates.create(for: local.id), "the delete stands — nothing is written back")
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

    /// The loop re-reads each record from the mirror rather than trusting the snapshot it took
    /// before `/users/me/`. Without that, deleting a *later* record while an earlier one's POST
    /// is in flight still POSTs it — creating a document the user threw away, orphaned on the
    /// server with nothing on the device referencing it. (The record itself is safe either way:
    /// every `updatePendingCreate` on this path is guarded on it still existing.)
    func testARecordDeletedDuringAnEarlierPostIsNeverCreated() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log, postDelay: 0.3)
        let env = makeEnvironment()
        let first = env.coordinator.createLocalDocument(
            title: "First", parentID: nil, ownerUserID: user)
        let second = env.coordinator.createLocalDocument(
            title: "Second", parentID: nil, ownerUserID: user)

        let coordinator = env.coordinator
        let pass = Task { await coordinator.syncPendingDrafts() }
        // Delete the second while the first is still on the wire.
        await waitUntil { self.creates(log) == 1 }
        coordinator.discardPendingWork(documentID: second.id)
        await pass.value

        XCTAssertEqual(creates(log), 1, "only the first — the deleted one is never POSTed")
        XCTAssertNil(env.creates.create(for: second.id), "the delete stands")
        XCTAssertNil(env.creates.create(for: first.id), "and the first still migrated")
    }

    /// The per-record block skip, isolated from the two guards that would otherwise mask it:
    /// a *replayable sibling* keeps the pre-flight gate open, and a **relaunch** re-seeds
    /// `states` to `.pendingSync` so the in-memory `.failed` skip is spent. Only
    /// `replayBlockedAt` is left to hold the blocked record back.
    func testABlockedRecordIsSkippedWhileItsSiblingReplays() async {
        let log = RequestRecorder()
        let env = makeEnvironment(appBuild: "100")
        let blocked = env.coordinator.createLocalDocument(
            title: "Unreadable", parentID: nil, ownerUserID: user)
        stubUsersMeThen(log: log) { _ in
            .init(statusCode: 201, headers: [:], body: Data("{\"unexpected\": true}".utf8), error: nil)
        }
        await env.coordinator.syncPendingDrafts()
        XCTAssertNotNil(env.creates.create(for: blocked.id)?.replayBlockedAt)

        // Relaunch on the same build, and add a healthy record so the gate lets the pass run.
        stubReplayPipeline(log: log)
        let relaunched = makeEnvironment(sharing: env.defaults, appBuild: "100")
        let healthy = relaunched.coordinator.createLocalDocument(
            title: "Fine", parentID: nil, ownerUserID: user)
        let before = creates(log)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertEqual(creates(log), before + 1, "exactly one POST — the healthy record's")
        XCTAssertNil(relaunched.creates.create(for: healthy.id), "which migrated")
        XCTAssertNotNil(relaunched.creates.create(for: blocked.id), "while the blocked one stayed put")
    }

    /// The children cache follows the same never-fabricate rule as the recents list: `nil`
    /// (level never fetched) is deliberately distinct from `[]` (fetched, empty), because the
    /// tree reads exactly that to decide whether it knows the level. The sibling test
    /// pre-fetches the level, so it cannot see this.
    func testASubpageNeverFabricatesAnUnfetchedParentLevel() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        let parent = UUID()
        // Deliberately no `env.children.save(…, for: parent)` — the level was never fetched.
        env.coordinator.createLocalDocument(title: "Child", parentID: parent, ownerUserID: user)

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(creates(log), 1, "it still replays")
        XCTAssertNil(env.children.children(for: parent), "but the level stays unknown, not a one-row list")
    }

    /// A record nothing can attribute must not cost a `/users/me/` either — the gate's other
    /// conjunct. The sibling test uses a foreign origin with a known owner, so it cannot see
    /// this one.
    func testAnUnattributableRecordCostsNoRequestAtAll() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        env.creates.save(
            PendingDocumentCreate(
                localID: UUID(), title: "Whose?", createdAt: Date(), serverOrigin: origin,
                ownerUserID: nil))

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertEqual(log.methods.count, 0, "not even /users/me/")
    }

    /// The resume's own write-back guard, the twin of the one on the POST path: a delete
    /// landing during the `formattedContent` await has already removed the record, and
    /// `updatePendingCreate` writes through to disk — so without the guard it comes back.
    func testADeleteDuringTheResumeDoesNotResurrectTheRecord() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)

        let relaunched = makeEnvironment(sharing: env.defaults)
        let coordinator = relaunched.coordinator
        // Hold the resume GET open, delete during it, then let the 404 land.
        stubUsersMeThen(log: log) { _ in
            .init(statusCode: 404, headers: [:], body: Data(), error: nil, delay: 0.3)
        }
        let pass = Task { await coordinator.syncPendingDrafts() }
        await waitUntil { log.count(ofMethod: "GET", urlContaining: "formatted-content") == 1 }
        coordinator.discardPendingWork(documentID: serverID)
        await pass.value

        XCTAssertNil(relaunched.creates.create(for: local.id), "the delete stands")
    }

    /// The conflict check compares **canonically**, because the local body has been through
    /// the parser and the server's has not. Without that, a formatting-only difference in the
    /// export records a conflict against a document nothing is wrong with — and the pill then
    /// parks every future save for it behind a question with no real answer.
    func testAFormattingOnlyDifferenceIsNotAConflict() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        env.coordinator.enqueue(documentID: local.id, title: "Notes", markdown: "# Heading\n\nBody")
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // Same document, spelled with trailing whitespace and an extra blank line.
        let formatted = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Notes",
             "content": "# Heading  \\n\\n\\nBody\\n",
             "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-02T12:00:00Z"}
            """.utf8)
        // One body answers both GETs (the cosmetic `document` fetch and `formatted-content`).
        stubUsersMeThen(log: log) { _ in .init(statusCode: 200, headers: [:], body: formatted, error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNil(relaunched.creates.create(for: local.id), "the migration completed")
        XCTAssertNil(
            relaunched.coordinator.conflict(for: serverID),
            "a formatting-only export difference is not a divergence to ask about")
    }

    /// The list-cache inserts dedupe by id. A migration deferred behind an open editor can run
    /// after an ordinary list fetch has already cached the real document, and a second copy
    /// would be a duplicate `Identifiable` row in Home.
    func testTheRecentsInsertDoesNotDuplicateAnAlreadyCachedRow() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        // The list fetch already brought the real document back under its server id.
        env.lists.saveRecentDocuments([
            Document(
                id: serverID, title: "Untitled document", excerpt: nil,
                abilities: DocumentAbilities(), linkReach: .restricted, linkRole: .reader,
                computedLinkReach: nil, computedLinkRole: nil, isFavorite: false, depth: 1,
                numchild: 0, path: "00000A", createdAt: Date(), updatedAt: Date(), userRole: .owner,
                creator: nil)
        ])

        await env.coordinator.syncPendingDrafts()

        XCTAssertNil(env.creates.create(for: local.id), "it migrated")
        XCTAssertEqual(
            env.lists.loadRecentDocuments()?.filter { $0.id == self.serverID }.count, 1,
            "one row, not two")
    }

    /// The children cache's dedupe, the twin of the recents one. Same reachability — a
    /// migration deferred behind an open editor running after the level was fetched — and the
    /// same consequence, a duplicate `Identifiable` row, here in the Pages tree drawer.
    func testTheChildrenInsertDoesNotDuplicateAnAlreadyCachedRow() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        let parent = UUID()
        let local = env.coordinator.createLocalDocument(
            title: "Child", parentID: parent, ownerUserID: user)
        // The level was fetched *and* already contains the real document.
        env.children.save(
            [
                Document(
                    id: serverID, title: "Child", excerpt: nil, abilities: DocumentAbilities(),
                    linkReach: .restricted, linkRole: .reader, computedLinkReach: nil,
                    computedLinkRole: nil, isFavorite: false, depth: 1, numchild: 0, path: "00000A",
                    createdAt: Date(), updatedAt: Date(), userRole: .owner, creator: nil)
            ], for: parent)

        await env.coordinator.syncPendingDrafts()

        XCTAssertNil(env.creates.create(for: local.id), "it migrated")
        XCTAssertEqual(
            env.children.children(for: parent)?.filter { $0.id == self.serverID }.count, 1,
            "one row, not two")
    }

    /// **The conflict must survive rule 1 as well as rule 2.** A checkpointed document is met
    /// under its *server* id, so the user can have opened it, typed and had that save land
    /// before the migration runs — leaving `lastConfirmedPushMarkdown[serverID]` holding the
    /// very body the migration then records a conflict against. `enqueue` stamps that onto the
    /// draft, and rule 1 (`serverHoldsOurLastPush`) is consulted *before* rule 2, so an honest
    /// baseline is never even reached: `releaseConflictIfProven` clears the conflict and the
    /// held save overwrites them. Every other conflict test uses a relaunched coordinator,
    /// where that map is structurally empty — which is exactly why this axis was uncovered.
    func testAConflictSurvivesEvidenceOfAPushUnderTheServerID() async throws {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        env.coordinator.enqueue(documentID: local.id, title: "Notes", markdown: "# Written offline")
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)

        // Relaunch so the mirror picks up the checkpoint, then — in *this* session — the user
        // meets the document under its server id and their save lands, leaving push evidence
        // on the same coordinator the migration will run on.
        let relaunched = makeEnvironment(sharing: env.defaults)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 200, headers: [:], body: Data(), error: nil)
        }
        relaunched.coordinator.enqueue(documentID: serverID, title: "Notes", markdown: "# Their newer text")
        await waitUntil {
            relaunched.coordinator.lastConfirmedPush(documentID: self.serverID) == "# Their newer text"
        }

        let formatted = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Notes",
             "content": "# Their newer text",
             "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-02T09:00:00Z"}
            """.utf8)
        stubUsersMeThen(log: log) { _ in .init(statusCode: 200, headers: [:], body: formatted, error: nil) }
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNotNil(relaunched.coordinator.conflict(for: serverID), "the divergence is recorded")
        let draft = try XCTUnwrap(relaunched.drafts.draft(for: serverID))
        XCTAssertNil(
            draft.lastPushedMarkdown,
            "the push evidence is cleared — the offline body does not descend from that push")
        let decision = draftSyncDecision(
            baseline: draft.baseline, lastPushedMarkdown: draft.lastPushedMarkdown,
            localMarkdown: draft.markdown, draftTitle: draft.title, draftUpdatedAt: draft.updatedAt,
            serverTitle: "Notes",
            serverUpdatedAt: ISO8601DateFormatter().date(from: "2026-03-02T09:00:00Z")!,
            serverMarkdown: "# Their newer text")
        guard case .conflict = decision else {
            return XCTFail("rule 1 must not release the conflict — got \(decision)")
        }
    }

    /// Both emptiness tests are **canonical**, matching the inequality between them. Raw, a
    /// local body of `" "` is non-empty, so it skips the adopt branch and falls to the conflict
    /// — arming a "Keep my version" that PATCHes whitespace over the co-author, the exact wipe
    /// that branch exists to prevent.
    func testAWhitespaceOnlyLocalBodyAdoptsTheServerRatherThanArmingAWipe() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // Present, and whitespace-only — canonically empty but raw non-empty.
        env.drafts.save(
            PendingDraft(
                documentID: local.id, title: "Notes", markdown: "   \n\n  ", updatedAt: Date(),
                baseline: nil))
        let formatted = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Notes",
             "content": "# Written on the web",
             "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-02T12:00:00Z"}
            """.utf8)
        stubUsersMeThen(log: log) { _ in .init(statusCode: 200, headers: [:], body: formatted, error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        // Positive first: without it, anything that stops the pass reaching the migration
        // turns the two absences green while testing nothing.
        XCTAssertNil(relaunched.creates.create(for: local.id), "the migration completed")
        XCTAssertNil(relaunched.coordinator.conflict(for: serverID), "nothing to ask about")
        XCTAssertNil(relaunched.drafts.draft(for: serverID), "and no whitespace draft left to push")
    }

    /// The other direction: a server body that is raw non-empty but canonically empty must not
    /// record a conflict at all. Raw, it records one that the very next evaluation releases
    /// (rule 2's body tiebreak matches `"" == ""`) — a pill that provably self-clears.
    func testAWhitespaceOnlyServerBodyIsNotADivergence() async {
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
            {"id": "\(serverID.uuidString.lowercased())", "title": "Notes", "content": "  \\n\\n ",
             "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-02T12:00:00Z"}
            """.utf8)
        stubUsersMeThen(log: log) { _ in .init(statusCode: 200, headers: [:], body: formatted, error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNil(relaunched.creates.create(for: local.id), "the migration completed")
        XCTAssertNil(
            relaunched.coordinator.conflict(for: serverID),
            "a canonically empty server body is not a divergence to ask about")
    }

    /// Adopting the server must also reset the state, as `resolveConflictKeepingServer` does
    /// for the same "the local side is gone" transition. Left at `.failed`, the editing surface
    /// keeps a live retry whose `saveNow` enqueues the *server's own* re-fetched body with no
    /// baseline — a full overwrite re-encoded through `MarkdownYjs`, exactly the flattening
    /// this branch refuses to perform.
    func testAdoptingTheServerClearsAFailedStateUnderTheServerID() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        env.drafts.remove(documentID: local.id)

        let relaunched = makeEnvironment(sharing: env.defaults)
        // A save under the server id, rejected on the merits, leaving `.failed` and an empty
        // server-id draft — the partial-migration shape the branch's comment names.
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 400, headers: [:], body: Data(), error: nil)
        }
        relaunched.coordinator.enqueue(documentID: serverID, title: "Notes", markdown: "")
        await waitUntil {
            if case .failed = relaunched.coordinator.state(for: self.serverID) { return true }
            return false
        }

        let formatted = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Notes",
             "content": "# Written on the web",
             "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-02T12:00:00Z"}
            """.utf8)
        stubUsersMeThen(log: log) { _ in .init(statusCode: 200, headers: [:], body: formatted, error: nil) }
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNil(relaunched.creates.create(for: local.id), "the migration completed")
        if case .failed = relaunched.coordinator.state(for: serverID) {
            XCTFail("a live retry here would PATCH the co-author's own body back, re-encoded")
        }
    }

    /// A start-over must discharge any conflict against the dead server id. The take-back's
    /// "the ordinary 404-draft rule will collect it" argument has a hole: `runSyncPass` **skips
    /// a conflicted draft**, so the 404 branch it defers to is unreachable for exactly that
    /// draft — and `init` rehydrates the stamp from disk, so the skip outlives relaunches. No
    /// process kill is needed to reach it.
    func testAStartOverKeepsAConflictAgainstTheDeadServerID() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // The user met the document under its server id, typed, and a divergence was recorded
        // there before the document was deleted — a draft carrying a conflict stamp.
        env.drafts.save(
            PendingDraft(
                documentID: serverID, title: "Notes", markdown: "# Typed under the server id",
                updatedAt: Date(), baseline: nil, lastPushedMarkdown: nil,
                conflictServerUpdatedAt: Date(timeIntervalSince1970: 1)))
        stubUsersMeThen(log: log) { _ in .init(statusCode: 404, headers: [:], body: Data(), error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        XCTAssertNotNil(relaunched.coordinator.conflict(for: serverID), "rehydrated from the draft")

        await relaunched.coordinator.syncPendingDrafts()

        // Round 33 asserted the opposite here, on the reasoning that a discharged conflict
        // stops the record stranding. That was wrong in the direction that costs content: a
        // bare 404 is not proof the document is gone, and discharging drops the held
        // keystrokes *and* the checkpoint protecting this draft, after which `runSyncPass` —
        // next in the same pass, on the same 404 — deletes it. Stranding is recoverable;
        // deleting the only copy is not.
        XCTAssertNotNil(
            relaunched.coordinator.conflict(for: serverID),
            "kept — the 404 is not evidence, and the body it holds is the only copy")
        XCTAssertEqual(
            relaunched.drafts.draft(for: serverID)?.markdown, "# Typed under the server id")
    }

    /// The partial-migration draft's push evidence must be **carried forward** when the body
    /// comes from it. That body is not the offline one — a previous attempt already wrote it
    /// under the server id — so "the local body does not descend from that push" is false of
    /// it, and dropping the stamp raises a conflict no evidence can ever release against the
    /// user's own earlier write. Every other test builds server-id drafts with a nil stamp, so
    /// replacing `carriedPush` with `nil` outright leaves them all green.
    func testAPartiallyMigratedDraftKeepsThePushItDescendsFrom() async throws {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // The partial-migration shape: local draft gone, server-id draft present — and it
        // records that its body was already pushed.
        env.drafts.remove(documentID: local.id)
        env.drafts.save(
            PendingDraft(
                documentID: serverID, title: "Notes", markdown: "# Already pushed",
                updatedAt: Date(), baseline: nil, lastPushedMarkdown: "# Already pushed"))
        // The server holds that same pushed body, so this is our own write, not a divergence.
        let formatted = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Notes",
             "content": "# Already pushed",
             "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-02T12:00:00Z"}
            """.utf8)
        stubUsersMeThen(log: log) { _ in .init(statusCode: 200, headers: [:], body: formatted, error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNil(relaunched.creates.create(for: local.id), "the migration completed")
        let draft = try XCTUnwrap(relaunched.drafts.draft(for: serverID))
        XCTAssertEqual(
            draft.lastPushedMarkdown, "# Already pushed",
            "the evidence rides along, so rule 1 can still recognise our own landed write")
    }

    /// The start-over must discharge the conflict **even with a save parked** — that cell is
    /// the whole point. A queued slot with nothing in flight *is* the conflict hold, and
    /// nothing settles it: `releaseHeldSave` is its only drainer and is reached only from the
    /// discharge. Gating the clear on `queued == nil` (as an earlier revision did) leaves the
    /// record stranded permanently, with `runSyncPass` skipping the draft on both `queued` and
    /// `conflicts`, and `init` rehydrating the stamp across relaunches.
    func testAStartOverKeepsAConflictEvenWithASaveParked() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        stubUsersMeThen(log: log) { _ in .init(statusCode: 404, headers: [:], body: Data(), error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        // The conflict hold: a recorded divergence, then an edit that parks rather than starts.
        relaunched.coordinator.recordConflict(documentID: serverID, serverUpdatedAt: Date())
        relaunched.coordinator.enqueue(documentID: serverID, title: "Notes", markdown: "# Parked")
        XCTAssertEqual(savesInFlight(log), 0, "held, not sent")

        await relaunched.coordinator.syncPendingDrafts()

        // Inverted for the same reason as the test above: the parked save *is* the user's
        // work, and discharging it here is the loss, not the cleanup.
        XCTAssertNotNil(relaunched.coordinator.conflict(for: serverID), "kept")
        XCTAssertEqual(relaunched.drafts.draft(for: serverID)?.markdown, "# Parked")
    }

    /// A bare 403 on the probe must **not** promote — the same rule the resume path states
    /// for the same evidence. An ancestor-access recompute 403s transiently and would 403 the
    /// create too, so promoting on it re-roots a sub-page irreversibly on "not right now".
    func testASubpageWhoseParentProbeIs403IsNotPromoted() async {
        let log = RequestRecorder()
        let parent = UUID()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(title: "Child", parentID: parent, ownerUserID: user)
        stubUsersMeThen(log: log) { _ in .init(statusCode: 403, headers: [:], body: Data(), error: nil) }

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(
            env.creates.create(for: local.id)?.parentID, parent,
            "a transient 403 is not evidence the parent is gone")
        // And it still owes a terminal state — `markCreateRejected` writes only `states`, so
        // the assertion above passes whether this cell parks or retries forever. Without it,
        // the record pays a POST plus a probe on every trigger with the caption reading "syncs
        // when online".
        guard case .failed = env.coordinator.state(for: local.id) else {
            return XCTFail("a non-retryable create with an indecisive probe must still terminate")
        }
    }

    /// The migration writes the body under `serverID` before removing the local draft, so a
    /// death in that window leaves it as the **only copy** — and `isPendingCreate` is keyed on
    /// the *local* id, so `runSyncPass`'s 404/403 sweep does not see it as protected. The
    /// `.notFound` start-over rescues it by moving it back; a `.forbidden` resume has no such
    /// branch and would land here, as would any pass where the record simply is not replayable
    /// this session (a foreign origin, another account, a failing `/users/me/`, an open
    /// editor — not a build block, which cannot coexist with a checkpoint). Deleting it makes
    /// the later migration build an empty document.
    func testTheSweepNeverDeletesTheOnlyCopyUnderACheckpointedServerID() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // The partial-migration window: local draft gone, body only under the server id.
        env.drafts.remove(documentID: local.id)
        env.drafts.save(
            PendingDraft(
                documentID: serverID, title: "Notes", markdown: "# The only copy",
                updatedAt: Date(), baseline: nil))
        // Everything 403s — the resume takes the transient branch and does not rescue it.
        stubUsersMeThen(log: log) { _ in .init(statusCode: 403, headers: [:], body: Data(), error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertEqual(
            relaunched.drafts.draft(for: serverID)?.markdown, "# The only copy",
            "the sweep must not delete the body of a checkpointed record")
    }

    /// A rename made **on this device, under the server id** must survive the migration.
    /// Once checkpointed the local row is withheld, so the user meets the document under
    /// `serverID` in an ordinary list; a rename there lands and `finish` removes that draft,
    /// leaving the seed draft holding the mint title. Preferring the local title
    /// unconditionally PATCHes "Untitled document" back over their rename, silently.
    func testAMigrationDoesNotRevertARenameMadeUnderTheServerID() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // The seed draft still holds the mint title — the local side never renamed.
        // The server has since been renamed under its own id.
        let formatted = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Recipes", "content": "",
             "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-02T12:00:00Z"}
            """.utf8)
        stubUsersMeThen(log: log) { _ in .init(statusCode: 200, headers: [:], body: formatted, error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNil(relaunched.creates.create(for: local.id), "the migration completed")
        XCTAssertEqual(
            relaunched.drafts.draft(for: serverID)?.title, "Recipes",
            "the server's rename is kept — the local side only ever held the mint title")
    }

    /// The `.discardServerWins` deleting line's own server-id guard. Rule 3 needs a nil
    /// baseline, which no production writer produces under a server id — but the guard states
    /// the invariant at the deleting line rather than resting on that, exactly as its twin in
    /// the 404/403 catch does.
    func testTheLaunchDiscardNeverDeletesACheckpointedServerIDDraft() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        env.drafts.remove(documentID: local.id)
        // Baseline-less, and far older than the 120 s tolerance, so rule 3 answers
        // `.discardServerWins`.
        env.drafts.save(
            PendingDraft(
                documentID: serverID, title: "Notes", markdown: "# The only copy",
                updatedAt: Date(timeIntervalSince1970: 1), baseline: nil))
        let formatted = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Notes",
             "content": "# Written on the web",
             "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-02T12:00:00Z"}
            """.utf8)
        // Another account, so `runCreatePass` skips the record before it can migrate or rescue.
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            if request.url?.absoluteString.hasSuffix("users/me/") == true {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data("{\"id\": \"99999999-9999-4999-8999-999999999999\"}".utf8), error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: formatted, error: nil)
        }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.recoverDrafts()

        XCTAssertEqual(
            relaunched.drafts.draft(for: serverID)?.markdown, "# The only copy",
            "the launch discard must not delete a checkpointed record's only copy")
    }

    /// **Both sides renamed.** A rename made *before* the POST is already the server's name,
    /// so comparing against the mint title reads it as a local rename forever — and the resume
    /// then pushes that now-stale title over the newer one made under the server id. Comparing
    /// against what the POST actually sent is what settles it.
    func testARenameMadeBeforeThePostDoesNotOutrankOneMadeAfterIt() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        // Renamed before the replay, so this is the title the POST sent.
        env.coordinator.enqueue(documentID: local.id, title: "Recipes", markdown: "# Body")
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        record.postedTitle = "Recipes"
        env.creates.save(record)
        // Then renamed again under the server id, which is where the user meets it.
        let formatted = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Notes", "content": "# Body",
             "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-02T12:00:00Z"}
            """.utf8)
        stubUsersMeThen(log: log) { _ in .init(statusCode: 200, headers: [:], body: formatted, error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNil(relaunched.creates.create(for: local.id), "the migration completed")
        XCTAssertEqual(
            relaunched.drafts.draft(for: serverID)?.title, "Notes",
            "the rename made after the server learned the name is the newer one")
    }

    /// The mirror cell: a rename made *after* the POST must still win. Comparing against the
    /// POSTed title must not weaken the case the discriminator was built for.
    func testARenameMadeAfterThePostStillWins() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        record.postedTitle = "Untitled document"
        env.creates.save(record)
        env.drafts.save(
            PendingDraft(
                documentID: local.id, title: "Renamed locally", markdown: "# Body",
                updatedAt: Date(), baseline: nil))
        // The server still holds the POSTed title — nobody renamed it there.
        let formatted = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Untitled document",
             "content": "# Body",
             "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-02T12:00:00Z"}
            """.utf8)
        stubUsersMeThen(log: log) { _ in .init(statusCode: 200, headers: [:], body: formatted, error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertEqual(
            relaunched.drafts.draft(for: serverID)?.title, "Renamed locally",
            "a local rename after the POST is still the newer one")
    }

    /// A save under the server id that starts **and settles inside the resume's fetch** leaves
    /// `inFlight`/`queued` nil and removes its own draft — so all three of `finishMigration`'s
    /// guards pass and the migration decides from a body the server no longer holds, pushing
    /// the older local one over content the user just saw confirmed as saved. That is the
    /// boolean this coordinator documents as insufficient; `mayPredateSave` is the instrument.
    func testAMigrationNeverActsOnABodyASaveOvertookMidFetch() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        record.postedTitle = "Untitled document"
        env.creates.save(record)

        let relaunched = makeEnvironment(sharing: env.defaults)
        let coordinator = relaunched.coordinator
        // The resume's `formatted-content` GET is held open; everything else answers at once.
        let formatted = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Untitled document",
             "content": "",
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
            if url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: formatted, error: nil, delay: 0.6)
            }
            return .init(statusCode: 200, headers: [:], body: formatted, error: nil)
        }

        let pass = Task { await coordinator.syncPendingDrafts() }
        // Inside that window the user types under the server id and the save lands.
        await waitUntil { log.count(ofMethod: "GET", urlContaining: "formatted-content") == 1 }
        coordinator.enqueue(documentID: serverID, title: "Untitled document", markdown: "# World")
        await waitUntil { coordinator.lastConfirmedPush(documentID: self.serverID) == "# World" }
        await pass.value

        XCTAssertNotNil(
            relaunched.creates.create(for: local.id),
            "the migration bailed rather than deciding from a body the save had overtaken")
        await waitAndConfirmNever {
            relaunched.coordinator.lastConfirmedPush(documentID: self.serverID) == ""
        }
    }

    /// The loss path with no conflict anywhere. A checkpointed record, a local draft, and the
    /// user's own work under the server id whose save failed transiently. The take-back
    /// declines by design (a local draft is present, so that body is not ours to move), and
    /// before the start-over was gated, clearing `syncedServerID` disarmed the only thing
    /// stopping `runSyncPass` — next in the same pass, on the same 404 — from deleting it.
    func testASpuriousNotFoundKeepsADraftTheTakeBackDeclinesToMove() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        record.postedTitle = "Untitled document"
        env.creates.save(record)
        // Both bodies exist: the seed draft under the local id, the user's under the server id.
        env.drafts.save(
            PendingDraft(
                documentID: serverID, title: "Notes", markdown: "# Their own work",
                updatedAt: Date(), baseline: nil))
        stubUsersMeThen(log: log) { _ in .init(statusCode: 404, headers: [:], body: Data(), error: nil) }

        // Relaunch, so the coordinator's in-memory mirror actually carries the checkpoint —
        // writing it straight to the store leaves the mirror stale, and every guard that keys
        // off `checkpointedRecord(forServerID:)` reads the mirror.
        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertEqual(env.drafts.draft(for: serverID)?.markdown, "# Their own work")
        XCTAssertNotNil(env.drafts.draft(for: local.id))
        XCTAssertEqual(env.creates.create(for: local.id)?.syncedServerID, serverID)
    }

    /// The take-back moves an orphaned body off the server id — but it must not do that under a
    /// live editor, which would yank the disk backing out from under the screen and let the
    /// re-POST mint a second document holding the same text.
    func testTheTakeBackDeclinesWhileAnEditorHoldsTheServerID() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        env.drafts.remove(documentID: local.id)
        env.drafts.save(
            PendingDraft(
                documentID: serverID, title: "Notes", markdown: "# Live", updatedAt: Date(), baseline: nil))
        stubUsersMeThen(log: log) { _ in .init(statusCode: 404, headers: [:], body: Data(), error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        relaunched.coordinator.retainOpenEditor(documentID: serverID)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertEqual(env.drafts.draft(for: serverID)?.markdown, "# Live")
        XCTAssertNil(env.drafts.draft(for: local.id))
        XCTAssertEqual(env.creates.create(for: local.id)?.syncedServerID, serverID)
    }

    /// A spurious 404 must not void a persisted conflict hold. The start-over's premise is
    /// "the document is gone", but a proxy hiccup maps to `.notFound` too — and discharging on
    /// one drops the held keystrokes, erases the hold in memory and on disk, and removes the
    /// suppression protecting that draft, after which a keystroke landing before `runSyncPass`
    /// re-detects reaches `enqueue` with nothing holding it.
    func testASpuriousNotFoundDoesNotVoidAHeldConflict() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        record.postedTitle = "Untitled document"
        env.creates.save(record)
        stubUsersMeThen(log: log) { _ in .init(statusCode: 404, headers: [:], body: Data(), error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        // The user typed under the server id, a conflict held the push — and they navigated
        // away, so no editor is open and no save is in flight. That is the whole point: the
        // work at stake leaves no witness of *concurrent* activity, so a gate that only asks
        // about concurrency lets the discharge through and reaps the draft.
        relaunched.coordinator.recordConflict(documentID: serverID, serverUpdatedAt: Date())
        relaunched.coordinator.enqueue(documentID: serverID, title: "Notes", markdown: "# Held")

        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNotNil(
            relaunched.coordinator.conflict(for: serverID),
            "a bare 404 is not evidence enough to void a hold the user still has to answer")
        XCTAssertEqual(
            relaunched.drafts.draft(for: serverID)?.markdown, "# Held",
            "and the held work is still on disk")
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
