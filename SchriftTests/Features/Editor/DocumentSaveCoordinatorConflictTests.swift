import XCTest

@testable import Schrift

@MainActor
final class DocumentSaveCoordinatorConflictTests: DocumentSaveCoordinatorTestCase {
    // MARK: - Sync conflicts

    /// The core detection: a queued draft whose baseline has diverged from the server
    /// (the server body changed *and* its `updated_at` is newer) is a conflict —
    /// recorded and preserved, never pushed and never discarded.
    func testSyncPendingDraftsRecordsAConflictWhenTheServerDivergesFromTheBaseline() async {
        let log = RequestRecorder()
        let (coordinator, draftStore, _) = makeCoordinator()
        let divergedBody = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "# Co-author edit", "created_at": "2099-01-01T00:00:00Z", "updated_at": "2099-01-01T00:00:00Z"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 200, headers: [:], body: divergedBody, error: nil)
        }
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Mine", updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 0), markdown: "# Base")))

        await coordinator.syncPendingDrafts()

        XCTAssertNotNil(coordinator.conflict(for: documentID), "the server diverged from the baseline — a conflict")
        XCTAssertNotNil(draftStore.draft(for: documentID), "the draft is preserved for the user to resolve")
        XCTAssertEqual(savesInFlight(log), 0, "a conflict never pushes")

        // A later sync trigger (reconnect/foreground fires this repeatedly) must skip a
        // conflicted draft entirely: it waits for the user's choice, so it neither pushes
        // over the server nor re-fetches to re-decide.
        let getsAfterDetection = log.count(ofMethod: "GET", urlContaining: "formatted-content")
        let draftAfterDetection = draftStore.draft(for: documentID)

        await coordinator.syncPendingDrafts()

        XCTAssertNotNil(coordinator.conflict(for: documentID), "the conflict still awaits the user")
        XCTAssertEqual(draftStore.draft(for: documentID), draftAfterDetection, "the draft is untouched")
        XCTAssertEqual(savesInFlight(log), 0, "still no push")
        XCTAssertEqual(
            log.count(ofMethod: "GET", urlContaining: "formatted-content"), getsAfterDetection,
            "a conflicted draft is skipped before the fetch")
    }

    /// `lastConfirmedPushMarkdown` is in-memory, so on a fresh process it is empty. An
    /// `enqueue` must NOT write that emptiness over the stamp `finish` persisted onto the
    /// draft last process — that would destroy decision rule 1 with the first
    /// post-relaunch enqueue (exactly the replay it exists to serve), and the document
    /// would then report the user's *own* earlier save as a sync conflict.
    func testEnqueueOnAFreshCoordinatorPreservesTheStoredLastPushedMarkdown() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log, saveDelay: 0.3)
        // A draft left by a previous process, already stamped with what that process pushed.
        let (coordinator, draftStore, _) = makeCoordinator()  // fresh: the in-memory map is empty
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Draft", updatedAt: Date(),
                baseline: DraftBaseline(
                    serverUpdatedAt: Date(timeIntervalSince1970: 1_800_000_000), markdown: "# Base"),
                lastPushedMarkdown: "# Pushed last process"))

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Draft edited")

        XCTAssertEqual(
            draftStore.draft(for: documentID)?.lastPushedMarkdown, "# Pushed last process",
            "a fresh process must carry the persisted stamp forward, not erase it")
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
    }

    /// The purge paths must clear the conflict record, or it wedges the document's save
    /// pipeline forever: the enqueue-hold would keep holding every future push for a
    /// conflict the user can no longer see or resolve.
    func testSuppressLocalWriteThroughClearsTheConflictAndUnwedgesSaving() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, draftStore, _) = makeCoordinator()
        coordinator.recordConflict(documentID: documentID, serverUpdatedAt: Date())

        coordinator.suppressLocalWriteThrough(documentID: documentID)

        XCTAssertNil(coordinator.conflict(for: documentID), "the stale record is cleared")
        // 404/403 revokes access, it does not delete unsaved work — the draft survives…
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# After")
        XCTAssertNotNil(draftStore.draft(for: documentID))
        // …and saving is no longer held.
        await waitUntil { self.savesInFlight(log) >= 1 }
    }

    func testDiscardPendingWorkClearsTheConflictAndTheDraft() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, draftStore, _) = makeCoordinator()
        coordinator.recordConflict(documentID: documentID, serverUpdatedAt: Date())
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine")  // held

        coordinator.discardPendingWork(documentID: documentID)

        XCTAssertNil(coordinator.conflict(for: documentID), "the deleted document's conflict is moot")
        XCTAssertNil(draftStore.draft(for: documentID))
        XCTAssertNil(coordinator.pendingSave(documentID: documentID))
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }
    }

    /// **A save is two PATCHes and can half-land.** If the content PATCH applies but the
    /// title PATCH drops (the flaky-network case this whole stack exists for), the server
    /// already holds this exact body — so the push must be recorded even though the save
    /// *failed*. Without it, rule 1 misses on the next replay, rule 2 sees a body diverged
    /// from the stale baseline, and the app raises a **sync conflict against the user's own
    /// text** — parking every further autosave behind a dialog about their own write.
    func testAHalfLandedSaveRecordsThePushSoItIsNotLaterSeenAsAConflict() async {
        let log = RequestRecorder()
        let (coordinator, draftStore, _) = makeCoordinator()
        // Content PATCH succeeds; the title PATCH (PATCH on documents/{id}/) drops.
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") {
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
            }
            if request.httpMethod == "PATCH" {
                return .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
            }
            // The server now holds exactly what we pushed, with a newer updated_at.
            return .init(
                statusCode: 200, headers: [:],
                body: Data(
                    """
                    {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "# Mine", "created_at": "2099-01-01T00:00:00Z", "updated_at": "2099-01-01T00:00:00Z"}
                    """.utf8), error: nil)
        }
        coordinator.enqueue(
            documentID: documentID, title: "Doc", markdown: "# Mine",
            baseline: DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 0), markdown: "# Base"))

        await waitUntil { self.isPendingSync(coordinator.state(for: self.documentID)) }
        XCTAssertEqual(
            draftStore.draft(for: documentID)?.lastPushedMarkdown, "# Mine",
            "the landed content PATCH is recorded on the draft, even though the save failed")

        // The replay must recognise its own write and push (to land the title), NOT conflict.
        await coordinator.syncPendingDrafts()

        XCTAssertNil(
            coordinator.conflict(for: documentID),
            "the server's body is our own half-landed save — never a conflict against the user")
        await waitUntil { self.savesInFlight(log) >= 2 }
    }

    /// `.discardServerWins` is the legacy (baseline-less) tolerance path. `syncPendingDrafts`
    /// is now repeatable (reconnect/foreground), and the editor may be *displaying* that
    /// draft — deleting it there would leave on-screen content with no disk backing, and the
    /// next keystroke would full-overwrite the newer server body. Only launch recovery, which
    /// runs before any editor exists, may discard outright.
    func testAStaleLegacyDraftIsOnlyDiscardedByLaunchRecovery() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)  // server updated_at 2026-01-15
        let (coordinator, draftStore, _) = makeCoordinator()
        // Baseline-less, and far older than the server → `.discardServerWins`.
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Stale",
                updatedAt: Date(timeIntervalSince1970: 0)))

        // A mid-session trigger (reconnect/foreground) must NOT delete it.
        await coordinator.syncPendingDrafts()
        XCTAssertNotNil(
            draftStore.draft(for: documentID),
            "a repeatable trigger must not delete a draft an open editor may be displaying")

        // Launch recovery may.
        await coordinator.recoverDrafts()
        XCTAssertNil(draftStore.draft(for: documentID), "launch recovery discards it")
    }

    /// A legacy (baseline-less) draft whose save is queued offline and whose server has
    /// moved past the tolerance window had **no funnel at all**: never pushed, never
    /// discarded, and — because the decision isn't `.conflict` — no pill either. The user
    /// saw "syncs when online" forever, and the only escape (tapping retry) full-overwrote
    /// the newer server copy with no prompt. It must be surfaced as a conflict instead.
    func testAStrandedLegacyPendingSyncDraftIsSurfacedAsAConflict() async {
        let log = RequestRecorder()
        let (coordinator, draftStore, _) = makeCoordinator()
        let futureBody = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "# Co-author", "created_at": "2099-01-01T00:00:00Z", "updated_at": "2099-01-01T00:00:00Z"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            if request.httpMethod == "PATCH" {
                return .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
            }
            return .init(statusCode: 200, headers: [:], body: futureBody, error: nil)
        }
        // No baseline (a pre-upgrade draft); the save fails offline → `.pendingSync`.
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine")
        await waitUntil { self.isPendingSync(coordinator.state(for: self.documentID)) }

        await coordinator.syncPendingDrafts()

        XCTAssertNotNil(
            coordinator.conflict(for: documentID),
            "a stranded legacy draft the server has moved past must get a UI funnel, not silence")
        XCTAssertNotNil(draftStore.draft(for: documentID), "and it is never discarded from under the user")
    }

    /// An overlapping sync trigger must be **coalesced, not dropped**. The pass in flight
    /// may already have tried (and failed on) the very draft the new trigger cares about —
    /// a reconnect landing mid-pass is exactly that — so returning early would lose it until
    /// the next background→foreground cycle. Distinguished from simply dropping the trigger:
    /// the first pass fails offline, a second trigger arrives *while it is still running*,
    /// and the network is healthy by the time the coalesced pass runs.
    func testAnOverlappingSyncTriggerIsCoalescedRatherThanDropped() async {
        let log = RequestRecorder()
        let (coordinator, draftStore, _) = makeCoordinator()
        draftStore.save(PendingDraft(documentID: documentID, title: "Doc", markdown: "# Draft", updatedAt: Date()))

        // Pass 1: the GET is held open, then fails — so the draft is not replayed.
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(
                statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet), delay: 0.3)
        }
        async let firstPass: Void = coordinator.syncPendingDrafts()

        // A reconnect lands *during* that pass (pinned on the recorded in-flight GET).
        await waitUntil { log.count(ofMethod: "GET", urlContaining: "formatted-content") >= 1 }
        stubSavePipeline(log: log)  // the network is healthy again
        await coordinator.syncPendingDrafts()  // must be coalesced, not dropped
        await firstPass

        // The coalesced pass re-fetched and replayed the draft the failing pass gave up on.
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
        XCTAssertGreaterThanOrEqual(savesInFlight(log), 1, "the coalesced pass replayed the draft")
        XCTAssertNil(draftStore.draft(for: documentID))
    }

    /// The push must be recorded even when the save settles into `finish`'s **discarded**
    /// branch. `suppressLocalWriteThrough` (the 404/403 path) deliberately KEEPS the draft,
    /// so a newer draft survives that branch — and recording the push after its `return` left
    /// exactly that draft unstamped. The replay then raised a conflict against the user's own
    /// landed save, and "keep the server version" would discard their real unsaved work.
    func testASaveLandingWhileTheDocumentIs404StillRecordsThePushOnTheSurvivingDraft() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log, saveDelay: 0.3)  // hold the content PATCH open
        let (coordinator, draftStore, _) = makeCoordinator()

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Landed")
        // The user keeps typing, so a NEWER draft is outstanding when the document 404s.
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Newer")
        coordinator.suppressLocalWriteThrough(documentID: documentID)  // 404/403: keeps the draft

        // The first save then lands on the server.
        await waitUntil { draftStore.draft(for: self.documentID)?.lastPushedMarkdown != nil }

        XCTAssertEqual(
            draftStore.draft(for: documentID)?.lastPushedMarkdown, "# Landed",
            "the surviving draft must carry what the landed save pushed, or the replay conflicts with it")
        XCTAssertEqual(draftStore.draft(for: documentID)?.markdown, "# Newer", "and keep the user's newer work")
    }

    /// The half-land must record the push even when the title failure is **not** retryable
    /// (a 4xx the server rejected on the merits → `.failed`). The content is on the server
    /// either way, which is the only thing rule 1 cares about.
    func testANonRetryableHalfLandedSaveStillRecordsThePush() async {
        let log = RequestRecorder()
        let (coordinator, draftStore, _) = makeCoordinator()
        let serverBody = Self.formattedBody
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") {
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
            }
            if request.httpMethod == "PATCH" {
                return .init(statusCode: 400, headers: [:], body: Data(), error: nil)  // title rejected
            }
            return .init(statusCode: 200, headers: [:], body: serverBody, error: nil)
        }

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine")

        await waitUntil { self.isFailed(coordinator.state(for: self.documentID)) }
        XCTAssertEqual(
            draftStore.draft(for: documentID)?.lastPushedMarkdown, "# Mine",
            "the content landed, so the push is recorded even though the save hard-failed")
    }

    /// A launch recovery that arrives *while a pass is already running* must still get its
    /// launch semantics — it is the only place a stale legacy draft may be discarded outright.
    func testALaunchRecoveryArrivingMidPassStillPerformsItsDiscard() async {
        let log = RequestRecorder()
        let (coordinator, draftStore, _) = makeCoordinator()
        // Baseline-less and far older than the 2026-01-15 fixture → `.discardServerWins`.
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Stale",
                updatedAt: Date(timeIntervalSince1970: 0)))
        let body = Self.formattedBody
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 200, headers: [:], body: body, error: nil, delay: 0.3)
        }

        // A mid-session pass starts (it will NOT discard) …
        async let midSession: Void = coordinator.syncPendingDrafts()
        await waitUntil { log.count(ofMethod: "GET", urlContaining: "formatted-content") >= 1 }
        // … and launch recovery arrives while it is still in flight.
        await coordinator.recoverDrafts()
        await midSession

        XCTAssertNil(
            draftStore.draft(for: documentID),
            "the coalesced pass must still carry the launch-recovery semantics, or the discard is lost")
    }

    /// Keep-mine on a **legacy** (baseline-less) draft. Advancing its baseline needs a body to
    /// carry, and there isn't one — fabricating `""` makes rule 2's content tiebreak match any
    /// **empty server document**, so a co-author who deliberately empties the doc would be
    /// silently full-overwritten instead of raising a fresh conflict. The draft's own body is
    /// the right fallback: the tiebreak can then only ever match our own writing.
    func testKeepingLocalOnALegacyDraftNeverFabricatesAnEmptyBaselineBody() async {
        let log = RequestRecorder()
        let (coordinator, draftStore, _) = makeCoordinator()
        let futureBody = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "# Co-author", "created_at": "2099-01-01T00:00:00Z", "updated_at": "2099-01-01T00:00:00Z"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            if request.httpMethod == "PATCH" {
                return .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
            }
            return .init(statusCode: 200, headers: [:], body: futureBody, error: nil)
        }
        // No baseline (a pre-upgrade draft); the save fails offline → `.pendingSync`.
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine")
        await waitUntil { self.isPendingSync(coordinator.state(for: self.documentID)) }
        await coordinator.syncPendingDrafts()
        XCTAssertNotNil(coordinator.conflict(for: documentID))

        coordinator.resolveConflictKeepingLocal(documentID: documentID)
        await waitUntil { self.isPendingSync(coordinator.state(for: self.documentID)) }

        XCTAssertEqual(
            draftStore.draft(for: documentID)?.baseline?.markdown, "# Mine",
            "the advanced baseline carries the draft's own body — never an empty string, which would "
                + "make the content tiebreak match any empty server document")
    }

    /// **The hold must survive a relaunch.** A conflict the app already detected and *showed
    /// the user* used to evaporate on process death, because the record was in-memory only. On
    /// the next launch the editor renders the stored draft synchronously and unblocks editing
    /// **before** any revalidation returns — so a Done tap or an autosave reached `enqueue`
    /// with `conflicts` empty and pushed a full overwrite over the co-author's body the user
    /// had literally just been warned about. Rule 1 and the baseline are persisted for exactly
    /// this reason; the hold is no different.
    func testAConflictHoldSurvivesARelaunch() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let suiteName = "DocumentSaveCoordinatorTests.\(UUID().uuidString)"
        draftSuiteNames.append(suiteName)
        let draftStore = PendingDraftStore(userDefaults: UserDefaults(suiteName: suiteName)!)
        let contentCache = DocumentContentCacheStore(directory: cacheDirectory)
        func makeProcess() -> DocumentSaveCoordinator {
            DocumentSaveCoordinator(
                client: DocsAPIClient(
                    baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] }),
                draftStore: draftStore, contentCache: contentCache, backgroundTasks: .noop)
        }

        // Process 1: a queued draft, and a conflict detected against it.
        let first = makeProcess()
        first.recordConflict(documentID: documentID, serverUpdatedAt: Date())
        first.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine")
        XCTAssertNotNil(first.conflict(for: documentID))
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }

        // Process 2: same draft store, brand-new coordinator (the app was killed).
        let second = makeProcess()

        XCTAssertNotNil(
            second.conflict(for: documentID), "the unanswered conflict must be in force from the first instant")
        // The decisive property: the very first enqueue of the new process is HELD, without
        // waiting for any revalidation to come back and re-derive the conflict.
        second.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine, edited after relaunch")
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }
        XCTAssertNotNil(draftStore.draft(for: documentID), "and the edit is still safely on disk")

        // Answering it releases the hold — on disk as well as in memory.
        second.resolveConflictKeepingLocal(documentID: documentID)
        await waitUntil { self.savesInFlight(log) >= 1 }
        XCTAssertNil(makeProcess().conflict(for: documentID), "a third process sees no stale hold")
    }

    /// The relaunch hold must cover the **sync pass** — the primary detection path for the
    /// offline-replay case this whole feature exists for. It wrote the conflict straight into
    /// the in-memory map, bypassing the on-disk mirror, so the hold it established died at the
    /// next launch: the user comes back, taps into the document, taps Done, and the co-author's
    /// body is gone with no pill and no prompt.
    func testAConflictDetectedByTheSyncPassSurvivesARelaunch() async {
        let log = RequestRecorder()
        let suiteName = "DocumentSaveCoordinatorTests.\(UUID().uuidString)"
        draftSuiteNames.append(suiteName)
        let draftStore = PendingDraftStore(userDefaults: UserDefaults(suiteName: suiteName)!)
        let contentCache = DocumentContentCacheStore(directory: cacheDirectory)
        func makeProcess() -> DocumentSaveCoordinator {
            DocumentSaveCoordinator(
                client: DocsAPIClient(
                    baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] }),
                draftStore: draftStore, contentCache: contentCache, backgroundTasks: .noop)
        }
        let divergedBody = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "# Co-author edit", "created_at": "2099-01-01T00:00:00Z", "updated_at": "2099-01-01T00:00:00Z"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            if request.httpMethod == "PATCH" {
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: divergedBody, error: nil)
        }

        // Process 1: a queued offline draft whose server has diverged. The SYNC PASS detects it.
        let first = makeProcess()
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Mine", updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 0), markdown: "# Base")))
        await first.syncPendingDrafts()
        XCTAssertNotNil(first.conflict(for: documentID), "the sync pass detected it")
        XCTAssertEqual(savesInFlight(log), 0, "and held the push")

        // Process 2: the app was killed. The user did not type again in process 1.
        let second = makeProcess()

        XCTAssertNotNil(
            second.conflict(for: documentID),
            "a conflict the app already detected and showed the user must not evaporate on process death")
        second.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine, edited after relaunch")
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }
        XCTAssertNotNil(draftStore.draft(for: documentID))
    }

    /// The mirror must follow **every** in-memory clear, not just the resolvers.
    /// `suppressLocalWriteThrough` (404/403) deliberately drops the conflict while KEEPING the
    /// draft — so a bare in-memory nil left the stamp on disk, and the next launch resurrected a
    /// hold this path had explicitly dropped: a destructive "Keep the server version" re-armed
    /// against a draft with no conflict, and a sync pass that skips the document forever.
    func testAConflictDroppedOnA404StaysDroppedAcrossARelaunch() async {
        let suiteName = "DocumentSaveCoordinatorTests.\(UUID().uuidString)"
        draftSuiteNames.append(suiteName)
        let draftStore = PendingDraftStore(userDefaults: UserDefaults(suiteName: suiteName)!)
        let contentCache = DocumentContentCacheStore(directory: cacheDirectory)
        func makeProcess() -> DocumentSaveCoordinator {
            DocumentSaveCoordinator(
                client: DocsAPIClient(
                    baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] }),
                draftStore: draftStore, contentCache: contentCache, backgroundTasks: .noop)
        }
        let log = RequestRecorder()
        stubSavePipeline(log: log)

        let first = makeProcess()
        first.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine")
        await waitUntil { self.isSaved(first.state(for: self.documentID)) }
        draftStore.save(PendingDraft(documentID: documentID, title: "Doc", markdown: "# Mine", updatedAt: Date()))
        first.recordConflict(documentID: documentID, serverUpdatedAt: Date())
        XCTAssertNotNil(draftStore.draft(for: documentID)?.conflictServerUpdatedAt, "the hold is on disk")

        // A 404/403 tears the document down: the conflict is dropped, the draft deliberately kept.
        first.suppressLocalWriteThrough(documentID: documentID)
        XCTAssertNil(first.conflict(for: documentID))

        XCTAssertNil(
            draftStore.draft(for: documentID)?.conflictServerUpdatedAt,
            "the clear must reach disk, or the next launch resurrects a hold this path dropped")
        XCTAssertNil(makeProcess().conflict(for: documentID), "…and a fresh process sees no stale hold")
    }

    /// **`finish`'s queued restart calls `start()` directly, bypassing `enqueue`'s hold.** So a
    /// conflict detected *while that save was failing* — by the deferred re-decision below, or by
    /// a sync pass — would be pushed straight over the moment the save settled. This is the one
    /// place a just-detected conflict can be overwritten, and the guard must re-apply the hold.
    func testAJustDetectedConflictIsNotPushedOverByTheQueuedRestart() async {
        let log = RequestRecorder()
        let (coordinator, draftStore, _) = makeCoordinator()
        let coauthor = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "# Co-author", "created_at": "2099-01-01T00:00:00Z", "updated_at": "2099-01-01T00:00:00Z"}
            """.utf8)
        // The content PATCH is held open, then fails: NOTHING reaches the server.
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") {
                return .init(
                    statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet), delay: 0.3)
            }
            return .init(statusCode: 200, headers: [:], body: coauthor, error: nil)
        }
        // Save A is on the wire; the user keeps typing, so B coalesces into `queued`.
        coordinator.enqueue(
            documentID: documentID, title: "Doc", markdown: "# A",
            baseline: DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 0), markdown: "# Base"))
        coordinator.enqueue(
            documentID: documentID, title: "Doc", markdown: "# B",
            baseline: DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 0), markdown: "# Base"))
        XCTAssertEqual(coordinator.pendingSave(documentID: documentID)?.markdown, "# B", "B is queued behind A")

        // A revalidation lands during A and sees the co-author's diverged body.
        coordinator.noteServerObservedDuringSave(
            documentID: documentID, serverUpdatedAt: Date(timeIntervalSince1970: 4_100_000_000),
            markdown: "# Co-author")

        // A fails → `finish` re-decides, records the conflict … and must NOT start B.
        await waitUntil { self.isPendingSync(coordinator.state(for: self.documentID)) }

        XCTAssertNotNil(coordinator.conflict(for: documentID), "the failed save's observation is re-decided")
        XCTAssertEqual(
            coordinator.pendingSave(documentID: documentID)?.markdown, "# B", "B is re-parked, not sent")
        await waitAndConfirmNever { self.savesInFlight(log) > 1 }
        XCTAssertNotNil(draftStore.draft(for: documentID))
    }

    /// The observation is scoped to **one** save, so it must be dropped even when that save is
    /// discarded (a 404/403 teardown), not only when it is consumed. Leaving it behind that
    /// early return let it leak into a *later, unrelated* save and manufacture a phantom
    /// conflict against a document the server had not touched.
    func testAnObservationFromADiscardedSaveDoesNotLeakIntoALaterOne() async {
        let log = RequestRecorder()
        let (coordinator, draftStore, _) = makeCoordinator()
        let serverBody = Self.formattedBody
        // Every content PATCH is held open, then fails (offline) — so save A can be discarded
        // mid-flight and save B can reach `finish`'s re-decide block.
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") {
                return .init(
                    statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet), delay: 0.3)
            }
            return .init(statusCode: 200, headers: [:], body: serverBody, error: nil)
        }

        // Save A is on the wire; a revalidation observes a wildly-diverged server body…
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# A")
        coordinator.noteServerObservedDuringSave(
            documentID: documentID, serverUpdatedAt: Date(timeIntervalSince1970: 4_100_000_000),
            markdown: "# Some unrelated server body")
        // …but then the document 404s, so A is discarded (its `finish` takes the early return,
        // settling to `.idle` and dropping the observation at the top of `finish`).
        coordinator.suppressLocalWriteThrough(documentID: documentID)
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
        XCTAssertNil(coordinator.conflict(for: documentID), "the discarded save records nothing")

        // A later save then fails and reaches the re-decide block. The leaked observation would
        // surface HERE — it must not.
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# B")
        await waitUntil {
            if case .pendingSync = coordinator.state(for: self.documentID) { return true }
            return false
        }

        XCTAssertNil(
            coordinator.conflict(for: documentID),
            "an observation scoped to the discarded save must not manufacture a conflict on a later one")
        XCTAssertNotNil(draftStore.draft(for: documentID))
    }

    /// The **benign** deferred re-decision. When a save that carried an observation fails, `finish`
    /// re-runs the decision — and if that observation resolves to a *proven* `.push` (the server
    /// held our own body, or a body that descends from the baseline), it must record **nothing**.
    /// Recording there would manufacture a false "conflict against the user's own writing" after a
    /// failed save, the exact hazard this whole subsystem exists to prevent. Every other test that
    /// reaches this block feeds a diverged body (`.conflict`); this pins the `.push` arm.
    func testAFailedSaveWhoseObservationMatchesOurBodyRecordsNoConflict() async {
        let log = RequestRecorder()
        let (coordinator, draftStore, _) = makeCoordinator()
        // The content PATCH is held open, then fails: the observation reaches `finish`'s re-decide.
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") {
                return .init(
                    statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet), delay: 0.3)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }

        coordinator.enqueue(
            documentID: documentID, title: "Doc", markdown: "# Mine",
            baseline: DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 0), markdown: "# Base"))
        // The revalidation saw a server body EQUAL TO OUR OWN (rule 0), with a newer `updated_at`.
        coordinator.noteServerObservedDuringSave(
            documentID: documentID, serverUpdatedAt: Date(timeIntervalSince1970: 4_100_000_000), markdown: "# Mine")

        await waitUntil { self.isPendingSync(coordinator.state(for: self.documentID)) }

        XCTAssertNil(
            coordinator.conflict(for: documentID),
            "the observed body is our own — a proven push, never a conflict against the user's own writing")
        XCTAssertNotNil(draftStore.draft(for: documentID))
    }

    /// The supersession rule. If the content PATCH **landed**, the server holds *our* body, so an
    /// observation taken during that save is stale — deciding against it would manufacture a
    /// conflict against the user's own writing.
    func testAnObservationIsDiscardedWhenTheSaveActuallyLanded() async {
        let log = RequestRecorder()
        let (coordinator, _, _) = makeCoordinator()
        stubSavePipeline(log: log, saveDelay: 0.3)

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine")
        coordinator.noteServerObservedDuringSave(
            documentID: documentID, serverUpdatedAt: Date(timeIntervalSince1970: 4_100_000_000),
            markdown: "# Some other body")

        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        XCTAssertNil(
            coordinator.conflict(for: documentID),
            "the save landed, so the server holds OUR body — the observation is superseded and must never "
                + "raise a conflict against the user's own writing")
    }

    /// **The enqueue-hold broke an invariant: `queued != nil` used to imply `inFlight != nil`.**
    /// The hold parks a save with nothing in flight, and only "Keep mine" ever drained it. So a
    /// conflict released *any other way* — a proven `.push` from a detection site, e.g. the
    /// co-author reverting — stranded that save forever: nothing starts it (`saveNow` no-ops on
    /// a non-nil `pendingSave`; `runSyncPass` skips a queued document), so the user's edit
    /// silently never syncs.
    func testReleasingAConflictStartsTheSaveItWasHolding() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, draftStore, _) = makeCoordinator()

        coordinator.recordConflict(documentID: documentID, serverUpdatedAt: Date())
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine")
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }  // held

        // A detection site proves the conflict is gone (the co-author reverted).
        coordinator.clearResolvedConflict(documentID: documentID)

        await waitUntil { self.savesInFlight(log) >= 1 }
        // Polled, not asserted outright: `pendingSave` reports the in-flight save
        // too, so it only empties once the save *finishes* — which is strictly
        // after the request this test just watched reach the network. Asserting
        // it instantly raced that window and failed on a loaded CI runner. The
        // property under test is unchanged: the parked work must actually be
        // sent, not stranded forever.
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
        await waitUntil { draftStore.draft(for: self.documentID) == nil }
    }

    /// …and the second half, which is the destructive one. If the released hold's save is left
    /// parked, the NEXT save takes `enqueue`'s `start` path (no conflict, nothing in flight)
    /// without clearing the slot — and when it lands, `finish` pops the **stale** save and
    /// starts it, full-overwriting the server with the OLDER body and stamping it as our last
    /// confirmed push. The user's newer text is destroyed on screen, disk and server.
    func testAStaleHeldSaveIsNeverResurrectedOverNewerContent() async {
        let log = RequestRecorder()
        let bodies = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") {
                bodies.record(request)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        let (coordinator, draftStore, contentCache) = makeCoordinator()

        coordinator.recordConflict(documentID: documentID, serverUpdatedAt: Date())
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# OLD held body")
        coordinator.clearResolvedConflict(documentID: documentID)  // releases and sends it
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        // The user types on. This save must be the last word.
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# NEW body")
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
        await waitAndConfirmNever { coordinator.pendingSave(documentID: self.documentID) != nil }

        XCTAssertNil(draftStore.draft(for: documentID))
        XCTAssertEqual(
            contentCache.content(for: documentID)?.markdown, "# NEW body",
            "the newer body must be the last thing written — a resurrected stale save would overwrite it")
    }
}
