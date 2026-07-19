import XCTest

@testable import Schrift

/// Captures the JSON of every `PATCH …/content/` body, so a live-snapshot test can prove
/// the base64 bytes and the `"websocket": true` flag actually went out. Lock-guarded
/// because stubs are delivered on URLSession's protocol thread.
private final class ContentPatchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [[String: Any]] = []

    func record(_ request: URLRequest) {
        guard request.httpMethod == "PATCH",
            request.url?.absoluteString.hasSuffix("/content/") == true,
            let data = bodyData(from: request),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        lock.lock()
        defer { lock.unlock() }
        bodies.append(json)
    }

    var contentValues: [String] {
        lock.lock()
        defer { lock.unlock() }
        return bodies.compactMap { $0["content"] as? String }
    }

    var websocketFlags: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return bodies.map { $0["websocket"] as? Bool ?? false }
    }
}

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
        XCTAssertNil(
            coordinator.pendingSave(documentID: documentID),
            "the work the hold was parking must actually be sent, not stranded forever")
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

    /// The no-regression half: a draft written before the baseline carried a title decodes
    /// with `title == nil`. There is nothing to compare against, so it behaves exactly as it
    /// did — the draft's own title is pushed, and no conflict is invented.
    func testALegacyBaselineWithoutATitlePushesTheDraftTitleUnchanged() async {
        let titles = PatchedTitleRecorder()
        let renamedBody = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Renamed on the web", "content": "# Base", "created_at": "2099-01-01T00:00:00Z", "updated_at": "2099-01-01T00:00:00Z"}
            """.utf8)
        let (coordinator, draftStore, _) = makeCoordinator()
        MockURLProtocol.stubHandler = { request in
            titles.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: renamedBody, error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Old title", markdown: "# Mine", updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 0), markdown: "# Base")))

        await coordinator.syncPendingDrafts()
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        XCTAssertNil(coordinator.conflict(for: documentID))
        XCTAssertEqual(titles.last, "Old title", "a titleless baseline keeps today's behavior exactly")
    }

    /// **The rename bug.** A save PATCHes content *and* title, so a replay that pushes the
    /// title its draft was made with silently reverts a rename made on the web — and a
    /// rename leaves the body untouched, which is exactly the body-equality `.push` above.
    /// With the server's title on the baseline, the replay adopts it instead: title and
    /// body are independent fields, so a one-sided rename is a merge, not a dialog.
    func testAReplayAdoptsARemoteRenameInsteadOfRevertingIt() async {
        let titles = PatchedTitleRecorder()
        let renamedBody = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Renamed on the web", "content": "# Base", "created_at": "2099-01-01T00:00:00Z", "updated_at": "2099-01-01T00:00:00Z"}
            """.utf8)
        let (coordinator, draftStore, _) = makeCoordinator()
        MockURLProtocol.stubHandler = { request in
            titles.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: renamedBody, error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        // The user edited the body offline and never touched the title.
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Old title", markdown: "# Mine", updatedAt: Date(),
                baseline: DraftBaseline(
                    serverUpdatedAt: Date(timeIntervalSince1970: 0), markdown: "# Base", title: "Old title")))

        await coordinator.syncPendingDrafts()
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        XCTAssertNil(coordinator.conflict(for: documentID), "a rename the user didn't make is merged, not dialogued")
        XCTAssertEqual(
            titles.last, "Renamed on the web",
            "the replay must PATCH the server's title — pushing the draft's reverts the co-author's rename")
    }

    /// The user's own rename, against a server that never touched the title, is just an
    /// edit being replayed — it must reach the server, not be second-guessed.
    func testAReplayPushesTheUsersOwnRenameWhenTheServerDidNotRename() async {
        let titles = PatchedTitleRecorder()
        let serverBody = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Old title", "content": "# Base", "created_at": "2099-01-01T00:00:00Z", "updated_at": "2099-01-01T00:00:00Z"}
            """.utf8)
        let (coordinator, draftStore, _) = makeCoordinator()
        MockURLProtocol.stubHandler = { request in
            titles.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: serverBody, error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "My new title", markdown: "# Mine", updatedAt: Date(),
                baseline: DraftBaseline(
                    serverUpdatedAt: Date(timeIntervalSince1970: 0), markdown: "# Base", title: "Old title")))

        await coordinator.syncPendingDrafts()
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        XCTAssertNil(coordinator.conflict(for: documentID))
        XCTAssertEqual(titles.last, "My new title", "the user's rename is the edit being replayed")
    }

    /// A save in flight carries its own title, and nothing here has reconciled *that* against
    /// the server — so adopting must leave it (and its draft) alone.
    func testAdoptingAServerTitleIsIgnoredWhileASaveIsInFlight() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log, saveDelay: 0.3)
        let (coordinator, draftStore, _) = makeCoordinator()
        coordinator.enqueue(documentID: documentID, title: "Old title", markdown: "# Mine")
        await waitUntil { self.savesInFlight(log) >= 1 }

        coordinator.adoptServerTitle(documentID: documentID, title: "Renamed on the web")

        XCTAssertEqual(
            draftStore.draft(for: documentID)?.title, "Old title",
            "the in-flight save's draft is not rewritten under it")
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
    }

    /// Adopting is **observation, not a push**: the caller may be holding a draft whose save
    /// failed, which is the user's to retry. It must rewrite the draft's title and nothing
    /// else — and start no save.
    func testAdoptingAServerTitleRewritesOnlyTheTitleAndStartsNoSave() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, draftStore, _) = makeCoordinator()
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let baseline = DraftBaseline(
            serverUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000), markdown: "# Base", title: "Old title")
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Old title", markdown: "# Mine", updatedAt: updatedAt,
                baseline: baseline, lastPushedMarkdown: "# Pushed earlier"))

        coordinator.adoptServerTitle(documentID: documentID, title: "Renamed on the web")

        let draft = draftStore.draft(for: documentID)
        XCTAssertEqual(draft?.title, "Renamed on the web")
        XCTAssertEqual(draft?.markdown, "# Mine", "the body is never touched — a title is not content")
        XCTAssertEqual(draft?.updatedAt, updatedAt)
        XCTAssertEqual(
            draft?.lastPushedMarkdown, "# Pushed earlier",
            "dropping this would re-break rule 1 — a false conflict against the user's own write")
        XCTAssertEqual(
            draft?.baseline?.title, "Renamed on the web",
            "the draft now descends from that server title — see adoptedBaseline")
        XCTAssertEqual(draft?.baseline?.markdown, "# Base", "…but its body still descends from the same state")
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }
        XCTAssertEqual(coordinator.state(for: documentID), .idle, "observing a rename is not a save")
    }

    func testAdoptingAServerTitleWithNoStoredDraftCreatesNone() {
        let (coordinator, draftStore, _) = makeCoordinator()

        coordinator.adoptServerTitle(documentID: documentID, title: "Renamed on the web")

        XCTAssertNil(draftStore.draft(for: documentID), "there is no unsaved work to retitle")
    }

    func testDiscardPendingWorkClearsTheKnownServerTitle() {
        let (coordinator, _, _) = makeCoordinator()
        coordinator.noteServerTitle(documentID: documentID, title: "Doc")

        coordinator.discardPendingWork(documentID: documentID)

        XCTAssertNil(coordinator.knownServerTitle(documentID: documentID), "the document is gone")
    }

    /// "Keep mine" on a **title** conflict has to stick exactly as it does on a body one: the
    /// released push usually fails (a conflict is reviewed on the connection that caused it),
    /// and the surviving draft must not re-detect the identical conflict on the next sync —
    /// the user's answer would evaporate and they would be asked forever.
    func testKeepingMineOnATitleConflictSticksAcrossAFailedPush() async {
        let log = RequestRecorder()
        let titles = PatchedTitleRecorder()
        let renamed = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Their title", "content": "# Base", "created_at": "2099-01-01T00:00:00Z", "updated_at": "2099-01-01T00:00:00Z"}
            """.utf8)
        let (coordinator, draftStore, _) = makeCoordinator()
        // The push fails (offline); the GET keeps working.
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            titles.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: renamed, error: nil)
            }
            return .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        // Both renamed, differently; the bodies agree — only the titles conflict.
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "My title", markdown: "# Base", updatedAt: Date(),
                baseline: DraftBaseline(
                    serverUpdatedAt: Date(timeIntervalSince1970: 0), markdown: "# Base", title: "Old title")))

        await coordinator.syncPendingDrafts()
        XCTAssertNotNil(coordinator.conflict(for: documentID), "two different renames")

        // They keep theirs — and the released push fails, which is the *common* case: a
        // conflict is reviewed on the same flaky connection that produced it.
        coordinator.resolveConflictKeepingLocal(documentID: documentID)
        await waitUntil {
            if case .pendingSync = coordinator.state(for: self.documentID) { return true }
            return false
        }
        let draft = draftStore.draft(for: documentID)
        XCTAssertEqual(draft?.title, "My title", "their answer survives on the draft")
        XCTAssertEqual(
            draft?.baseline?.title, "Old title",
            "the baseline still records what the SERVER held — writing their title into it would make "
                + "the next reconcile mistake the server's title for a rename and adopt it back over theirs")
        XCTAssertNil(coordinator.conflict(for: documentID), "the record is cleared by the resolution")

        // The connection comes back and the sync trigger fires again (reconnect/foreground).
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            titles.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: renamed, error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        await coordinator.syncPendingDrafts()
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        XCTAssertNil(
            coordinator.conflict(for: documentID),
            "the answered conflict must not be re-raised — the user's answer would evaporate and they "
                + "would be asked the same question forever")
        XCTAssertEqual(titles.last, "My title", "and the retry finally pushes the title they chose")
    }

    /// Both sides renamed, differently: there is no merge that keeps both, so it takes the
    /// same funnel a body conflict does — the push is held and the pill asks the user. The
    /// bodies are identical here, so nothing but the titles can raise it.
    func testTwoDifferentRenamesConflictInsteadOfPushing() async {
        let log = RequestRecorder()
        let titles = PatchedTitleRecorder()
        let renamedBody = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Their title", "content": "# Base", "created_at": "2099-01-01T00:00:00Z", "updated_at": "2099-01-01T00:00:00Z"}
            """.utf8)
        let (coordinator, draftStore, _) = makeCoordinator()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            titles.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: renamedBody, error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        // The user renamed it too, offline, to something else.
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "My title", markdown: "# Base", updatedAt: Date(),
                baseline: DraftBaseline(
                    serverUpdatedAt: Date(timeIntervalSince1970: 0), markdown: "# Base", title: "Old title")))

        await coordinator.syncPendingDrafts()

        XCTAssertNotNil(coordinator.conflict(for: documentID), "two different renames are a genuine conflict")
        XCTAssertNotNil(draftStore.draft(for: documentID), "the draft waits for the user's choice")
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }  // a save is an unstructured Task
        XCTAssertTrue(titles.all.isEmpty, "a conflict never PATCHes a title")
    }

    // MARK: - Live-snapshot save (C2b)

    /// A queued live snapshot routes to `saveLiveSnapshot`: the content PATCH carries the
    /// exact snapshot bytes AND `"websocket": true`, then a title PATCH follows.
    func testEnqueueLiveSnapshotRoutesToSaveLiveSnapshot() async {
        let bodies = ContentPatchRecorder()
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            bodies.record(request)
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        let (coordinator, _, _) = makeCoordinator()
        let snapshot = Data([0xAA, 0xBB, 0xCC])

        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: snapshot, projectedMarkdown: "# Body", title: "Doc")

        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
        XCTAssertEqual(log.methods, ["PATCH", "PATCH"], "content then title")
        XCTAssertEqual(bodies.contentValues, [snapshot.base64EncodedString()], "the snapshot bytes are sent verbatim")
        XCTAssertEqual(bodies.websocketFlags, [true], "the content PATCH is tagged websocket:true")
    }

    /// A classic `enqueue` must NOT leak the live flag — its content PATCH carries no
    /// `"websocket"` key, and its bytes are the markdown-derived Yjs update, not the raw
    /// projected markdown.
    func testClassicEnqueueStillRoutesToSaveDocumentContentWithNoWebsocketFlag() async {
        let bodies = ContentPatchRecorder()
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            bodies.record(request)
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        let (coordinator, _, _) = makeCoordinator()

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Content")

        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
        XCTAssertEqual(bodies.websocketFlags, [false], "a classic save never carries the live-collab flag")
        // A real Yjs v1 update begins with the client-count varUint 0x01 — NOT the raw markdown.
        let sent = bodies.contentValues.first.flatMap { Data(base64Encoded: $0) }
        XCTAssertEqual(sent?.first, 0x01, "the classic path still sends MarkdownYjs.encode output")
    }

    /// Write-ahead: `enqueueLiveSnapshot` persists a draft carrying the **projected
    /// markdown** as its body and the supplied baseline, before the save completes — so the
    /// whole reconcile/replay machinery keys off the projected markdown, never the bytes.
    func testEnqueueLiveSnapshotWritesTheDraftWithProjectedMarkdownAndBaseline() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log, saveDelay: 0.3)  // hold the save open so we can read the draft
        let (coordinator, draftStore, _) = makeCoordinator()
        let baseline = DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 0), markdown: "# Base", title: "Doc")

        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0x09]), projectedMarkdown: "# Projected", title: "Doc",
            baseline: baseline)

        let draft = draftStore.draft(for: documentID)
        XCTAssertEqual(draft?.markdown, "# Projected", "the draft body is the projected markdown, not the bytes")
        XCTAssertEqual(draft?.title, "Doc")
        XCTAssertEqual(draft?.baseline, baseline, "the baseline is threaded through unchanged")
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
    }

    /// On live-snapshot success, `lastConfirmedPushMarkdown` is stamped with the **projected
    /// markdown** — so a later classic reconcile recognises the server as holding our body
    /// (rule 1) and never raises a conflict against our own live write.
    func testLiveSnapshotSuccessStampsLastConfirmedPushWithProjectedMarkdown() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, _, _) = makeCoordinator()

        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0x01, 0x02]), projectedMarkdown: "# Projected", title: "Doc")

        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
        XCTAssertEqual(
            coordinator.lastConfirmedPush(documentID: documentID), "# Projected",
            "the projected markdown is what the server is known to hold")
    }

    /// Enqueue-hold applies to the live path too: while a conflict is recorded, a queued live
    /// snapshot writes its draft but starts NO save (an autosave must never push over the
    /// conflicting server copy unasked), and the state degrades to `.pendingSync`.
    func testLiveSnapshotIsHeldWhileAConflictIsRecorded() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, draftStore, _) = makeCoordinator()
        coordinator.recordConflict(documentID: documentID, serverUpdatedAt: Date(timeIntervalSince1970: 100))

        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0x07]), projectedMarkdown: "# Held", title: "Doc")

        await waitAndConfirmNever { self.savesInFlight(log) > 0 }  // a save is an unstructured Task
        XCTAssertEqual(coordinator.state(for: documentID), .pendingSync, "a held live save is not a saved save")
        XCTAssertEqual(draftStore.draft(for: documentID)?.markdown, "# Held", "the write-ahead draft still lands")
        XCTAssertEqual(coordinator.pendingSave(documentID: documentID)?.markdown, "# Held", "it sits in the hold")
    }

    /// Latest-wins coalescing applies to the live path: three snapshots queued behind an
    /// in-flight save collapse to the newest, which is the only one that reaches the wire.
    func testLiveSnapshotCoalescesToLatestWhileInFlight() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log, saveDelay: 0.2)
        let (coordinator, _, _) = makeCoordinator()

        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0x01]), projectedMarkdown: "v1", title: "Doc")
        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0x02]), projectedMarkdown: "v2", title: "Doc")
        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0x03]), projectedMarkdown: "v3", title: "Doc")

        XCTAssertEqual(coordinator.pendingSave(documentID: documentID)?.markdown, "v3")

        await waitUntil(timeout: 5) { self.isSaved(coordinator.state(for: self.documentID)) }
        // Two saves total (the first, then the coalesced v3), each one content PATCH.
        XCTAssertEqual(savesInFlight(log), 2)
        XCTAssertEqual(coordinator.lastConfirmedPush(documentID: documentID), "v3")
    }

    // MARK: - Live-snapshot inherits the coordinator invariants (C2b Task 3)
    //
    // `saveLiveSnapshot` and `saveDocumentContent` share the identical half-land contract
    // (a THROW means the content PATCH never confirmed; a non-nil `DocsAPIError` RETURN means
    // it landed but the title PATCH failed) — see `DocumentSaveCoordinator.start`, which is the
    // one piece of code both paths share below the public entry points. These tests pin that
    // contract for the live path specifically, so a future change that special-cases
    // `save.liveSnapshot` inside `start`/`finish` cannot silently break it.

    /// Half-land, `contentLanded == false`: the content PATCH itself fails transiently
    /// (offline), so `saveLiveSnapshot` THROWS before it can even attempt the title PATCH.
    /// `finish` must NOT stamp `lastPushedMarkdown` — the server never confirmed holding this
    /// body, and stamping it would tell the next replay we pushed content we never actually
    /// sent, masking a real conflict against whatever the server actually holds.
    func testLiveSnapshotContentFailureIsRetryableAndLeavesThePushUnstamped() async {
        let (coordinator, draftStore, contentCache) = makeCoordinator()
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0x0A]), projectedMarkdown: "# Unconfirmed", title: "Doc")

        await waitUntil { self.isPendingSync(coordinator.state(for: self.documentID)) }

        XCTAssertEqual(
            draftStore.draft(for: documentID)?.markdown, "# Unconfirmed", "the unsent edit stays safely on-device")
        XCTAssertNil(
            draftStore.draft(for: documentID)?.lastPushedMarkdown,
            "the content PATCH never confirmed landing (`saveLiveSnapshot` threw) — the push must not be "
                + "recorded, or the next replay would wrongly believe the server already holds this body")
        XCTAssertNil(contentCache.content(for: documentID), "a pending-sync save writes no cache entry")
    }

    /// Same throw path, a 5xx cause: `retryableSaveFailure` classifies a live snapshot exactly
    /// like a classic save (mirrors `testServerErrorSaveFailureBecomesPendingSync`).
    func testLiveSnapshotServerErrorContentFailureBecomesPendingSync() async {
        let log = RequestRecorder()
        let (coordinator, _, _) = makeCoordinator()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") {
                return .init(statusCode: 503, headers: [:], body: Data(), error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: Data(), error: nil)
        }

        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0x0B]), projectedMarkdown: "# Retry me", title: "Doc")

        await waitUntil { self.isPendingSync(coordinator.state(for: self.documentID)) }

        // `saveLiveSnapshot` PATCHes content first and throws before attempting the title
        // PATCH, so exactly one request should have reached the stub — the failed content one.
        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: "/content/"), 1)
        XCTAssertEqual(log.count(ofMethod: "PATCH"), 1, "the content PATCH throws before a title PATCH is attempted")
    }

    /// The mirror classification: a content PATCH the server rejects on the merits (never a
    /// transport/5xx problem) is `.failed`, not `.pendingSync` — and, being a throw, must still
    /// leave the push unstamped (mirrors `testFailedSaveKeepsDraftAndReportsFailure`, for the
    /// live path).
    func testLiveSnapshotServerRejectedContentBecomesFailedNotPendingSync() async {
        let log = RequestRecorder()
        let (coordinator, draftStore, _) = makeCoordinator()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") {
                return .init(statusCode: 400, headers: [:], body: Data(), error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: Data(), error: nil)
        }

        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0x0C]), projectedMarkdown: "# Rejected", title: "Doc")

        await waitUntil { self.isFailed(coordinator.state(for: self.documentID)) }
        XCTAssertEqual(draftStore.draft(for: documentID)?.markdown, "# Rejected")
        XCTAssertNil(
            draftStore.draft(for: documentID)?.lastPushedMarkdown,
            "the content PATCH was rejected outright (never landed) — the push must not be recorded")
        // A rejected content PATCH throws before the title PATCH is attempted — same
        // half-land short-circuit as the transient case above.
        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: "/content/"), 1)
        XCTAssertEqual(log.count(ofMethod: "PATCH"), 1, "the content PATCH throws before a title PATCH is attempted")
    }

    /// Half-land, `contentLanded == true`: the content PATCH lands (204) but the title PATCH is
    /// rejected on the merits, so `saveLiveSnapshot` RETURNS a non-nil `DocsAPIError` instead of
    /// throwing. The server now holds this exact body, so the push must be recorded even though
    /// the save as a whole reports `.failed` (mirrors `testANonRetryableHalfLandedSaveStillRecordsThePush`).
    func testLiveSnapshotHalfLandRecordsThePushWhenOnlyTheTitleIsRejected() async {
        let log = RequestRecorder()
        let (coordinator, draftStore, _) = makeCoordinator()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") {
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
            }
            if request.httpMethod == "PATCH" {
                return .init(statusCode: 400, headers: [:], body: Data(), error: nil)  // title rejected
            }
            return .init(statusCode: 200, headers: [:], body: Data(), error: nil)
        }

        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0x0D]), projectedMarkdown: "# Half-landed", title: "Doc")

        await waitUntil { self.isFailed(coordinator.state(for: self.documentID)) }
        XCTAssertEqual(
            draftStore.draft(for: documentID)?.lastPushedMarkdown, "# Half-landed",
            "the content PATCH landed (`saveLiveSnapshot` returned a non-nil error, not a throw) — the push "
                + "must be recorded even though the save as a whole failed")
    }

    /// A live snapshot must bump `settledSaves` on settle exactly like a classic save, or a
    /// revalidation fetch issued just before it would not be recognised as possibly racing it —
    /// `mayPredateSave` would wrongly clear a marker that in fact predates a landed live write.
    func testLiveSnapshotSaveMarkerBumpsSettledSavesOnSettle() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, _, _) = makeCoordinator()
        let marker = coordinator.saveMarker(documentID: documentID)
        XCTAssertFalse(coordinator.mayPredateSave(marker))

        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0x0E]), projectedMarkdown: "# Marked", title: "Doc")
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        XCTAssertTrue(
            coordinator.mayPredateSave(marker),
            "the live snapshot must bump `settledSaves` on settle exactly like a classic save")
    }

    /// Mirrors `testSaveSuccessWritesContentCacheEntry` for the live path: `finish`'s
    /// content-cache write is not gated on `save.liveSnapshot == nil`, so a landed live
    /// snapshot must write through exactly like a classic save. Pins that against a future
    /// `if save.liveSnapshot == nil` guard slipping in around the cache write.
    func testLiveSnapshotSuccessWritesContentCacheEntry() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, _, contentCache) = makeCoordinator(backgroundTasks: .noop)

        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0x0F]), projectedMarkdown: "# Live Content", title: "Doc")
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        let entry = contentCache.content(for: documentID)
        XCTAssertEqual(entry?.title, "Doc")
        XCTAssertEqual(
            entry?.markdown, "# Live Content", "the cache body is the projected markdown, not the raw snapshot bytes")
        XCTAssertNotNil(entry?.syncedAt)
        XCTAssertNil(entry?.serverUpdatedAt, "a void PATCH carries no server timestamp")
    }

    /// **`releaseHeldSave` must still route through `saveLiveSnapshot`, not reconstruct a
    /// classic save.** A live snapshot held behind a recorded conflict is parked in `queued` as
    /// the exact `PendingSave` it was enqueued with (bytes + `liveSnapshot` intact); when the
    /// user resolves the conflict, `releaseHeldSave` hands that same value straight to `start`.
    /// If it were ever rebuilt from `save.title`/`save.markdown` instead, the released PATCH
    /// would silently re-derive Yjs bytes from the *projected* markdown via `MarkdownYjs.encode`
    /// (wrong bytes) and drop the `"websocket": true` flag the server needs to accept a
    /// full-state snapshot over the live-collaboration channel.
    func testAReleasedHeldLiveSnapshotStillPatchesThroughSaveLiveSnapshot() async {
        let bodies = ContentPatchRecorder()
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            bodies.record(request)
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        let (coordinator, draftStore, _) = makeCoordinator()
        let snapshot = Data([0x11, 0x22])
        coordinator.recordConflict(documentID: documentID, serverUpdatedAt: Date())

        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: snapshot, projectedMarkdown: "# Held", title: "Doc")
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }  // confirm it was held

        coordinator.resolveConflictKeepingLocal(documentID: documentID)

        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
        XCTAssertEqual(
            bodies.contentValues, [snapshot.base64EncodedString()],
            "the released save must carry the ORIGINAL snapshot bytes it was held with")
        XCTAssertEqual(
            bodies.websocketFlags, [true],
            "and it must still be tagged websocket:true — a released hold is not a classic save")
        XCTAssertNil(draftStore.draft(for: documentID))
    }

    /// **`finish`'s plain queued-restart (latest-wins coalescing, no conflict involved) must
    /// also preserve the live-snapshot identity of the coalesced follow-up.** This is a
    /// different code path from the conflict-hold release above: when a second live snapshot
    /// coalesces behind an in-flight one and the first lands, `finish` calls `start` directly
    /// with the queued `PendingSave` — which must still carry `liveSnapshot` bytes and route
    /// through `saveLiveSnapshot`, not silently fall back to re-deriving Yjs from markdown.
    func testACoalescedQueuedRestartOfALiveSnapshotStillCarriesTheWebsocketFlag() async {
        let bodies = ContentPatchRecorder()
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            bodies.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") {
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil, delay: 0.2)
            }
            return .init(statusCode: 200, headers: [:], body: Data(), error: nil)
        }
        let (coordinator, _, _) = makeCoordinator()

        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0x01]), projectedMarkdown: "v1", title: "Doc")
        // Coalesces behind the in-flight v1 (no conflict, so this is `finish`'s plain restart —
        // not `releaseHeldSave`).
        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0x02]), projectedMarkdown: "v2", title: "Doc")

        await waitUntil(timeout: 5) {
            self.isSaved(coordinator.state(for: self.documentID)) && bodies.websocketFlags.count == 2
        }

        XCTAssertEqual(
            bodies.contentValues, [Data([0x01]).base64EncodedString(), Data([0x02]).base64EncodedString()],
            "the queued restart must carry the coalesced save's OWN snapshot bytes, not re-derive them")
        XCTAssertEqual(
            bodies.websocketFlags, [true, true],
            "both the first save and the coalesced restart must route through `saveLiveSnapshot`")
    }

    // MARK: - Downgrade / reconcile coherence (C2b Task 4)

    /// **Downgrade coherence.** After a live snapshot lands (stamping
    /// `lastConfirmedPushMarkdown = projectedMarkdown`), a stored draft written afterward
    /// carries that stamp, so a later markdown-based reconcile against a server holding the
    /// projected body hits `draftSyncDecision` rule 1 ("the server's most recent writer was
    /// us") — a `.push`, never a false `.conflict` against pre-live state — **even though the
    /// server's `updated_at` is far newer than the draft**. This is what lets C2c fall back
    /// from the live-snapshot path to a classic save without inventing a conflict.
    func testAClassicReconcileAfterALiveSnapshotDoesNotFalseConflict() async {
        let log = RequestRecorder()
        let (coordinator, draftStore, _) = makeCoordinator()

        // 1. A live snapshot lands, rendering "# Body" on the server.
        stubSavePipeline(log: log)
        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0x07]), projectedMarkdown: "# Body", title: "Doc")
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
        XCTAssertEqual(coordinator.lastConfirmedPush(documentID: documentID), "# Body")

        // 2. A later offline edit is queued as a draft, stamped with what the snapshot pushed.
        let lastPushed = coordinator.lastConfirmedPush(documentID: documentID)
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Body edited more", updatedAt: Date(),
                baseline: nil, lastPushedMarkdown: lastPushed))

        // 3. The reconcile sees the server still holding the projected body "# Body" with a far
        //    NEWER updated_at (a pre-live-baseline timestamp would otherwise trip a conflict).
        let serverBody = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "# Body", "created_at": "2099-01-01T00:00:00Z", "updated_at": "2099-01-01T00:00:00Z"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: serverBody, error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)  // content / title PATCH
        }

        await coordinator.syncPendingDrafts()

        XCTAssertNil(
            coordinator.conflict(for: documentID),
            "rule 1 recognises the server body as our own live-snapshot push — never a conflict")
        // `savesInFlight` counts every content PATCH sent by this test, including step 1's live
        // snapshot — so the reconcile's own replay is the SECOND one; waiting on `>= 1` would
        // pass instantly (before the replay's async save even lands) and race the draft-cleared
        // assertion below.
        await waitUntil { self.savesInFlight(log) >= 2 }
        await waitUntil { draftStore.draft(for: self.documentID) == nil }
        XCTAssertNil(draftStore.draft(for: documentID), "the draft replayed and cleared")
    }

}
