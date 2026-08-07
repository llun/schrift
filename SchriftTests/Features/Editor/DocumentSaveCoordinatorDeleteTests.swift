import XCTest

@testable import Schrift

/// Deletions queued while the server could not be reached: the tombstone mirror, and the
/// suppressions that keep every other pipeline off a document the user has asked to delete.
@MainActor
final class DocumentSaveCoordinatorDeleteTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let origin = "https://docs.example.org"
    private let user = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let otherUser = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
    private let serverID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let otherServerID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private var cacheDirectory: URL!
    private var suiteNames: [String] = []

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeleteTests-\(UUID().uuidString)", isDirectory: true)
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
        let deletes: PendingDocumentDeleteStore
        let lists: DocumentCacheStore
        let children: DocumentChildrenCacheStore
        let defaults: UserDefaults
    }

    /// Every store on this test's own suite — the create *and* delete stores especially. A
    /// coordinator that falls back to `UserDefaults.standard` writes real records into the
    /// shared domain, and a later pass then issues a genuine `/users/me/` that escapes
    /// `MockURLProtocol` and stalls the run for a minute.
    private func makeEnvironment(sharing defaults: UserDefaults? = nil, serverOrigin: String? = nil) -> Environment {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let defaults =
            defaults
            ?? {
                let name = "DeleteTests.\(UUID().uuidString)"
                suiteNames.append(name)
                return UserDefaults(suiteName: name)!
            }()
        let drafts = PendingDraftStore(userDefaults: defaults)
        let creates = PendingDocumentCreateStore(userDefaults: defaults)
        let deletes = PendingDocumentDeleteStore(userDefaults: defaults)
        let lists = DocumentCacheStore(userDefaults: defaults)
        let children = DocumentChildrenCacheStore(userDefaults: defaults)
        return Environment(
            coordinator: DocumentSaveCoordinator(
                client: client, draftStore: drafts,
                contentCache: DocumentContentCacheStore(directory: cacheDirectory),
                createStore: creates, deleteStore: deletes, listCache: lists, childrenCache: children,
                serverOrigin: serverOrigin ?? origin, appBuild: "1", backgroundTasks: .noop),
            drafts: drafts, creates: creates, deletes: deletes, lists: lists, children: children,
            defaults: defaults)
    }

    /// The state the suppressions exist for: a deletion that is queued and **still unsent**,
    /// against a server that answers 404 for the document itself.
    ///
    /// The DELETE fails transiently so the tombstone survives the pass — otherwise the
    /// deletion completes and takes the draft with it *legitimately*, and the test proves
    /// nothing about the suppressions. The 404 on everything else is what a queued deletion
    /// actually predicts (our own DELETE may have landed in a pass that died before its
    /// cleanup) and is indistinguishable from a co-author's delete — which is exactly why
    /// the reap must not fire on it.
    private func stubGoneServer(log: RequestRecorder) {
        let userBody = Data(
            """
            {"id": "\(user.uuidString.lowercased())", "email": "a@example.org"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.hasSuffix("users/me/") {
                return .init(statusCode: 200, headers: [:], body: userBody, error: nil)
            }
            if request.httpMethod == "DELETE" {
                return .init(
                    statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
            }
            return .init(
                statusCode: 404, headers: ["Content-Type": "application/json"],
                body: Data(#"{"detail":"Not found."}"#.utf8), error: nil)
        }
    }

    /// `/users/me/` plus a server that accepts the DELETE. `deleteStatus` drives the outcome
    /// ladder; everything else answers 200 so nothing unrelated fails for the wrong reason.
    private func stubDeletePipeline(
        log: RequestRecorder, deleteStatus: Int = 204, deleteError: Error? = nil, deleteDelay: TimeInterval = 0
    ) {
        let userBody = Data(
            """
            {"id": "\(user.uuidString.lowercased())", "email": "a@example.org"}
            """.utf8)
        let documentBody = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Doc", "content": "",
             "abilities": {}, "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-01T12:00:00Z",
             "depth": 1, "numchild": 0, "path": "00000A", "link_reach": "restricted",
             "link_role": "reader", "user_role": "owner"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.hasSuffix("users/me/") {
                return .init(statusCode: 200, headers: [:], body: userBody, error: nil)
            }
            if request.httpMethod == "DELETE" {
                return .init(
                    statusCode: deleteStatus, headers: ["Content-Type": "application/json"],
                    body: Data(#"{"detail":"."}"#.utf8), error: deleteError, delay: deleteDelay)
            }
            return .init(statusCode: 200, headers: [:], body: documentBody, error: nil)
        }
    }

    /// Like `stubDeletePipeline`, but the server **stops serving the document** once it has
    /// accepted the DELETE — which is what a real one does. The original stub kept answering
    /// 200 for `formatted-content` afterwards, so any test using it exercised a server that had
    /// simultaneously deleted the document and still served it, and could not see what the rest
    /// of the pass does with a 404 the pass itself caused.
    private func stubDeleteThenGone(log: RequestRecorder, deleteDelay: TimeInterval = 0) {
        let userBody = Data(
            """
            {"id": "\(user.uuidString.lowercased())", "email": "a@example.org"}
            """.utf8)
        let documentBody = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Doc", "content": "server body",
             "abilities": {}, "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-01T12:00:00Z",
             "depth": 1, "numchild": 0, "path": "00000A", "link_reach": "restricted",
             "link_role": "reader", "user_role": "owner"}
            """.utf8)
        let deleted = DeletedFlag()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.hasSuffix("users/me/") {
                return .init(statusCode: 200, headers: [:], body: userBody, error: nil)
            }
            if request.httpMethod == "DELETE" {
                deleted.set()
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil, delay: deleteDelay)
            }
            if deleted.isSet {
                return .init(
                    statusCode: 404, headers: ["Content-Type": "application/json"],
                    body: Data(#"{"detail":"Not found."}"#.utf8), error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: documentBody, error: nil)
        }
    }

    /// Thread-safe because the stub handler runs on URLSession's protocol thread.
    private final class DeletedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }

    /// The fan-out keys observers on object identity, so a test needs something to be.
    @MainActor private final class Announcements {
        var ids: [UUID] = []
    }

    private func documentFixture(_ id: UUID, title: String = "Doc") -> Document {
        Document(
            id: id, title: title, excerpt: nil, abilities: DocumentAbilities(),
            linkReach: .restricted, linkRole: .reader, isFavorite: false,
            depth: 1, numchild: 0, path: "0001",
            createdAt: Date(), updatedAt: Date(), userRole: nil, creator: nil)
    }

    private func draft(_ documentID: UUID, markdown: String = "the user's only copy") -> PendingDraft {
        PendingDraft(
            documentID: documentID, title: "Doc", markdown: markdown, updatedAt: Date(),
            baseline: DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 1), markdown: "", title: "Doc"))
    }

    // MARK: - The mirror

    func testQueueingADeletionMirrorsItAndBumpsTheVersion() {
        let env = makeEnvironment()
        let before = env.coordinator.pendingDeletesVersion

        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)

        XCTAssertTrue(env.coordinator.isPendingDelete(documentID: serverID))
        XCTAssertGreaterThan(env.coordinator.pendingDeletesVersion, before, "so rows re-render")
        XCTAssertEqual(env.deletes.pendingDelete(for: serverID)?.ownerUserID, user, "and it is on disk")
    }

    func testUndoingADeletionRemovesTheTombstoneEverywhere() {
        let env = makeEnvironment()
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)
        let queued = env.coordinator.pendingDeletesVersion

        env.coordinator.cancelPendingDelete(documentID: serverID)

        XCTAssertFalse(env.coordinator.isPendingDelete(documentID: serverID))
        XCTAssertNil(env.deletes.pendingDelete(for: serverID))
        XCTAssertGreaterThan(env.coordinator.pendingDeletesVersion, queued, "so rows un-strike")
    }

    func testUndoingSomethingNeverQueuedChangesNothing() {
        let env = makeEnvironment()
        let before = env.coordinator.pendingDeletesVersion

        env.coordinator.cancelPendingDelete(documentID: serverID)

        XCTAssertEqual(env.coordinator.pendingDeletesVersion, before, "no spurious re-render")
    }

    /// A tombstone is rehydrated before anything can run, so the suppressions are in force
    /// from this process's very first sync pass — which `recoverDrafts()` starts as soon as
    /// Home loads.
    func testATombstoneSurvivesARelaunch() {
        let first = makeEnvironment()
        first.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)

        let relaunched = makeEnvironment(sharing: first.defaults)

        XCTAssertTrue(relaunched.coordinator.isPendingDelete(documentID: serverID))
    }

    /// **Protection is unconditional.** A tombstone queued against another server — or by
    /// another account — is still mirrored, because `runSyncPass` walks every draft on the
    /// device and is not origin-scoped either. Mirroring only the matching ones would leave a
    /// foreign tombstone's draft unsuppressed, and the pass would reap it on the 404.
    func testAForeignTombstoneIsStillProtective() {
        let elsewhere = makeEnvironment(serverOrigin: "https://other.example.org")
        elsewhere.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: otherUser)

        let here = makeEnvironment(sharing: elsewhere.defaults)

        XCTAssertTrue(here.coordinator.isPendingDelete(documentID: serverID), "protected")
        XCTAssertFalse(
            here.coordinator.isListablePendingDelete(documentID: serverID, currentUserID: user),
            "but never shown to this session")
    }

    // MARK: - What may be shown

    func testAQueuedDeletionIsShownToTheAccountThatQueuedIt() {
        let env = makeEnvironment()
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)

        XCTAssertTrue(env.coordinator.isListablePendingDelete(documentID: serverID, currentUserID: user))
    }

    /// Tombstones survive sign-out and the metadata caches are neither account-scoped nor
    /// cleared, so an unscoped predicate would strike user A's document through user B's
    /// lists — and offer B a button that cancels A's deletion.
    func testAQueuedDeletionIsNeverShownToAnotherAccount() {
        let env = makeEnvironment()
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)

        XCTAssertFalse(env.coordinator.isListablePendingDelete(documentID: serverID, currentUserID: otherUser))
        XCTAssertFalse(
            env.coordinator.isListablePendingDelete(documentID: serverID, currentUserID: nil),
            "and not before /users/me/ has ever answered either")
    }

    /// "I don't know whose this is" must never resolve to "anyone may see it". Only a future
    /// or damaged schema can produce one — `recordPendingDelete` takes a non-optional owner.
    func testAnUnattributableTombstoneIsProtectedButNeverShown() {
        let env = makeEnvironment()
        env.deletes.save(
            PendingDocumentDelete(
                documentID: serverID, requestedAt: Date(), serverOrigin: origin, ownerUserID: nil))
        let relaunched = makeEnvironment(sharing: env.defaults)

        XCTAssertTrue(relaunched.coordinator.isPendingDelete(documentID: serverID))
        XCTAssertFalse(relaunched.coordinator.isListablePendingDelete(documentID: serverID, currentUserID: user))
    }

    // MARK: - The sync pass leaves a tombstoned document alone

    /// The draft of a document queued for deletion is the undo's only payload — whatever the
    /// user typed before deciding. The pass must neither push it (racing our own DELETE) nor
    /// reap it on the 404 a queued deletion actually predicts.
    func testATombstonedDraftIsNeitherFetchedNorReaped() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        env.drafts.save(draft(serverID))
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)
        stubGoneServer(log: log)

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(
            log.count(ofMethod: "GET", urlContaining: serverID.uuidString.lowercased()), 0,
            "nothing is asked about a document being deleted")
        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: serverID.uuidString.lowercased()), 0)
        XCTAssertEqual(
            env.drafts.draft(for: serverID)?.markdown, "the user's only copy",
            "and the undo still has something to restore")
    }

    /// The same protection must survive an undo: once the tombstone is gone the document is
    /// an ordinary one again, and the pass resumes exactly as it would have.
    func testUndoingADeletionLetsTheDraftSyncAgain() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        env.drafts.save(draft(serverID))
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)
        stubGoneServer(log: log)
        await env.coordinator.syncPendingDrafts()
        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: serverID.uuidString.lowercased()), 0)

        env.coordinator.cancelPendingDelete(documentID: serverID)
        await env.coordinator.syncPendingDrafts()

        XCTAssertGreaterThan(
            log.count(ofMethod: "GET", urlContaining: serverID.uuidString.lowercased()), 0,
            "the document is reconciled again")
    }

    /// A legacy (baseline-less) draft routes to the clock-tolerance rule, whose launch-only
    /// branch is the loop's *other* deleting line. It must be suppressed too.
    func testTheLaunchDiscardNeverDeletesATombstonedDraft() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        env.drafts.save(
            PendingDraft(
                documentID: serverID, title: "Doc", markdown: "legacy body",
                updatedAt: Date(timeIntervalSince1970: 1_000)))
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)
        stubGoneServer(log: log)

        await env.coordinator.recoverDrafts()

        XCTAssertEqual(env.drafts.draft(for: serverID)?.markdown, "legacy body")
    }

    /// A conflict recorded before the deletion was queued parks the save. Nothing must
    /// release it while the tombstone stands — the pass skips conflicted drafts already, and
    /// the tombstone keeps the whole document out of the pass regardless.
    func testAConflictedTombstonedDraftKeepsItsHeldSave() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        env.drafts.save(draft(serverID))
        env.coordinator.recordConflict(documentID: serverID, serverUpdatedAt: Date())
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)
        stubGoneServer(log: log)

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: serverID.uuidString.lowercased()), 0)
        XCTAssertNotNil(env.drafts.draft(for: serverID), "and the body is still there for the undo")
    }

    // MARK: - The create pass leaves a tombstoned document alone

    /// **The resurrection guard.** Past the skip, `replayCreate` resumes: it GETs
    /// `formatted-content` on the checkpointed server id, reads the 404 a queued deletion
    /// predicts as "the document is gone", clears the checkpoint — and the next pass re-POSTs
    /// the document from its draft. The user's deletion would reliably undo itself.
    func testACheckpointedRecordWhoseServerIDIsTombstonedNeverResumes() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(title: "Doomed", parentID: nil, ownerUserID: user)
        var checkpointed = env.coordinator.pendingCreateForTesting(localID: local.id)!
        checkpointed.syncedServerID = serverID
        checkpointed.postedTitle = "Doomed"
        env.coordinator.savePendingCreateForTesting(checkpointed)
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)
        stubGoneServer(log: log)

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(log.methods.filter { $0 == "POST" }.count, 0, "nothing is re-created")
        XCTAssertEqual(
            log.count(ofMethod: "GET", urlContaining: serverID.uuidString.lowercased()), 0,
            "and the resume never even asks")
        XCTAssertEqual(
            env.creates.create(for: local.id)?.syncedServerID, serverID,
            "the checkpoint stands, so nothing can read the 404 as 'start over'")
    }

    /// A parent queued for deletion is a **real** server document, so `POST
    /// documents/{serverID}/children/` would succeed — filing a brand-new sub-page into a
    /// document that is about to be deleted, to be orphaned or taken down with it.
    func testAChildOfATombstonedParentIsNeverPosted() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let child = env.coordinator.createLocalDocument(title: "Child", parentID: serverID, ownerUserID: user)
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)
        stubGoneServer(log: log)

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(log.count(ofMethod: "POST", urlContaining: "/children/"), 0)
        XCTAssertNotNil(env.creates.create(for: child.id), "it waits rather than being lost")
    }

    // MARK: - The replay

    func testAQueuedDeletionIsSentAndEveryLocalTraceGoes() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        env.drafts.save(draft(serverID))
        env.lists.saveRecentDocuments([documentFixture(serverID), documentFixture(otherServerID)])
        env.children.save([documentFixture(serverID)], for: otherServerID)
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)
        stubDeletePipeline(log: log)

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(
            log.count(ofMethod: "DELETE", urlContaining: "documents/\(serverID.uuidString.lowercased())/"), 1)
        XCTAssertFalse(env.coordinator.isPendingDelete(documentID: serverID), "the tombstone is discharged")
        XCTAssertNil(env.drafts.draft(for: serverID))
        XCTAssertEqual(env.lists.loadRecentDocuments()?.map(\.id), [otherServerID], "gone from the list cache")
        XCTAssertEqual(
            env.children.children(for: otherServerID)?.map(\.id), [],
            "and from its ghost under another parent")
    }

    /// The deletion runs before the create and sync passes, so those simply find nothing
    /// rather than having to reason about a document that is about to go.
    ///
    /// Asserted on the **order** of the recorded requests, not on a count: the sync pass
    /// already skips a tombstoned draft, so a count-only assertion holds whichever way round
    /// the passes run and pins nothing.
    func testTheDeletePassRunsFirst() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        // A second, *un*-tombstoned document, so the sync pass has real work of its own and
        // its request actually lands in the log to be ordered against.
        env.drafts.save(draft(serverID))
        env.drafts.save(draft(otherServerID))
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)
        stubDeletePipeline(log: log)

        await env.coordinator.syncPendingDrafts()

        let methods = log.methods
        guard let deleteIndex = methods.firstIndex(of: "DELETE") else {
            return XCTFail("the deletion was never sent")
        }
        let syncIndex = log.indexOfFirstRequest(method: "GET", urlContaining: "formatted-content")
        XCTAssertNotNil(syncIndex, "precondition: the sync pass had work of its own")
        XCTAssertLessThan(deleteIndex, syncIndex ?? 0, "deletions are sent before the sync pass runs")
    }

    /// A 404 is the *expected* second half of a completion torn by a crash, as well as what a
    /// co-author's delete looks like. Either way there is nothing left to delete.
    func testAnAlreadyDeletedDocumentCompletesLikeASuccess() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        env.drafts.save(draft(serverID))
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)
        stubDeletePipeline(log: log, deleteStatus: 404)

        await env.coordinator.syncPendingDrafts()

        XCTAssertFalse(env.coordinator.isPendingDelete(documentID: serverID))
        XCTAssertNil(env.drafts.draft(for: serverID))
    }

    /// The crash window: a pass died between the DELETE landing and its cleanup, so the
    /// tombstone is still there with nothing left to clean up. Re-sending answers 404 and the
    /// completion finishes idempotently — which is what makes "tombstone removed last" safe.
    func testACompletionTornByACrashFinishesOnTheNextPass() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)
        stubDeletePipeline(log: log, deleteStatus: 404)

        await env.coordinator.syncPendingDrafts()

        XCTAssertFalse(env.coordinator.isPendingDelete(documentID: serverID))
        XCTAssertNil(env.deletes.pendingDelete(for: serverID), "and off disk, so no pass retries it")
    }

    /// Terminal, and the one outcome that gives the document back: this session may not make
    /// the deletion at all, so retrying forever would strike the row through for good.
    func testAForbiddenDeletionDropsTheTombstoneAndKeepsLocalData() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        env.drafts.save(draft(serverID))
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)
        stubDeletePipeline(log: log, deleteStatus: 403)

        await env.coordinator.syncPendingDrafts()

        XCTAssertFalse(env.coordinator.isPendingDelete(documentID: serverID), "no longer struck through")
        XCTAssertEqual(env.drafts.draft(for: serverID)?.markdown, "the user's only copy", "and nothing was lost")
    }

    func testATransportFailureKeepsTheTombstoneForALaterPass() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        env.drafts.save(draft(serverID))
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)
        stubDeletePipeline(log: log, deleteError: URLError(.notConnectedToInternet))

        await env.coordinator.syncPendingDrafts()

        XCTAssertTrue(env.coordinator.isPendingDelete(documentID: serverID))
        XCTAssertNotNil(env.drafts.draft(for: serverID))
    }

    /// A server error, a rate limit and an expired session all keep the tombstone — the last
    /// because the re-login sheet is already up and the deletion is still owed afterwards.
    func testServerFailuresAndAnExpiredSessionKeepTheTombstone() async {
        for status in [500, 429, 401] {
            let log = RequestRecorder()
            let env = makeEnvironment()
            env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)
            stubDeletePipeline(log: log, deleteStatus: status)

            await env.coordinator.syncPendingDrafts()

            XCTAssertTrue(env.coordinator.isPendingDelete(documentID: serverID), "kept for \(status)")
            MockURLProtocol.reset()
        }
    }

    /// `.routeNotFound` says something about the *server*, not about this document — a
    /// reverse proxy answering HTML for a path it swallowed must not read as "already gone".
    func testARouteNotFoundKeepsTheTombstone() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)
        let userBody = Data(#"{"id": "11111111-1111-4111-8111-111111111111", "email": "a@example.org"}"#.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            if request.httpMethod == "GET", request.url?.absoluteString.hasSuffix("users/me/") == true {
                return .init(statusCode: 200, headers: [:], body: userBody, error: nil)
            }
            return .init(
                statusCode: 404, headers: ["Content-Type": "text/html; charset=utf-8"],
                body: Data("<html>Not Found</html>".utf8), error: nil)
        }

        await env.coordinator.syncPendingDrafts()

        XCTAssertTrue(env.coordinator.isPendingDelete(documentID: serverID))
    }

    /// Every record remover here defers to an open editor, and this one removes more than
    /// most — including, for a checkpointed record, the local subtree.
    func testAnOpenEditorDefersTheDeletion() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)
        env.coordinator.retainOpenEditor(documentID: serverID)
        stubDeletePipeline(log: log)

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(log.methods.filter { $0 == "DELETE" }.count, 0)
        XCTAssertTrue(env.coordinator.isPendingDelete(documentID: serverID))
    }

    /// And closing that editor is the moment the deferral clears — on iPad the designed
    /// completion path, since the editor is a persistent detail column.
    func testClosingThatEditorKicksTheFunnel() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)
        env.coordinator.retainOpenEditor(documentID: serverID)
        stubDeletePipeline(log: log)
        await env.coordinator.syncPendingDrafts()

        env.coordinator.releaseOpenEditor(documentID: serverID)

        await waitUntil { log.methods.filter { $0 == "DELETE" }.count == 1 }
        await waitUntil { !env.coordinator.isPendingDelete(documentID: serverID) }
    }

    /// Deleting a *checkpointed* record means deleting the server document it was migrating
    /// onto, so its whole local subtree goes with it — the sub-pages the server has never
    /// seen have nowhere left to be filed.
    func testCompletingACheckpointedTombstoneCascadesTheLocalSubtree() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let parent = env.coordinator.createLocalDocument(title: "Parent", parentID: nil, ownerUserID: user)
        let child = env.coordinator.createLocalDocument(title: "Child", parentID: parent.id, ownerUserID: user)
        var checkpointed = env.coordinator.pendingCreateForTesting(localID: parent.id)!
        checkpointed.syncedServerID = serverID
        checkpointed.postedTitle = "Parent"
        env.coordinator.savePendingCreateForTesting(checkpointed)
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)
        stubDeletePipeline(log: log)

        await env.coordinator.syncPendingDrafts()

        XCTAssertNil(env.creates.create(for: parent.id), "the record goes")
        XCTAssertNil(env.creates.create(for: child.id), "and its sub-page with it")
        XCTAssertNil(env.drafts.draft(for: child.id), "including that sub-page's body")
        XCTAssertFalse(env.coordinator.isPendingDelete(documentID: serverID))
    }

    /// The undo is one request wide and can lose — but it must never lose the user's *work*.
    /// The document simply reads as deleted by someone else at the next fetch.
    func testAnUndoDuringTheRequestKeepsEveryLocalTrace() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        env.drafts.save(draft(serverID))
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)
        stubDeletePipeline(log: log, deleteDelay: 0.25)

        let coordinator = env.coordinator
        let pass = Task { await coordinator.syncPendingDrafts() }
        // Pin the order: undo only once the DELETE has actually reached the stub, or this
        // would be testing the plain "cancelled before the pass looked" path instead.
        await waitUntil { log.methods.contains("DELETE") }
        coordinator.cancelPendingDelete(documentID: serverID)
        await pass.value

        XCTAssertEqual(
            env.drafts.draft(for: serverID)?.markdown, "the user's only copy",
            "the request was lost, the work was not")
        XCTAssertFalse(env.coordinator.isPendingDelete(documentID: serverID))
    }

    /// **The undo race must not cost the user their text.** The DELETE lands, the undo arrives
    /// too late — and then, *in the same pass*, `runSyncPass` finds a draft whose document now
    /// 404s, with the tombstone gone so none of its suppressions apply, and reaps it. The user
    /// pressed "keep this document" and lost both the document and their only copy of the
    /// unsaved text.
    ///
    /// The fix keeps the work by re-minting the document as a locally-created one, which is the
    /// honest reading of the undo: the server copy is gone, so the way to keep the content is to
    /// create it again. The checkpointed path already did exactly this via its start-over.
    func testAnUndoThatLosesTheRaceKeepsTheUsersTextAsALocalDocument() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        env.drafts.save(draft(serverID, markdown: "the user's only copy"))
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)
        stubDeleteThenGone(log: log, deleteDelay: 0.25)

        let coordinator = env.coordinator
        let pass = Task { await coordinator.syncPendingDrafts() }
        await waitUntil { log.methods.contains("DELETE") }
        coordinator.cancelPendingDelete(documentID: serverID)
        await pass.value

        let bodies = env.drafts.allDrafts().map(\.markdown)
        XCTAssertTrue(
            bodies.contains("the user's only copy"),
            "the text survives somewhere — it is the only copy the user has")
        let revived = env.creates.allCreates().first
        XCTAssertNotNil(revived, "and as a local document, so the replay can create it again")
        XCTAssertEqual(env.drafts.draft(for: revived!.localID)?.markdown, "the user's only copy")
        XCTAssertEqual(revived?.ownerUserID, user, "attributable, so it can actually be sent")
        XCTAssertNil(env.drafts.draft(for: serverID), "nothing is left under the dead id")
    }

    /// The send-side gate has two halves and they must bind **independently** — a test that
    /// varies origin and owner together still passes if one half is dropped.
    func testATombstoneFromThisOriginButAnotherAccountIsNeverSent() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        // Same origin as the coordinator; only the owner differs.
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)
        env.deletes.save(
            PendingDocumentDelete(
                documentID: serverID, requestedAt: Date(), serverOrigin: origin, ownerUserID: otherUser))
        let relaunched = makeEnvironment(sharing: env.defaults)
        stubDeletePipeline(log: log)

        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertEqual(log.methods.filter { $0 == "DELETE" }.count, 0, "the owner half of the gate binds")
        XCTAssertTrue(relaunched.coordinator.isPendingDelete(documentID: serverID))
    }

    /// Nothing may PATCH a document whose deletion is queued. The screen that deleted it pops
    /// and every fresh editor is gated, but a **second, already-loaded** editor in another tab
    /// goes through neither — so the hold has to be in `enqueue` itself.
    func testASaveForATombstonedDocumentIsHeldRatherThanSent() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 200, headers: [:], body: Data(), error: nil)
        }

        env.coordinator.enqueue(documentID: serverID, title: "Doc", markdown: "typed after deleting")

        await waitAndConfirmNever { log.methods.contains("PATCH") }
        XCTAssertEqual(
            env.drafts.draft(for: serverID)?.markdown, "typed after deleting",
            "written ahead, so the keystrokes are on disk either way")
    }

    /// And the undo **releases** the held save rather than leaving it parked. Every other hold
    /// here drains on release for the same reason: `runSyncPass` skips any document with a
    /// non-nil `queued` slot, so a save left parked wedges the document out of the replay
    /// permanently — until an unrelated keystroke happens to drain it, which for a document
    /// the user has stopped editing never comes.
    func testUndoingReleasesAHeldSaveRatherThanLeavingItParked() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 200, headers: [:], body: Data(), error: nil)
        }
        env.coordinator.enqueue(documentID: serverID, title: "Doc", markdown: "typed after deleting")
        await waitAndConfirmNever { log.methods.contains("PATCH") }

        // The undo alone — no further keystroke to drain the slot for it.
        env.coordinator.cancelPendingDelete(documentID: serverID)

        await waitUntil { log.methods.contains("PATCH") }
        await waitUntil { env.coordinator.pendingSave(documentID: serverID) == nil }
    }

    /// The mirror of the pending-create rule: `releaseHeldSave` is one of the two paths that
    /// reach `start` without passing `enqueue`'s hold, and the editor clears conflicts from
    /// five places — so a conflict resolved while a deletion is queued must not break the hold.
    func testResolvingAConflictNeverReleasesASaveForATombstonedDocument() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        env.coordinator.recordConflict(documentID: serverID, serverUpdatedAt: Date())
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 200, headers: [:], body: Data(), error: nil)
        }
        env.coordinator.enqueue(documentID: serverID, title: "Doc", markdown: "typed after deleting")

        env.coordinator.clearResolvedConflict(documentID: serverID)

        await waitAndConfirmNever { log.methods.contains("PATCH") }
        XCTAssertNotNil(
            env.coordinator.pendingSave(documentID: serverID), "kept parked, not dropped")
    }

    /// **Unknown tombstones must not disarm the resurrection guard.** With the store
    /// undecodable every suppression is silently off, and the one that matters is the resume's
    /// **start-over**: a checkpointed record whose DELETE landed in a pass that died before its
    /// cleanup would read the 404 as "gone", clear its checkpoint, and re-POST the document
    /// under a new id — which no later launch can undo.
    ///
    /// Only that branch waits, not the whole resume: nothing clears the quarantine, so
    /// withholding the resume outright would strand every checkpointed record on the install
    /// permanently — body safe on disk, server document empty, no recovery short of reinstall.
    func testAnUnreadableDeleteStoreWithholdsTheStartOver() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(title: "Doomed", parentID: nil, ownerUserID: user)
        var checkpointed = env.coordinator.pendingCreateForTesting(localID: local.id)!
        checkpointed.syncedServerID = serverID
        checkpointed.postedTitle = "Doomed"
        env.coordinator.savePendingCreateForTesting(checkpointed)
        env.defaults.set(Data("not json".utf8), forKey: "dev.llun.Schrift.pendingDeletes")
        let relaunched = makeEnvironment(sharing: env.defaults)
        stubGoneServer(log: log)

        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertEqual(log.methods.filter { $0 == "POST" }.count, 0, "nothing is re-created")
        XCTAssertEqual(
            relaunched.creates.create(for: local.id)?.syncedServerID, serverID,
            "the checkpoint stands rather than being cleared by an unverifiable 404")
    }

    /// A landed deletion tells the lists, so a row already on screen leaves rather than
    /// **un-striking** back into looking like a live document — which reads as "my deletion
    /// was cancelled", the opposite of what happened.
    func testCompletingADeletionAnnouncesIt() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let announcements = Announcements()
        env.coordinator.observeDocumentDeleted(announcements) { announcements.ids.append($0) }
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)
        stubDeletePipeline(log: log)

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(announcements.ids, [serverID])
    }

    /// The coordinator is app-scoped and outlives every screen, so a strong closure per
    /// observer would accumulate one entry for every document ever opened. A dead observer is
    /// dropped rather than merely skipped.
    func testADeadObserverIsDroppedRatherThanKeptForever() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        var liveCalls = 0
        let live = Announcements()
        env.coordinator.observeDocumentDeleted(live) { _ in liveCalls += 1 }
        // Registered, then released before anything is announced.
        do {
            let transient = Announcements()
            env.coordinator.observeDocumentDeleted(transient) { _ in
                XCTFail("a deallocated observer must never be called")
            }
        }
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)
        stubDeletePipeline(log: log)

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(liveCalls, 1, "the live observer still hears about it")
        XCTAssertEqual(
            env.coordinator.documentDeletedObserverCountForTesting, 1,
            "and the dead one is gone, not merely skipped")
    }

    /// The `.forbidden` refusal must **not** announce: the document is still there, and the
    /// row it restores is a real one.
    func testAForbiddenDeletionAnnouncesNothing() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let announcements = Announcements()
        env.coordinator.observeDocumentDeleted(announcements) { announcements.ids.append($0) }
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)
        stubDeletePipeline(log: log, deleteStatus: 403)

        await env.coordinator.syncPendingDrafts()

        XCTAssertTrue(announcements.ids.isEmpty)
    }

    /// The undo-loses-the-race path for a **checkpointed** record, where the body is not where
    /// the revive looks for it: the tombstone names `syncedServerID`, but the draft is still
    /// under the record's `localID` until the migration moves it. Reviving from the server id
    /// finds nothing, and the purge that follows cascades the record's local subtree — taking
    /// the only copy of the body with it.
    func testAnUndoThatLosesTheRaceKeepsACheckpointedRecordsBody() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(title: "Doomed", parentID: nil, ownerUserID: user)
        env.drafts.save(
            PendingDraft(documentID: local.id, title: "Doomed", markdown: "typed offline", updatedAt: Date()))
        var checkpointed = env.coordinator.pendingCreateForTesting(localID: local.id)!
        checkpointed.syncedServerID = serverID
        checkpointed.postedTitle = "Doomed"
        env.coordinator.savePendingCreateForTesting(checkpointed)
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)
        stubDeleteThenGone(log: log, deleteDelay: 0.25)

        let coordinator = env.coordinator
        let pass = Task { await coordinator.syncPendingDrafts() }
        await waitUntil { log.methods.contains("DELETE") }
        coordinator.cancelPendingDelete(documentID: serverID)
        await pass.value

        XCTAssertTrue(
            env.drafts.allDrafts().map(\.markdown).contains("typed offline"),
            "the body survives — it is the only copy the user has")
        let record = env.creates.allCreates().first
        XCTAssertNotNil(record, "and a record still exists to send it")
        XCTAssertNil(
            record?.syncedServerID,
            "un-checkpointed, so the create replay POSTs it fresh rather than resuming onto a dead id")
    }

    /// **The revive runs even with an editor open on the dying id**, unlike every other record
    /// remover here. Deferring was the obvious choice and is the unsafe one: the tombstone is
    /// already gone, so `runSyncPass` later in the same pass reaps the draft — the exact loss
    /// the revive prevents — and a relaunch never reconsiders it, since `openEditors` is empty
    /// but so is the tombstone. Preserving the body wins over preserving the screen's backing.
    func testTheReviveRunsEvenWithAnEditorOpenOnTheDyingID() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        env.drafts.save(draft(serverID, markdown: "the user's only copy"))
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)
        stubDeleteThenGone(log: log, deleteDelay: 0.25)

        let coordinator = env.coordinator
        let pass = Task { await coordinator.syncPendingDrafts() }
        // Both acquired *during* the request: the pre-send guard has already run, so this is
        // the post-await re-check and nothing else.
        await waitUntil { log.methods.contains("DELETE") }
        coordinator.retainOpenEditor(documentID: serverID)
        coordinator.cancelPendingDelete(documentID: serverID)
        await pass.value

        let revived = env.creates.allCreates().first
        XCTAssertNotNil(revived, "the body was carried to a document that can actually be sent")
        XCTAssertEqual(env.drafts.draft(for: revived!.localID)?.markdown, "the user's only copy")
        XCTAssertNil(env.drafts.draft(for: serverID), "nothing is left under the dead id to be reaped")
    }

    /// A foreign tombstone is never sent — and, because the gate is checked before the
    /// request, never *completed* either. Sending under this session's cookies would very
    /// likely take DRF's 403-as-404, which the ladder reads as "already deleted".
    func testAForeignTombstoneIsNeitherSentNorCompleted() async {
        let log = RequestRecorder()
        let elsewhere = makeEnvironment(serverOrigin: "https://other.example.org")
        elsewhere.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: otherUser)
        let env = makeEnvironment(sharing: elsewhere.defaults)
        env.drafts.save(draft(serverID))
        stubDeletePipeline(log: log)

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(log.methods.filter { $0 == "DELETE" }.count, 0)
        XCTAssertTrue(env.coordinator.isPendingDelete(documentID: serverID), "still owed to its own session")
        XCTAssertNotNil(env.drafts.draft(for: serverID))
    }

    /// The cheap gate: a pass with nothing this session could send costs no round trip at
    /// all, so the funnel's other triggers stay free.
    func testAPassWithNothingToSendCostsNoRequests() async {
        let log = RequestRecorder()
        let elsewhere = makeEnvironment(serverOrigin: "https://other.example.org")
        elsewhere.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: otherUser)
        let env = makeEnvironment(sharing: elsewhere.defaults)
        stubDeletePipeline(log: log)

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(log.methods.count, 0, "not even /users/me/")
    }

    /// And it is only *waiting*: undoing the deletion lets the sub-page replay normally, so
    /// the gate costs a pass rather than the document.
    func testUndoingTheParentsDeletionReleasesItsChild() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        _ = env.coordinator.createLocalDocument(title: "Child", parentID: serverID, ownerUserID: user)
        env.coordinator.recordPendingDelete(documentID: serverID, ownerUserID: user)
        let createdBody = Data(
            """
            {"id": "\(otherServerID.uuidString.lowercased())", "title": "Child",
             "abilities": {}, "content": "", "created_at": "2026-03-01T12:00:00Z",
             "updated_at": "2026-03-01T12:00:00Z", "depth": 1, "numchild": 0, "path": "00000A",
             "link_reach": "restricted", "link_role": "reader", "user_role": "owner"}
            """.utf8)
        let userBody = Data(#"{"id": "11111111-1111-4111-8111-111111111111", "email": "a@example.org"}"#.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            switch request.httpMethod {
            case "GET" where url.hasSuffix("users/me/"):
                return .init(statusCode: 200, headers: [:], body: userBody, error: nil)
            case "POST":
                return .init(statusCode: 201, headers: [:], body: createdBody, error: nil)
            case "DELETE":
                // Kept unsent, so the parent stays tombstoned through the precondition. A
                // DELETE that landed would discharge the tombstone in the same pass and
                // release the child for the wrong reason.
                return .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
            default:
                return .init(statusCode: 200, headers: [:], body: createdBody, error: nil)
            }
        }
        await env.coordinator.syncPendingDrafts()
        XCTAssertEqual(log.count(ofMethod: "POST", urlContaining: "/children/"), 0, "precondition: held")

        env.coordinator.cancelPendingDelete(documentID: serverID)
        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(log.count(ofMethod: "POST", urlContaining: "/children/"), 1, "sent once the parent lives")
    }
}
