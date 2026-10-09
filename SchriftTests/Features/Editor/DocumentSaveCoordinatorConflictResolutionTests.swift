import XCTest

@testable import Schrift

@MainActor
final class DocumentSaveCoordinatorConflictResolutionTests: DocumentSaveCoordinatorTestCase {
    /// A web edit that only bumped `updated_at` (a title rename) without touching the
    /// body still matches the baseline body → `.push`, not a conflict.
    func testSyncPendingDraftsPushesWhenTheServerBodyStillMatchesTheBaseline() async {
        let log = RequestRecorder()
        let renamedBody = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Renamed", "content": "# Base", "created_at": "2099-01-01T00:00:00Z", "updated_at": "2099-01-01T00:00:00Z"}
            """.utf8)
        let (coordinator, draftStore, _) = makeCoordinator()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: renamedBody, error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)  // content / title PATCH
        }
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Mine", updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 0), markdown: "# Base")))

        await coordinator.syncPendingDrafts()
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        XCTAssertNil(coordinator.conflict(for: documentID), "unchanged body vs the baseline is not a conflict")
        XCTAssertGreaterThanOrEqual(savesInFlight(log), 1)
    }

    /// Enqueue-hold: while a conflict is recorded, `enqueue` writes the draft and the
    /// queued slot (so `pendingSave()` still sees the unsaved work) but must NOT start
    /// a save — an autosave push would overwrite the conflicting server copy unasked.
    func testEnqueueIsHeldWhileAConflictIsRecorded() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, draftStore, _) = makeCoordinator()

        // Land a save first, so the state is `.saved` — i.e. the exact state a held save
        // must NOT be left reading as.
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Landed")
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        coordinator.recordConflict(documentID: documentID, serverUpdatedAt: Date())
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine")

        XCTAssertNotNil(coordinator.pendingSave(documentID: documentID), "the queued edit is retained")
        XCTAssertNotNil(draftStore.draft(for: documentID), "the write-ahead draft is retained")
        XCTAssertTrue(
            isPendingSync(coordinator.state(for: documentID)),
            "a held save is NOT a saved save — leaving `.saved` here tells the user their work synced "
                + "while it sits parked behind an unanswered conflict")
        await waitAndConfirmNever { self.savesInFlight(log) > 1 }
    }

    /// "Keep mine" clears the record and releases the held push (last-writer-wins).
    func testResolveConflictKeepingLocalPushesTheHeldWork() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, draftStore, _) = makeCoordinator()

        coordinator.recordConflict(documentID: documentID, serverUpdatedAt: Date())
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine")
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }  // confirm it was held

        coordinator.resolveConflictKeepingLocal(documentID: documentID)

        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
        XCTAssertNil(coordinator.conflict(for: documentID))
        XCTAssertGreaterThanOrEqual(savesInFlight(log), 1, "the held work is pushed")
        XCTAssertNil(draftStore.draft(for: documentID), "the pushed draft is cleared")
    }

    /// "Keep mine" has to **stick on the draft**, not just in the in-memory conflict map.
    /// The released push very often fails (a conflict is usually reviewed on the same flaky
    /// connection that produced it); the draft then survives, and if it still carried its
    /// original baseline the next sync would re-run the decision, re-detect the *identical*
    /// conflict and hold the push again — the user's answer would silently evaporate and
    /// they would be asked forever. Advancing the baseline past the server state they chose
    /// to overwrite makes the retry a `.push`.
    func testKeepingLocalSurvivesAFailedPushAndDoesNotReDetectTheSameConflict() async {
        let log = RequestRecorder()
        let (coordinator, draftStore, _) = makeCoordinator()
        let divergedBody = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "# Co-author edit", "created_at": "2099-01-01T00:00:00Z", "updated_at": "2099-01-01T00:00:00Z"}
            """.utf8)
        // The server is diverged; every content PATCH fails transiently (still offline).
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") {
                return .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
            }
            return .init(statusCode: 200, headers: [:], body: divergedBody, error: nil)
        }
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Mine", updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 0), markdown: "# Base")))
        await coordinator.syncPendingDrafts()
        XCTAssertNotNil(coordinator.conflict(for: documentID))

        // The user chooses their version. The push is released — and fails (still offline).
        coordinator.resolveConflictKeepingLocal(documentID: documentID)
        await waitUntil { self.isPendingSync(coordinator.state(for: self.documentID)) }
        XCTAssertNotNil(draftStore.draft(for: documentID), "the failed push keeps the draft")

        // The next sync trigger must NOT re-raise the conflict the user already answered.
        await coordinator.syncPendingDrafts()

        XCTAssertNil(
            coordinator.conflict(for: documentID),
            "the resolution stuck: the same conflict is not re-detected after a failed push")
        await waitUntil { self.savesInFlight(log) >= 2 }  // it retried the push instead
    }

    /// "Keep the server version" clears the record and drops the local draft/queued
    /// work without pushing — the editor re-fetches the server body separately.
    func testResolveConflictKeepingServerDropsTheDraftWithoutPushing() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, draftStore, _) = makeCoordinator()

        coordinator.recordConflict(documentID: documentID, serverUpdatedAt: Date())
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine")

        coordinator.resolveConflictKeepingServer(documentID: documentID)

        XCTAssertNil(coordinator.conflict(for: documentID))
        XCTAssertNil(draftStore.draft(for: documentID), "the local draft is discarded")
        XCTAssertNil(coordinator.pendingSave(documentID: documentID), "the queued work is dropped")
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }
    }

    /// A conflict is nearly always reached from a `.pendingSync`/`.failed` draft, and
    /// discarding it leaves nothing to save — so the save state must stop claiming one.
    /// Left alone it strands the reading surface's "Couldn't save · tap to retry" caption
    /// on a document with no unsaved work, offering a retry `saveNow` would no-op.
    func testKeepingTheServerVersionResetsAStaleFailedSaveState() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log, contentStatus: 400)  // non-retryable → `.failed`
        let (coordinator, draftStore, _) = makeCoordinator()

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine")
        await waitUntil { self.isFailed(coordinator.state(for: self.documentID)) }
        coordinator.recordConflict(documentID: documentID, serverUpdatedAt: Date())

        coordinator.resolveConflictKeepingServer(documentID: documentID)

        XCTAssertNil(coordinator.conflict(for: documentID))
        XCTAssertNil(draftStore.draft(for: documentID))
        XCTAssertFalse(
            isFailed(coordinator.state(for: documentID)),
            "a discarded conflict leaves nothing to save, so nothing may still report a failed save")
    }

    /// After a save the coordinator remembers what it pushed, and the *next* edit's
    /// draft carries it as `lastPushedMarkdown` — so a cross-relaunch replay recognises
    /// our own write (decision rule 1) instead of flagging a false conflict.
    func testEnqueueStampsTheDraftWithTheLastConfirmedPush() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log, saveDelay: 0.3)
        let (coordinator, draftStore, _) = makeCoordinator()

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# v1")
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
        XCTAssertNil(draftStore.draft(for: documentID))

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# v2")

        XCTAssertEqual(draftStore.draft(for: documentID)?.lastPushedMarkdown, "# v1")
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
    }

    /// `finish`'s *surviving-draft* branch: when a save lands while a **newer** draft
    /// has coalesced behind it (the user kept typing during the save), that draft must
    /// be re-stamped with what we just pushed. Otherwise it keeps its enqueue-time
    /// `lastPushedMarkdown` (nil here), decision rule 1 can't recognise our own write
    /// after a relaunch, and the replay reports a **false conflict** against it. The
    /// sibling test above only covers the enqueue-time stamp, where the prior save had
    /// already settled and its draft was removed by the equality branch.
    func testASurvivingNewerDraftIsStampedWithTheJustConfirmedPush() async {
        let log = RequestRecorder()
        // Hold the content PATCH open so a newer edit can coalesce behind the in-flight save.
        stubSavePipeline(log: log, saveDelay: 0.3)
        let (coordinator, draftStore, _) = makeCoordinator()

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# A")
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# B")  // queued behind A
        XCTAssertEqual(
            coordinator.state(for: documentID), .saving,
            "coalescing behind an in-flight save is NOT the conflict hold — it must stay `.saving`")
        XCTAssertEqual(draftStore.draft(for: documentID)?.markdown, "# B")
        XCTAssertNil(
            draftStore.draft(for: documentID)?.lastPushedMarkdown, "nothing has been confirmed pushed yet")

        // A lands → finish() re-stamps the surviving B draft with A's markdown.
        await waitUntil { draftStore.draft(for: self.documentID)?.lastPushedMarkdown == "# A" }
        XCTAssertEqual(
            draftStore.draft(for: documentID)?.markdown, "# B", "B is still the unsaved work, only re-stamped")

        await waitUntil {
            self.isSaved(coordinator.state(for: self.documentID))
                && coordinator.pendingSave(documentID: self.documentID) == nil
        }
        XCTAssertNil(draftStore.draft(for: documentID), "B then saved and cleared")
    }
}
