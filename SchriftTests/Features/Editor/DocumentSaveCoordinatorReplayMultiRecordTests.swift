import XCTest

@testable import Schrift

/// The create replay across more than one record: one record's skip, failure or deletion
/// must not affect its siblings.
@MainActor
final class DocumentSaveCoordinatorReplayMultiRecordTests: DocumentSaveCoordinatorReplayTestCase {
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
}
