import XCTest

@testable import Schrift

@MainActor
final class EditorViewModelRevalidationTests: EditorViewModelTestCase {
    // MARK: - Revalidation failure classes + stale-draft server-wins + re-entrancy

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
}
