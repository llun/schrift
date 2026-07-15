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
        autosaveInterval: Duration = .seconds(10),
        remoteChangeDebounce: Duration = .milliseconds(600)
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
            autosaveInterval: autosaveInterval,
            remoteChangeDebounce: remoteChangeDebounce
        )
        return (viewModel, coordinator, draftStore, contentCache)
    }

    private func cachedEntry(markdown: String = "# Cached", syncedAt: Date = Date(timeIntervalSince1970: 1_000_000))
        -> CachedDocumentContent
    {
        CachedDocumentContent(documentID: documentID, title: "Cached Doc", markdown: markdown, syncedAt: syncedAt)
    }

    private func formattedBody(
        content: String?, title: String = "Doc", updatedAt: String = "2026-01-15T10:30:00Z"
    ) -> Data {
        let contentJSON = content.map { "\"\($0)\"" } ?? "null"
        return Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "\(title)", "content": \(contentJSON), "created_at": "2026-01-15T10:30:00Z", "updated_at": "\(updatedAt)"}
            """.utf8)
    }

    /// A server `updated_at` after `formattedBody`'s default — i.e. the server has been written
    /// since the baseline a first load established, so the title rule's "no newer than the
    /// baseline" short-circuit does not fire.
    private let laterServerUpdatedAt = "2027-01-01T00:00:00Z"

    /// The server `updated_at` in `formattedBody`'s default. A baseline older than this is one
    /// the server has moved past; a baseline at or after it is one the server hasn't been
    /// written since.
    private var fixtureServerUpdatedAt: Date {
        ISO8601DateFormatter().date(from: "2026-01-15T10:30:00Z")!
    }

    private func stubLoad(content: String?, log: RequestRecorder? = nil) {
        let body = formattedBody(content: content)
        MockURLProtocol.stubHandler = { request in
            log?.record(request)
            return .init(statusCode: 200, headers: [:], body: body, error: nil)
        }
    }

    /// A co-author's body: changed content **and a newer `updated_at`** than the shared fixture.
    private func divergedServerBody(content: String) -> Data {
        Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "\(content)", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-02-20T10:30:00Z"}
            """.utf8)
    }

    /// A co-author's write: a changed body **and a newer `updated_at`**. The shared
    /// `formattedBody` fixture pins `updated_at` to 2026-01-15, so reusing it for a "server
    /// changed" scenario silently makes rule 2 say the server has *not* moved past the
    /// baseline — a test written that way passes for the wrong reason. Saves go through.
    private func stubDivergedServer(content: String, log: RequestRecorder) {
        let body = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "\(content)", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-02-20T10:30:00Z"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: body, error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
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

    // MARK: - live-collaboration change signal

    func testRemoteChangeSignalRevalidatesAndAppliesTheNewBody() async {
        let (viewModel, _, _, _) = makeEnvironment(remoteChangeDebounce: .milliseconds(1))
        stubLoad(content: "# First")
        await viewModel.load()
        XCTAssertEqual(viewModel.rawMarkdown, "# First")

        // A peer signals a change: a debounced silent revalidation adopts the new
        // clean body (the same rule as pull-to-refresh / on-open revalidation).
        stubLoad(content: "# Second")
        viewModel.noteRemoteChange()
        await waitUntil { viewModel.rawMarkdown == "# Second" }
        XCTAssertFalse(viewModel.updateAvailable, "a clean copy adopts the body directly, no banner")
    }

    func testRemoteChangeSignalBeforeLoadIsANoOp() async {
        let recorder = RequestRecorder()
        let (viewModel, _, _, _) = makeEnvironment(remoteChangeDebounce: .milliseconds(1))
        stubLoad(content: "# Body", log: recorder)

        // No load() yet — nothing on screen, so the signal must not fetch.
        viewModel.noteRemoteChange()
        await waitAndConfirmNever { recorder.count(ofMethod: "GET", urlContaining: "content") > 0 }
    }

    func testRapidRemoteChangeSignalsCoalesceIntoOneRevalidation() async {
        let recorder = RequestRecorder()
        let (viewModel, _, _, _) = makeEnvironment(remoteChangeDebounce: .milliseconds(80))
        stubLoad(content: "# First", log: recorder)
        await viewModel.load()
        let afterLoad = recorder.count(ofMethod: "GET", urlContaining: "content")

        // Three signals inside one debounce window collapse to a single re-fetch.
        viewModel.noteRemoteChange()
        viewModel.noteRemoteChange()
        viewModel.noteRemoteChange()
        await waitUntil { recorder.count(ofMethod: "GET", urlContaining: "content") == afterLoad + 1 }
        await waitAndConfirmNever { recorder.count(ofMethod: "GET", urlContaining: "content") > afterLoad + 1 }
    }

    func testRemoteChangeSignal404WhileEditingDoesNotTearDown() async {
        let (viewModel, _, _, _) = makeEnvironment(remoteChangeDebounce: .milliseconds(1))
        stubLoad(content: "# Body")
        await viewModel.load()
        viewModel.startEditing()

        // A peer's edit prompts a revalidation that 404s (a transient hiccup, or a
        // co-author's own permission flap). A background prompt must never eject an
        // active editing session — unlike an on-open / pull-to-refresh 404.
        stubStatus(404)
        viewModel.noteRemoteChange()
        await waitAndConfirmNever { viewModel.isUnavailable }
        XCTAssertTrue(viewModel.hasLoadedContent)
        XCTAssertTrue(viewModel.isEditing)
        XCTAssertEqual(viewModel.rawMarkdown, "# Body")
    }

    func testRemoteChangeSignalAfterDeleteIssuesNoFetch() async {
        let recorder = RequestRecorder()
        let (viewModel, _, _, _) = makeEnvironment(remoteChangeDebounce: .milliseconds(1))
        stubLoad(content: "# Body", log: recorder)
        await viewModel.load()
        let afterLoad = recorder.count(ofMethod: "GET", urlContaining: "content")

        // A late signal after the document is deleted must not fetch (the task is
        // cancelled and `revalidateFromRemoteChange` re-checks `isDocumentDiscarded`).
        viewModel.handleDidDelete()
        viewModel.noteRemoteChange()
        await waitAndConfirmNever { recorder.count(ofMethod: "GET", urlContaining: "content") > afterLoad }
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
        let log = RequestRecorder()
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        // Fixture updated_at is 2026-01-15T10:30:00Z; a draft stamped now is
        // far newer → within tolerance, draft stays.
        draftStore.save(PendingDraft(documentID: documentID, title: "Draft", markdown: "# Draft", updatedAt: Date()))
        // Hold the hand-back re-save's PATCH open: within tolerance, reconcileDraft
        // re-enqueues the draft, and a *completed* re-save would legitimately clear
        // it — which raced the assertion below and flaked on fast CI machines.
        let body = formattedBody(content: "# Server")
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: body, error: nil)
            }
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") {
                return MockURLProtocol.Stub(statusCode: 204, headers: [:], body: Data(), error: nil, delay: 0.3)
            }
            return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: Data(), error: nil)
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.rawMarkdown, "# Draft", "the within-tolerance draft's content stays on screen")
        XCTAssertNotNil(
            draftStore.draft(for: documentID), "the draft is kept (re-enqueued), not server-wins-discarded")
        // Let the held re-save settle so nothing outlives the test.
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
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
        stubLoadAndSavePipeline(content: "# Server", log: log, contentStatus: 400)
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
        stubLoadAndSavePipeline(content: "# Server", log: log, contentStatus: 400)
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
        stubLoadAndSavePipeline(content: "# Server", log: log, contentStatus: 400)
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
        stubLoadAndSavePipeline(content: "Original text", log: log, contentStatus: 400)
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

    /// A transient (5xx/offline) save failure surfaces as `.pendingSync`, not the
    /// scary `.failed`, and still counts as unsaved local content (its draft is the
    /// user's only copy until the queued sync lands).
    func testTransientSaveFailureSurfacesPendingSyncAndCountsAsUnsaved() async {
        let log = RequestRecorder()
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "# Server body", log: log, contentStatus: 503)
        await viewModel.load()
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Server body edited")
        viewModel.flushPendingChanges()
        await waitUntil { viewModel.saveState == .pendingSync }

        XCTAssertEqual(viewModel.saveState, .pendingSync)
        XCTAssertTrue(viewModel.hasUnsavedLocalContent, "a pending-sync draft is unsaved local content")
    }

    /// Regression: a queued offline (`.pendingSync`) draft must survive a
    /// pull-to-refresh even when a co-author moved the server past the tolerance
    /// window. reconcileDraft's guard covers `.pendingSync`, not only `.failed`;
    /// without it the draft is silently discarded and the server body installed.
    func testPendingSyncDraftSurvivesAPullToRefreshBeyondTolerance() async {
        let log = RequestRecorder()
        let (viewModel, _, draftStore, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "# Server body", log: log, contentStatus: 503)
        await viewModel.load()
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Offline edit")
        viewModel.flushPendingChanges()
        await waitUntil { viewModel.saveState == .pendingSync }
        XCTAssertNotNil(draftStore.draft(for: documentID))

        // A co-author edits: the server updated_at is now far past the window.
        let futureBody = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "# Co-author", "created_at": "2099-01-01T00:00:00Z", "updated_at": "2099-01-01T00:00:00Z"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: futureBody, error: nil)
        }
        await viewModel.refresh()

        XCTAssertTrue(
            draftStore.draft(for: documentID)?.markdown.contains("Offline edit") ?? false,
            "the queued offline edit is preserved, not tolerance-discarded on refresh")
    }

    /// Recoverability: an online transient failure parks the save at `.pendingSync`
    /// with no auto-sync trigger able to fire, so `saveNow()` must re-enqueue it
    /// (the manual retry the caption offers when online).
    func testSaveNowRetriesAPendingSyncDraft() async {
        let log = RequestRecorder()
        let (viewModel, _, draftStore, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "# Server body", log: log, contentStatus: 503)
        await viewModel.load()
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Edited")
        viewModel.flushPendingChanges()
        await waitUntil { viewModel.saveState == .pendingSync }

        // The server recovers; the manual retry re-enqueues and it succeeds.
        stubLoadAndSavePipeline(content: "# Server body", log: log, contentStatus: 204)
        viewModel.saveNow()
        await waitUntil { viewModel.saveState == .saved }
        XCTAssertNil(draftStore.draft(for: documentID), "the retried pending-sync draft synced and cleared")
    }

    /// Typing and undoing after a failed save leaves `isDirty` true with content
    /// that matches `savedMarkdown`, so the flush enqueues nothing. `saveNow()` must
    /// still fire the retry — swallowing it strands the document behind its failed
    /// save (`reconcileDraft` pins the screen while that draft survives), and the
    /// reading surface has no retry affordance at all.
    func testSaveNowRetriesWhenADirtyFlushEnqueuesNothing() async {
        let log = RequestRecorder()
        let (viewModel, _, _, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "Original text", log: log, contentStatus: 400)
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
        stubLoadAndSavePipeline(content: "Original text", log: log, contentStatus: 400)
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
        XCTAssertEqual(baseline?.title, "Doc", "the baseline records the server's TITLE too, or a rename can't be seen")

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
        XCTAssertEqual(baseline?.title, "Cached Doc", "the cache entry's title anchors rename detection too")

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
        XCTAssertEqual(baseline?.title, "Doc")
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
        XCTAssertEqual(baseline?.title, "Doc", "the stashed body's fetch also recorded its title")
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

        // The flush actually re-enqueued the NEW edit (not just left the identical
        // pre-existing draft in place) — otherwise the baseline check is vacuous.
        XCTAssertTrue(
            draftStore.draft(for: documentID)?.markdown.contains("more") ?? false,
            "the flush re-enqueued the edited content")
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

        // The flush actually re-enqueued the NEW edit, not the original "# Queued".
        XCTAssertTrue(
            draftStore.draft(for: documentID)?.markdown.contains("Queued edit") ?? false,
            "the flush re-enqueued the edited content")
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

    /// A stored draft plus a successful fetch reaches reconcileDraft's push
    /// (draft-wins) branch, which re-enqueues the draft. That re-enqueue must carry
    /// the draft's own baseline through — the draft-replay reconciliation the
    /// baseline exists to serve.
    func testReconcileDraftReplayCarriesTheBaseline() async {
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        // Baseline no older than the fixture's 2026-01-15 server updated_at, so
        // `draftSyncDecision` rule 2 pushes (the server has not moved past the baseline)
        // and reconcileDraft re-enqueues with the draft's baseline.
        let serverDate = Date(timeIntervalSince1970: 1_800_000_000)
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

        await viewModel.load()  // reconcileDraft baseline-push re-enqueues with draft.baseline

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

    // MARK: - Sync conflicts

    /// A stored draft whose baseline has diverged from the server (newer server
    /// `updated_at` *and* a different body) makes `reconcileDraft` record a conflict:
    /// the reading surface exposes it (`syncConflict`), and the draft — the user's
    /// only copy — stays on screen rather than being overwritten by the server body.
    func testReconcileDraftRecordsAConflictWhenTheServerDiverges() async {
        let (viewModel, _, draftStore, _) = makeEnvironment()
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Mine", updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000), markdown: "# Base")
            )
        )
        stubLoad(content: "# Co-author edit")

        await viewModel.load()

        XCTAssertNotNil(viewModel.syncConflict, "the reading surface exposes the detected conflict")
        XCTAssertEqual(
            draftStore.draft(for: documentID)?.markdown, "# Mine", "the draft is not overwritten by the server body")
    }

    /// The hole this PR exists to close. `reconcileDraft` returns early for a
    /// `.pendingSync`/`.failed` draft so the tolerance rule can't discard visible
    /// content — but it must still *detect* a conflict on the way out. Without that,
    /// a revalidation proves the server moved on, records nothing, and the user's next
    /// "tap to retry" (`saveNow` enqueues straight through) full-overwrites the web
    /// edit the app had already fetched. Detection engages the enqueue-hold, so the
    /// retry is held and the pill asks first.
    func testPendingSyncDraftDetectsAConflictSoARetryCannotOverwriteTheServer() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()

        // 1. Load the server copy (baseline "# Base" @ the fixture's 2026-01-15), edit
        //    it, and let the save fail transiently → .pendingSync with a draft.
        let baseBody = formattedBody(content: "# Base")
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: baseBody, error: nil)
            }
            return .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        await viewModel.load()
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Mine")
        viewModel.flushPendingChanges()
        await waitUntil {
            if case .pendingSync = coordinator.state(for: self.documentID) { return true }
            return false
        }
        let savesBeforeRetry = savesInFlight(log)
        // The user's only copy of the edit. Every assertion below compares against this
        // snapshot rather than a literal, so the test pins *preservation*, not the
        // serializer's exact output.
        let queuedDraft = draftStore.draft(for: documentID)?.markdown
        XCTAssertNotNil(queuedDraft)
        XCTAssertTrue(queuedDraft?.contains("Mine") == true, "the draft holds the offline edit")

        // 2. A co-author edits on the web: the server body diverges from the baseline
        //    and its updated_at moves past it. The save PATCH would now SUCCEED.
        let divergedBody = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "# Co-author edit", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-02-20T10:30:00Z"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: divergedBody, error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }

        // 3. A pull-to-refresh observes the divergence while still .pendingSync.
        await viewModel.refresh()

        XCTAssertNotNil(viewModel.syncConflict, "the observed web edit must be recorded as a conflict")
        XCTAssertEqual(
            draftStore.draft(for: documentID)?.markdown, queuedDraft,
            "the queued edit is still the user's only copy — never discarded here")

        // 4. The user taps retry. It must be HELD by the conflict, not pushed: pushing
        //    would full-overwrite "# Co-author edit" with the "# Base"-derived draft.
        viewModel.saveNow()

        await waitAndConfirmNever { self.savesInFlight(log) > savesBeforeRetry }
        XCTAssertNotNil(viewModel.syncConflict, "still awaiting the user's choice")
        XCTAssertEqual(
            draftStore.draft(for: documentID)?.markdown, queuedDraft, "the held retry keeps the draft intact")
    }

    /// "Keep mine" flushes any in-progress edit, clears the conflict, and pushes the
    /// draft (last-writer-wins).
    func testResolveConflictKeepingMinePushesTheDraft() async {
        let log = RequestRecorder()
        let (viewModel, _, draftStore, _) = makeEnvironment()
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Mine", updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000), markdown: "# Base")
            )
        )
        let coauthorBody = formattedBody(content: "# Co-author edit")
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: coauthorBody, error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)  // content / title PATCH
        }
        await viewModel.load()
        XCTAssertNotNil(viewModel.syncConflict)

        viewModel.resolveConflictKeepingMine()

        // The push is asynchronous — wait for its content PATCH to land, not just for
        // the (synchronously cleared) conflict record.
        await waitUntil { self.savesInFlight(log) >= 1 }
        XCTAssertNil(viewModel.syncConflict, "resolving clears the conflict record")
        await waitUntil { viewModel.saveCoordinator.pendingSave(documentID: self.documentID) == nil }
    }

    /// "Keep the server version" clears the conflict, discards the local draft, and
    /// re-fetches so the server body installs through the normal guarded funnel —
    /// never pushing, and taking no content from the conflict record itself.
    func testResolveConflictKeepingServerDiscardsTheDraftAndShowsTheServerBody() async {
        let log = RequestRecorder()
        let (viewModel, _, draftStore, _) = makeEnvironment()
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Mine", updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000), markdown: "# Base")
            )
        )
        let coauthorBody = formattedBody(content: "# Co-author edit")
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 200, headers: [:], body: coauthorBody, error: nil)
        }
        await viewModel.load()
        XCTAssertNotNil(viewModel.syncConflict)

        await viewModel.resolveConflictKeepingServer()

        XCTAssertNil(viewModel.syncConflict, "the conflict is resolved")
        XCTAssertNil(draftStore.draft(for: documentID), "the local draft is discarded")
        XCTAssertEqual(savesInFlight(log), 0, "keep-server never pushes")
        XCTAssertTrue(
            viewModel.blocks.contains { $0.text.contains("Co-author edit") },
            "the server body is re-fetched and installed")
    }

    /// "Keep the server version" must **fetch before it discards**. A conflict is usually
    /// reviewed on the same flaky connection that caused it, so the fetch failing is the
    /// common case — and discarding first left the user staring at the body they had just
    /// thrown away, with it gone from disk, the conflict record cleared and the stale
    /// baseline intact. The next keystroke then full-overwrote the server copy they had
    /// explicitly chosen to keep. Nothing may be destroyed until the winning body is in hand.
    func testKeepingTheServerVersionKeepsTheDraftWhenTheFetchFails() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Mine", updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000), markdown: "# Base")
            )
        )
        let coauthorBody = formattedBody(content: "# Co-author edit")
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 200, headers: [:], body: coauthorBody, error: nil)
        }
        await viewModel.load()
        XCTAssertNotNil(viewModel.syncConflict)

        // The device drops offline before the user commits to the server's copy.
        stubOffline()
        await viewModel.resolveConflictKeepingServer()

        XCTAssertNotNil(
            draftStore.draft(for: documentID), "a failed fetch must not cost the user their only copy")
        XCTAssertNotNil(viewModel.syncConflict, "the conflict survives, so the pill and sheet stay available")
        XCTAssertNotNil(viewModel.errorKey, "the failure is surfaced")
        XCTAssertTrue(
            viewModel.blocks.contains { $0.text.contains("Mine") },
            "the draft is still on screen — and still backed by disk")
        XCTAssertEqual(savesInFlight(log), 0)
    }

    /// The destructive resolution taken from inside a dirty editing session: the edit is
    /// discarded (not re-drafted, not pushed) and the autosave debounce must not fire a
    /// save after the fact.
    func testKeepingTheServerVersionFromADirtyEditingSessionPushesNothing() async {
        let log = RequestRecorder()
        let (viewModel, _, draftStore, _) = makeEnvironment(autosaveInterval: .milliseconds(50))
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Mine", updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000), markdown: "# Base")
            )
        )
        let coauthorBody = formattedBody(content: "# Co-author edit")
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: coauthorBody, error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        await viewModel.load()
        XCTAssertNotNil(viewModel.syncConflict)

        // The user keeps typing, arming the autosave debounce, then chooses the server copy.
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Mine and more")
        XCTAssertTrue(viewModel.isDirty)

        await viewModel.resolveConflictKeepingServer()

        XCTAssertNil(viewModel.syncConflict)
        XCTAssertNil(draftStore.draft(for: documentID), "the discarded edit leaves no draft behind")
        XCTAssertFalse(viewModel.isDirty, "the editing session ended")
        XCTAssertEqual(viewModel.mode, .reading)
        XCTAssertTrue(
            viewModel.blocks.contains { $0.text.contains("Co-author edit") }, "the server body is installed")
        // Past the (50ms) autosave window: the armed debounce must not resurrect the edit.
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }
    }

    /// Keeping the server version must still work when the enqueue-hold has parked a save
    /// in the queued slot (the user typed once more after the conflict landed). A held save
    /// is **never sent**, so it cannot have raced the fetch — but `SaveMarker.hadPendingSave`
    /// used to ask `pendingSave != nil`, which the hold pins true forever (nothing drains it
    /// and `settledSaves` never advances). `mayPredateSave` was therefore true on every
    /// attempt, permanently wedging the non-destructive resolution and leaving only the
    /// overwrite the user had explicitly declined.
    func testKeepingTheServerVersionWorksWithASaveHeldByTheConflict() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Mine", updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000), markdown: "# Base")
            )
        )
        let coauthorBody = formattedBody(content: "# Co-author edit")
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: coauthorBody, error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        await viewModel.load()
        XCTAssertNotNil(viewModel.syncConflict)

        // The user keeps typing after the conflict lands; the flush is HELD, not pushed.
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Mine again")
        viewModel.flushPendingChanges()
        XCTAssertNotNil(coordinator.pendingSave(documentID: documentID), "the save is parked by the hold")
        XCTAssertEqual(savesInFlight(log), 0, "and never sent")

        await viewModel.resolveConflictKeepingServer()

        XCTAssertNil(viewModel.syncConflict, "the resolution is not wedged by the held save")
        XCTAssertNil(draftStore.draft(for: documentID))
        XCTAssertNil(coordinator.pendingSave(documentID: documentID), "the held save is dropped with the draft")
        XCTAssertTrue(
            viewModel.blocks.contains { $0.text.contains("Co-author edit") }, "the server body is installed")
        XCTAssertEqual(savesInFlight(log), 0, "keep-server never pushes")
    }

    /// "Keep mine" pushes the user's **newest in-progress** text, not the older stored
    /// draft — which is what the load-bearing `flushPendingChanges()` in
    /// `resolveConflictKeepingMine()` is for.
    func testKeepingMineFromAnEditingSessionPushesTheNewestText() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Stored draft", updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000), markdown: "# Base")
            )
        )
        let coauthorBody = formattedBody(content: "# Co-author edit")
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: coauthorBody, error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        await viewModel.load()
        XCTAssertNotNil(viewModel.syncConflict)

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Newest in-progress text")

        viewModel.resolveConflictKeepingMine()

        // Snapshot SYNCHRONOUSLY. `enqueue`/`start` set the pending save before returning,
        // and `finish` clears it the moment the save settles — so reading it after an await
        // races the (immediately-stubbed) PATCH, and an `Optional?.contains(...) != false`
        // test would then pass **vacuously** on nil, whatever was actually pushed.
        let released = coordinator.pendingSave(documentID: documentID)
        XCTAssertNotNil(released, "keep-mine released a push")
        XCTAssertTrue(
            released?.markdown.contains("Newest in-progress text") == true,
            "the released push must carry the newest in-progress edit")
        XCTAssertFalse(
            released?.markdown.contains("Stored draft") == true,
            "…and not the older stored draft — which is what `flushPendingChanges()` is for")

        await waitUntil { self.savesInFlight(log) >= 1 }
        XCTAssertNil(viewModel.syncConflict)
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
    }

    /// The post-await guard in `resolveConflictKeepingServer()`: ending the editing session
    /// does not lock the screen, so the user can tap back in and type **while the fetch is
    /// in flight**. That work was never part of the choice they made, so it must not be
    /// destroyed. Held open with `Stub(delay:)` and pinned on the recorded GET so the edit
    /// really does land inside the await.
    func testKeepingTheServerVersionAbandonsIfTheUserEditsDuringTheFetch() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Mine", updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000), markdown: "# Base")
            )
        )
        let coauthorBody = formattedBody(content: "# Co-author edit")
        // The FIRST GET (load) answers immediately; the resolution's GET is held open.
        MockURLProtocol.stubHandler = { request in
            let priorGets = log.count(ofMethod: "GET", urlContaining: "formatted-content")
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(
                    statusCode: 200, headers: [:], body: coauthorBody, error: nil,
                    delay: priorGets == 0 ? 0 : 0.4)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        await viewModel.load()
        XCTAssertNotNil(viewModel.syncConflict)
        let getsAfterLoad = log.count(ofMethod: "GET", urlContaining: "formatted-content")

        async let resolution: Void = viewModel.resolveConflictKeepingServer()
        // Wait until the resolution's fetch is genuinely in flight, then type into it.
        await waitUntil { log.count(ofMethod: "GET", urlContaining: "formatted-content") > getsAfterLoad }
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Typed after choosing the server copy")
        viewModel.flushPendingChanges()
        await resolution

        XCTAssertNotNil(
            viewModel.syncConflict, "the conflict stands, so the user can decide again with the new edit in hand")
        XCTAssertTrue(
            draftStore.draft(for: documentID)?.markdown.contains("Typed after choosing the server copy") == true,
            "the post-choice edit must survive on disk")
        XCTAssertFalse(
            viewModel.blocks.contains { $0.text.contains("Co-author edit") },
            "the server body must not be installed over an edit the user never agreed to discard")
        XCTAssertEqual(savesInFlight(log), 0, "and the held save is still held")
        _ = coordinator
    }

    /// Keep-mine's baseline advance has to survive the *next autosave flush*. The
    /// coordinator rewrites the stored draft's baseline, but `enqueue` rebuilds the draft
    /// from whatever baseline its caller passes — and `flushPendingChanges` passes the
    /// editor's `serverBaseline`. If that stayed stale, the very next keystroke after a
    /// failed push would clobber the advance and the identical conflict would be
    /// re-detected and re-held, silently undoing the answer the user just gave.
    func testKeepingMineAdvancesTheEditorBaselineSoALaterFlushDoesNotResurrectTheConflict() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Mine", updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000), markdown: "# Base")
            )
        )
        let coauthorBody = formattedBody(content: "# Co-author edit")  // updated_at = 2026-01-15
        // The push fails transiently, exactly as it does on the connection that caused the conflict.
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: coauthorBody, error: nil)
            }
            return .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        await viewModel.load()
        XCTAssertNotNil(viewModel.syncConflict)

        viewModel.resolveConflictKeepingMine()
        await waitUntil {
            if case .pendingSync = coordinator.state(for: self.documentID) { return true }
            return false
        }

        // The user keeps typing after the failed push. This flush re-enqueues with the
        // editor's baseline — which must now be the one they chose to overwrite.
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Still mine")
        viewModel.flushPendingChanges()

        XCTAssertEqual(
            draftStore.draft(for: documentID)?.baseline?.serverUpdatedAt, fetchedUpdatedAt,
            "the flush must not clobber the advanced baseline with the stale pre-conflict one")

        // Settle that flush's save first: `syncPendingDrafts` skips any document with an
        // in-flight or queued save *before* it fetches, so re-syncing while it is still in
        // flight would skip the draft entirely and leave `conflict(for:)` trivially nil —
        // passing no matter whether the baseline advance stuck.
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
        // …so a later sync does not re-raise the conflict the user already answered.
        await coordinator.syncPendingDrafts()
        XCTAssertNil(coordinator.conflict(for: documentID), "the answered conflict must not come back")
    }

    /// The destructive resolver's 404/403 branch tears the document down *before* the draft
    /// is discarded, so a transient 404 (a proxy hiccup) must leave the user's only copy of
    /// the edit intact — a regression that reordered the discard ahead of the fetch would
    /// destroy it here with nothing to catch it. The conflict *record* is deliberately
    /// cleared, because `becomeUnavailable` → `suppressLocalWriteThrough` must not leave a
    /// stale record on a torn-down document; it is re-detected once the document is
    /// reachable again (both `syncPendingDrafts` and `reconcileDraft` re-run the decision).
    func testKeepingTheServerVersionKeepsTheDraftWhenTheDocumentIs404() async {
        let log = RequestRecorder()
        let (viewModel, _, draftStore, _) = makeEnvironment()
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Mine", updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000), markdown: "# Base")
            )
        )
        let coauthorBody = formattedBody(content: "# Co-author edit")
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 200, headers: [:], body: coauthorBody, error: nil)
        }
        await viewModel.load()
        XCTAssertNotNil(viewModel.syncConflict)

        // The resolution's fetch 404s (which may be transient — a proxy hiccup).
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 404, headers: [:], body: Data(), error: nil)
        }
        await viewModel.resolveConflictKeepingServer()

        XCTAssertEqual(
            draftStore.draft(for: documentID)?.markdown, "# Mine",
            "a 404 must not cost the user their only copy of the edit — the discard never ran")
        XCTAssertTrue(viewModel.isUnavailable, "the document is torn down, as on any 404")
        XCTAssertNil(
            viewModel.syncConflict,
            "the record is cleared with the teardown (no stale conflict on a gone document); it is re-detected "
                + "by the decision once the document is reachable again")
        XCTAssertEqual(savesInFlight(log), 0)
    }

    /// Everything on screen must stay backed by disk. Keep-server used to clear `isDirty`
    /// *without flushing*, so an edit typed after the pill appeared lived only in `blocks`:
    /// on the failure path (the common one — the conflict is usually reviewed on the
    /// connection that caused it) the reading surface went on rendering it while it existed
    /// in **no draft and no funnel**, and `flushPendingChanges` early-returned forever.
    /// Navigating away lost it silently. Reachable only because the pill now renders while
    /// editing — which is exactly when it has to be safe.
    func testKeepingTheServerVersionPersistsAnUnflushedEditWhenTheFetchFails() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Mine", updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000), markdown: "# Base")
            )
        )
        let coauthorBody = formattedBody(content: "# Co-author edit")
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 200, headers: [:], body: coauthorBody, error: nil)
        }
        await viewModel.load()
        XCTAssertNotNil(viewModel.syncConflict)

        // The user types while the pill is up — the autosave debounce has NOT fired yet,
        // so this text lives only in `blocks`.
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Typed but never flushed")
        XCTAssertTrue(viewModel.isDirty)

        // They choose the server copy… and the fetch fails offline.
        stubOffline()
        await viewModel.resolveConflictKeepingServer()

        XCTAssertNotNil(viewModel.syncConflict, "the conflict survives a failed fetch")
        XCTAssertTrue(
            draftStore.draft(for: documentID)?.markdown.contains("Typed but never flushed") == true,
            "the in-progress edit must be on disk — the screen still shows it, so a funnel must own it")
        XCTAssertTrue(
            viewModel.blocks.contains { $0.text.contains("Typed but never flushed") },
            "…and it is still what the reading surface renders")
        XCTAssertEqual(savesInFlight(log), 0, "the flush is held by the conflict, never pushed")
        XCTAssertNotNil(coordinator.pendingSave(documentID: documentID), "it is parked in the hold")
    }

    /// **Whether a destructive push is checked must not hinge on keystroke timing.** `apply`
    /// diverts to `cacheServerCopy` whenever the screen is dirty, so a single character typed
    /// while the revalidation was in flight used to skip conflict detection entirely — and the
    /// autosave that followed full-overwrote the web edit the app had just fetched. Detection
    /// now runs in that branch too.
    func testAKeystrokeDuringTheRevalidationCannotBypassConflictDetection() async {
        let log = RequestRecorder()
        // Default (10 s) autosave: the point is a keystroke that lands *inside* the fetch
        // window WITHOUT the debounce firing. A debounce that fired first would push before
        // the app had even seen the co-author's edit — a race no detection can win, and a
        // different scenario entirely.
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        // A queued offline draft (baseline B0) — the case this PR exists for.
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Mine", updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000), markdown: "# Base")
            )
        )
        // Hold the revalidation open so the keystroke lands *inside* it; a co-author has
        // edited the server since B0.
        let coauthorBody = formattedBody(content: "# Co-author edit")
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: coauthorBody, error: nil, delay: 0.3)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        async let load: Void = viewModel.load()
        // The draft is rendered synchronously; type one character while the fetch is open.
        await waitUntil { viewModel.hasLoadedContent }
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Mine plus one")
        XCTAssertTrue(viewModel.isDirty)
        await load

        XCTAssertNotNil(
            viewModel.syncConflict,
            "a keystroke racing the fetch must not disable detection — the server moved on and we saw it")
        // …and the autosave that follows is HELD, not pushed over the co-author's edit.
        viewModel.flushPendingChanges()
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }
        XCTAssertNotNil(coordinator.pendingSave(documentID: documentID), "parked by the enqueue-hold")
    }

    /// The dirty branch's `pendingSave == nil` gate, which is what keeps the coordinator's
    /// invariant ("while a conflict is recorded, no save for that document is in flight")
    /// true now that detection runs *on* that branch. `apply` is reachable with a save on the
    /// wire — the marker is taken when the fetch is **issued**, so a save that starts
    /// afterwards leaves `mayPredateSave` false — and `finish` drains the queued slot
    /// **unconditionally**, so a conflict recorded mid-PATCH would have `finish` *start* the
    /// held save behind the user's back. The dialog would be unanswerable anyway: an
    /// already-sent full overwrite cannot be recalled, so "keep the server version" would
    /// fetch back our own body.
    ///
    /// The second half matters just as much: deferring must not become a permanent blind
    /// spot. The next revalidation, seeing the settled state, has to detect it.
    func testNoConflictIsRecordedWhileOurSaveIsInFlightButTheNextRevalidationDetectsIt() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, _, _) = makeEnvironment()

        let baseBody = formattedBody(content: "# Base")
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: baseBody, error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        await viewModel.load()
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Mine")

        // The content PATCH is held open *longer* than the GET, so the co-author's body
        // genuinely lands while our own save is still on the wire — the window the gate exists
        // for.
        let divergedBody = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "# Co-author edit", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-02-20T10:30:00Z"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: divergedBody, error: nil, delay: 0.3)
            }
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") {
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil, delay: 0.8)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }

        // The GET must be issued BEFORE the save starts, or `mayPredateSave` would divert the
        // response and the gate would never be reached. Pin that on the recorder — never on
        // `async let` ordering, which answers a different question.
        let getsBefore = log.count(ofMethod: "GET", urlContaining: "formatted-content")
        let revalidation = Task { await viewModel.refresh() }
        await waitUntil { log.count(ofMethod: "GET", urlContaining: "formatted-content") > getsBefore }
        viewModel.flushPendingChanges()  // `enqueue` → `start` sets the in-flight save synchronously
        XCTAssertNotNil(coordinator.pendingSave(documentID: documentID), "our save is on the wire")
        await revalidation.value

        XCTAssertNil(
            viewModel.syncConflict,
            "a conflict recorded mid-PATCH is unanswerable, and `finish` would start the held save")

        // The save settles normally — it was never held.
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
        XCTAssertNil(coordinator.conflict(for: documentID), "…and nothing was recorded behind it")

        // The divergence is real (the server body is neither our push nor the baseline), and
        // the user is still typing — so the next revalidation must detect it.
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Mine, still typing")
        await viewModel.refresh()

        XCTAssertEqual(
            viewModel.syncConflict?.serverUpdatedAt,
            ISO8601DateFormatter().date(from: "2026-02-20T10:30:00Z"),
            "the deferred conflict is detected by the next revalidation — deferral is not a blind spot")
    }

    /// The flip side, and the reason rule 1 must be fed from the coordinator rather than the
    /// stored draft: right after **our own** save lands there is no draft left to carry the
    /// stamp, and `serverBaseline` is deliberately not advanced by a save — so a revalidation
    /// arriving while the user keeps typing would compare our own just-pushed body against a
    /// stale baseline and raise a conflict against the user's own write.
    func testARevalidationAfterOurOwnSaveRaisesNoConflictWhileStillEditing() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "# Base", log: log)
        await viewModel.load()

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "My edit")
        viewModel.flushPendingChanges()
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
        XCTAssertNil(draftStore.draft(for: documentID), "the save landed and cleared the draft")

        // The server now returns OUR body with a newer updated_at, while the user types on.
        let ourBody = formattedBody(content: serializeMarkdown(viewModel.blocks))
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: ourBody, error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "My edit, still going")
        XCTAssertTrue(viewModel.isDirty)
        await viewModel.refresh()

        XCTAssertNil(
            viewModel.syncConflict,
            "the server's body is our own confirmed push — rule 1 must recognise it, not ask the user "
                + "about their own write")
    }

    /// The other side of the same race. A revalidation landing on a **clean, open editing
    /// session** stashes the fetched body behind the "Updated" banner — and the first
    /// keystroke used to throw that stash away with nothing recorded, so the ensuing autosave
    /// full-overwrote a web edit the app had fetched, cached, *and shown the user a banner
    /// for*. Type one character **before** the fetch resolves and the push is held and the
    /// user asked; type one character **after** it resolves and the identical push went
    /// through unchecked. Abandoning the stash now records the conflict.
    func testAbandoningTheUpdatedStashRecordsAConflictInsteadOfOverwritingIt() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, _, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "# Server body", log: log)
        await viewModel.load()

        // An open editing session, still clean. A co-author's edit lands as the stash — with a
        // NEWER `updated_at` than the baseline, which is what a real server write does. (The
        // shared fixture's timestamp is fixed, so reusing it would make rule 2 correctly say
        // "the server has not moved past the baseline" and decline to conflict.)
        viewModel.startEditing()
        let coauthorBody = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "# Co-author edit", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-02-20T10:30:00Z"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: coauthorBody, error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        await viewModel.load()
        XCTAssertTrue(viewModel.updateAvailable, "the fetched body is stashed behind the banner")
        XCTAssertNil(viewModel.syncConflict, "…and is merely offered, not yet a conflict")

        // The user ignores the banner and types.
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "My edit")

        XCTAssertFalse(viewModel.updateAvailable, "the stash is dropped…")
        XCTAssertNotNil(
            viewModel.syncConflict,
            "…but a server body we fetched AND showed the user cannot be silently overwritten by the "
                + "next autosave — abandoning it must record the conflict")

        viewModel.flushPendingChanges()
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }
        XCTAssertNotNil(coordinator.pendingSave(documentID: documentID), "the push is held, not sent")
    }

    /// `.discardServerWins` is **not** "no conflict". It is rule 3 firing for a *legacy*
    /// (baseline-less) draft the server has moved past — and `runSyncPass` deliberately
    /// records a conflict for exactly that state, because the draft is visible unsaved work
    /// whose only other funnel is a retry tap that overwrites the newer server copy unasked.
    /// Treating it as "resolved" in `reconcileDraft` cleared that record on the next
    /// pull-to-refresh and re-opened the hole.
    func testAPullToRefreshDoesNotClearTheConflictOnAStaleLegacyDraft() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        // The server is well BEYOND the clock-tolerance window (a 2099 `updated_at`), which is
        // what makes rule 3 return `.discardServerWins` for a baseline-less draft — the state
        // this test exists for. A merely "newer body" is not enough: with a server timestamp
        // older than the draft, rule 3 correctly says `.push`.
        let staleForServer = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "# Co-author", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2099-01-01T00:00:00Z"}
            """.utf8)
        // Legacy: the draft is written with NO baseline, and its save fails offline.
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: staleForServer, error: nil)
            }
            return .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        draftStore.save(
            PendingDraft(documentID: documentID, title: "Doc", markdown: "# Mine", updatedAt: Date()))
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine")
        await waitUntil {
            if case .pendingSync = coordinator.state(for: self.documentID) { return true }
            return false
        }
        await viewModel.load()

        // The sync pass records the conflict for the stranded legacy draft.
        coordinator.recordConflict(documentID: documentID, serverUpdatedAt: Date(timeIntervalSince1970: 4_100_000_000))
        XCTAssertNotNil(viewModel.syncConflict)
        XCTAssertNil(draftStore.draft(for: documentID)?.baseline, "a legacy, baseline-less draft")

        // A pull-to-refresh must NOT quietly release the hold.
        await viewModel.refresh()

        XCTAssertNotNil(
            viewModel.syncConflict,
            "a stale legacy draft the server has moved past is still a conflict — clearing it here would let "
                + "the next retry overwrite the newer server copy with no prompt")
    }

    /// The **editor-side** half of "never fabricate an empty baseline body". It is the half that
    /// actually decides what lands on disk: `resolveConflictKeepingMine` sets `serverBaseline`
    /// and then `flushPendingChanges()` → `enqueue` persists *that* verbatim, over whatever the
    /// coordinator wrote. `serverBaseline` is nil exactly for a legacy (baseline-less) draft, so
    /// this is the only path where the fallback fires — and an empty body would make rule 2's
    /// content tiebreak match any **empty server document**, silently full-overwriting a
    /// co-author who deliberately emptied the doc.
    func testKeepingMineOnALegacyDraftPersistsARealBaselineBodyNotAnEmptyOne() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        // A server far beyond the tolerance window, so a baseline-less draft decides
        // `.discardServerWins` → `reconcileDraft` records the conflict.
        let futureServer = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "# Co-author", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2099-01-01T00:00:00Z"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: futureServer, error: nil)
            }
            return .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        // Legacy: no baseline. Its save fails offline → `.pendingSync`.
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine")
        await waitUntil {
            if case .pendingSync = coordinator.state(for: self.documentID) { return true }
            return false
        }
        await viewModel.load()
        XCTAssertNotNil(viewModel.syncConflict)
        XCTAssertNil(
            draftStore.draft(for: documentID)?.baseline,
            "a legacy draft has no baseline — which is what leaves the editor's `serverBaseline` nil")

        viewModel.resolveConflictKeepingMine()

        let persisted = draftStore.draft(for: documentID)?.baseline?.markdown
        XCTAssertNotNil(persisted)
        XCTAssertFalse(
            persisted?.isEmpty == true,
            "an empty baseline body makes rule 2's tiebreak match any empty server document — so a "
                + "co-author who deliberately empties the doc would be silently overwritten")
    }

    /// **The relaunch case, end to end in the editor.** The conflict now persists but the save
    /// *state* does not — so a legacy (baseline-less) draft comes back as `.idle`, skips the
    /// `.failed`/`.pendingSync` branch, and falls to rule 3, which for a server past the
    /// tolerance window answers `.discardServerWins`. Without the guard, `reconcileDraft` hands
    /// it to `discardStoredDraft` and **deletes the very work the pill is asking about**.
    func testAfterARelaunchAStaleLegacyDraftUnderAConflictIsNotDeleted() async {
        let log = RequestRecorder()
        let suiteName = "EditorViewModelTests.\(UUID().uuidString)"
        draftSuiteNames.append(suiteName)
        let draftStore = PendingDraftStore(userDefaults: UserDefaults(suiteName: suiteName)!)
        // A legacy draft (no baseline) carrying an unanswered conflict, as left by a previous
        // process. The fresh coordinator rehydrates the conflict; `states` starts empty.
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# My only copy",
                updatedAt: Date(timeIntervalSince1970: 1_000_000),
                conflictServerUpdatedAt: Date(timeIntervalSince1970: 4_100_000_000)))
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let contentCache = DocumentContentCacheStore(directory: cacheDirectory)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: draftStore, contentCache: contentCache, backgroundTasks: .noop)
        let viewModel = EditorViewModel(
            client: client, documentID: documentID, title: "Doc", saveCoordinator: coordinator,
            contentCache: contentCache,
            childrenCache: DocumentChildrenCacheStore(userDefaults: UserDefaults(suiteName: childrenSuiteName)!))
        XCTAssertNotNil(coordinator.conflict(for: documentID), "the hold was rehydrated")
        if case .idle = coordinator.state(for: documentID) {
        } else {
            XCTFail("a fresh process has no save state — that asymmetry is the whole point")
        }
        // A server far beyond the tolerance window → rule 3 says `.discardServerWins`.
        let futureServer = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "# Co-author", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2099-01-01T00:00:00Z"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 200, headers: [:], body: futureServer, error: nil)
        }

        await viewModel.load()

        XCTAssertEqual(
            draftStore.draft(for: documentID)?.markdown, "# My only copy",
            "the work the pill is asking about must not be deleted from under the question")
        XCTAssertNotNil(viewModel.syncConflict, "and the conflict still stands")
        XCTAssertFalse(
            viewModel.blocks.contains { $0.text.contains("Co-author") },
            "the server body must not be installed over it")
    }

    /// A **legacy** (baseline-less) draft that goes dirty must still be protected. Both editor
    /// detection sites used to require a non-nil `serverBaseline` — which is nil for exactly this
    /// draft — so it was the one class that got no detection at all: the fetch proved the server
    /// had moved on, nothing was recorded, and the next autosave full-overwrote the co-author.
    func testALegacyDraftGoingDirtyStillDetectsAConflict() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        // Legacy: no baseline at all.
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Mine",
                updatedAt: Date(timeIntervalSince1970: 1_000_000)))
        let futureServer = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "# Co-author", "created_at": "2026-01-15T10:30:00Z", "updated_at": "2099-01-01T00:00:00Z"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: futureServer, error: nil, delay: 0.3)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        async let load: Void = viewModel.load()
        await waitUntil { viewModel.hasLoadedContent }
        // Type while the revalidation is in flight → `apply` diverts to the dirty branch.
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Mine plus one")
        await load

        XCTAssertNotNil(
            viewModel.syncConflict,
            "a baseline-less draft is still visible unsaved work — it cannot be the one case with no detection")
        viewModel.flushPendingChanges()
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }
        XCTAssertNotNil(coordinator.pendingSave(documentID: documentID), "the push is held")
    }

    /// "Keep my version" must never be a silent no-op: if there is no local work to push, the
    /// record is moot and pushing the on-screen body would overwrite the co-author with the
    /// server's own older copy. It releases the record instead.
    func testKeepingMineWithNoLocalWorkReleasesTheRecordInsteadOfPushing() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, _, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "# Server body", log: log)
        await viewModel.load()
        XCTAssertFalse(viewModel.isDirty)

        coordinator.recordConflict(documentID: documentID, serverUpdatedAt: Date())
        XCTAssertNotNil(viewModel.syncConflict)

        viewModel.resolveConflictKeepingMine()

        XCTAssertNil(viewModel.syncConflict, "a moot record is released")
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }
    }

    /// **A clock-only push must not release a standing conflict.** `.push` has two very different
    /// provenances: rules 0–2 prove something about the *body*, but rule 3 proves nothing — it
    /// only says the draft's client clock is within tolerance of the server's `updated_at`. And
    /// the user typing *after* a conflict was surfaced bumps that clock past the server's, so
    /// rule 3 then starts answering `.push` for a baseline-less draft whose conflict is still
    /// standing and still persisted. Releasing on that basis discarded the hold and
    /// full-overwrote the co-author with no pill and no prompt — defeating the whole point of
    /// persisting the hold across the relaunch.
    func testAClockOnlyPushDoesNotReleaseAStandingConflict() async {
        let log = RequestRecorder()
        let suiteName = "EditorViewModelTests.\(UUID().uuidString)"
        draftSuiteNames.append(suiteName)
        let draftStore = PendingDraftStore(userDefaults: UserDefaults(suiteName: suiteName)!)
        // A legacy (baseline-less) draft carrying an unanswered, persisted conflict — and whose
        // own clock is NEWER than the server's, because the user kept typing after the pill
        // appeared. Rule 3 therefore answers `.push`.
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# My only copy", updatedAt: Date(),
                conflictServerUpdatedAt: Date(timeIntervalSince1970: 1_768_473_000)))
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let contentCache = DocumentContentCacheStore(directory: cacheDirectory)
        // A fresh coordinator: the conflict rehydrates, but `states` is empty (`.idle`).
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: draftStore, contentCache: contentCache, backgroundTasks: .noop)
        let viewModel = EditorViewModel(
            client: client, documentID: documentID, title: "Doc", saveCoordinator: coordinator,
            contentCache: contentCache,
            childrenCache: DocumentChildrenCacheStore(userDefaults: UserDefaults(suiteName: childrenSuiteName)!))
        XCTAssertNotNil(coordinator.conflict(for: documentID), "the hold was rehydrated")
        // The server holds the co-author's body, with an `updated_at` OLDER than the draft's
        // clock — so rule 3 (and only rule 3) says `.push`.
        stubLoadAndSavePipeline(content: "# Co-author edit", log: log)

        await viewModel.load()

        XCTAssertNotNil(
            viewModel.syncConflict,
            "a clock-tolerance push is not evidence the conflict is gone — releasing it here overwrites "
                + "the co-author with no prompt")
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }
        XCTAssertEqual(
            draftStore.draft(for: documentID)?.markdown, "# My only copy", "and the user's only copy survives")
    }

    /// **A server body observed while our own save is on the wire must not be thrown away.**
    /// Detection cannot run then (a conflict may only be recorded with no save in flight), so
    /// `apply` skipped it and merely cached the body. If that save then FAILS, nothing reached
    /// the server: the draft survives with a stale baseline and no push stamp, and the next
    /// flush full-overwrote the co-author's body the app had already fetched **and cached** —
    /// no pill, no prompt. The observation is now handed to the coordinator and re-decided in
    /// `finish`, where the no-save-in-flight invariant holds again.
    func testAServerBodyObservedWhileSavingIsStillDetectedWhenThatSaveFails() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        let coauthor = divergedServerBody(content: "# Co-author edit")
        let base = formattedBody(content: "# Base")
        let gets = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                let priorGets = gets.count(ofMethod: "GET", urlContaining: "formatted-content")
                gets.record(request)
                // First GET = the initial load; the next = the co-author's newer body, held open
                // so the user's save starts underneath it.
                return .init(
                    statusCode: 200, headers: [:], body: priorGets == 0 ? base : coauthor, error: nil,
                    delay: priorGets == 0 ? 0 : 0.3)
            }
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") {
                // Held open, then fails: NOTHING reaches the server.
                return .init(
                    statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet), delay: 0.4)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        await viewModel.load()

        // The fetch is issued FIRST, with nothing pending — so `mayPredateSave` is false and the
        // response is trusted. It is then held open while the user's save starts underneath it.
        // (Issuing it *after* the save would make `mayPredateSave` true and `apply` would discard
        // the response outright — a different, already-safe path.)
        async let revalidation: Void = viewModel.refresh()
        await waitUntil { gets.count(ofMethod: "GET", urlContaining: "formatted-content") >= 2 }
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Mine")
        viewModel.flushPendingChanges()
        XCTAssertNotNil(coordinator.pendingSave(documentID: documentID), "a save is on the wire")
        await revalidation  // …and the co-author's body lands while it is

        // …and then the save fails. The observation must survive it.
        await waitUntil {
            if case .pendingSync = coordinator.state(for: self.documentID) { return true }
            return false
        }

        XCTAssertNotNil(
            viewModel.syncConflict,
            "the app fetched and cached the co-author's body while saving; that save then failed, so nothing "
                + "reached the server — the next push must be held, not silently destroy it")
        let before = savesInFlight(log)
        viewModel.saveNow()
        await waitAndConfirmNever { self.savesInFlight(log) > before }
        XCTAssertNotNil(draftStore.draft(for: documentID), "and the user's edit is safe on disk")
    }

    /// The post-flush "nothing to push" branch of keep-mine. `isDirty` is not proof there is
    /// anything to push: the flush enqueues nothing when the content serializes back to
    /// `savedMarkdown` (the user typed, then undid it). Clearing the conflict and advancing the
    /// baseline while pushing nothing hands the user exactly the outcome they declined.
    func testKeepingMineAfterAnUndoneEditPushesNothingAndRestoresTheBaseline() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "# Server body", log: log)
        await viewModel.load()

        coordinator.recordConflict(documentID: documentID, serverUpdatedAt: Date(timeIntervalSince1970: 1))
        viewModel.startEditing()
        let blockID = viewModel.blocks[0].id
        let original = viewModel.blocks[0].text
        viewModel.updateText(blockID: blockID, text: "Server body edited")
        viewModel.updateText(blockID: blockID, text: original)  // …and undone
        XCTAssertTrue(viewModel.isDirty, "dirty — but the content is back to what was saved")

        viewModel.resolveConflictKeepingMine()

        XCTAssertNil(viewModel.syncConflict, "the record was moot — released")
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }
        XCTAssertNil(draftStore.draft(for: documentID), "nothing was pushed and nothing was drafted")

        // The load-bearing part: the baseline was put back, so a later real edit does not carry a
        // baseline advanced past a server state we never actually overwrote.
        viewModel.updateText(blockID: blockID, text: "A real edit now")
        viewModel.flushPendingChanges()
        XCTAssertEqual(
            draftStore.draft(for: documentID)?.baseline?.serverUpdatedAt, fetchedUpdatedAt,
            "the pre-conflict baseline must be restored when keep-mine pushed nothing")
    }

    // MARK: - The conflict record's lifecycle
    //
    // The rule the four detection sites share: **a conflict record is meaningful only while
    // local work exists that would overwrite the observed server body.** Record it when such
    // work appears; release it the moment it is gone. Both halves are load-bearing — one way
    // the user loses a co-author's edit, the other way the document's save pipeline wedges.

    /// Merely *entering* edit mode is not local work, so it must record nothing. Recording
    /// there produced a **phantom conflict**: a pill and an enqueue-hold on a document with no
    /// unsaved changes, which nothing on the clean path cleared and whose "Keep my version"
    /// had nothing to push.
    func testEnteringEditModeOverAnUpdateBannerRecordsNoConflict() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, _, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "# Server body", log: log)
        await viewModel.load()

        // Editing session; a co-author's body lands and is stashed behind the banner.
        viewModel.startEditing()
        stubDivergedServer(content: "# Co-author edit", log: log)
        await viewModel.load()
        XCTAssertTrue(viewModel.updateAvailable)

        // Done without typing, then tap back into the text to read.
        viewModel.finishEditing()
        viewModel.startEditing()

        XCTAssertNil(
            viewModel.syncConflict,
            "entering edit mode is not local work — a conflict here is a phantom that wedges every future save")
        XCTAssertFalse(viewModel.isDirty)
    }

    /// …but the stash must survive that, or the first real keystroke has nothing left to
    /// detect. (This is why `startEditing` hides the banner instead of destroying the stash.)
    func testTheStashSurvivesEnteringEditModeSoTheFirstKeystrokeStillDetects() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, _, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "# Server body", log: log)
        await viewModel.load()

        viewModel.startEditing()
        stubDivergedServer(content: "# Co-author edit", log: log)
        await viewModel.load()
        viewModel.finishEditing()
        viewModel.startEditing()  // stash kept, banner hidden, nothing recorded
        XCTAssertNil(viewModel.syncConflict)

        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "My edit")

        XCTAssertNotNil(
            viewModel.syncConflict,
            "the first keystroke IS local work — and the server body we fetched must not be overwritten unasked")
        viewModel.flushPendingChanges()
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }
        XCTAssertNotNil(coordinator.pendingSave(documentID: documentID), "the push is held")
    }

    /// The release side, exercised with the conflict **still standing** when the decision comes
    /// back `.push`. This is the property that matters: the record is the only thing holding the
    /// enqueue, and `syncPendingDrafts` skips any document that has one — so if it is never
    /// released, the document can **never sync again**, with a destructive "Keep the server
    /// version" armed against whatever the user types next.
    ///
    /// (An earlier version of this test resolved the conflict via `resolveConflictKeepingServer()`
    /// first — which clears the record inside the coordinator — so it passed with every
    /// `clearResolvedConflict` call site deleted. It asserted the right thing about the wrong
    /// state. The conflict must be live at the moment the `.push` decision lands.)
    func testAPushDecisionReleasesAStandingConflictSoTheDocumentCanSyncAgain() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Mine", updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000), markdown: "# Base")
            )
        )
        stubDivergedServer(content: "# Co-author edit", log: log)
        await viewModel.load()
        XCTAssertNotNil(viewModel.syncConflict, "a conflict stands over the queued draft")

        // The co-author reverts: the server body is the baseline again, so the decision is
        // `.push` — and the conflict is STILL RECORDED when that decision lands.
        stubDivergedServer(content: "# Base", log: log)
        await viewModel.refresh()

        XCTAssertNil(
            viewModel.syncConflict,
            "the conflict is moot — releasing it is the only thing that lets this document sync again")
        // The hold is genuinely gone: the draft actually reaches the network.
        await waitUntil { self.savesInFlight(log) >= 1 }
        XCTAssertNil(coordinator.conflict(for: documentID))
    }

    /// The same release, via `reconcileClean` — reached only with no pending save, no draft and
    /// not dirty, i.e. no local work by construction, so a record there cannot be live. Here the
    /// local work is destroyed by a *successful save* rather than by a resolver, so
    /// `clearResolvedConflict` is the only thing that can null the record.
    func testReconcileCleanReleasesAConflictLeftOverAfterTheLocalWorkIsGone() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        stubLoadAndSavePipeline(content: "# Server body", log: log)
        await viewModel.load()

        // Local work, saved successfully → no draft, not dirty, nothing pending.
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "My edit")
        viewModel.flushPendingChanges()
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
        viewModel.finishEditing()
        XCTAssertNil(draftStore.draft(for: documentID))
        XCTAssertFalse(viewModel.isDirty)

        // A conflict record survives from earlier (e.g. the sync pass recorded one before the
        // save landed). It is now moot: there is no local work left to overwrite anything.
        coordinator.recordConflict(documentID: documentID, serverUpdatedAt: Date())
        XCTAssertNotNil(viewModel.syncConflict)

        await viewModel.refresh()  // clean path

        XCTAssertNil(
            viewModel.syncConflict,
            "no pending save, no draft, not dirty — the record has nothing left to protect and must be released")

        // …and the pipeline is genuinely unwedged: new work reaches the network.
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Fresh unrelated work")
        viewModel.flushPendingChanges()
        await waitUntil { self.savesInFlight(log) >= 2 }
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
        let (viewModel, coordinator, draftStore, contentCache) = makeEnvironment()
        stubLoad(content: "# Server body")
        await viewModel.load()  // baseline A, cached A

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

        // The mayPredate early-return uniquely takes NOTHING from the raced fetch:
        // in particular it does not write-through the cache with body B (the
        // pendingSave branch's cacheServerCopy would, so this is what distinguishes
        // the guard from that branch). Asserted while the first save is still held.
        XCTAssertEqual(
            contentCache.content(for: documentID)?.markdown, "# Server body",
            "the raced fetch's body must not be installed or cached")

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
        // GET ok (baseline A); the content PATCH is rejected with a non-retryable
        // 400 so the save reaches `.failed` (the retry state), and the draft (with
        // its baseline) survives to be retried.
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: bodyA, error: nil)
            }
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") {
                return MockURLProtocol.Stub(statusCode: 400, headers: [:], body: Data(), error: nil)
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

    /// A response that may predate one of our own saves teaches `knownServerTitles` nothing —
    /// the mirror, for titles, of the rule that keeps such a body from being installed. Hoist
    /// `noteServerTitle` above that guard and the app learns an **older** title after `finish`
    /// recorded ours, then PATCHes it back over the user's own rename.
    func testAFetchThatMayPredateOurSaveDoesNotTeachAStaleServerTitle() async {
        let log = RequestRecorder()
        let titles = PatchedTitleRecorder()
        let (viewModel, coordinator, _, _) = makeEnvironment()
        stubLoad(content: "# Base")
        await viewModel.load()

        // The user renames and the save goes out; hold the content PATCH open. A revalidation
        // issued while it is in flight is answered from the server's PRE-rename state.
        let stale = formattedBody(content: "# Base", title: "Doc")
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            titles.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: stale, error: nil)
            }
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") {
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil, delay: 0.3)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        viewModel.startEditing()
        viewModel.updateTitle("My new title")
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Base edited")
        viewModel.flushPendingChanges()
        await viewModel.refresh()  // races the save; its response predates it
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }

        XCTAssertEqual(
            coordinator.knownServerTitle(documentID: documentID), "My new title",
            "the pre-save response must not teach a title older than the one we just pushed")

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Base edited twice")
        viewModel.flushPendingChanges()
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }

        XCTAssertEqual(titles.last, "My new title", "so the next flush cannot revert the user's own rename")
        XCTAssertEqual(viewModel.title, "My new title")
    }

    /// The editor **never refetches on foreground** — it only flushes — which is exactly
    /// when a background `syncPendingDrafts` replay runs. So a replay can adopt a rename
    /// into this document's queued work, and land it, entirely behind an open screen still
    /// showing the old title. The next keystroke's flush PATCHes `title`, so without a
    /// check there it would revert the rename the replay had just adopted.
    func testAFlushDoesNotRevertARenameAdoptedByABackgroundReplay() async {
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        let titles = PatchedTitleRecorder()
        let renamed = formattedBody(content: "# Base", title: "Renamed on the web")
        MockURLProtocol.stubHandler = { request in
            titles.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: renamed, error: nil)
            }
            return MockURLProtocol.Stub(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        // A draft from an offline session, on screen. The editor loads it *offline*, so it
        // never sees the rename itself.
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Old title", markdown: "# Mine", updatedAt: Date(),
                baseline: DraftBaseline(
                    serverUpdatedAt: fixtureServerUpdatedAt.addingTimeInterval(-3600), markdown: "# Base",
                    title: "Old title")))
        stubOffline()
        await viewModel.load()
        XCTAssertEqual(viewModel.title, "Old title", "the screen shows the draft's title, pre-rename")

        // Reconnect: RootView fires the coordinator's replay. It adopts the rename, pushes,
        // and the save lands — taking the draft with it. The open editor is told nothing.
        MockURLProtocol.stubHandler = { request in
            titles.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: renamed, error: nil)
            }
            return MockURLProtocol.Stub(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        await coordinator.syncPendingDrafts()
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
        XCTAssertEqual(titles.last, "Renamed on the web", "the replay adopted it")
        XCTAssertNil(draftStore.draft(for: documentID), "and its draft is gone, so nothing local holds the title")

        // The user, still on the open screen, types.
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Mine, edited again")
        viewModel.flushPendingChanges()
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }

        XCTAssertEqual(titles.last, "Renamed on the web", "the flush must not PATCH the pre-rename title back")
        XCTAssertEqual(viewModel.title, "Renamed on the web", "and the screen catches up to it")
    }

    /// The dirty branch **with a draft on screen**. `reconcileDraft` — the other adopter —
    /// is unreachable while the screen is dirty (`apply` returns first), so the stored draft
    /// keeps its pre-rename title; and `adoptQueuedTitleIfUnseen` prefers a draft's title
    /// over the server's, because unsaved local work normally *is* the newer one. Without the
    /// adopt in the dirty branch itself, the rename is PATCHed away by the very flush that is
    /// supposed to merge it.
    func testALiveTypistWithAQueuedDraftStillMergesARemoteRename() async {
        let log = RequestRecorder()
        let titles = PatchedTitleRecorder()
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Old title", markdown: "# Mine", updatedAt: Date(),
                baseline: DraftBaseline(
                    serverUpdatedAt: fixtureServerUpdatedAt.addingTimeInterval(-3600), markdown: "# Base",
                    title: "Old title")))
        stubOffline()
        await viewModel.load()  // the draft is on screen, pre-rename title
        XCTAssertEqual(viewModel.title, "Old title")

        // The co-author's rename arrives on a fetch that lands while the user is typing.
        let renamed = formattedBody(content: "# Base", title: "Renamed on the web", updatedAt: laterServerUpdatedAt)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            titles.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: renamed, error: nil, delay: 0.3)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        async let load: Void = viewModel.load()
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Mine, still typing")
        XCTAssertTrue(viewModel.isDirty)
        await load

        XCTAssertNil(viewModel.syncConflict, "a rename the typist didn't make is merged, not dialogued")

        viewModel.flushPendingChanges()
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }

        XCTAssertEqual(titles.last, "Renamed on the web", "the flush must not PATCH the draft's stale title")
        XCTAssertEqual(viewModel.title, "Renamed on the web")
    }

    /// `apply`'s **dirty** branch reaches the decision too (a keystroke must not decide
    /// whether a push is checked). A rename the live typist didn't make is still a merge:
    /// no conflict is raised, and the autosave that follows PATCHes the *server's* title
    /// rather than reverting it — the on-screen title was never touched, so it has no claim.
    func testALiveTypistsFlushMergesARemoteRenameInsteadOfRevertingIt() async {
        let log = RequestRecorder()
        let titles = PatchedTitleRecorder()
        let (viewModel, coordinator, _, _) = makeEnvironment()
        stubLoad(content: "# Base")
        await viewModel.load()  // baseline: title "Doc", body "# Base"
        XCTAssertEqual(viewModel.title, "Doc")

        // A co-author renames it (body untouched). Hold the fetch open so the keystroke
        // lands inside it and `apply` takes the dirty branch.
        let renamed = formattedBody(content: "# Base", title: "Renamed on the web", updatedAt: laterServerUpdatedAt)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            titles.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: renamed, error: nil, delay: 0.3)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        async let load: Void = viewModel.load()
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Base, edited")
        XCTAssertTrue(viewModel.isDirty)
        await load

        XCTAssertNil(viewModel.syncConflict, "a rename the typist didn't make is merged, not dialogued")

        viewModel.flushPendingChanges()
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }

        XCTAssertEqual(titles.last, "Renamed on the web", "the autosave must not revert the rename it just fetched")
        XCTAssertEqual(viewModel.title, "Renamed on the web")
    }

    /// The other half: the live typist renamed it too, differently. There is no merge that
    /// keeps both, so it takes the same funnel a body conflict does — the push is held and
    /// the pill asks. The bodies agree here, so only the titles can raise it.
    func testALiveTypistsOwnRenameAgainstADifferentRemoteRenameIsAConflict() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, _, _) = makeEnvironment()
        stubLoad(content: "# Base")
        await viewModel.load()

        let renamed = formattedBody(content: "# Base", title: "Their title", updatedAt: laterServerUpdatedAt)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: renamed, error: nil, delay: 0.3)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        async let load: Void = viewModel.load()
        viewModel.startEditing()
        viewModel.updateTitle("My title")
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Base, edited")
        await load

        XCTAssertNotNil(viewModel.syncConflict, "two different renames are a genuine conflict")

        // …and the autosave that follows is HELD, not pushed over the co-author's rename.
        viewModel.flushPendingChanges()
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }
        XCTAssertNotNil(coordinator.pendingSave(documentID: documentID), "parked by the enqueue-hold")
        XCTAssertEqual(viewModel.title, "My title", "the user's own rename is not overwritten while they decide")
    }

    /// A draft whose save is queued for sync (`.pendingSync`) is *not* replayed by the
    /// editor — it stays on screen behind its caption, and its funnel is the user's retry
    /// (`saveNow`), which PATCHes `savedTitle` with no reconcile of its own. So the rename
    /// has to be adopted when it is *observed*, or tapping retry reverts it.
    func testAPendingSyncDraftAdoptsARemoteRenameSoTheRetryDoesNotRevertIt() async {
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        let titles = PatchedTitleRecorder()
        let renamed = formattedBody(content: "# Base", title: "Renamed on the web")
        let offline = MockURLProtocol.Stub(
            statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        // The content PATCH fails (offline) → the save is queued for sync; GETs succeed.
        MockURLProtocol.stubHandler = { request in
            titles.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: renamed, error: nil)
            }
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") { return offline }
            return MockURLProtocol.Stub(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        coordinator.enqueue(
            documentID: documentID, title: "Old title", markdown: "# Mine",
            baseline: DraftBaseline(
                serverUpdatedAt: fixtureServerUpdatedAt.addingTimeInterval(-3600), markdown: "# Base",
                title: "Old title"))
        await waitUntil {
            if case .pendingSync = coordinator.state(for: self.documentID) { return true }
            return false
        }

        await viewModel.load()  // reconcileDraft's .pendingSync branch observes the rename

        XCTAssertEqual(viewModel.title, "Renamed on the web", "observed on screen…")
        XCTAssertEqual(draftStore.draft(for: documentID)?.title, "Renamed on the web", "…and on the draft")
        XCTAssertNotNil(draftStore.draft(for: documentID), "the queued work is untouched otherwise")

        // Now the network comes back and the user taps "retry".
        MockURLProtocol.stubHandler = { request in
            titles.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: renamed, error: nil)
            }
            return MockURLProtocol.Stub(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        viewModel.saveNow()
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }

        XCTAssertEqual(titles.last, "Renamed on the web", "the retry must not revert the rename")
    }

    /// The guard on all of the above: an unflushed local rename is the user's own edit and
    /// outranks every adopted title. It must reach the server, not be quietly replaced by
    /// the last title the app knew the server had.
    func testAnUnflushedLocalRenameIsNeverReplacedByAKnownServerTitle() async {
        let (viewModel, coordinator, _, _) = makeEnvironment()
        let titles = PatchedTitleRecorder()
        let body = formattedBody(content: "# Base", title: "Server title")
        MockURLProtocol.stubHandler = { request in
            titles.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: body, error: nil)
            }
            return MockURLProtocol.Stub(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        await viewModel.load()  // the app now knows the server's title is "Server title"
        XCTAssertEqual(viewModel.title, "Server title")

        viewModel.startEditing()
        viewModel.updateTitle("My new title")  // a local rename, not yet flushed
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Base edited")
        viewModel.flushPendingChanges()
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }

        XCTAssertEqual(titles.last, "My new title", "the user's rename wins over the known server title")
        XCTAssertEqual(viewModel.title, "My new title")
    }

    /// "Keep the server version" installs a fetched copy **without going through `apply`**,
    /// and it is the one path that also drops the draft. If that install didn't record the
    /// server's title, the next flush would fall through to a `knownServerTitle` from *before*
    /// the copy the user just chose to keep — reverting the co-author's rename by way of the
    /// backstop that exists to preserve it.
    func testKeepingTheServerVersionThenEditingDoesNotRevertToAStaleKnownTitle() async {
        let log = RequestRecorder()
        let titles = PatchedTitleRecorder()
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()

        // The app knows the server's title is "Doc" (an earlier fetch).
        stubLoad(content: "# Base")
        await viewModel.load()
        XCTAssertEqual(viewModel.title, "Doc")

        // A queued offline draft, and a co-author who changed the body *and* renamed it.
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Mine", updatedAt: Date(),
                baseline: DraftBaseline(
                    serverUpdatedAt: fixtureServerUpdatedAt.addingTimeInterval(-3600), markdown: "# Base",
                    title: "Doc")))
        let renamed = formattedBody(
            content: "# Their edit", title: "Renamed on the web", updatedAt: laterServerUpdatedAt)
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
        XCTAssertNotNil(coordinator.conflict(for: documentID), "the body diverged — a real conflict")

        await viewModel.resolveConflictKeepingServer()
        XCTAssertEqual(viewModel.title, "Renamed on the web", "the server's copy is on screen, rename included")
        XCTAssertNil(draftStore.draft(for: documentID), "and their draft is gone — this is the sanctioned discard")

        // Now they edit the copy they chose to keep.
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Their edit, plus mine")
        viewModel.flushPendingChanges()
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }

        XCTAssertEqual(titles.last, "Renamed on the web", "the flush must not resurrect the pre-conflict title")
        XCTAssertEqual(viewModel.title, "Renamed on the web")
    }

    /// **The whole scenario, end to end, with no hand-seeded baseline** — the one the bug
    /// was reported from. Open the document online (so the app builds the baseline itself,
    /// title included), edit it offline, have a co-author rename it on the web, reconnect.
    /// Every other test here seeds `DraftBaseline(title:)` by hand, so none of them would
    /// notice if the app stopped *recording* the title it descends from.
    func testOpenOnlineEditOfflineRemoteRenameThenReconnectKeepsTheRename() async {
        let log = RequestRecorder()
        let titles = PatchedTitleRecorder()
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()

        // 1. Open it online: `installFetched` records the baseline — body *and* title.
        stubLoad(content: "# Base")
        await viewModel.load()
        XCTAssertEqual(viewModel.title, "Doc")

        // 2. Edit offline: the save fails transiently, leaving a queued draft that carries
        //    the baseline the app built in step 1.
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            titles.record(request)
            return .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Base, my offline edit")
        viewModel.flushPendingChanges()
        await waitUntil {
            if case .pendingSync = coordinator.state(for: self.documentID) { return true }
            return false
        }
        XCTAssertEqual(
            draftStore.draft(for: documentID)?.baseline?.title, "Doc",
            "the baseline the app built must record the server's title, or the rename can't be seen")

        // 3. A co-author renames it on the web (body untouched). 4. Reconnect → replay.
        let renamed = formattedBody(content: "# Base", title: "Renamed on the web", updatedAt: laterServerUpdatedAt)
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
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }

        XCTAssertNil(coordinator.conflict(for: documentID), "a rename the user didn't make is merged")
        XCTAssertEqual(titles.last, "Renamed on the web", "the co-author's rename survives the replay")
        XCTAssertNil(draftStore.draft(for: documentID), "and the offline edit is saved")
    }

    /// The editor's own draft replay (`reconcileDraft`'s push branch). The body is
    /// unchanged on the server, so the draft still descends from it and pushes — and the
    /// push must carry the **server's** title, or it reverts the co-author's rename. The
    /// screen takes it too: `flushPendingChanges` PATCHes `title`, so a stale one there
    /// would put the old name straight back on the next keystroke.
    func testReconcileDraftReplayAdoptsARemoteRenameOnScreenAndInThePush() async {
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        let titles = PatchedTitleRecorder()
        let renamed = formattedBody(content: "# Base", title: "Renamed on the web")
        MockURLProtocol.stubHandler = { request in
            titles.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return MockURLProtocol.Stub(statusCode: 200, headers: [:], body: renamed, error: nil)
            }
            return MockURLProtocol.Stub(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        // Edited the body offline; never touched the title. The baseline predates the
        // server's `updated_at`, so the server has genuinely moved on (the rename).
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Old title", markdown: "# Mine", updatedAt: Date(),
                baseline: DraftBaseline(
                    serverUpdatedAt: fixtureServerUpdatedAt.addingTimeInterval(-3600), markdown: "# Base",
                    title: "Old title")))

        await viewModel.load()  // restoreLocalContent .draft → revalidate → reconcileDraft .push

        XCTAssertNil(coordinator.conflict(for: documentID), "a rename the user didn't make is merged, not dialogued")
        XCTAssertEqual(viewModel.title, "Renamed on the web", "the screen shows the title it is about to push")
        XCTAssertEqual(
            draftStore.draft(for: documentID)?.title, "Renamed on the web",
            "and the replayed draft carries it, so nothing pushes the stale one")
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) == nil }
        XCTAssertEqual(titles.last, "Renamed on the web", "the replay PATCHed the server's title")
        XCTAssertEqual(viewModel.rawMarkdown, "# Mine", "the user's body still wins — only the title merged")
    }

}
