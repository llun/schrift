import XCTest

@testable import Schrift

@MainActor
final class DocumentSaveCoordinatorTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!
    private let otherDocumentID = UUID(uuidString: "9C2C2C2C-2C2C-4C2C-8C2C-2C2C2C2C2C2C")!
    private var cacheDirectory: URL!
    /// Every suite `makeCoordinator` creates, so tearDown can remove each persistent
    /// domain instead of leaking a plist per test.
    private var draftSuiteNames: [String] = []

    private static let formattedBody = Data(
        """
        {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "Server content", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
        """.utf8)

    @MainActor
    private final class BackgroundTaskRecorder {
        var beginCount = 0
        var endCount = 0

        var provider: BackgroundTaskProvider {
            BackgroundTaskProvider(
                begin: { [weak self] _ in
                    self?.beginCount += 1
                    return 7
                },
                end: { [weak self] _ in
                    self?.endCount += 1
                }
            )
        }
    }

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentSaveCoordinatorTests.\(UUID().uuidString)", isDirectory: true)
        draftSuiteNames = []
    }

    override func tearDown() {
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: cacheDirectory)
        cacheDirectory = nil
        for suiteName in draftSuiteNames {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    private func makeCoordinator(
        backgroundTasks: BackgroundTaskProvider = .noop
    ) -> (DocumentSaveCoordinator, PendingDraftStore, DocumentContentCacheStore) {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let suiteName = "DocumentSaveCoordinatorTests.\(UUID().uuidString)"
        draftSuiteNames.append(suiteName)
        let draftStore = PendingDraftStore(userDefaults: UserDefaults(suiteName: suiteName)!)
        let contentCache = DocumentContentCacheStore(directory: cacheDirectory)
        let coordinator = DocumentSaveCoordinator(
            client: client,
            draftStore: draftStore,
            contentCache: contentCache,
            backgroundTasks: backgroundTasks
        )
        return (coordinator, draftStore, contentCache)
    }

    /// A save is now two PATCHes: content (base64 Yjs) then title. Each save is
    /// counted by its single content PATCH. `recoverDrafts` first GETs
    /// formatted-content to compare timestamps.
    private func savesInFlight(_ log: RequestRecorder) -> Int {
        log.count(ofMethod: "PATCH", urlContaining: "/content/")
    }

    private func stubSavePipeline(log: RequestRecorder, saveDelay: TimeInterval = 0, contentStatus: Int = 204) {
        let formattedBody = Self.formattedBody
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            switch request.httpMethod {
            case "GET" where url.contains("formatted-content"):
                return .init(statusCode: 200, headers: [:], body: formattedBody, error: nil)
            case "PATCH" where url.hasSuffix("/content/"):
                return .init(statusCode: contentStatus, headers: [:], body: Data(), error: nil, delay: saveDelay)
            case "PATCH":
                return .init(statusCode: 200, headers: [:], body: Data(), error: nil)  // title
            default:
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
            }
        }
    }

    private func isSaved(_ state: DocumentSaveCoordinator.DocSaveState) -> Bool {
        if case .saved = state { return true }
        return false
    }

    private func isFailed(_ state: DocumentSaveCoordinator.DocSaveState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    func testEnqueueRunsPipelineClearsDraftAndBalancesBackgroundTask() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let recorder = BackgroundTaskRecorder()
        let (coordinator, draftStore, _) = makeCoordinator(backgroundTasks: recorder.provider)

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Content")

        // Write-ahead: the draft exists before the save completes.
        XCTAssertNotNil(draftStore.draft(for: documentID))

        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        XCTAssertTrue(isSaved(coordinator.state(for: documentID)))
        // A save PATCHes content (base64 Yjs) then title.
        XCTAssertEqual(log.methods, ["PATCH", "PATCH"])
        XCTAssertEqual(savesInFlight(log), 1)
        XCTAssertNil(draftStore.draft(for: documentID))
        XCTAssertEqual(recorder.beginCount, 1)
        XCTAssertEqual(recorder.endCount, 1)
    }

    func testEnqueueWhileInFlightCoalescesToLatestContent() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log, saveDelay: 0.2)
        let (coordinator, draftStore, _) = makeCoordinator()

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "v1")
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "v2")
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "v3")

        XCTAssertEqual(coordinator.pendingSave(documentID: documentID)?.markdown, "v3")

        await waitUntil(timeout: 5) {
            self.isSaved(coordinator.state(for: self.documentID)) && self.savesInFlight(log) == 2
        }

        // v1 saved, v2 dropped by coalescing, v3 saved as the follow-up.
        XCTAssertEqual(savesInFlight(log), 2)
        XCTAssertNil(coordinator.pendingSave(documentID: documentID))
        XCTAssertNil(draftStore.draft(for: documentID))
    }

    func testReenqueueingIdenticalContentWhileInFlightSkipsFollowUp() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log, saveDelay: 0.2)
        let (coordinator, _, _) = makeCoordinator()

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "same")
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "same")

        await waitUntil(timeout: 5) { self.isSaved(coordinator.state(for: self.documentID)) }
        await waitAndConfirmNever { self.savesInFlight(log) > 1 }

        XCTAssertEqual(savesInFlight(log), 1)
    }

    func testFailedSaveKeepsDraftAndReportsFailure() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log, contentStatus: 400)
        let (coordinator, draftStore, _) = makeCoordinator()

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Content")

        await waitUntil { self.isFailed(coordinator.state(for: self.documentID)) }

        XCTAssertTrue(isFailed(coordinator.state(for: documentID)))
        XCTAssertEqual(draftStore.draft(for: documentID)?.markdown, "# Content")
    }

    private func isPendingSync(_ state: DocumentSaveCoordinator.DocSaveState) -> Bool {
        if case .pendingSync = state { return true }
        return false
    }

    /// A transient/transport failure (offline) is classified as `.pendingSync`, not
    /// `.failed`: the edit is safely on-device and queued to replay.
    func testTransientSaveFailureBecomesPendingSync() async {
        let (coordinator, draftStore, contentCache) = makeCoordinator()
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Content")
        await waitUntil { self.isPendingSync(coordinator.state(for: self.documentID)) }

        XCTAssertEqual(draftStore.draft(for: documentID)?.markdown, "# Content", "the draft is queued for sync")
        XCTAssertNil(contentCache.content(for: documentID), "a pending-sync save writes no cache entry")
    }

    /// A 5xx is transient too → `.pendingSync`.
    func testServerErrorSaveFailureBecomesPendingSync() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log, contentStatus: 503)
        let (coordinator, _, _) = makeCoordinator()
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Content")
        await waitUntil { self.isPendingSync(coordinator.state(for: self.documentID)) }
    }

    /// An expired session is NOT retryable — it would just fail again — so it stays
    /// a hard `.failed` (the shared client's hook raises the re-login sheet).
    func testSessionExpiredSaveBecomesFailedNotPendingSync() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log, contentStatus: 401)
        let (coordinator, _, _) = makeCoordinator()
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Content")
        await waitUntil { self.isFailed(coordinator.state(for: self.documentID)) }
    }

    /// A queued offline save (`.pendingSync`) whose server copy has moved past the
    /// tolerance window is a conflict, not a stale draft — `syncPendingDrafts` must
    /// preserve it, not discard it.
    func testSyncPendingDraftsKeepsAPendingSyncDraftBeyondTolerance() async {
        let log = RequestRecorder()
        let (coordinator, draftStore, _) = makeCoordinator()
        let futureBody = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "# Co-author", "created_at": "2099-01-01T00:00:00Z", "updated_at": "2099-01-01T00:00:00Z"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") {
                return MockURLProtocol.Stub(
                    statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
            }
            return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: futureBody, error: nil)
        }
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine")
        await waitUntil { self.isPendingSync(coordinator.state(for: self.documentID)) }

        await coordinator.syncPendingDrafts()

        XCTAssertNotNil(
            draftStore.draft(for: documentID),
            "a pending-sync draft beyond tolerance is a conflict — preserved, not discarded")
    }

    /// The primary success path the state enables: an offline save lands in
    /// `.pendingSync`, then `syncPendingDrafts` replays and clears it once the
    /// server is reachable and within tolerance.
    func testPendingSyncDraftResyncsAndClearsWhenWithinTolerance() async {
        let log = RequestRecorder()
        let (coordinator, draftStore, _) = makeCoordinator()
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Content")
        await waitUntil { self.isPendingSync(coordinator.state(for: self.documentID)) }
        XCTAssertNotNil(draftStore.draft(for: documentID))

        // Reconnect: the server (2026-01-15) is older than the "now" draft → within
        // tolerance → replay and clear.
        stubSavePipeline(log: log)
        await coordinator.syncPendingDrafts()
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
        XCTAssertNil(draftStore.draft(for: documentID), "the queued offline edit synced and cleared")
    }

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

    func testDocumentsSaveIndependently() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, _, _) = makeCoordinator()

        coordinator.enqueue(documentID: documentID, title: "A", markdown: "a")
        coordinator.enqueue(documentID: otherDocumentID, title: "B", markdown: "b")

        await waitUntil {
            self.isSaved(coordinator.state(for: self.documentID))
                && self.isSaved(coordinator.state(for: self.otherDocumentID))
        }

        XCTAssertTrue(isSaved(coordinator.state(for: documentID)))
        XCTAssertTrue(isSaved(coordinator.state(for: otherDocumentID)))
    }

    func testRecoverDraftsReplaysDraftNewerThanServer() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, draftStore, _) = makeCoordinator()
        // Server updated_at is 2026-01-15; a draft written "now" is newer.
        draftStore.save(PendingDraft(documentID: documentID, title: "Doc", markdown: "# Draft", updatedAt: Date()))

        await coordinator.recoverDrafts()
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        XCTAssertTrue(isSaved(coordinator.state(for: documentID)))
        XCTAssertGreaterThanOrEqual(savesInFlight(log), 1)
        XCTAssertNil(draftStore.draft(for: documentID))
    }

    func testRecoverDraftsPreservesTheBaselineOnReplay() async {
        let log = RequestRecorder()
        // Hold the content PATCH open so the replayed draft can be read in flight.
        stubSavePipeline(log: log, saveDelay: 0.3)
        let (coordinator, draftStore, _) = makeCoordinator()
        // No older than the 2026-01-15 fixture, so `draftSyncDecision` rule 2 pushes
        // (the server has not moved past the baseline) and re-enqueues the draft —
        // where we can verify the baseline is carried through.
        let serverDate = Date(timeIntervalSince1970: 1_800_000_000)
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Draft", updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: serverDate, markdown: "# Server base")))

        await coordinator.recoverDrafts()

        let baseline = draftStore.draft(for: documentID)?.baseline
        XCTAssertEqual(baseline?.markdown, "# Server base", "the replayed draft keeps its baseline")
        XCTAssertEqual(baseline?.serverUpdatedAt, serverDate)
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
    }

    func testRecoverDraftsDiscardsDraftOlderThanServer() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, draftStore, _) = makeCoordinator()
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Stale", updatedAt: Date(timeIntervalSince1970: 0)))

        await coordinator.recoverDrafts()

        XCTAssertNil(draftStore.draft(for: documentID))
        XCTAssertEqual(savesInFlight(log), 0)
    }

    func testRecoverDraftsDropsDraftForInaccessibleDocument() async {
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 404, headers: [:], body: Data(), error: nil)
        }
        let (coordinator, draftStore, _) = makeCoordinator()
        draftStore.save(PendingDraft(documentID: documentID, title: "Doc", markdown: "# Gone", updatedAt: Date()))

        await coordinator.recoverDrafts()

        XCTAssertNil(draftStore.draft(for: documentID))
        XCTAssertEqual(savesInFlight(log), 0)
    }

    func testRecoverDraftsRunsOnlyOnce() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, draftStore, _) = makeCoordinator()
        draftStore.save(PendingDraft(documentID: documentID, title: "Doc", markdown: "# Draft", updatedAt: Date()))

        await coordinator.recoverDrafts()
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
        let savesAfterFirstRecovery = savesInFlight(log)

        await coordinator.recoverDrafts()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(savesInFlight(log), savesAfterFirstRecovery)
    }

    /// Unlike `recoverDrafts()` (once per process), `syncPendingDrafts()` is
    /// repeatable — the funnel for the reconnect/foreground triggers. A draft left
    /// behind by an offline sync must replay on the next call.
    func testSyncPendingDraftsIsRepeatable() async {
        let log = RequestRecorder()
        let (coordinator, draftStore, _) = makeCoordinator()
        draftStore.save(PendingDraft(documentID: documentID, title: "Doc", markdown: "# Draft", updatedAt: Date()))

        // Offline: the fetch fails, so the draft is left for later.
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return MockURLProtocol.Stub(
                statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        await coordinator.syncPendingDrafts()
        XCTAssertNotNil(draftStore.draft(for: documentID), "an offline sync leaves the draft")
        XCTAssertEqual(savesInFlight(log), 0)

        // Reconnect: a second sync replays it (recoverDrafts would be a no-op here).
        stubSavePipeline(log: log)
        await coordinator.syncPendingDrafts()
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
        XCTAssertGreaterThanOrEqual(savesInFlight(log), 1)
        XCTAssertNil(draftStore.draft(for: documentID))
    }

    /// Overlapping sync triggers (a foreground coinciding with a reconnect) must
    /// not double-replay: the second call no-ops while the first is in flight.
    func testSyncPendingDraftsIsReentrant() async {
        let log = RequestRecorder()
        let (coordinator, draftStore, _) = makeCoordinator()
        draftStore.save(PendingDraft(documentID: documentID, title: "Doc", markdown: "# Draft", updatedAt: Date()))
        let formattedBody = Self.formattedBody
        // Hold the GET open so the first sync is still awaiting it when the second
        // starts and sees the re-entrancy guard set.
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: formattedBody, error: nil, delay: 0.3)
            }
            return MockURLProtocol.Stub(statusCode: 204, headers: [:], body: Data(), error: nil)
        }

        async let first: Void = coordinator.syncPendingDrafts()
        async let second: Void = coordinator.syncPendingDrafts()
        _ = await (first, second)
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        // Exactly one replay — the draft was fetched once, not twice.
        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "formatted-content"), 1)
        XCTAssertEqual(savesInFlight(log), 1)
    }

    /// A save that FAILED this session leaves a `.failed` state and its draft (the
    /// user's only copy). Firing `syncPendingDrafts()` mid-session must NOT
    /// tolerance-discard it even when the server has moved far past the draft —
    /// that would silently delete visible content the retry affordance still owns.
    func testSyncPendingDraftsSkipsAFailedSaveDraft() async {
        let log = RequestRecorder()
        let (coordinator, draftStore, _) = makeCoordinator()
        // Far-future server updated_at: the raw tolerance rule WOULD discard the draft.
        let futureBody = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "# Co-author", "created_at": "2099-01-01T00:00:00Z", "updated_at": "2099-01-01T00:00:00Z"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") {
                return MockURLProtocol.Stub(statusCode: 400, headers: [:], body: Data(), error: nil)
            }
            return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: futureBody, error: nil)
        }
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine")
        await waitUntil {
            if case .failed = coordinator.state(for: self.documentID) { return true }
            return false
        }
        XCTAssertNotNil(draftStore.draft(for: documentID))

        await coordinator.syncPendingDrafts()

        XCTAssertNotNil(
            draftStore.draft(for: documentID), "a failed-save draft is never tolerance-discarded mid-session")
        // Sync skipped it before any fetch.
        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "formatted-content"), 0)
    }

    func testSaveSuccessWritesContentCacheEntry() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, _, contentCache) = makeCoordinator(backgroundTasks: .noop)

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Content")
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        let entry = contentCache.content(for: documentID)
        XCTAssertEqual(entry?.title, "Doc")
        XCTAssertEqual(entry?.markdown, "# Content")
        XCTAssertNotNil(entry?.syncedAt)
        // Void PATCHes return no server timestamp, so the write-through must record
        // nil here (not the client clock) — the clock-mixing guard this stack rests on.
        XCTAssertNil(entry?.serverUpdatedAt)
    }

    func testSaveFailureWritesNoContentCacheEntry() async {
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 400, headers: [:], body: Data(), error: nil)
        }
        let (coordinator, _, contentCache) = makeCoordinator(backgroundTasks: .noop)

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Content")
        await waitUntil {
            if case .failed = coordinator.state(for: self.documentID) { return true }
            return false
        }

        XCTAssertNil(contentCache.content(for: documentID))
    }

    func testDiscardStoredDraftRemovesOnlyIfUnchanged() {
        let (coordinator, draftStore, _) = makeCoordinator(backgroundTasks: .noop)
        let original = PendingDraft(
            documentID: documentID, title: "A", markdown: "a", updatedAt: Date(timeIntervalSince1970: 100))
        draftStore.save(original)

        // Draft changed since the caller captured it: keep the newer one.
        let newer = PendingDraft(
            documentID: documentID, title: "B", markdown: "b", updatedAt: Date(timeIntervalSince1970: 200))
        draftStore.save(newer)
        coordinator.discardStoredDraft(original)
        XCTAssertEqual(draftStore.draft(for: documentID), newer)

        // Unchanged: removed.
        coordinator.discardStoredDraft(newer)
        XCTAssertNil(draftStore.draft(for: documentID))
    }

    func testDiscardPendingWorkDropsDraft() {
        let (coordinator, draftStore, _) = makeCoordinator(backgroundTasks: .noop)
        draftStore.save(PendingDraft(documentID: documentID, title: "A", markdown: "a", updatedAt: Date()))
        coordinator.discardPendingWork(documentID: documentID)
        XCTAssertNil(draftStore.draft(for: documentID))
    }

    /// A delete purges the local copy, but an in-flight save can land *after* it —
    /// and `finish`'s success path write-throughs the content cache, recreating the
    /// entry the delete just removed. Nothing purges it again, so a deleted document
    /// keeps rendering its full body from retained Search/Shared results.
    func testSaveLandingAfterADeleteNeverRecreatesTheCacheEntry() async {
        let log = RequestRecorder()
        let (coordinator, draftStore, contentCache) = makeCoordinator(backgroundTasks: .noop)
        stubSavePipeline(log: log, saveDelay: 0.2)
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine")

        // The delete happens while the save's PATCH is still on the wire.
        contentCache.remove(documentID: documentID)
        coordinator.discardPendingWork(documentID: documentID)

        await waitUntil { coordinator.state(for: self.documentID) != .saving }

        XCTAssertNil(contentCache.content(for: documentID), "a deleted document keeps no local copy")
        XCTAssertNil(draftStore.draft(for: documentID))
    }

    /// A 404/403 purges the local copy too — and an in-flight save landing after it
    /// would write the full body straight back into the cache (a privacy problem on
    /// a 403: the content is revoked, not deleted). Unlike a delete, the draft is
    /// the user's only copy of unsaved work and must survive.
    /// A save whose PATCH **failed** leaves the draft: it is the user's only copy.
    func testSuppressedWriteThroughSkipsTheCacheAndKeepsAnUnsavedDraft() async {
        let log = RequestRecorder()
        let (coordinator, draftStore, contentCache) = makeCoordinator(backgroundTasks: .noop)
        stubSavePipeline(log: log, saveDelay: 0.2, contentStatus: 400)
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine")

        // The document becomes unavailable while the save's PATCH is on the wire.
        contentCache.remove(documentID: documentID)
        coordinator.suppressLocalWriteThrough(documentID: documentID)

        await waitUntil { coordinator.state(for: self.documentID) != .saving }

        XCTAssertNil(contentCache.content(for: documentID), "a revoked document keeps no local body")
        XCTAssertEqual(draftStore.draft(for: documentID)?.markdown, "# Mine", "unsaved work survives")
    }

    /// A save whose PATCH **landed** is not unsaved work. Keeping its draft lets the
    /// editor's stranded-draft replay push already-acknowledged bytes back over a
    /// co-author's newer write — and leaves a revoked document's body in UserDefaults.
    func testSuppressedWriteThroughDropsADraftTheServerConfirmed() async {
        let log = RequestRecorder()
        let (coordinator, draftStore, contentCache) = makeCoordinator(backgroundTasks: .noop)
        stubSavePipeline(log: log, saveDelay: 0.2)  // 204: the PATCH lands
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine")

        contentCache.remove(documentID: documentID)
        coordinator.suppressLocalWriteThrough(documentID: documentID)

        await waitUntil { coordinator.state(for: self.documentID) != .saving }

        XCTAssertNil(contentCache.content(for: documentID), "still no local body")
        XCTAssertNil(draftStore.draft(for: documentID), "the server has it; it is not unsaved work")
    }

    // MARK: - Save markers (raced-revalidation detection)

    func testSaveMarkerWithNoSaveActivityDoesNotPredate() {
        let (coordinator, _, _) = makeCoordinator(backgroundTasks: .noop)
        let marker = coordinator.saveMarker(documentID: documentID)
        XCTAssertFalse(coordinator.mayPredateSave(marker))
    }

    func testSaveMarkerTakenWhileASaveIsInFlightPredates() async {
        let log = RequestRecorder()
        let (coordinator, _, _) = makeCoordinator(backgroundTasks: .noop)
        stubSavePipeline(log: log, saveDelay: 0.2)
        coordinator.enqueue(documentID: documentID, title: "A", markdown: "a")

        let marker = coordinator.saveMarker(documentID: documentID)

        XCTAssertTrue(coordinator.mayPredateSave(marker), "in flight when the marker was taken")
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
        XCTAssertTrue(coordinator.mayPredateSave(marker), "still true once it lands")
    }

    /// The case a "was a save pending?" boolean alone would miss: no save existed
    /// when the fetch was issued, but one started *and settled* while it awaited.
    func testSaveMarkerPredatesASaveThatStartedAndSettledAfterIt() async {
        let log = RequestRecorder()
        let (coordinator, _, _) = makeCoordinator(backgroundTasks: .noop)
        stubSavePipeline(log: log)
        let marker = coordinator.saveMarker(documentID: documentID)
        XCTAssertFalse(coordinator.mayPredateSave(marker))

        coordinator.enqueue(documentID: documentID, title: "A", markdown: "a")
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        XCTAssertTrue(coordinator.mayPredateSave(marker))
    }

    func testSaveMarkerPredatesAFailedSaveToo() async {
        let log = RequestRecorder()
        let (coordinator, _, _) = makeCoordinator(backgroundTasks: .noop)
        stubSavePipeline(log: log, contentStatus: 400)
        let marker = coordinator.saveMarker(documentID: documentID)

        coordinator.enqueue(documentID: documentID, title: "A", markdown: "a")
        await waitUntil {
            if case .failed = coordinator.state(for: self.documentID) { return true }
            return false
        }

        XCTAssertTrue(
            coordinator.mayPredateSave(marker),
            "a failed content PATCH may still have been applied server-side before it errored")
    }

    func testSaveMarkerIsPerDocument() async {
        let log = RequestRecorder()
        let (coordinator, _, _) = makeCoordinator(backgroundTasks: .noop)
        let otherID = UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!
        stubSavePipeline(log: log)
        let marker = coordinator.saveMarker(documentID: otherID)

        coordinator.enqueue(documentID: documentID, title: "A", markdown: "a")
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        XCTAssertFalse(coordinator.mayPredateSave(marker), "another document's save is irrelevant")
    }
}
