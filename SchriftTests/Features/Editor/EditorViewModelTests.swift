import XCTest
@testable import Schrift

@MainActor
final class EditorViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!

    private var cacheDirectory: URL!

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorViewModelTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        MockURLProtocol.stubHandler = nil
        MockURLProtocol.lastRequest = nil
        try? FileManager.default.removeItem(at: cacheDirectory)
        super.tearDown()
    }

    private func makeEnvironment(
        title: String = "Untitled document",
        autosaveInterval: Duration = .seconds(10)
    ) -> (viewModel: EditorViewModel, coordinator: DocumentSaveCoordinator, draftStore: PendingDraftStore, contentCache: DocumentContentCacheStore) {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let suiteName = "EditorViewModelTests.\(UUID().uuidString)"
        let draftStore = PendingDraftStore(userDefaults: UserDefaults(suiteName: suiteName)!)
        let contentCache = DocumentContentCacheStore(directory: cacheDirectory)
        let coordinator = DocumentSaveCoordinator(client: client, draftStore: draftStore, contentCache: contentCache, backgroundTasks: .noop)
        let viewModel = EditorViewModel(
            client: client,
            documentID: documentID,
            title: title,
            saveCoordinator: coordinator,
            contentCache: contentCache,
            autosaveInterval: autosaveInterval
        )
        return (viewModel, coordinator, draftStore, contentCache)
    }

    private func cachedEntry(markdown: String = "# Cached", syncedAt: Date = Date(timeIntervalSince1970: 1_000_000)) -> CachedDocumentContent {
        CachedDocumentContent(documentID: documentID, title: "Cached Doc", markdown: markdown, syncedAt: syncedAt)
    }

    private func formattedBody(content: String?) -> Data {
        let contentJSON = content.map { "\"\($0)\"" } ?? "null"
        return Data("""
        {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": \(contentJSON), "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
        """.utf8)
    }

    private func stubLoad(content: String?, log: RequestRecorder? = nil) {
        let body = formattedBody(content: content)
        MockURLProtocol.stubHandler = { request in
            log?.record(request)
            return .init(statusCode: 200, headers: [:], body: body, error: nil)
        }
    }

    /// A save is a content PATCH (base64 Yjs) followed by a title PATCH; each
    /// save is counted by its single content PATCH.
    private func savesInFlight(_ log: RequestRecorder) -> Int {
        log.count(ofMethod: "PATCH", urlContaining: "/content/")
    }

    private func stubLoadAndSavePipeline(content: String?, log: RequestRecorder, contentStatus: Int = 204) {
        let body = formattedBody(content: content)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            switch request.httpMethod {
            case "GET" where url.contains("formatted-content"):
                return .init(statusCode: 200, headers: [:], body: body, error: nil)
            case "PATCH" where url.hasSuffix("/content/"):
                return .init(statusCode: contentStatus, headers: [:], body: Data(), error: nil)
            case "PATCH":
                return .init(statusCode: 200, headers: [:], body: Data(), error: nil) // title
            default:
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
            }
        }
    }

    // MARK: - Loading

    func testLoadParsesMarkdownContentIntoBlocks() async {
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoad(content: "# Heading\\n\\nA paragraph.")

        await viewModel.load()

        XCTAssertTrue(blocksContentEqual(viewModel.blocks, [
            EditorBlock(kind: .heading(level: 1), text: "Heading"),
            EditorBlock(kind: .paragraph, text: "A paragraph."),
        ]))
        XCTAssertEqual(viewModel.title, "Doc")
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.openInMarkdownMode)
    }

    func testLoadWithNullContentProducesNoBlocks() async {
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoad(content: nil)

        await viewModel.load()

        XCTAssertTrue(viewModel.blocks.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testLoadKeepsOriginalTitleWhenServerTitleIsNull() async {
        let (viewModel, _, _, _) = makeEnvironment(title: "Original Title")
        let body = Data("""
        {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": null, "content": "Text", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
        """.utf8)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }

        await viewModel.load()

        XCTAssertEqual(viewModel.title, "Original Title")
    }

    func testLoadFailureSetsErrorMessage() async {
        let (viewModel, _, _, _) = makeEnvironment()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }

        await viewModel.load()

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertTrue(viewModel.blocks.isEmpty)
    }

    func testLoadPrefersStoredDraftNewerThanServer() async {
        let (viewModel, _, draftStore, _) = makeEnvironment()
        stubLoad(content: "Server content")
        draftStore.save(PendingDraft(documentID: documentID, title: "Draft Title", markdown: "Draft content", updatedAt: Date()))

        await viewModel.load()

        XCTAssertEqual(viewModel.rawMarkdown, "Draft content")
        XCTAssertEqual(viewModel.title, "Draft Title")
        XCTAssertTrue(blocksContentEqual(viewModel.blocks, [EditorBlock(kind: .paragraph, text: "Draft content")]))
    }

    func testLoadIgnoresStoredDraftOlderThanServer() async {
        let (viewModel, _, draftStore, _) = makeEnvironment()
        stubLoad(content: "Server content")
        draftStore.save(PendingDraft(documentID: documentID, title: "Old", markdown: "Stale draft", updatedAt: Date(timeIntervalSince1970: 0)))

        await viewModel.load()

        XCTAssertEqual(viewModel.rawMarkdown, "Server content")
    }

    func testLoadDefaultsToMarkdownModeWhenRoundTripUnsafe() async {
        let (viewModel, _, _, _) = makeEnvironment()
        // A lone opening fence can't round-trip through block editing.
        stubLoad(content: "```")

        await viewModel.load()
        viewModel.startEditing()

        XCTAssertTrue(viewModel.openInMarkdownMode)
        XCTAssertEqual(viewModel.mode, .markdown)
    }

    // MARK: - Instant local phase + revalidation

    func testCachedDocumentRendersWithoutLoadingSpinner() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry())
        // Failing network keeps the outcome deterministic: only the local
        // phase can have produced the content, and isLoading never flips.
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        let task = Task { await viewModel.load() }
        // The local phase is synchronous — content is visible after the first
        // suspension, before the fetch resolves.
        await waitUntil { !viewModel.blocks.isEmpty }
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(viewModel.displaySource, .clean)
        XCTAssertTrue(viewModel.hasLocalCopy)
        XCTAssertEqual(viewModel.title, "Cached Doc")
        await task.value
    }

    func testCachedDocumentSetsLastSyncedAtFromEntry() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        let syncedAt = Date(timeIntervalSince1970: 999_000)
        contentCache.save(cachedEntry(syncedAt: syncedAt))
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.lastSyncedAt, syncedAt)
    }

    func testOfflineWithCacheKeepsContentAndShowsNoError() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry())
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        await viewModel.load()

        XCTAssertFalse(viewModel.blocks.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.hasLocalCopy)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testOfflineWithNoCacheShowsError() async {
        let (viewModel, _, _, _) = makeEnvironment()
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.errorMessage, "Couldn't load this document. Pull to refresh to try again.")
        XCTAssertFalse(viewModel.hasLocalCopy)
    }

    func testStoredDraftRendersOfflineWithoutCache() async {
        // Regression for the current gap: drafts were unreachable offline.
        let (viewModel, _, draftStore, _) = makeEnvironment()
        draftStore.save(PendingDraft(documentID: documentID, title: "Draft Doc", markdown: "# Draft", updatedAt: Date()))
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.displaySource, .draft)
        XCTAssertEqual(viewModel.title, "Draft Doc")
        XCTAssertNil(viewModel.errorMessage)
    }

    func testFirstFetchWritesCacheSoNextOpenIsInstant() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        stubLoad(content: "# Fresh")

        await viewModel.load()

        let entry = contentCache.content(for: documentID)
        XCTAssertEqual(entry?.markdown, "# Fresh")
        XCTAssertEqual(viewModel.displaySource, .clean)
        XCTAssertNotNil(viewModel.lastSyncedAt)
    }

    // MARK: - Staleness comparison + "Updated" banner

    func testRevalidateIdenticalContentBumpsSyncedAtWithoutBanner() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        let old = Date(timeIntervalSince1970: 900_000)
        contentCache.save(cachedEntry(markdown: "# Same", syncedAt: old))
        stubLoad(content: "# Same")

        await viewModel.load()

        XCTAssertFalse(viewModel.updateAvailable)
        XCTAssertNotNil(viewModel.lastSyncedAt)
        XCTAssertNotEqual(viewModel.lastSyncedAt, old, "syncedAt advances on a confirmed sync")
        XCTAssertEqual(viewModel.rawMarkdown, "# Same")
    }

    func testRevalidateCanonicalizationOnlyDifferenceShowsNoBanner() async {
        // "* bullet" and "- bullet" parse to the same blocks; the serializer
        // canonicalizes. A cosmetic export difference must not banner.
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "- bullet"))
        stubLoad(content: "* bullet")

        await viewModel.load()

        XCTAssertFalse(viewModel.updateAvailable)
        XCTAssertNotNil(viewModel.lastSyncedAt)
        // Comparisons converge on the fetched raw for future opens.
        XCTAssertEqual(contentCache.content(for: documentID)?.markdown, "* bullet")
    }

    func testRevalidateChangedBodyStashesBehindBanner() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Old"))
        stubLoad(content: "# New")

        await viewModel.load()

        XCTAssertTrue(viewModel.updateAvailable)
        XCTAssertEqual(viewModel.rawMarkdown, "# Old", "on-screen content untouched")
        XCTAssertEqual(contentCache.content(for: documentID)?.markdown, "# New", "future opens get the fresh copy")

        viewModel.applyPendingUpdate()

        XCTAssertFalse(viewModel.updateAvailable)
        XCTAssertEqual(viewModel.rawMarkdown, "# New")
    }

    func testRevalidateChangedTitleAppliesSilently() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Same"))
        stubLoad(content: "# Same") // stubLoad's fixture title is "Doc"

        await viewModel.load()

        XCTAssertEqual(viewModel.title, "Doc")
        XCTAssertFalse(viewModel.updateAvailable, "title alone never banners")
        // savedTitle followed, so no spurious save is enqueued on flush.
        viewModel.flushPendingChanges()
        XCTAssertNil(viewModel.saveCoordinator.pendingSave(documentID: documentID))
    }

    func testStartEditingClearsPendingUpdate() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Old"))
        stubLoad(content: "# New")
        await viewModel.load()
        XCTAssertTrue(viewModel.updateAvailable)

        viewModel.startEditing()

        XCTAssertFalse(viewModel.updateAvailable)
        XCTAssertEqual(viewModel.rawMarkdown, "# Old", "blocks unchanged")
    }

    func testApplyPendingUpdateWhileEditingIsANoOp() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Old"))
        stubLoad(content: "# New")
        await viewModel.load()
        viewModel.startEditing()

        viewModel.applyPendingUpdate()

        XCTAssertEqual(viewModel.rawMarkdown, "# Old")
    }

    func testNonRoundTrippableCachedContentOpensInMarkdownMode() async {
        // Destructive-save regression: the cached install must run the same
        // round-trip check as a fetch, or editing a lone opening fence would
        // silently rewrite it via a full-overwrite save. (A "*"-bulleted line
        // is not a suitable fixture here — it canonicalizes to "-" and still
        // round-trips cleanly, so it wouldn't exercise this path.)
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "```"))
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        await viewModel.load()

        XCTAssertTrue(viewModel.openInMarkdownMode)
    }

    func testApplyPendingUpdateRecomputesRoundTripMode() async {
        // The banner apply must route through install() — a bare blocks swap
        // would skip the round-trip check.
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Old"))
        stubLoad(content: "```")
        await viewModel.load()
        XCTAssertTrue(viewModel.updateAvailable)

        viewModel.applyPendingUpdate()

        XCTAssertTrue(viewModel.openInMarkdownMode)
        XCTAssertEqual(viewModel.rawMarkdown, "```")
    }

    func testRevalidateWhileDirtyUpdatesCacheSilently() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Old"))
        stubLoad(content: "# Server")
        await viewModel.load() // banner set; now simulate editing instead
        viewModel.startEditing()
        viewModel.updateTitle("Edited")

        stubLoad(content: "# Server 2")
        await viewModel.load()

        XCTAssertFalse(viewModel.updateAvailable)
        XCTAssertEqual(viewModel.title, "Edited", "edits untouched")
        XCTAssertEqual(contentCache.content(for: documentID)?.markdown, "# Server 2")
    }

    // MARK: - Revalidation failure classes + stale-draft server-wins + re-entrancy

    private func stubStatus(_ code: Int) {
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: code, headers: [:], body: Data(), error: nil)
        }
    }

    func testRevalidate404PurgesCacheAndShowsUnavailable() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry())
        stubStatus(404)

        await viewModel.load()

        XCTAssertNil(contentCache.content(for: documentID))
        XCTAssertEqual(viewModel.errorMessage, "This document is no longer available.")
        XCTAssertFalse(viewModel.hasLocalCopy)
        XCTAssertNil(viewModel.lastSyncedAt)
        viewModel.startEditing()
        XCTAssertFalse(viewModel.isEditing, "editing disabled in the terminal state")
    }

    func testRevalidate403PurgesCacheToo() async {
        // Privacy: revoked-access content must not stay readable on disk.
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry())
        stubStatus(403)

        await viewModel.load()

        XCTAssertNil(contentCache.content(for: documentID))
        XCTAssertEqual(viewModel.errorMessage, "This document is no longer available.")
    }

    func testRevalidate401KeepsCacheReadable() async {
        // Cookie expiry must not purge the cache or offline reading dies on
        // every re-login.
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry())
        stubStatus(401)

        await viewModel.load()

        XCTAssertNotNil(contentCache.content(for: documentID))
        XCTAssertFalse(viewModel.blocks.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testStaleDraftLosesToNewerServerCopy() async {
        // Server updated_at beyond draft.updatedAt + 120s tolerance → server
        // wins, draft removed (preserves today's server-wins rule).
        let (viewModel, _, draftStore, contentCache) = makeEnvironment()
        draftStore.save(PendingDraft(
            documentID: documentID, title: "Old draft", markdown: "# Stale",
            updatedAt: Date(timeIntervalSince1970: 1_000_000)
        ))
        // stubLoad's fixture updated_at is 2026-01-15T10:30:00Z — far beyond
        // 1970-epoch + tolerance.
        stubLoad(content: "# Server")

        await viewModel.load()

        XCTAssertEqual(viewModel.rawMarkdown, "# Server")
        XCTAssertNil(draftStore.draft(for: documentID), "stale draft removed")
        XCTAssertEqual(contentCache.content(for: documentID)?.markdown, "# Server")
        XCTAssertEqual(viewModel.displaySource, .clean)
    }

    func testDraftWithinToleranceIsKeptOnScreen() async {
        let (viewModel, _, draftStore, _) = makeEnvironment()
        // Fixture updated_at is 2026-01-15T10:30:00Z; a draft stamped now is
        // far newer → within tolerance, draft stays.
        draftStore.save(PendingDraft(documentID: documentID, title: "Draft", markdown: "# Draft", updatedAt: Date()))
        stubLoad(content: "# Server")

        await viewModel.load()

        XCTAssertEqual(viewModel.rawMarkdown, "# Draft")
        XCTAssertNotNil(draftStore.draft(for: documentID))
    }

    func testSecondLoadSupersedesFirstRevalidation() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Old"))
        stubLoad(content: "# New")

        async let first: Void = viewModel.load()
        async let second: Void = viewModel.load()
        _ = await (first, second)

        // Whatever interleaving occurred, exactly one coherent outcome:
        // banner set with old content displayed, and no stale stash.
        XCTAssertTrue(viewModel.updateAvailable)
        XCTAssertEqual(viewModel.rawMarkdown, "# Old")
    }

    // MARK: - Explicit refresh (pull-to-refresh)

    func testRefreshAppliesNewerContentDirectlyWithoutBanner() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Old"))
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        await viewModel.load() // instant from cache, revalidation failed silently

        stubLoad(content: "# New")
        await viewModel.refresh()

        XCTAssertEqual(viewModel.rawMarkdown, "# New", "explicit refresh applies directly")
        XCTAssertFalse(viewModel.updateAvailable)
        XCTAssertNotNil(viewModel.lastSyncedAt)
    }

    func testRefreshClearsAPendingBanner() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Old"))
        stubLoad(content: "# New")
        await viewModel.load()
        XCTAssertTrue(viewModel.updateAvailable)

        await viewModel.refresh()

        XCTAssertFalse(viewModel.updateAvailable)
        XCTAssertEqual(viewModel.rawMarkdown, "# New")
    }

    func testRefreshFailureSurfacesErrorEvenWithLocalContent() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry())
        stubLoad(content: "# Cached")
        await viewModel.load()

        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        await viewModel.refresh()

        XCTAssertEqual(viewModel.errorMessage, "Couldn't refresh. Please try again.")
        XCTAssertFalse(viewModel.blocks.isEmpty, "content stays readable")
    }

    func testRefreshWhileDirtyLeavesEditsUntouched() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Mine"))
        stubLoad(content: "# Mine")
        await viewModel.load()
        viewModel.startEditing()
        viewModel.updateTitle("Edited title")

        stubLoad(content: "# Theirs")
        await viewModel.refresh()

        XCTAssertEqual(viewModel.title, "Edited title")
        XCTAssertEqual(viewModel.rawMarkdown, "# Mine")
        XCTAssertFalse(viewModel.updateAvailable)
        XCTAssertEqual(contentCache.content(for: documentID)?.markdown, "# Theirs")
    }

    // MARK: - Editing session

    func testStartEditingEntersBlocksMode() async {
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoad(content: "Original text")
        await viewModel.load()

        viewModel.startEditing()

        XCTAssertTrue(viewModel.isEditing)
        XCTAssertEqual(viewModel.mode, .blocks)
        XCTAssertFalse(viewModel.isDirty)
    }

    func testStartEditingOnEmptyDocumentSeedsAParagraph() async {
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoad(content: nil)
        await viewModel.load()

        viewModel.startEditing()

        XCTAssertEqual(viewModel.mode, .blocks)
        XCTAssertEqual(viewModel.blocks.count, 1)
        XCTAssertEqual(viewModel.blocks[0].kind, .paragraph)
        XCTAssertEqual(viewModel.focusedBlockID, viewModel.blocks[0].id)
    }

    func testStartEditingIsBlockedUntilContentLoads() async {
        let (viewModel, _, _, _) = makeEnvironment()
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 500, headers: [:], body: Data(), error: nil) }
        await viewModel.load()

        viewModel.startEditing()

        // Editing an unloaded document would autosave an empty draft over
        // the entire server copy.
        XCTAssertFalse(viewModel.isEditing)
        XCTAssertEqual(viewModel.mode, .reading)
    }

    func testEditingMarksDirty() async {
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoad(content: "Original text")
        await viewModel.load()
        viewModel.startEditing()

        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Changed text")

        XCTAssertTrue(viewModel.isDirty)
        XCTAssertEqual(viewModel.saveState, .dirty)
    }

    func testAutosaveFlushesAfterInterval() async {
        let log = RequestRecorder()
        let (viewModel, _, _, _) = makeEnvironment(autosaveInterval: .milliseconds(80))
        stubLoadAndSavePipeline(content: "Original text", log: log)
        await viewModel.load()
        viewModel.startEditing()

        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Changed text")

        XCTAssertEqual(savesInFlight(log), 0)
        await waitUntil { self.savesInFlight(log) >= 1 && viewModel.saveState == .saved }

        XCTAssertEqual(viewModel.saveState, .saved)
        XCTAssertGreaterThanOrEqual(savesInFlight(log), 1)
    }

    func testTypingRestartsTheDebounce() async {
        let log = RequestRecorder()
        let (viewModel, _, _, _) = makeEnvironment(autosaveInterval: .milliseconds(400))
        stubLoadAndSavePipeline(content: "Original text", log: log)
        await viewModel.load()
        viewModel.startEditing()

        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Change one")
        try? await Task.sleep(for: .milliseconds(200))
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Change two")

        // 200ms after the first edit the (restarted) debounce must not have fired.
        XCTAssertEqual(savesInFlight(log), 0)

        await waitUntil { viewModel.saveState == .saved }
        XCTAssertEqual(savesInFlight(log), 1)
    }

    func testFlushSkipsWhenContentUnchanged() async {
        let log = RequestRecorder()
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "Original text", log: log)
        await viewModel.load()
        viewModel.startEditing()
        let blockID = viewModel.blocks[0].id

        viewModel.updateText(blockID: blockID, text: "Changed")
        viewModel.updateText(blockID: blockID, text: "Original text")
        viewModel.flushPendingChanges()

        XCTAssertFalse(viewModel.isDirty)
        XCTAssertEqual(savesInFlight(log), 0)
        XCTAssertEqual(viewModel.saveState, .idle)
    }

    func testDoneFlushesPendingChangesAndExits() async {
        let log = RequestRecorder()
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "Original text", log: log)
        await viewModel.load()
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Changed text")

        viewModel.finishEditing()

        XCTAssertEqual(viewModel.mode, .reading)
        XCTAssertFalse(viewModel.isDirty)
        XCTAssertNil(viewModel.focusedBlockID)
        await waitUntil { viewModel.saveState == .saved }
        XCTAssertEqual(savesInFlight(log), 1)
    }

    func testFailedSaveSurfacesFailedStateAndKeepsDraft() async {
        let log = RequestRecorder()
        let (viewModel, _, draftStore, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "Original text", log: log, contentStatus: 500)
        await viewModel.load()
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Changed text")

        viewModel.flushPendingChanges()

        await waitUntil {
            if case .failed = viewModel.saveState { return true }
            return false
        }
        guard case .failed = viewModel.saveState else {
            return XCTFail("Expected failed save state, got \(viewModel.saveState)")
        }
        XCTAssertEqual(draftStore.draft(for: documentID)?.markdown, "Changed text\n")
        XCTAssertTrue(viewModel.isEditing)
    }

    func testSaveNowRetriesAfterFailure() async {
        let log = RequestRecorder()
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "Original text", log: log, contentStatus: 500)
        await viewModel.load()
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Changed text")
        viewModel.flushPendingChanges()
        await waitUntil {
            if case .failed = viewModel.saveState { return true }
            return false
        }

        stubLoadAndSavePipeline(content: "Original text", log: log, contentStatus: 204)
        viewModel.saveNow()

        await waitUntil { viewModel.saveState == .saved }
        XCTAssertEqual(viewModel.saveState, .saved)
    }

    // MARK: - Mode toggle

    func testSwitchingToMarkdownSerializesBlocks() async {
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoad(content: "# Title\\n\\nBody")
        await viewModel.load()
        viewModel.startEditing()

        viewModel.setMode(.markdown)

        XCTAssertEqual(viewModel.mode, .markdown)
        XCTAssertEqual(viewModel.rawMarkdown, "# Title\n\nBody\n")
    }

    func testSwitchingBackToBlocksReparsesMarkdown() async {
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoad(content: "# Title")
        await viewModel.load()
        viewModel.startEditing()
        viewModel.setMode(.markdown)

        viewModel.updateRawMarkdown("# Title\n\n- New item\n")
        viewModel.setMode(.blocks)

        XCTAssertEqual(viewModel.mode, .blocks)
        XCTAssertTrue(blocksContentEqual(viewModel.blocks, [
            EditorBlock(kind: .heading(level: 1), text: "Title"),
            EditorBlock(kind: .bulletItem, text: "New item"),
        ]))
        XCTAssertTrue(viewModel.isDirty)
    }

    func testCurrentMarkdownFollowsTheActiveMode() async {
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoad(content: "# Title")
        await viewModel.load()
        viewModel.startEditing()

        XCTAssertEqual(viewModel.currentMarkdown(), "# Title\n")

        viewModel.setMode(.markdown)
        viewModel.updateRawMarkdown("raw edited")

        XCTAssertEqual(viewModel.currentMarkdown(), "raw edited")
    }

    // MARK: - Subpages fetch-awareness

    func testSubpagesAreNilBeforeAnySuccessfulFetch() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry())
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        await viewModel.load()

        XCTAssertNil(viewModel.subpages, "offline: unknown, not 'none'")
    }

    func testSubpagesBecomeEmptyArrayAfterSuccessfulFetch() async {
        let (viewModel, _, _, _) = makeEnvironment()
        // Stub both endpoints explicitly: formatted-content, and an empty
        // paginated children list (do not rely on stubLoad's handling of the
        // children URL — a decode failure must now read as "not fetched").
        let docBody = formattedBody(content: "# Doc")
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("children") {
                return MockURLProtocol.Stub(
                    statusCode: 200, headers: [:],
                    body: Data(#"{"count": 0, "next": null, "previous": null, "results": []}"#.utf8),
                    error: nil
                )
            }
            return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: docBody, error: nil)
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.subpages, [])
    }

    func testHandleDidDeletePurgesCacheAndDrafts() async {
        let (viewModel, _, draftStore, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry())
        draftStore.save(PendingDraft(documentID: documentID, title: "D", markdown: "# D", updatedAt: Date()))

        viewModel.handleDidDelete()

        XCTAssertNil(contentCache.content(for: documentID))
        XCTAssertNil(draftStore.draft(for: documentID))
    }
}
