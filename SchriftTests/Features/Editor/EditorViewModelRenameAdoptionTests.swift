import XCTest

@testable import Schrift

@MainActor
final class EditorViewModelRenameAdoptionTests: EditorViewModelTestCase {
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
