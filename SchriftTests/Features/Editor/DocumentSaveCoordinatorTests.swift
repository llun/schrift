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
        stubSavePipeline(log: log, contentStatus: 500)
        let (coordinator, draftStore, _) = makeCoordinator()

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Content")

        await waitUntil { self.isFailed(coordinator.state(for: self.documentID)) }

        XCTAssertTrue(isFailed(coordinator.state(for: documentID)))
        XCTAssertEqual(draftStore.draft(for: documentID)?.markdown, "# Content")
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
        let serverDate = Date(timeIntervalSince1970: 1_700_000_000)
        // Newer than the 2026-01-15 fixture → tolerance replay re-enqueues it.
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
                return MockURLProtocol.Stub(statusCode: 500, headers: [:], body: Data(), error: nil)
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
            MockURLProtocol.Stub(statusCode: 500, headers: [:], body: Data(), error: nil)
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
        stubSavePipeline(log: log, saveDelay: 0.2, contentStatus: 500)
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
        stubSavePipeline(log: log, contentStatus: 500)
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
