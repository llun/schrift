import XCTest

@testable import Schrift

/// The create replay: POST a document this device made, move everything keyed by its
/// client-minted id onto the one the server assigned, and hand the content to the ordinary
/// draft replay. These drive the coordinator
/// directly.
@MainActor
final class DocumentSaveCoordinatorReplayTests: DocumentSaveCoordinatorReplayTestCase {
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

        // Positive control first. Both assertions here are negative, so without it any
        // mutation that stops the replay running at all — the pre-flight gate, `/users/me/`,
        // the record loop — leaves the test green while proving nothing.
        XCTAssertEqual(creates(log), 1, "the replay ran")
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
}
