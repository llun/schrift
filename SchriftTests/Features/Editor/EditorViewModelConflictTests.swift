import XCTest

@testable import Schrift

@MainActor
final class EditorViewModelConflictTests: EditorViewModelTestCase {
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
}
