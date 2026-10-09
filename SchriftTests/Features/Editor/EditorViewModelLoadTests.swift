import XCTest

@testable import Schrift

@MainActor
final class EditorViewModelLoadTests: EditorViewModelTestCase {
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

        XCTAssertNil(viewModel.errorKey)
        XCTAssertTrue(viewModel.needsOnlineContent)
        XCTAssertFalse(viewModel.canStartEditing)
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

    /// The claim offline editing rests on: a cold open with no network installs the
    /// cached copy, which sets `hasLoadedContent` — `startEditing`'s only guard, and
    /// the sole gate left now that the view's `!isOffline` checks are gone.
    func testStartEditingWorksOfflineFromTheCachedCopy() async {
        let (viewModel, _, _, contentCache) = makeEnvironment()
        contentCache.save(cachedEntry())
        stubOffline()
        await viewModel.load()

        XCTAssertTrue(viewModel.canStartEditing, "the predicate the guard and the Edit button share")
        viewModel.startEditing()

        XCTAssertTrue(viewModel.isEditing, "a cached copy is loaded content, so editing may begin offline")
        XCTAssertFalse(viewModel.blocks.isEmpty)
    }

    /// Offline with nothing cached is the state this change makes common, and it is where
    /// the load error also suppresses "Start writing" — so Edit would be the only thing on
    /// screen, doing nothing. The button disables against the same predicate the guard
    /// uses, so an affordance that would silently decline is never offered.
    func testEditIsWithheldOfflineWhenNothingIsCachedToEdit() async {
        let (viewModel, _, _, _) = makeEnvironment()
        stubOffline()

        await viewModel.load()

        XCTAssertFalse(viewModel.canStartEditing, "nothing loaded, so the Edit button is disabled")
        viewModel.startEditing()
        XCTAssertFalse(viewModel.isEditing, "and the guard declines even if something did tap it")
    }

    /// End-to-end offline edit: the write-ahead draft is on disk before the PATCH is
    /// attempted, a transport failure parks the save at `.pendingSync` (never `.failed`),
    /// and the reconnect trigger replays it once the network is back. This composition —
    /// cold offline open → edit → queue → replay — is what the lifted view gates expose.
    func testOfflineFlushLeavesAPendingSyncDraftThatReplaysOnReconnect() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, draftStore, contentCache) = makeEnvironment()
        // Title matches `formattedBody`'s fixture deliberately: with a different one the
        // replay also resolves `draftTitleOutcome` to `.adoptServer`, and this test would
        // be quietly exercising the remote-rename branch instead of the body push.
        contentCache.save(offlineCachedEntry(markdown: "# Cached"))
        stubOffline(log: log)
        await viewModel.load()

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Edited offline")
        viewModel.flushPendingChanges()
        await waitUntil { viewModel.saveState == .pendingSync }
        XCTAssertTrue(
            draftStore.draft(for: documentID)?.markdown.contains("Edited offline") ?? false,
            "the offline edit is on disk before any network attempt")

        // The offline flush already attempted (and failed) a content PATCH, and the stub
        // records it — so `> 0` would be true before the replay even runs. Snapshot the
        // count and assert it *increases*, or this proves nothing.
        let savesBeforeReconnect = savesInFlight(log)

        // Network returns: the reconnect/foreground funnel replays the queued draft.
        // The replay's decision is rule 2's date check — the cached baseline carries the
        // fixture's own `updated_at`, so the server has not moved past it.
        stubLoadAndSavePipeline(content: "# Cached", log: log)
        await coordinator.syncPendingDrafts()

        await waitUntil { self.savesInFlight(log) > savesBeforeReconnect }
        await waitUntil { viewModel.saveState == .saved }
        await waitUntil { draftStore.draft(for: documentID) == nil }
        // A draft is also removed when the replay's GET 404s and when rule 3 discards it,
        // so the disappearance above does not by itself distinguish "pushed" from
        // "dropped". This does.
        XCTAssertEqual(
            coordinator.lastConfirmedPush(documentID: documentID)?.contains("Edited offline"), true,
            "the offline edit is what reached the server, not a discard")
    }

    /// The destructive twin of the test above, on the baseline shape this change makes
    /// canonical (cache-derived). A co-author wrote while we were offline, so the replay
    /// must record a conflict and **push nothing** — the queued draft is held, not sent.
    /// Every link in this chain is pinned individually; the composition is where a wiring
    /// mistake would silently full-overwrite someone else's work.
    func testAnOfflineEditFromTheCacheConflictsWhenTheServerMovedWhileOffline() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, draftStore, contentCache) = makeEnvironment()
        contentCache.save(offlineCachedEntry(markdown: "# Cached"))
        stubOffline(log: log)
        await viewModel.load()

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Edited offline")
        viewModel.flushPendingChanges()
        await waitUntil { viewModel.saveState == .pendingSync }
        let queuedBody = draftStore.draft(for: documentID)?.markdown
        let savesBeforeReconnect = savesInFlight(log)

        // Reconnect to a co-author's write: a different body *and* an `updated_at` past
        // the baseline's, so rule 2 cannot read it as descending from what we edited.
        stubDivergedServer(content: "# Co-author edit", log: log)
        await coordinator.syncPendingDrafts()

        await waitUntil { viewModel.syncConflict != nil }
        XCTAssertEqual(
            draftStore.draft(for: documentID)?.markdown, queuedBody,
            "the offline edit is held for the user to resolve, never discarded")
        // `waitAndConfirmNever`, not a point-in-time equality: a push enqueued but not yet
        // at the stub would slip past the latter.
        await waitAndConfirmNever { self.savesInFlight(log) > savesBeforeReconnect }
    }

    /// "Start writing" is the gate whose removal creates a genuinely new kind of draft:
    /// one whose baseline body is the empty string, because the cached document had no
    /// content. Empty baseline bodies are a named hazard class here — rule 2's content
    /// tiebreak matches *any* empty server document — and the existing tests guard only
    /// against *fabricating* one. This pins the newly-opened legitimate producer.
    func testOfflineStartWritingOnAnEmptyCachedDocumentConflictsWithACoAuthorsText() async {
        let log = RequestRecorder()
        let (viewModel, coordinator, draftStore, contentCache) = makeEnvironment()
        contentCache.save(offlineCachedEntry(markdown: ""))
        stubOffline(log: log)
        await viewModel.load()
        XCTAssertTrue(viewModel.blocks.isEmpty, "the empty cached body is what makes this the Start-writing path")

        viewModel.startEditing()  // seeds the paragraph "Start writing" would
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "# Written offline")
        viewModel.flushPendingChanges()
        await waitUntil { viewModel.saveState == .pendingSync }
        XCTAssertEqual(
            draftStore.draft(for: documentID)?.baseline?.markdown, "",
            "the baseline records the empty document this was authored against")
        let savesBeforeReconnect = savesInFlight(log)

        stubDivergedServer(content: "# Co-author edit", log: log)
        await coordinator.syncPendingDrafts()

        await waitUntil { viewModel.syncConflict != nil }
        // An empty baseline must never push over real text — see the sibling test for why
        // this is `waitAndConfirmNever` rather than an equality.
        await waitAndConfirmNever { self.savesInFlight(log) > savesBeforeReconnect }
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
}
