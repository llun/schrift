import XCTest

@testable import Schrift

/// The pending-attachment save hold: a body still naming an un-uploaded photo may be written to
/// disk and queued, but never pushed. Every path that can reach `start` is covered here, each
/// with a negative control proving the same flow *does* push once the placeholder is gone —
/// without one, "no PATCH happened" only says the test never provokes a save at all.
@MainActor
final class DocumentSaveCoordinatorAttachmentHoldTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let origin = "https://docs.example.org"
    private let documentID = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!
    private let attachmentID = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!

    private var cacheDirectory: URL!
    private var suiteNames: [String] = []

    private var placeholder: String { pendingAttachmentPlaceholderURL(for: attachmentID) }
    /// A body whose image block still names a queued photo.
    private var heldMarkdown: String { "# Notes\n\n![](\(placeholder))" }
    /// The same body once the upload resolved — the negative control for every test below.
    private var resolvedMarkdown: String { "# Notes\n\n![](https://docs.example.org/media/key.jpg)" }

    private static let formattedBody = Data(
        """
        {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "Server content", \
        "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
        """.utf8)

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachmentHoldTests-\(UUID().uuidString)", isDirectory: true)
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

    /// Every store is injected onto a per-test suite. A half-isolated coordinator (drafts
    /// injected, creates defaulted onto `.standard`) leaks state between tests and can stall the
    /// whole suite on a real network timeout the moment anything mints a record.
    private func makeCoordinator() -> (DocumentSaveCoordinator, PendingDraftStore) {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let name = "AttachmentHoldTests.\(UUID().uuidString)"
        suiteNames.append(name)
        let defaults = UserDefaults(suiteName: name)!
        let drafts = PendingDraftStore(userDefaults: defaults)
        let coordinator = DocumentSaveCoordinator(
            client: client,
            draftStore: drafts,
            contentCache: DocumentContentCacheStore(directory: cacheDirectory),
            createStore: PendingDocumentCreateStore(userDefaults: defaults),
            listCache: DocumentCacheStore(userDefaults: defaults),
            childrenCache: DocumentChildrenCacheStore(userDefaults: defaults),
            serverOrigin: origin,
            backgroundTasks: .noop)
        return (coordinator, drafts)
    }

    private func stubSavePipeline(log: RequestRecorder, saveDelay: TimeInterval = 0) {
        let formattedBody = Self.formattedBody
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            switch request.httpMethod {
            case "GET" where url.contains("formatted-content"):
                return .init(statusCode: 200, headers: [:], body: formattedBody, error: nil)
            case "PATCH" where url.hasSuffix("/content/"):
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil, delay: saveDelay)
            default:
                return .init(statusCode: 200, headers: [:], body: Data(), error: nil)
            }
        }
    }

    private func contentPatches(_ log: RequestRecorder) -> Int {
        log.count(ofMethod: "PATCH", urlContaining: "/content/")
    }

    private func isPendingSync(_ state: DocumentSaveCoordinator.DocSaveState) -> Bool {
        if case .pendingSync = state { return true }
        return false
    }

    private func isSaved(_ state: DocumentSaveCoordinator.DocSaveState) -> Bool {
        if case .saved = state { return true }
        return false
    }

    // MARK: - enqueue

    func testEnqueueParksAPlaceholderSaveWriteAheadAndNeverPushesIt() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, drafts) = makeCoordinator()

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: heldMarkdown)

        // Write-ahead still applies — the photo and the text are both safe on the device.
        XCTAssertEqual(drafts.draft(for: documentID)?.markdown, heldMarkdown)
        XCTAssertNotNil(coordinator.pendingSave(documentID: documentID))
        await waitAndConfirmNever { self.contentPatches(log) > 0 }
        // A held save is not a saved save: anything but `.pendingSync` would render as though
        // the work had synced.
        XCTAssertTrue(isPendingSync(coordinator.state(for: documentID)))
    }

    func testEnqueuePushesTheSameDocumentOnceThePlaceholderIsResolved() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, _) = makeCoordinator()

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: resolvedMarkdown)

        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
        XCTAssertEqual(contentPatches(log), 1)
    }

    func testAMentionThatIsNotAnImageBlockDoesNotHoldTheSave() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, _) = makeCoordinator()

        // Fenced, so there is no image leaf — and therefore no way for the user to clear a hold
        // if one were taken. The predicate parses rather than scanning for the substring.
        coordinator.enqueue(
            documentID: documentID, title: "Doc", markdown: "```\n![](\(placeholder))\n```")

        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
        XCTAssertEqual(contentPatches(log), 1)
    }

    // MARK: - finish's queued restart

    func testFinishReParksAQueuedPlaceholderSaveInsteadOfStartingIt() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log, saveDelay: 0.2)
        let (coordinator, _) = makeCoordinator()

        // An ordinary autosave goes out first...
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Notes")
        await waitUntil { self.contentPatches(log) == 1 }
        // ...and the queued photo lands behind it. This is the reachable path: a photo whose
        // upload failed transiently while a save was already on the wire parks on `inFlight`,
        // so `finish`'s queued restart — which calls `start` directly — is what would push it.
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: heldMarkdown)

        await waitAndConfirmNever(timeout: 0.6) { self.contentPatches(log) > 1 }
        XCTAssertEqual(coordinator.pendingSave(documentID: documentID)?.markdown, heldMarkdown)
        XCTAssertTrue(isPendingSync(coordinator.state(for: documentID)))
    }

    func testFinishStartsAQueuedSaveThatCarriesNoPlaceholder() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log, saveDelay: 0.2)
        let (coordinator, _) = makeCoordinator()

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Notes")
        await waitUntil { self.contentPatches(log) == 1 }
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: resolvedMarkdown)

        await waitUntil(timeout: 5) { self.contentPatches(log) == 2 }
    }

    // MARK: - releaseHeldSave (via clearResolvedConflict)

    func testResolvingAConflictDoesNotReleaseASaveStillNamingAQueuedPhoto() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, _) = makeCoordinator()

        coordinator.recordConflict(documentID: documentID, serverUpdatedAt: Date())
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: heldMarkdown)
        await waitAndConfirmNever { self.contentPatches(log) > 0 }

        // The conflict is answered, but the photo is still un-uploaded: the hold must survive
        // the release, and the parked save must be kept rather than dropped.
        coordinator.clearResolvedConflict(documentID: documentID)

        await waitAndConfirmNever { self.contentPatches(log) > 0 }
        XCTAssertEqual(coordinator.pendingSave(documentID: documentID)?.markdown, heldMarkdown)
    }

    func testResolvingAConflictReleasesASaveWithNoPendingPhoto() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, _) = makeCoordinator()

        coordinator.recordConflict(documentID: documentID, serverUpdatedAt: Date())
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: resolvedMarkdown)
        await waitAndConfirmNever { self.contentPatches(log) > 0 }

        coordinator.clearResolvedConflict(documentID: documentID)

        await waitUntil { self.contentPatches(log) == 1 }
    }

    // MARK: - runSyncPass

    func testTheSyncPassNeverFetchesForADraftNamingAQueuedPhoto() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, drafts) = makeCoordinator()
        // A draft left by a previous process: no in-memory state, so nothing but the draft's
        // own content can tell the pass to leave it alone. Reaching the decision would risk
        // rule 3 answering `.discardServerWins` and deleting the user's queued photo with it.
        drafts.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: heldMarkdown,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)))

        await coordinator.syncPendingDrafts()

        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "formatted-content"), 0)
        XCTAssertEqual(contentPatches(log), 0)
        XCTAssertEqual(drafts.draft(for: documentID)?.markdown, heldMarkdown, "the draft must survive")
    }

    func testTheSyncPassStillReconcilesADraftWithNoPendingPhoto() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, drafts) = makeCoordinator()
        drafts.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: resolvedMarkdown,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)))

        await coordinator.syncPendingDrafts()

        XCTAssertEqual(log.count(ofMethod: "GET", urlContaining: "formatted-content"), 1)
    }
}
