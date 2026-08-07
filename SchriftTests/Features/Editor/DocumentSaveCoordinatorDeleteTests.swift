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

    /// `/users/me/` plus a server that has forgotten every document — the shape a queued
    /// deletion predicts, and the one that would reap a draft if a suppression were missing.
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
            return .init(
                statusCode: 404, headers: ["Content-Type": "application/json"],
                body: Data(#"{"detail":"Not found."}"#.utf8), error: nil)
        }
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
