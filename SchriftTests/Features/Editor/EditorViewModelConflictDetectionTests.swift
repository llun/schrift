import XCTest

@testable import Schrift

@MainActor
final class EditorViewModelConflictDetectionTests: EditorViewModelTestCase {
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
}
