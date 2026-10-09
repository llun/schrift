import XCTest

@testable import Schrift

/// The create replay's ordering for sub-pages of a document this device also created.
@MainActor
final class DocumentSaveCoordinatorReplaySubpageTests: DocumentSaveCoordinatorReplayTestCase {
    /// The probe is for a parent that might be **gone**, so it is entered only on 403/404.
    /// Widening it to any non-retryable sub-page failure looks harmless and is not: a
    /// `.decoding` create whose parent happens to 404 would take the promote arm and `return`
    /// *before* the `.decoding` block, so `replayBlockedAt` is never stamped and the record
    /// re-POSTs on every launch — abandoning a document each time. That is the `is_favorite`
    /// incident on a loop, which is the whole reason the build-scoped block exists.
    func testASubpageWhoseCreateResponseCannotBeReadIsBlockedRatherThanPromoted() async {
        let log = RequestRecorder()
        let parent = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: parent, ownerUserID: user)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("users/me/") {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data("{\"id\": \"11111111-1111-4111-8111-111111111111\"}".utf8), error: nil)
            }
            // A 201 the client cannot decode: the server very likely built the document.
            if request.httpMethod == "POST" {
                return .init(statusCode: 201, headers: [:], body: Data("{}".utf8), error: nil)
            }
            // And the parent 404s, which is what would send a widened probe down the
            // promote arm and skip the block entirely.
            return .init(statusCode: 404, headers: [:], body: Data(), error: nil)
        }

        await env.coordinator.syncPendingDrafts()

        let record = env.creates.create(for: local.id)
        XCTAssertNotNil(record?.replayBlockedAt, "the unreadable response is blocked for this build")
        XCTAssertEqual(record?.parentID, parent, "and the parent is not rewritten on that evidence")
        XCTAssertEqual(creates(log), 1, "exactly one POST")
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

    /// The dependency gate. A sub-page whose parent has never been POSTed names that parent's
    /// **client-minted** id, so sending it would address `documents/{local-uuid}/children/` —
    /// a 404, a parent probe that 404s too, and a silent re-root of a document the user filed
    /// deliberately.
    func testASubpageIsNeverPostedWhileItsParentIsStillPending() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let parent = env.coordinator.createLocalDocument(title: "Parent", parentID: nil, ownerUserID: user)
        let child = env.coordinator.createLocalDocument(title: "Child", parentID: parent.id, ownerUserID: user)
        // The parent's own create fails in a way it will retry, which is what keeps its record
        // alive for the child's gate to see.
        stubUsersMeThen(log: log) { _ in .init(statusCode: 503, headers: [:], body: Data(), error: nil) }

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(creates(log), 1, "only the parent is attempted")
        XCTAssertEqual(
            log.count(ofMethod: "POST", urlContaining: parent.id.uuidString.lowercased()), 0,
            "and nothing ever addresses the client-minted parent id")
        XCTAssertEqual(
            env.creates.create(for: child.id)?.parentID, parent.id,
            "the sub-page still names its local parent, so it is re-parented by nothing")
        XCTAssertNotNil(env.creates.create(for: parent.id), "and both records survive to retry")
    }

    /// The gate plus the rewrite, end to end. The sub-page is POSTed to the id the parent's
    /// own create had *just* returned — a URL that cannot be formed before that response
    /// arrives, which is what makes this an ordering assertion and not merely a count.
    func testAParentAndItsSubpageReplayInOneOrderedPass() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let parent = env.coordinator.createLocalDocument(title: "Parent", parentID: nil, ownerUserID: user)
        let child = env.coordinator.createLocalDocument(title: "Child", parentID: parent.id, ownerUserID: user)
        env.coordinator.enqueue(documentID: child.id, title: "Child", markdown: "# Sub-page")
        stubChainedReplayPipeline(log: log, rootID: rootServerID, childIDs: [rootServerID: childServerID])

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(
            log.count(
                ofMethod: "POST", urlContaining: "documents/\(rootServerID.uuidString.lowercased())/children/"),
            1, "the sub-page goes to the children route of the id its parent was just given")
        XCTAssertEqual(creates(log), 2, "and neither document is POSTed twice")
        XCTAssertNil(env.creates.create(for: parent.id), "both records are gone once the server owns them")
        XCTAssertNil(env.creates.create(for: child.id))
        // The body follows the sub-page onto its own server id, not the parent's.
        await waitUntil {
            log.count(
                ofMethod: "PATCH", urlContaining: "documents/\(self.childServerID.uuidString.lowercased())/content/")
                == 1
        }
        XCTAssertNil(env.drafts.draft(for: child.id), "and nothing is left under the local id")
    }

    /// Depth is not a special case: the rewrite runs at every migration, so B unblocks C in
    /// the same pass that A unblocked B.
    func testAGrandchildChainReplaysInOnePass() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let a = env.coordinator.createLocalDocument(title: "A", parentID: nil, ownerUserID: user)
        let b = env.coordinator.createLocalDocument(title: "B", parentID: a.id, ownerUserID: user)
        let c = env.coordinator.createLocalDocument(title: "C", parentID: b.id, ownerUserID: user)
        stubChainedReplayPipeline(
            log: log, rootID: rootServerID,
            childIDs: [rootServerID: childServerID, childServerID: grandchildServerID])

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(
            log.count(
                ofMethod: "POST", urlContaining: "documents/\(rootServerID.uuidString.lowercased())/children/"),
            1)
        XCTAssertEqual(
            log.count(
                ofMethod: "POST", urlContaining: "documents/\(childServerID.uuidString.lowercased())/children/"),
            1, "the grandchild lands under the id its own parent was given in this same pass")
        XCTAssertEqual(creates(log), 3)
        for local in [a, b, c] { XCTAssertNil(env.creates.create(for: local.id)) }
    }

    /// The rewrite is **not** conditional on the sub-page being sendable. Here the child's
    /// own editor is open, so it is skipped for the rest of the pass — but leaving it naming
    /// the parent's dead local id is exactly the state that re-roots it later.
    func testAMigratingParentRepointsASubpageItCannotSendYet() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let parent = env.coordinator.createLocalDocument(title: "Parent", parentID: nil, ownerUserID: user)
        let child = env.coordinator.createLocalDocument(title: "Child", parentID: parent.id, ownerUserID: user)
        env.coordinator.retainOpenEditor(documentID: child.id)
        stubChainedReplayPipeline(log: log, rootID: rootServerID, childIDs: [rootServerID: childServerID])

        await env.coordinator.syncPendingDrafts()

        XCTAssertNil(env.creates.create(for: parent.id), "the parent migrated")
        XCTAssertEqual(
            env.creates.create(for: child.id)?.parentID, rootServerID,
            "and the sub-page was repointed at its real id even though it stayed put")
        XCTAssertEqual(log.count(ofMethod: "POST", urlContaining: "/children/"), 0, "nothing was sent for it")
    }

    /// A parent found already checkpointed resumes rather than re-POSTing, and the rewrite
    /// still runs — the gate keys on the record, which outlives the checkpoint.
    func testAResumedParentUnblocksItsSubpage() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let parent = env.coordinator.createLocalDocument(title: "Parent", parentID: nil, ownerUserID: user)
        let child = env.coordinator.createLocalDocument(title: "Child", parentID: parent.id, ownerUserID: user)
        var checkpointed = env.coordinator.pendingCreateForTesting(localID: parent.id)!
        checkpointed.syncedServerID = rootServerID
        checkpointed.postedTitle = "Parent"
        env.coordinator.savePendingCreateForTesting(checkpointed)
        stubChainedReplayPipeline(log: log, rootID: rootServerID, childIDs: [rootServerID: childServerID])

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(creates(log), 1, "the parent is resumed, not created a second time")
        XCTAssertEqual(
            log.count(
                ofMethod: "POST", urlContaining: "documents/\(rootServerID.uuidString.lowercased())/children/"),
            1, "and that one POST is the sub-page's")
        XCTAssertNil(env.creates.create(for: parent.id))
        XCTAssertNil(env.creates.create(for: child.id))
    }

    /// The state a kill between the rewrite and `removePendingCreate` leaves behind: the
    /// sub-page already points at a live server id while the parent's record is still there.
    /// It must simply send, once — the checkpoint is what proves that parent exists.
    func testASubpageAlreadyRepointedIsPostedExactlyOnce() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let parent = env.coordinator.createLocalDocument(title: "Parent", parentID: nil, ownerUserID: user)
        let child = env.coordinator.createLocalDocument(title: "Child", parentID: rootServerID, ownerUserID: user)
        var checkpointed = env.coordinator.pendingCreateForTesting(localID: parent.id)!
        checkpointed.syncedServerID = rootServerID
        checkpointed.postedTitle = "Parent"
        env.coordinator.savePendingCreateForTesting(checkpointed)
        stubChainedReplayPipeline(log: log, rootID: rootServerID, childIDs: [rootServerID: childServerID])

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(
            log.count(
                ofMethod: "POST", urlContaining: "documents/\(rootServerID.uuidString.lowercased())/children/"),
            1, "sent once, under the id it already named")
        XCTAssertNil(env.creates.create(for: child.id))
        XCTAssertNil(env.creates.create(for: parent.id))
    }

    /// Every reason the parent is held holds the sub-page with it, and releasing the parent
    /// releases both. An open editor is the one that clears without a relaunch.
    func testASubpageWaitsWhileItsParentsEditorIsOpen() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let parent = env.coordinator.createLocalDocument(title: "Parent", parentID: nil, ownerUserID: user)
        let child = env.coordinator.createLocalDocument(title: "Child", parentID: parent.id, ownerUserID: user)
        env.coordinator.retainOpenEditor(documentID: parent.id)
        stubChainedReplayPipeline(log: log, rootID: rootServerID, childIDs: [rootServerID: childServerID])

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(creates(log), 0, "neither is sent under a live parent screen")
        XCTAssertEqual(env.creates.create(for: child.id)?.parentID, parent.id)

        env.coordinator.releaseOpenEditor(documentID: parent.id)
        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(creates(log), 2, "and both go once it closes")
        XCTAssertNil(env.creates.create(for: parent.id))
        XCTAssertNil(env.creates.create(for: child.id))
    }

    /// **The gate is keyed on the record, not on the checkpoint, and this is what pins that.**
    /// A parent that has been POSTed but whose migration is deferred still holds its sub-pages:
    /// the repoint happens in `migrateCreatedDocument`, after every one of `finishMigration`'s
    /// bails, so until it runs the child still names an id the server has never seen. Weakening
    /// the gate to `syncedServerID == nil` passes every other test in this suite and loses this
    /// document's placement irreversibly — the POST 404s, the probe 404s, and it is re-rooted.
    func testASubpageWaitsWhileItsCheckpointedParentsMigrationIsDeferred() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let parent = env.coordinator.createLocalDocument(title: "Parent", parentID: nil, ownerUserID: user)
        let child = env.coordinator.createLocalDocument(title: "Child", parentID: parent.id, ownerUserID: user)
        var checkpointed = env.coordinator.pendingCreateForTesting(localID: parent.id)!
        checkpointed.syncedServerID = rootServerID
        checkpointed.postedTitle = "Parent"
        env.coordinator.savePendingCreateForTesting(checkpointed)
        // The migration is deferred, not the POST: a screen is live on the parent's local id.
        env.coordinator.retainOpenEditor(documentID: parent.id)
        stubChainedReplayPipeline(log: log, rootID: rootServerID, childIDs: [rootServerID: childServerID])

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(creates(log), 0, "the sub-page is not sent behind an unmigrated parent")
        XCTAssertEqual(
            log.count(ofMethod: "POST", urlContaining: parent.id.uuidString.lowercased()), 0,
            "and nothing addresses the id the server has never seen")
        XCTAssertEqual(
            env.creates.create(for: child.id)?.parentID, parent.id,
            "so nothing re-roots it: it still names its parent's local id")
    }

    /// A parent the server rejected on the merits parks its sub-page too — losing the sync,
    /// never the content. `init` re-seeds `.pendingSync`, so a relaunch retries the chain.
    func testASubpageOfAFailedParentWaitsAndRetriesAfterARelaunch() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let parent = env.coordinator.createLocalDocument(title: "Parent", parentID: nil, ownerUserID: user)
        let child = env.coordinator.createLocalDocument(title: "Child", parentID: parent.id, ownerUserID: user)
        env.coordinator.enqueue(documentID: child.id, title: "Child", markdown: "# Sub-page")
        stubUsersMeThen(log: log) { _ in
            .init(statusCode: 400, headers: [:], body: Data("{\"title\": [\"too long\"]}".utf8), error: nil)
        }

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(creates(log), 1, "the sub-page is never attempted behind a failed parent")
        XCTAssertEqual(env.drafts.draft(for: child.id)?.markdown, "# Sub-page", "and its body is untouched")

        let relaunched = makeEnvironment(sharing: env.defaults)
        stubChainedReplayPipeline(log: log, rootID: rootServerID, childIDs: [rootServerID: childServerID])
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNil(relaunched.creates.create(for: parent.id))
        XCTAssertNil(relaunched.creates.create(for: child.id), "both replay on the next launch")
    }

    /// A parent whose checkpoint is discharged starts over under a **new** server id, and the
    /// sub-page follows it there — because the child keeps naming the parent's `localID`,
    /// which no part of the start-over touches.
    func testAParentThatStartsOverStillTakesItsSubpageWithIt() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let parent = env.coordinator.createLocalDocument(title: "Parent", parentID: nil, ownerUserID: user)
        let child = env.coordinator.createLocalDocument(title: "Child", parentID: parent.id, ownerUserID: user)
        // A checkpoint onto a document that is no longer there. Nothing survives under that
        // server id, so the resume discharges it rather than retrying forever.
        var checkpointed = env.coordinator.pendingCreateForTesting(localID: parent.id)!
        checkpointed.syncedServerID = rootServerID
        checkpointed.postedTitle = "Parent"
        env.coordinator.savePendingCreateForTesting(checkpointed)
        stubUsersMeThen(log: log) { _ in
            .init(statusCode: 404, headers: [:], body: Data("{\"detail\": \"Not found.\"}".utf8), error: nil)
        }

        await env.coordinator.syncPendingDrafts()

        XCTAssertNil(
            env.creates.create(for: parent.id)?.syncedServerID, "the dead checkpoint is discharged")
        XCTAssertEqual(
            env.creates.create(for: child.id)?.parentID, parent.id,
            "and the sub-page still waits on the parent's local id, not the id that vanished")
        XCTAssertEqual(log.count(ofMethod: "POST", urlContaining: "/children/"), 0)

        stubChainedReplayPipeline(log: log, rootID: restartedServerID, childIDs: [restartedServerID: childServerID])
        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(
            log.count(
                ofMethod: "POST", urlContaining: "documents/\(restartedServerID.uuidString.lowercased())/children/"),
            1, "it lands under whichever id the parent's fresh create won")
        XCTAssertNil(env.creates.create(for: parent.id))
        XCTAssertNil(env.creates.create(for: child.id))
    }

    /// The point of the delete cascade, stated as the replay sees it: a deleted subtree comes
    /// back as *nothing*. Without it the orphaned sub-page would POST under its dead parent id,
    /// be re-rooted by the probe, and reappear in Home as a root document the user had thrown
    /// away — content and all.
    func testADeletedLocalSubtreeIsNeverResurrectedByTheReplay() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let root = env.coordinator.createLocalDocument(title: "Root", parentID: nil, ownerUserID: user)
        let child = env.coordinator.createLocalDocument(title: "Child", parentID: root.id, ownerUserID: user)
        env.coordinator.enqueue(documentID: child.id, title: "Child", markdown: "# Thrown away")
        stubChainedReplayPipeline(log: log, rootID: rootServerID, childIDs: [rootServerID: childServerID])

        env.coordinator.discardPendingWork(documentID: root.id)
        await env.coordinator.syncPendingDrafts()
        await waitAndConfirmNever { creates(log) > 0 }

        XCTAssertNil(env.drafts.draft(for: child.id), "and no body is left for a later pass to find")
    }

    /// A chain belonging to another account stays dormant whole: not sent, not re-parented,
    /// not deleted.
    func testASubpageChainFromAnotherAccountIsNeverSent() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let other = UUID()
        let parent = env.coordinator.createLocalDocument(title: "Parent", parentID: nil, ownerUserID: other)
        let child = env.coordinator.createLocalDocument(title: "Child", parentID: parent.id, ownerUserID: other)
        stubChainedReplayPipeline(log: log, rootID: rootServerID, childIDs: [rootServerID: childServerID])

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(creates(log), 0)
        XCTAssertEqual(env.creates.create(for: child.id)?.parentID, parent.id)
        XCTAssertNotNil(env.creates.create(for: parent.id))
    }
}
