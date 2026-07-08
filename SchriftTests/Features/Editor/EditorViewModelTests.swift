import XCTest

@testable import Schrift

@MainActor
final class EditorViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!

    private var cacheDirectory: URL!
    private var childrenSuiteName: String!
    /// Every suite `makeEnvironment` creates, so tearDown can remove each
    /// persistent domain instead of leaking a plist per environment.
    private var draftSuiteNames: [String] = []

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorViewModelTests-\(UUID().uuidString)", isDirectory: true)
        childrenSuiteName = "EditorViewModelTests.children.\(UUID().uuidString)"
        draftSuiteNames = []
    }

    override func tearDown() {
        MockURLProtocol.stubHandler = nil
        MockURLProtocol.lastRequest = nil
        try? FileManager.default.removeItem(at: cacheDirectory)
        UserDefaults(suiteName: childrenSuiteName)?.removePersistentDomain(forName: childrenSuiteName)
        for suiteName in draftSuiteNames {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    private func makeEnvironment(
        title: String = "Untitled document",
        autosaveInterval: Duration = .seconds(10)
    ) -> (
        viewModel: EditorViewModel, coordinator: DocumentSaveCoordinator, draftStore: PendingDraftStore,
        contentCache: DocumentContentCacheStore
    ) {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let suiteName = "EditorViewModelTests.\(UUID().uuidString)"
        draftSuiteNames.append(suiteName)
        let draftStore = PendingDraftStore(userDefaults: UserDefaults(suiteName: suiteName)!)
        let contentCache = DocumentContentCacheStore(directory: cacheDirectory)
        // Isolated: load()/delete/404 paths touch the children cache, which
        // must never read from or write to UserDefaults.standard in tests.
        let childrenCache = DocumentChildrenCacheStore(userDefaults: UserDefaults(suiteName: childrenSuiteName)!)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: draftStore, contentCache: contentCache, backgroundTasks: .noop)
        let viewModel = EditorViewModel(
            client: client,
            documentID: documentID,
            title: title,
            saveCoordinator: coordinator,
            contentCache: contentCache,
            childrenCache: childrenCache,
            autosaveInterval: autosaveInterval
        )
        return (viewModel, coordinator, draftStore, contentCache)
    }

    private func cachedEntry(markdown: String = "# Cached", syncedAt: Date = Date(timeIntervalSince1970: 1_000_000))
        -> CachedDocumentContent
    {
        CachedDocumentContent(documentID: documentID, title: "Cached Doc", markdown: markdown, syncedAt: syncedAt)
    }

    private func formattedBody(content: String?) -> Data {
        let contentJSON = content.map { "\"\($0)\"" } ?? "null"
        return Data(
            """
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

    /// Every request fails as if the device were offline — the way to reach an
    /// installed-from-cache screen whose revalidation never landed.
    private func stubOffline() {
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
    }

    /// A save is a content PATCH (base64 Yjs) followed by a title PATCH; each
    /// save is counted by its single content PATCH.
    private func savesInFlight(_ log: RequestRecorder) -> Int {
        log.count(ofMethod: "PATCH", urlContaining: "/content/")
    }

    /// `saveDelay` holds the content PATCH open so a save is deterministically
    /// still in flight when a concurrently-issued GET reaches `apply`. `getDelay`
    /// holds the GET open instead, so its response lands *after* the save settled
    /// — the raced-fetch case. Both use `Stub.delay`, never `Thread.sleep`, so one
    /// stalled request never blocks the other.
    private func stubLoadAndSavePipeline(
        content: String?,
        log: RequestRecorder,
        contentStatus: Int = 204,
        saveDelay: TimeInterval = 0,
        getDelay: TimeInterval = 0
    ) {
        let body = formattedBody(content: content)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            switch request.httpMethod {
            case "GET" where url.contains("formatted-content"):
                return .init(statusCode: 200, headers: [:], body: body, error: nil, delay: getDelay)
            case "PATCH" where url.hasSuffix("/content/"):
                return .init(statusCode: contentStatus, headers: [:], body: Data(), error: nil, delay: saveDelay)
            case "PATCH":
                return .init(statusCode: 200, headers: [:], body: Data(), error: nil)  // title
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

        XCTAssertTrue(
            blocksContentEqual(
                viewModel.blocks,
                [
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
        let body = Data(
            """
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
        draftStore.save(
            PendingDraft(documentID: documentID, title: "Draft Title", markdown: "Draft content", updatedAt: Date()))

        await viewModel.load()

        XCTAssertEqual(viewModel.rawMarkdown, "Draft content")
        XCTAssertEqual(viewModel.title, "Draft Title")
        XCTAssertTrue(blocksContentEqual(viewModel.blocks, [EditorBlock(kind: .paragraph, text: "Draft content")]))
    }

    func testLoadIgnoresStoredDraftOlderThanServer() async {
        let (viewModel, _, draftStore, _) = makeEnvironment()
        stubLoad(content: "Server content")
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Old", markdown: "Stale draft", updatedAt: Date(timeIntervalSince1970: 0)
            ))

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
        draftStore.save(
            PendingDraft(documentID: documentID, title: "Draft Doc", markdown: "# Draft", updatedAt: Date()))
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

    /// The reported bug: a document edited on the web showed its new title but
    /// kept rendering the cached body, because a passive revalidation only ever
    /// stashed the fresh body behind the "Updated" banner.
    func testRevalidateAppliesChangedBodyWhenNotEditing() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Old"))
        stubLoad(content: "# New")

        await viewModel.load()

        XCTAssertEqual(viewModel.rawMarkdown, "# New", "a clean reading copy always shows the server's body")
        XCTAssertEqual(viewModel.blocks.first?.text, "New")
        XCTAssertFalse(viewModel.updateAvailable, "nothing to opt into — it is already on screen")
        XCTAssertEqual(contentCache.content(for: documentID)?.markdown, "# New")
    }

    /// Reopening the screen (`.task` refires on pop-back) must keep applying
    /// remote edits, not strand the first-loaded copy.
    func testSecondLoadAppliesContentChangedSinceTheFirst() async {
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoad(content: "# First")
        await viewModel.load()

        stubLoad(content: "# Second")
        await viewModel.load()

        XCTAssertEqual(viewModel.rawMarkdown, "# Second")
        XCTAssertFalse(viewModel.updateAvailable)
    }

    /// The route the shipped app actually takes into the banner: the cached copy
    /// renders synchronously, so the reading surface is live while the fetch is
    /// in flight. Tapping a block then starts editing *before* the response
    /// lands. (The other banner tests drive `load()` twice, which the app never
    /// does — this one guards against the banner becoming unreachable UI.)
    func testEditingStartedDuringTheFetchStashesTheResponseBehindTheBanner() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Old"))
        let body = formattedBody(content: "# New")
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: body, error: nil, delay: 0.3)  // held open
        }

        async let loading: Void = viewModel.load()
        // The cached copy is on screen after the synchronous local phase; the
        // user taps into it while the revalidation is still awaiting.
        await waitUntil { viewModel.hasLoadedContent }
        viewModel.startEditing()
        await loading

        XCTAssertTrue(viewModel.updateAvailable, "the response arrived mid-edit and was stashed")
        XCTAssertEqual(viewModel.blocks.first?.text, "Old", "content under the caret is never swapped")

        viewModel.finishEditing()
        viewModel.applyPendingUpdate()

        XCTAssertEqual(viewModel.blocks.first?.text, "New")
    }

    /// The banner's remaining job: an editing session owns the caret, so a
    /// changed body waits until editing ends rather than being swapped in.
    func testRevalidateWhileEditingStashesBehindBanner() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Old"))
        stubOffline()
        await viewModel.load()  // instant from cache, revalidation failed silently
        viewModel.startEditing()

        stubLoad(content: "# New")
        await viewModel.load()

        XCTAssertTrue(viewModel.updateAvailable)
        XCTAssertEqual(viewModel.rawMarkdown, "# Old", "content under the caret is never swapped")
        XCTAssertEqual(contentCache.content(for: documentID)?.markdown, "# New", "future opens get the fresh copy")

        viewModel.finishEditing()
        viewModel.applyPendingUpdate()

        XCTAssertFalse(viewModel.updateAvailable)
        XCTAssertEqual(viewModel.rawMarkdown, "# New")
    }

    func testRevalidateChangedTitleAppliesSilently() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Same"))
        stubLoad(content: "# Same")  // stubLoad's fixture title is "Doc"

        await viewModel.load()

        XCTAssertEqual(viewModel.title, "Doc")
        XCTAssertFalse(viewModel.updateAvailable, "title alone never banners")
        // savedTitle followed, so no spurious save is enqueued on flush.
        viewModel.flushPendingChanges()
        XCTAssertNil(viewModel.saveCoordinator.pendingSave(documentID: documentID))
    }

    /// Re-entering an editing session drops a body stashed by the session
    /// before it: the user chose to work on what is on screen.
    func testStartEditingClearsPendingUpdate() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Old"))
        stubOffline()
        await viewModel.load()
        viewModel.startEditing()
        stubLoad(content: "# New")
        await viewModel.load()
        XCTAssertTrue(viewModel.updateAvailable)
        viewModel.finishEditing()

        viewModel.startEditing()

        XCTAssertFalse(viewModel.updateAvailable)
        XCTAssertEqual(viewModel.blocks.first?.text, "Old", "blocks unchanged")
    }

    func testApplyPendingUpdateWhileEditingIsANoOp() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Old"))
        stubOffline()
        await viewModel.load()
        viewModel.startEditing()
        stubLoad(content: "# New")
        await viewModel.load()
        XCTAssertTrue(viewModel.updateAvailable, "precondition: a body is stashed")

        viewModel.applyPendingUpdate()

        XCTAssertEqual(viewModel.rawMarkdown, "# Old")
        // The stash must SURVIVE the refused apply — clearing it before the
        // guard would silently destroy the fetched body.
        XCTAssertTrue(viewModel.updateAvailable)
        viewModel.finishEditing()
        viewModel.applyPendingUpdate()
        XCTAssertEqual(viewModel.blocks.first?.text, "New")
    }

    func testNonRoundTrippableCachedContentOpensInMarkdownMode() async {
        // Destructive-save regression: the cached install must run the same
        // round-trip check as a fetch, or editing a lone opening fence would
        // silently rewrite it via a full-overwrite save. (A "*"-bulleted line
        // is not a suitable fixture here — it canonicalizes to "-" and still
        // round-trips cleanly, so it wouldn't exercise this path.)
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "```"))
        stubOffline()

        await viewModel.load()

        XCTAssertTrue(viewModel.openInMarkdownMode)
    }

    func testApplyPendingUpdateRecomputesRoundTripMode() async {
        // The banner apply must route through install() — a bare blocks swap
        // would skip the round-trip check.
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Old"))
        stubOffline()
        await viewModel.load()
        viewModel.startEditing()
        stubLoad(content: "```")
        await viewModel.load()
        XCTAssertTrue(viewModel.updateAvailable)
        viewModel.finishEditing()

        viewModel.applyPendingUpdate()

        XCTAssertTrue(viewModel.openInMarkdownMode)
        XCTAssertEqual(viewModel.rawMarkdown, "```")
    }

    func testRevalidateWhileDirtyUpdatesCacheSilently() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Old"))
        stubLoad(content: "# Server")
        await viewModel.load()
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
        draftStore.save(
            PendingDraft(
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
        // Distinct bodies, and the *first* (superseded) fetch resolves last.
        // With one shared body both loads agree and the test passes even with the
        // generation guard deleted — it has to be able to tell them apart.
        let log = RequestRecorder()
        let requestCount = Counter()
        let firstBody = formattedBody(content: "# First")
        let secondBody = formattedBody(content: "# Second")
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let isFirst = requestCount.next() == 1
            return .init(
                statusCode: 200, headers: [:], body: isFirst ? firstBody : secondBody, error: nil,
                delay: isFirst ? 0.3 : 0)
        }

        let first = Task { await viewModel.load() }
        // Don't race the stub: the second load may only be issued once the first
        // request is inside the handler, or "first request" and "first generation"
        // can disagree and the assertion below becomes a coin flip.
        await waitUntil { log.count(ofMethod: "GET", urlContaining: "formatted-content") >= 1 }
        let second = Task { await viewModel.load() }
        await first.value
        await second.value

        XCTAssertEqual(viewModel.rawMarkdown, "# Second", "the superseded fetch never applies")
        XCTAssertFalse(viewModel.updateAvailable)
        XCTAssertFalse(viewModel.isLoading)
    }

    // MARK: - Explicit refresh (pull-to-refresh)

    func testRefreshAppliesNewerContentDirectlyWithoutBanner() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Old"))
        stubOffline()
        await viewModel.load()  // instant from cache, revalidation failed silently

        stubLoad(content: "# New")
        await viewModel.refresh()

        XCTAssertEqual(viewModel.rawMarkdown, "# New", "explicit refresh applies directly")
        XCTAssertFalse(viewModel.updateAvailable)
        XCTAssertNotNil(viewModel.lastSyncedAt)
    }

    func testRefreshClearsABannerStashedByAnEditingSession() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Old"))
        stubOffline()
        await viewModel.load()
        viewModel.startEditing()
        stubLoad(content: "# New")
        await viewModel.load()
        XCTAssertTrue(viewModel.updateAvailable)
        viewModel.finishEditing()

        await viewModel.refresh()

        XCTAssertFalse(viewModel.updateAvailable)
        XCTAssertEqual(viewModel.rawMarkdown, "# New")
    }

    /// Opening a document while its save is still in flight pinned
    /// `displaySource` to `.pendingSave` for the life of the screen, so once
    /// the save landed every later revalidation — and every pull-to-refresh —
    /// silently did nothing and remote edits could never arrive.
    func testRefreshAppliesRemoteContentAfterAnInFlightSaveCompletes() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, _, _) = makeEnvironment()
        // The stalled PATCH keeps the save in flight while the GET reaches apply().
        stubLoadAndSavePipeline(content: "# Server", log: log, saveDelay: 0.2)
        // Enqueue synchronously so restoreLocalContent() sees the pending save.
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine")

        await viewModel.load()
        XCTAssertEqual(viewModel.displaySource, .pendingSave)
        XCTAssertEqual(viewModel.rawMarkdown, "# Mine", "the in-flight content owns the screen")
        await waitUntil { viewModel.saveState == .saved }

        stubLoad(content: "# Remote")
        await viewModel.refresh()

        XCTAssertEqual(viewModel.rawMarkdown, "# Remote")
        XCTAssertEqual(viewModel.displaySource, .clean)
        XCTAssertEqual(savesInFlight(log), 1, "reconciling never re-saves")
    }

    /// The same unpinning must not throw away unsaved work: a save that failed
    /// leaves its draft behind, and that draft still owns the screen.
    func testRefreshAfterAFailedSaveKeepsTheDraftOnScreen() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "# Server", log: log, contentStatus: 500, saveDelay: 0.2)
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine")

        await viewModel.load()
        XCTAssertEqual(viewModel.displaySource, .pendingSave)
        await waitUntil {
            if case .failed = viewModel.saveState { return true }
            return false
        }

        // The fixture's updated_at (2026-01-15) predates the just-written
        // draft, so the draft wins and stays on screen.
        stubLoad(content: "# Remote")
        await viewModel.refresh()

        XCTAssertEqual(viewModel.rawMarkdown, "# Mine", "unsaved work is never clobbered")
        XCTAssertEqual(viewModel.displaySource, .draft)
        XCTAssertNotNil(draftStore.draft(for: documentID))
        XCTAssertNil(viewModel.errorMessage, "a protected draft is a deliberate, silent no-op")
    }

    /// A draft left behind by a *failed* save is unsaved work no matter which
    /// source installed the screen. Reaching `reconcileClean` with `.clean` on
    /// screen (the state a save failing mid-session leaves behind) used to
    /// install the server body straight over it — and `saveNow()` would then
    /// push the server's own body back, making the loss permanent.
    func testRevalidationAfterAFailedSaveNeverClobbersTheSurvivingDraft() async {
        let log = RequestRecorder()
        let (viewModel, _, draftStore, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "# Server", log: log, contentStatus: 500)
        await viewModel.load()
        XCTAssertEqual(viewModel.displaySource, .clean)

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Mine")
        viewModel.finishEditing()  // flush → enqueue → PATCH 500, draft survives
        await waitUntil {
            if case .failed = viewModel.saveState { return true }
            return false
        }

        stubLoad(content: "# Server")  // the save never landed
        await viewModel.load()

        XCTAssertEqual(viewModel.blocks.first?.text, "Mine", "the failed save's content survives")
        XCTAssertEqual(draftStore.draft(for: documentID)?.markdown, "# Mine\n", "the edited block is still a heading")
        XCTAssertEqual(viewModel.displaySource, .draft, "a surviving draft owns the screen")
        XCTAssertTrue(viewModel.hasUnsavedLocalContent)
    }

    /// The clock-tolerance rule exists for drafts *stranded by an earlier
    /// session* (`recoverDrafts`' job). A save that failed **this** session is a
    /// retry candidate the user is looking at, with the "Couldn't save" retry on
    /// screen — the server must never silently delete it. Note the trigger needs
    /// no remote edit at all: a device clock two minutes slow puts every server
    /// `updated_at` beyond `draft.updatedAt + tolerance`.
    func testRevalidationAfterAFailedSaveKeepsTheDraftEvenWhenTheServerLooksNewer() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "# Server", log: log, contentStatus: 500, saveDelay: 0.2)
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine")

        await viewModel.load()
        XCTAssertEqual(viewModel.displaySource, .pendingSave)
        await waitUntil {
            if case .failed = viewModel.saveState { return true }
            return false
        }
        // Age the surviving draft far past the fixture's updated_at (2026-01-15):
        // the tolerance comparison now says "server wins".
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Mine",
                updatedAt: Date(timeIntervalSince1970: 0)))

        stubLoad(content: "# Remote")
        await viewModel.refresh()

        XCTAssertEqual(viewModel.rawMarkdown, "# Mine", "a failed save's content is never silently deleted")
        XCTAssertEqual(viewModel.displaySource, .draft)
        XCTAssertNotNil(draftStore.draft(for: documentID), "the retry still has something to send")
        XCTAssertTrue(viewModel.hasUnsavedLocalContent)
    }

    /// A draft stranded by an *earlier* session still loses to a meaningfully
    /// newer server copy — that rule is unchanged, and `saveState` is `.idle`
    /// because no save was attempted this session.
    func testStrandedDraftStillLosesToANewerServerCopyOnRefresh() async {
        let (viewModel, _, draftStore, _) = makeEnvironment()
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Old draft", markdown: "# Stale",
                updatedAt: Date(timeIntervalSince1970: 1_000_000)))
        stubLoad(content: "# Server")
        await viewModel.load()

        XCTAssertEqual(viewModel.rawMarkdown, "# Server", "server wins beyond the clock tolerance")
        XCTAssertEqual(viewModel.displaySource, .clean)
        XCTAssertNil(draftStore.draft(for: documentID), "stale draft discarded")
    }

    /// `becomeUnavailable` tears the screen down but deliberately keeps the draft
    /// (a 403 is revoked access, not a deleted document — purging would destroy
    /// unsaved work with no recovery). The caption must not then claim unsaved
    /// local content for a document that is no longer on screen.
    func testUnavailableDocumentReportsNoUnsavedLocalContent() async {
        let (viewModel, _, draftStore, _) = makeEnvironment()
        draftStore.save(PendingDraft(documentID: documentID, title: "Draft", markdown: "# Draft", updatedAt: Date()))
        stubStatus(404)

        await viewModel.load()

        XCTAssertEqual(viewModel.errorMessage, "This document is no longer available.")
        XCTAssertFalse(viewModel.hasUnsavedLocalContent, "nothing is on screen to be unsaved")
    }

    /// The unchanged branch drops a stash unconditionally: if the server has
    /// converged back to what is on screen, the stashed body has nothing to offer.
    func testRevalidationMatchingTheScreenDropsAStaleStash() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Old"))
        stubOffline()
        await viewModel.load()
        viewModel.startEditing()
        stubLoad(content: "# New")
        await viewModel.load()
        XCTAssertTrue(viewModel.updateAvailable)

        stubLoad(content: "# Old")  // the server reverted
        await viewModel.load()

        XCTAssertFalse(viewModel.updateAvailable)
        viewModel.finishEditing()
        viewModel.applyPendingUpdate()  // the stash is really gone, not just the flag
        XCTAssertEqual(viewModel.blocks.first?.text, "Old")
    }

    /// A revalidation issued while one of our own saves was in flight may be
    /// answered from the server's pre-save state. Installing that body would
    /// resurrect exactly what the save replaced — and the next full-overwrite
    /// save would push it back to the server.
    func testRevalidationRacingOurOwnSaveNeverInstallsThePreSaveBody() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, _, contentCache) = makeEnvironment()
        // The GET is stalled so its (pre-save) response lands after the PATCH
        // has completed and cleared the pending save.
        stubLoadAndSavePipeline(content: "# Old", log: log, getDelay: 0.3)
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine")

        await viewModel.load()
        await waitUntil { viewModel.saveState == .saved }

        XCTAssertEqual(viewModel.rawMarkdown, "# Mine", "the just-saved content stays on screen")
        XCTAssertEqual(contentCache.content(for: documentID)?.markdown, "# Mine", "cache not poisoned")

        // …and the screen is not stranded: the next fetch reconciles normally.
        stubLoad(content: "# Remote")
        await viewModel.refresh()

        XCTAssertEqual(viewModel.rawMarkdown, "# Remote")
        XCTAssertEqual(viewModel.displaySource, .clean)
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
        XCTAssertTrue(
            blocksContentEqual(
                viewModel.blocks,
                [
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
