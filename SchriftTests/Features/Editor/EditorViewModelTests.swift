import XCTest

@testable import Schrift

@MainActor
final class EditorViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!
    /// The `updated_at` every `formattedBody` fixture pins — the server-clock value
    /// a fetched baseline must record (never the client clock).
    private let fetchedUpdatedAt = ISO8601DateFormatter().date(from: "2026-01-15T10:30:00Z")!

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
        MockURLProtocol.reset()
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

    /// `getDelay` holds the formatted-content GET open (via `Stub.delay`, never
    /// `Thread.sleep`, which would stall the PATCH too) so its response lands
    /// *after* a concurrent save settled — the raced-fetch case. Nothing needs to
    /// stall the save: `enqueue` sets the pending save synchronously, which is all
    /// `restoreLocalContent` reads.
    private func stubLoadAndSavePipeline(
        content: String?,
        log: RequestRecorder,
        contentStatus: Int = 204,
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
                return .init(statusCode: contentStatus, headers: [:], body: Data(), error: nil)
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
        XCTAssertNil(viewModel.errorKey)
    }

    func testLoadWithNullContentProducesNoBlocks() async {
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoad(content: nil)

        await viewModel.load()

        XCTAssertTrue(viewModel.blocks.isEmpty)
        XCTAssertNil(viewModel.errorKey)
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

        XCTAssertNotNil(viewModel.errorKey)
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
        XCTAssertNil(viewModel.errorKey)
        XCTAssertTrue(viewModel.hasLocalCopy)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testOfflineWithNoCacheShowsError() async {
        let (viewModel, _, _, _) = makeEnvironment()
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.errorKey, .editor_error_load)
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
        XCTAssertNil(viewModel.errorKey)
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

    func testApplyPendingUpdateInstallsFreshContent() async {
        // The banner apply must route through install() — a bare blocks swap would
        // skip the reparse and leave rawMarkdown (the reading-mode source) stale.
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Old"))
        stubOffline()
        await viewModel.load()
        viewModel.startEditing()
        stubLoad(content: "# Fresh")
        await viewModel.load()
        XCTAssertTrue(viewModel.updateAvailable)
        viewModel.finishEditing()

        viewModel.applyPendingUpdate()

        XCTAssertEqual(viewModel.rawMarkdown, "# Fresh")
        XCTAssertEqual(viewModel.blocks.first?.text, "Fresh")
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
        XCTAssertEqual(viewModel.errorKey, .editor_unavailable)
        XCTAssertFalse(viewModel.hasLocalCopy)
        XCTAssertNil(viewModel.lastSyncedAt)
        viewModel.startEditing()
        XCTAssertFalse(viewModel.isEditing, "editing disabled in the terminal state")
    }

    /// `startEditing` guards the *entry* to an editing session on
    /// `hasLoadedContent`; nothing guarded the exit. A 404/403 landing mid-edit
    /// cleared the blocks but left `isDirty`, `mode` and the autosave timer alive,
    /// so the next flush serialized the now-empty block list and enqueued it —
    /// replacing the user's draft with an empty document, and (after a *transient*
    /// 404) letting `recoverDrafts()` replay that emptiness onto the server.
    ///
    /// The edit itself must not be thrown away either: `enqueue` is write-ahead, so
    /// flushing *before* the content goes puts the user's real text on disk, where
    /// `recoverDrafts()` replays it if the 404/403 turns out to have been transient.
    func testUnavailableMidEditPersistsTheEditAndNeverEnqueuesAnEmptyDocument() async {
        let (viewModel, coordinator, draftStore, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Mine"))
        stubOffline()
        await viewModel.load()  // cached copy on screen, revalidation failed silently

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Mine edited")
        XCTAssertTrue(viewModel.isDirty)

        stubStatus(404)
        await viewModel.load()  // the document is gone; the editing session is not
        // The teardown flushes write-ahead, so a PATCH goes out; let it settle
        // rather than leaving it to land inside a later test.
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }

        XCTAssertEqual(
            draftStore.draft(for: documentID)?.markdown, "# Mine edited\n",
            "the in-flight edit is persisted, not discarded and not emptied")
        XCTAssertFalse(viewModel.isEditing, "the editing session ends with the document")
        XCTAssertFalse(viewModel.isDirty)
        XCTAssertEqual(viewModel.errorKey, .editor_unavailable_with_draft, "the write-ahead flush left a draft")

        // A later autosave / .onDisappear / scenePhase flush must not empty it.
        viewModel.flushPendingChanges()

        XCTAssertEqual(draftStore.draft(for: documentID)?.markdown, "# Mine edited\n")
    }

    func testRevalidate403PurgesCacheToo() async {
        // Privacy: revoked-access content must not stay readable on disk.
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry())
        stubStatus(403)

        await viewModel.load()

        XCTAssertNil(contentCache.content(for: documentID))
        XCTAssertEqual(viewModel.errorKey, .editor_unavailable)
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
        XCTAssertNil(viewModel.errorKey)
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
        let requestCount = Counter()
        let firstBody = formattedBody(content: "# First")
        let secondBody = formattedBody(content: "# Second")
        MockURLProtocol.stubHandler = { _ in
            let isFirst = requestCount.next() == 1
            return .init(
                statusCode: 200, headers: [:], body: isFirst ? firstBody : secondBody, error: nil,
                delay: isFirst ? 0.3 : 0)
        }

        let first = Task { await viewModel.load() }
        // Don't race the stub: the second load may only be issued once the first
        // request has *taken its branch*, or "first request" and "first generation"
        // can disagree and the assertion below becomes a coin flip. Gate on the
        // counter the branch is chosen from, not on a recorder — recording order
        // need not match branch order.
        await waitUntil { requestCount.current >= 1 }
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
        stubLoadAndSavePipeline(content: "# Server", log: log)
        // `enqueue` sets the pending save synchronously, and `restoreLocalContent`
        // reads it before `load()`'s first await — so the screen is installed from
        // the in-flight content without needing to stall the PATCH to prove it.
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine")
        XCTAssertNotNil(coordinator.pendingSave(documentID: documentID))

        await viewModel.load()
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
        stubLoadAndSavePipeline(content: "# Server", log: log, contentStatus: 500)
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine")
        XCTAssertNotNil(coordinator.pendingSave(documentID: documentID))

        await viewModel.load()
        XCTAssertEqual(viewModel.rawMarkdown, "# Mine")
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
        XCTAssertNil(viewModel.errorKey, "a protected draft is a deliberate, silent no-op")
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
    /// screen — the server must never silently delete it. The comparison mixes
    /// clocks (`draft.updatedAt` is the device's, `formatted.updatedAt` the
    /// server's *last write*), so a slow device widens the set of server writes
    /// that read as "newer" — including the user's own partially-landed save.
    func testRevalidationAfterAFailedSaveKeepsTheDraftEvenWhenTheServerLooksNewer() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "# Server", log: log, contentStatus: 500)
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine")
        XCTAssertNotNil(coordinator.pendingSave(documentID: documentID))

        await viewModel.load()
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

        // The draft is kept (a 403 revokes access, it doesn't delete), and the
        // terminal message says so rather than letting the work vanish silently.
        XCTAssertEqual(viewModel.errorKey, .editor_unavailable_with_draft)
        XCTAssertNotNil(draftStore.draft(for: documentID))
        XCTAssertFalse(viewModel.hasUnsavedLocalContent, "nothing is on screen to be unsaved")
    }

    /// A 404 can be transient (proxy hiccup, brief permission flap). The screen
    /// stays mounted and keeps its pull-to-refresh, so the document can come back —
    /// and once it is back on screen, editing it must save. A permanent
    /// "discarded" latch made every save funnel silently return while the caption
    /// still read "Edited just now".
    func testDocumentRecoveredFromATransient404SavesAgain() async {
        let (viewModel, coordinator, _, _) = makeEnvironment()
        stubStatus(404)
        await viewModel.load()
        XCTAssertFalse(viewModel.hasLoadedContent)

        stubLoad(content: "# Back")  // the 404 was transient
        await viewModel.refresh()
        XCTAssertTrue(viewModel.hasLoadedContent, "the document is back on screen")
        XCTAssertNil(viewModel.errorKey)

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Back edited")
        viewModel.flushPendingChanges()

        XCTAssertNotNil(
            coordinator.pendingSave(documentID: documentID),
            "a recovered document must still save — every funnel routes through flushPendingChanges")
        XCTAssertFalse(viewModel.isDirty)
        // Let the PATCH settle rather than leaving it to land inside a later test.
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
    }

    /// The scenario `becomeUnavailable`'s write-ahead flush exists for: a transient
    /// 404 taken *while the user has unsaved edits*. The flush stores a draft — and
    /// on the recovery fetch `apply` diverts into `reconcileDraft`, which keeps the
    /// draft and never calls `install(...)`. Discharging the terminal state only in
    /// `install(...)` therefore stranded the document forever: empty body, "no
    /// longer available", and pull-to-refresh the only affordance, no-oping.
    /// A 200 is the server saying the document is back — that is what clears it.
    func testTransient404WithUnsavedEditRecoversAndRestoresTheDraft() async {
        let (viewModel, coordinator, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Mine"))
        stubOffline()
        await viewModel.load()

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Mine edited")
        stubStatus(404)
        await viewModel.load()  // proxy hiccup: teardown flushes, writing a draft
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
        XCTAssertTrue(viewModel.isUnavailable)

        stubLoad(content: "# Mine")  // the hiccup is over
        await viewModel.refresh()

        XCTAssertFalse(viewModel.isUnavailable, "a 200 means the document is back")
        XCTAssertTrue(viewModel.hasLoadedContent)
        XCTAssertNil(viewModel.errorKey)
        XCTAssertEqual(viewModel.blocks.first?.text, "Mine edited", "the user's only copy is back on screen")
        XCTAssertTrue(viewModel.hasLocalCopy)
    }

    /// `becomeUnavailable`'s flush pulls the draft *out* of the save pipeline
    /// (`suppressLocalWriteThrough` drops the queued save, and `finish`'s discarded
    /// branch resets the state to `.idle` — not `.failed`). Re-installing that draft
    /// on recovery therefore put a healthy-looking, unsaveable document on screen:
    /// `flushPendingChanges` needs `isDirty`, `saveNow` needs `.failed`, the retry
    /// caption needs `.failed`, and `recoverDrafts` already ran. The edit would sit
    /// there labelled "Edited just now" until a co-author's write pushed the server
    /// past the clock tolerance — and then `reconcileDraft` would silently delete it.
    /// The document is back, so the draft goes back into the pipeline.
    func testRecoveredDraftIsHandedBackToTheSavePipeline() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, draftStore, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Mine"))
        stubOffline()
        await viewModel.load()
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Mine edited")

        stubStatus(404)
        await viewModel.load()  // teardown flushes; its PATCH 404s
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
        XCTAssertEqual(coordinator.state(for: documentID), .idle, "the discarded branch resets the state")
        XCTAssertNotNil(draftStore.draft(for: documentID))

        stubLoadAndSavePipeline(content: "# Mine", log: log)  // the hiccup is over
        await viewModel.refresh()

        XCTAssertEqual(viewModel.blocks.first?.text, "Mine edited", "the draft is back on screen")
        await waitUntil { viewModel.saveState == .saved }
        XCTAssertNil(draftStore.draft(for: documentID), "and it reached the server")
        XCTAssertEqual(savesInFlight(log), 1)
    }

    /// The escape from the stranded-draft state must key off the *state*, not off
    /// which screen instance happened to recover. Tapping Back is the natural reaction
    /// to "no longer available", and it destroys the view model — so on reopen a fresh
    /// one restores the draft locally, `hasLoadedContent` is already true, and a
    /// `recovered`-gated re-enqueue never fires. The draft then sits on screen
    /// captioned "Edited just now" until a co-author's write deletes it.
    func testStrandedDraftIsSavedEvenWhenAFreshScreenRestoresIt() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, draftStore, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Mine"))
        stubOffline()
        await viewModel.load()
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Mine edited")

        stubStatus(404)
        await viewModel.load()  // teardown flushes; PATCH 404s; state becomes .idle
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
        XCTAssertEqual(coordinator.state(for: documentID), .idle)
        XCTAssertNotNil(draftStore.draft(for: documentID))

        // The user taps Back and reopens: EditorScreen builds a brand-new view model
        // over the same app-scoped coordinator and the same on-disk draft.
        let reopened = EditorViewModel(
            client: DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] }),
            documentID: documentID,
            title: "Doc",
            saveCoordinator: coordinator,
            contentCache: contentCache,
            childrenCache: DocumentChildrenCacheStore(userDefaults: UserDefaults(suiteName: childrenSuiteName)!)
        )
        stubLoadAndSavePipeline(content: "# Mine", log: log)  // the hiccup is over
        await reopened.load()

        XCTAssertEqual(reopened.blocks.first?.text, "Mine edited")
        await waitUntil { reopened.saveState == .saved }
        XCTAssertNil(draftStore.draft(for: documentID), "the stranded draft reached the server")
    }

    /// The invariant `refresh()`'s `markAvailableAgain()` call relies on: a document
    /// declared gone has no loaded content, so `refresh()` always diverts to `load()`.
    /// Break it and the terminal state can outlive the fetch that revived it.
    func testUnavailableAlwaysImpliesNoLoadedContent() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry())
        stubStatus(404)

        await viewModel.load()
        XCTAssertTrue(viewModel.isUnavailable)
        XCTAssertFalse(viewModel.hasLoadedContent)

        stubOffline()
        await viewModel.refresh()  // diverts into load(); still gone
        XCTAssertTrue(viewModel.isUnavailable)
        XCTAssertFalse(viewModel.hasLoadedContent)
    }

    /// `markAvailableAgain()` must not clear the terminal state for a response
    /// `apply` then declines to use. The teardown's own write-ahead flush starts a
    /// save, so a refresh issued while that PATCH is in flight has
    /// `mayPredateLocalSave == true` and `apply` returns without installing —
    /// leaving an empty body, no error and no spinner: a blank screen offering
    /// "Start writing" on a document that never loads.
    func testRecoveryFetchThatAppliesNothingKeepsTheTerminalState() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Mine"))
        stubOffline()
        await viewModel.load()
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Mine edited")

        stubStatus(404)
        await viewModel.load()  // teardown flushes: a PATCH is now in flight
        XCTAssertTrue(viewModel.isUnavailable)

        // A 200 arrives while that save is still pending, so apply() installs nothing.
        stubLoadAndSavePipeline(content: "# Mine", log: log, getDelay: 0.05)
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine edited")
        await viewModel.refresh()

        XCTAssertFalse(viewModel.hasLoadedContent, "nothing was installed")
        XCTAssertEqual(
            viewModel.errorKey, .editor_unavailable_with_draft,
            "a response apply() ignored must not clear the terminal message")
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
    }

    /// The terminal state must be sticky against the *local* phase: a document
    /// declared gone must not be re-rendered from a cached copy or the draft the
    /// 403 teardown just wrote, with its "no longer available" message cleared.
    func testUnavailableDocumentIsNotResurrectedFromLocalCopies() async {
        let (viewModel, _, draftStore, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Secret"))
        draftStore.save(PendingDraft(documentID: documentID, title: "D", markdown: "# Secret", updatedAt: Date()))
        stubStatus(403)
        await viewModel.load()
        XCTAssertTrue(viewModel.blocks.isEmpty)

        // Pull to refresh, and the revalidation fails transiently this time.
        stubOffline()
        await viewModel.refresh()

        XCTAssertTrue(viewModel.blocks.isEmpty, "revoked content is never re-rendered from disk")
        XCTAssertFalse(viewModel.hasLoadedContent)
        XCTAssertEqual(
            viewModel.errorKey, .editor_unavailable_with_draft,
            "the terminal message survives a transient failure")
    }

    /// No draft: the terminal message must not promise changes that don't exist.
    func testUnavailableDocumentWithNoDraftSaysNothingAboutUnsavedChanges() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry())
        stubStatus(404)

        await viewModel.load()

        XCTAssertEqual(viewModel.errorKey, .editor_unavailable)
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

        XCTAssertEqual(viewModel.errorKey, .editor_error_refresh)
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
        // A 2 s debounce with a 200 ms gap between edits leaves ~1.8 s of slack for
        // the negative assertion — the earlier 400 ms/200 ms pairing left only
        // ~200 ms, which a loaded CI runner routinely overran, firing the save early.
        let (viewModel, _, _, _) = makeEnvironment(autosaveInterval: .seconds(2))
        stubLoadAndSavePipeline(content: "Original text", log: log)
        await viewModel.load()
        viewModel.startEditing()

        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Change one")
        try? await Task.sleep(for: .milliseconds(200))
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Change two")

        // A fraction into the (restarted) debounce, the save must not have fired.
        XCTAssertEqual(savesInFlight(log), 0)

        await waitUntil(timeout: 6) { viewModel.saveState == .saved }
        XCTAssertEqual(savesInFlight(log), 1, "the two edits coalesced into one save")
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

    /// Typing and undoing after a failed save leaves `isDirty` true with content
    /// that matches `savedMarkdown`, so the flush enqueues nothing. `saveNow()` must
    /// still fire the retry — swallowing it strands the document behind its failed
    /// save (`reconcileDraft` pins the screen while that draft survives), and the
    /// reading surface has no retry affordance at all.
    func testSaveNowRetriesWhenADirtyFlushEnqueuesNothing() async {
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

        // Type and undo: dirty again, but the content is what the failed save held.
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Changed text!")
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Changed text")
        XCTAssertTrue(viewModel.isDirty)

        stubLoadAndSavePipeline(content: "Original text", log: log, contentStatus: 204)
        viewModel.saveNow()

        await waitUntil { viewModel.saveState == .saved }
        XCTAssertEqual(viewModel.saveState, .saved)
    }

    /// `applyPendingUpdate` is the last content-installing path; a draft must veto
    /// it, or it becomes the same install-over-unsaved-work bug review already found.
    func testApplyPendingUpdateRefusesWhileADraftExists() async {
        let (viewModel, _, draftStore, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry(markdown: "# Old"))
        stubOffline()
        await viewModel.load()
        viewModel.startEditing()
        stubLoad(content: "# New")
        await viewModel.load()
        XCTAssertTrue(viewModel.updateAvailable)
        viewModel.finishEditing()

        draftStore.save(PendingDraft(documentID: documentID, title: "Doc", markdown: "# Mine", updatedAt: Date()))
        viewModel.applyPendingUpdate()

        XCTAssertEqual(viewModel.blocks.first?.text, "Old", "unsaved work is never installed over")
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

    // MARK: - currentMarkdown

    func testCurrentMarkdownSerializesBlocksWhileEditing() async {
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoad(content: "# Title")
        await viewModel.load()
        viewModel.startEditing()

        XCTAssertEqual(viewModel.mode, .blocks)
        XCTAssertEqual(viewModel.currentMarkdown(), "# Title\n")
    }

    func testCurrentMarkdownReturnsTheLoadedSourceWhileReading() async {
        // Reading mode keeps `rawMarkdown` as the authoritative loaded source — a
        // late photo insert saves from it, not from a re-serialization of the lossy
        // blocks. A lone opening fence can't round-trip, so this is where it matters.
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoad(content: "```")
        await viewModel.load()

        XCTAssertEqual(viewModel.mode, .reading)
        XCTAssertEqual(viewModel.currentMarkdown(), "```")
    }

    func testNonRoundTrippableDocClosedWithoutEditingEnqueuesNoSave() async {
        // Removing the markdown fallback means a doc whose markdown can't survive a
        // block round-trip (a lone opening fence) now opens in `.blocks` rather than
        // a markdown source view. Opening and closing it without an edit must NOT
        // enqueue a full-overwrite save that would normalize the fence — the dirty
        // baseline `savedMarkdown = serializeMarkdown(blocks)` is what guarantees it.
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        stubLoad(content: "```")
        await viewModel.load()

        viewModel.startEditing()
        XCTAssertEqual(viewModel.mode, .blocks)
        viewModel.finishEditing()

        XCTAssertFalse(viewModel.isDirty)
        XCTAssertNil(coordinator.pendingSave(documentID: documentID), "a no-op session must not overwrite the fence")
        XCTAssertNil(draftStore.draft(for: documentID))
        XCTAssertEqual(viewModel.rawMarkdown, "```", "the untouched source is preserved verbatim")
    }

    func testFinishEditingSyncsTheReadingSourceToTheEditedBlocks() async {
        // `finishEditing`'s conditional resync is the sole path keeping the
        // reading-mode source fresh after an edit; a stale source would let a later
        // photo insert or Options "copy markdown" reflect the loaded body, not the edit.
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoad(content: "# Title")
        await viewModel.load()
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Edited heading")
        viewModel.finishEditing()

        XCTAssertEqual(viewModel.mode, .reading)
        XCTAssertEqual(viewModel.currentMarkdown(), "# Edited heading\n")
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

    /// The revalidation counterpart of
    /// `DocumentSaveCoordinatorTests.testSaveLandingAfterADeleteNeverRecreatesTheCacheEntry`:
    /// a content GET issued before the delete can be answered with a 200 *after*
    /// `handleDidDelete` purged the cache — and before SwiftUI cancels the
    /// editor's `.task`. `reconcileClean` write-throughs unconditionally, so
    /// without the generation bump the deleted body reappears on disk and keeps
    /// rendering from retained Search/Shared results until eviction.
    func testRevalidationLandingAfterADeleteNeverRecreatesTheCacheEntry() async {
        let log = RequestRecorder()
        let (viewModel, _, _, contentCache) = makeEnvironment()
        // Seeded so load()'s synchronous local phase installs it: the fetch that
        // follows is a revalidation, and `apply` reaches `reconcileClean`.
        contentCache.save(cachedEntry(markdown: "# Cached"))
        stubLoadAndSavePipeline(content: "# Server", log: log, getDelay: 0.2)

        async let loading: Void = viewModel.load()
        // The stub records at issue time, before the delayed delivery — so this
        // resolves while the GET is genuinely still in flight.
        await waitUntil { log.count(ofMethod: "GET", urlContaining: "formatted-content") >= 1 }
        viewModel.handleDidDelete()
        await loading

        XCTAssertNil(contentCache.content(for: documentID), "the purge survives the late 200")
        XCTAssertTrue(viewModel.isDocumentDiscarded)
    }

    // MARK: - Server baseline capture (plumbing for offline sync)

    /// A flush after editing fetched content carries the server body and its
    /// `updated_at` as the draft's baseline — the state the edit descends from.
    func testFlushCapturesServerBaselineFromFetchedContent() async {
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        stubLoad(content: "# Server body")
        await viewModel.load()  // installFetched captures the server baseline

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Server body edited")
        viewModel.flushPendingChanges()  // enqueue writes the draft synchronously

        // Read before the background save (all-200 stub) can settle and clear it.
        let baseline = draftStore.draft(for: documentID)?.baseline
        XCTAssertEqual(baseline?.markdown, "# Server body")
        // The exact server clock, not the client clock — a Date() regression in
        // installFetched would keep this non-nil but wrong.
        XCTAssertEqual(baseline?.serverUpdatedAt, fetchedUpdatedAt)

        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
    }

    /// The baseline can also come from a cache-restored copy — carrying the
    /// server `updated_at` the cache entry recorded (nil for void-save entries).
    func testFlushCapturesBaselineFromCacheRestoredContent() async {
        let (viewModel, coordinator, draftStore, contentCache) = makeEnvironment()
        let serverDate = Date(timeIntervalSince1970: 1_700_000_000)
        contentCache.save(
            CachedDocumentContent(
                documentID: documentID, title: "Cached Doc", markdown: "# Cached",
                syncedAt: Date(timeIntervalSince1970: 1_000_000), serverUpdatedAt: serverDate))
        stubOffline()
        await viewModel.load()  // cached copy on screen; revalidation fails, baseline from cache

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Cached edited")
        viewModel.flushPendingChanges()

        let baseline = draftStore.draft(for: documentID)?.baseline
        XCTAssertEqual(baseline?.markdown, "# Cached")
        XCTAssertEqual(baseline?.serverUpdatedAt, serverDate)

        // The offline save fails (draft stays); let it settle so no request
        // outlives the test.
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
    }

    /// Load-bearing: while a dirty screen observes a diverged server body, the
    /// revalidation routes through `cacheServerCopy`, which must NOT advance the
    /// baseline — the edit still descends from the body it was made against, so a
    /// later conflict check (a stack PR) must not push over the web edit we saw.
    func testCacheServerCopyDoesNotAdvanceTheBaseline() async {
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        stubLoad(content: "# Server body")
        await viewModel.load()  // baseline = server body A

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# My local edit")
        XCTAssertTrue(viewModel.isDirty)

        // A revalidation lands with a diverged body while the screen is dirty →
        // apply short-circuits to cacheServerCopy(B).
        stubLoad(content: "# Co-author edit")
        await viewModel.load()

        viewModel.flushPendingChanges()
        XCTAssertEqual(
            draftStore.draft(for: documentID)?.baseline?.markdown, "# Server body",
            "cacheServerCopy must not advance the baseline over an observed web edit")

        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
    }

    /// A server change installed while NOT editing (reconcileClean install branch)
    /// advances the baseline to the freshly-installed body.
    func testReconcileCleanInstallCapturesBaseline() async {
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        stubLoad(content: "# Server body")
        await viewModel.load()  // baseline = A, reading mode

        stubLoad(content: "# Co-author edit")
        await viewModel.load()  // not editing, not dirty → installs B, baseline = B

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Co-author edit and mine")
        viewModel.flushPendingChanges()

        let baseline = draftStore.draft(for: documentID)?.baseline
        XCTAssertEqual(baseline?.markdown, "# Co-author edit")
        XCTAssertEqual(baseline?.serverUpdatedAt, fetchedUpdatedAt)
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
    }

    /// Opting into a body stashed behind the "Updated" banner (applyPendingUpdate)
    /// makes that body the baseline — the on-screen content now descends from it.
    func testApplyPendingUpdateCapturesBaseline() async {
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        stubLoad(content: "# Server body")
        await viewModel.load()  // baseline = A

        viewModel.startEditing()  // editing, not dirty
        stubLoad(content: "# Co-author edit")
        await viewModel.load()  // server changed mid-edit → stashed behind the banner
        XCTAssertTrue(viewModel.updateAvailable)

        viewModel.finishEditing()
        viewModel.applyPendingUpdate()  // installs the stashed body → baseline = B

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Co-author edit and mine")
        viewModel.flushPendingChanges()

        let baseline = draftStore.draft(for: documentID)?.baseline
        XCTAssertEqual(baseline?.markdown, "# Co-author edit")
        XCTAssertEqual(baseline?.serverUpdatedAt, fetchedUpdatedAt)
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
    }

    /// The primary offline scenario: a draft persisted by an earlier session is
    /// reopened offline (restoreLocalContent's `.draft` branch reconstructs the
    /// baseline from it), edited, and flushed — the re-enqueued draft must still
    /// descend from the original server baseline, so a later conflict check can't
    /// tolerance-discard baseline-carrying work.
    func testDraftRestoreReconstructsBaselineForOfflineReopen() async {
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        let serverDate = Date(timeIntervalSince1970: 1_700_000_000)
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Offline edit",
                updatedAt: Date(), baseline: DraftBaseline(serverUpdatedAt: serverDate, markdown: "# Server base")))
        stubOffline()
        await viewModel.load()  // restoreLocalContent .draft branch → serverBaseline = draft.baseline

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Offline edit more")
        viewModel.flushPendingChanges()

        XCTAssertEqual(draftStore.draft(for: documentID)?.baseline?.markdown, "# Server base")
        XCTAssertEqual(draftStore.draft(for: documentID)?.baseline?.serverUpdatedAt, serverDate)
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
    }

    /// Reopening a document whose save is still in flight runs restoreLocalContent's
    /// `.pendingSave` branch, which reconstructs the baseline from the stored draft.
    func testPendingSaveRestoreReconstructsBaseline() async {
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        let baseline = DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 1_000), markdown: "# Base")
        // Hold the content PATCH open so the save stays in flight while we reopen.
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return MockURLProtocol.Stub(
                    statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
            }
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") {
                return MockURLProtocol.Stub(statusCode: 204, headers: [:], body: Data(), error: nil, delay: 0.3)
            }
            return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: Data(), error: nil)
        }
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Queued", baseline: baseline)
        XCTAssertNotNil(coordinator.pendingSave(documentID: documentID), "the save is in flight")

        await viewModel.load()  // restoreLocalContent .pendingSave branch
        XCTAssertEqual(viewModel.displaySource, .pendingSave)

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Queued edit")
        viewModel.flushPendingChanges()

        XCTAssertEqual(draftStore.draft(for: documentID)?.baseline?.markdown, "# Base")
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
    }

    /// A 404 mid-edit tears the document down, but `becomeUnavailable` flushes
    /// write-ahead *first* — the persisted draft must carry the baseline so a
    /// transient 404's replay (recoverDrafts / reconcileDraft) can reconcile it.
    func testTeardownFlushCarriesTheServerBaseline() async {
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        stubLoad(content: "# Server body")
        await viewModel.load()  // installFetched → baseline A

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Server body edited")
        XCTAssertTrue(viewModel.isDirty)

        stubStatus(404)
        await viewModel.load()  // 404 → becomeUnavailable flushes write-ahead with the baseline
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }

        XCTAssertEqual(
            draftStore.draft(for: documentID)?.baseline?.markdown, "# Server body",
            "the write-ahead teardown flush persists the baseline the edit descended from")
    }

    /// A stored draft plus a successful fetch reaches reconcileDraft's tolerance
    /// (draft-wins) branch, which re-enqueues the draft. That re-enqueue must carry
    /// the draft's own baseline through — the draft-replay reconciliation the
    /// baseline exists to serve.
    func testReconcileDraftReplayCarriesTheBaseline() async {
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        let serverDate = Date(timeIntervalSince1970: 1_700_000_000)
        // Draft written "now" is newer than the fixture's 2026-01-15 server
        // updated_at, so the fetch lands in reconcileDraft's tolerance-push branch.
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Draft body", updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: serverDate, markdown: "# Server base")))
        let body = formattedBody(content: "# Server")
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: body, error: nil)
            }
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") {
                return MockURLProtocol.Stub(statusCode: 204, headers: [:], body: Data(), error: nil, delay: 0.3)
            }
            return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: Data(), error: nil)
        }

        await viewModel.load()  // reconcileDraft tolerance-push re-enqueues with draft.baseline

        // The replay must actually have fired (not just left the identical draft
        // untouched): the re-enqueued save is in flight, held open by the stub.
        XCTAssertNotNil(
            coordinator.pendingSave(documentID: documentID), "the tolerance replay re-enqueued a save")
        // …and that in-flight draft carries the baseline through.
        let baseline = draftStore.draft(for: documentID)?.baseline
        XCTAssertEqual(baseline?.markdown, "# Server base")
        XCTAssertEqual(baseline?.serverUpdatedAt, serverDate)
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
    }

    /// reconcileClean's unchanged-body (else) branch advances the baseline's
    /// timestamp: a cache-restored entry with an unknown (void-save) server
    /// timestamp gets promoted to the real server clock once a clean revalidation
    /// confirms the same body.
    func testReconcileCleanUnchangedBodyAdvancesBaselineTimestamp() async {
        let (viewModel, coordinator, draftStore, contentCache) = makeEnvironment()
        contentCache.save(
            CachedDocumentContent(
                documentID: documentID, title: "Doc", markdown: "# Body",
                syncedAt: Date(timeIntervalSince1970: 1_000_000), serverUpdatedAt: nil))
        stubLoad(content: "# Body")  // same body (serverChanged == false), known updated_at
        await viewModel.load()  // reconcileClean else-branch promotes nil → the server timestamp

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Body edited")
        viewModel.flushPendingChanges()

        XCTAssertEqual(
            draftStore.draft(for: documentID)?.baseline?.serverUpdatedAt, fetchedUpdatedAt,
            "an unchanged-body revalidation advances the baseline timestamp from nil to the server clock")
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
    }

    /// Mirror of testCacheServerCopyDoesNotAdvanceTheBaseline for the *editing-but-
    /// clean* path: a diverged server body that lands mid-edit is stashed behind the
    /// "Updated" banner, and the on-screen (older) body must keep owning the
    /// baseline — the caret is in it, so an edit descends from it, not the stash.
    func testReconcileCleanStashDoesNotAdvanceTheBaseline() async {
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        stubLoad(content: "# Server body")
        await viewModel.load()  // baseline A

        viewModel.startEditing()  // editing, not yet dirty
        stubLoad(content: "# Co-author edit")
        await viewModel.load()  // server changed mid-edit → stashed, baseline stays A
        XCTAssertTrue(viewModel.updateAvailable)

        // Edit WITHOUT opting into the stash, then flush.
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# My edit")
        viewModel.flushPendingChanges()

        XCTAssertEqual(
            draftStore.draft(for: documentID)?.baseline?.markdown, "# Server body",
            "the editing stash must not advance the baseline over an observed web edit")
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
    }

    /// A fetch that races one of our own saves (mayPredateLocalSave == true) makes
    /// `apply` early-return, taking nothing from the response — including the
    /// baseline. If it did, a later full-overwrite save would push the resurrected
    /// stale body back to the server.
    func testMayPredateFetchDoesNotAdvanceTheBaseline() async {
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        stubLoad(content: "# Server body")
        await viewModel.load()  // baseline A

        // Hold the save's content PATCH open so it stays in flight; a GET that lands
        // during it is answered with a diverged body and races the save.
        let bodyB = formattedBody(content: "# Co-author edit")
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: bodyB, error: nil)
            }
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") {
                return MockURLProtocol.Stub(statusCode: 204, headers: [:], body: Data(), error: nil, delay: 0.4)
            }
            return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: Data(), error: nil)
        }
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# My edit")
        viewModel.flushPendingChanges()  // save enqueued, PATCH held → in flight
        XCTAssertNotNil(coordinator.pendingSave(documentID: documentID))

        await viewModel.refresh()  // fetch B races the in-flight save → apply early-returns

        // Edit again and flush; the still-in-flight save queues this, writing a draft.
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# My edit 2")
        viewModel.flushPendingChanges()
        XCTAssertEqual(
            draftStore.draft(for: documentID)?.baseline?.markdown, "# Server body",
            "a fetch racing our own save must not advance the baseline to the raced body")
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
    }

    /// The `saveNow` failed-save retry is a baseline-carrying enqueue site too: it
    /// must re-push with the stored draft's baseline, not nil (which would degrade
    /// a retried offline save to the legacy tolerance rule).
    func testSaveNowRetryPreservesTheBaseline() async {
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        let bodyA = formattedBody(content: "# Server body")
        // GET ok (baseline A); the content PATCH 500s so the save fails and the
        // draft (with its baseline) survives to be retried.
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: bodyA, error: nil)
            }
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") {
                return MockURLProtocol.Stub(statusCode: 500, headers: [:], body: Data(), error: nil)
            }
            return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: Data(), error: nil)
        }
        await viewModel.load()  // installFetched → baseline A

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Server body edited")
        viewModel.flushPendingChanges()
        await waitUntil {
            if case .failed = coordinator.state(for: self.documentID) { return true }
            return false
        }
        XCTAssertEqual(
            draftStore.draft(for: documentID)?.baseline?.markdown, "# Server body",
            "the failed draft carries the baseline")

        viewModel.saveNow()  // retry re-enqueues with the stored draft's baseline
        let baseline = draftStore.draft(for: documentID)?.baseline
        XCTAssertEqual(baseline?.markdown, "# Server body")
        XCTAssertEqual(baseline?.serverUpdatedAt, fetchedUpdatedAt)
        await waitUntil {
            if case .failed = coordinator.state(for: self.documentID) { return true }
            return false
        }
    }
}
