import XCTest

@testable import Schrift

@MainActor
final class DocumentSaveCoordinatorRenameTests: DocumentSaveCoordinatorTestCase {
    /// The no-regression half: a draft written before the baseline carried a title decodes
    /// with `title == nil`. There is nothing to compare against, so it behaves exactly as it
    /// did — the draft's own title is pushed, and no conflict is invented.
    func testALegacyBaselineWithoutATitlePushesTheDraftTitleUnchanged() async {
        let titles = PatchedTitleRecorder()
        let renamedBody = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Renamed on the web", "content": "# Base", "created_at": "2099-01-01T00:00:00Z", "updated_at": "2099-01-01T00:00:00Z"}
            """.utf8)
        let (coordinator, draftStore, _) = makeCoordinator()
        MockURLProtocol.stubHandler = { request in
            titles.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: renamedBody, error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Old title", markdown: "# Mine", updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 0), markdown: "# Base")))

        await coordinator.syncPendingDrafts()
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        XCTAssertNil(coordinator.conflict(for: documentID))
        XCTAssertEqual(titles.last, "Old title", "a titleless baseline keeps today's behavior exactly")
    }

    /// **The rename bug.** A save PATCHes content *and* title, so a replay that pushes the
    /// title its draft was made with silently reverts a rename made on the web — and a
    /// rename leaves the body untouched, which is exactly the body-equality `.push` above.
    /// With the server's title on the baseline, the replay adopts it instead: title and
    /// body are independent fields, so a one-sided rename is a merge, not a dialog.
    func testAReplayAdoptsARemoteRenameInsteadOfRevertingIt() async {
        let titles = PatchedTitleRecorder()
        let renamedBody = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Renamed on the web", "content": "# Base", "created_at": "2099-01-01T00:00:00Z", "updated_at": "2099-01-01T00:00:00Z"}
            """.utf8)
        let (coordinator, draftStore, _) = makeCoordinator()
        MockURLProtocol.stubHandler = { request in
            titles.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: renamedBody, error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        // The user edited the body offline and never touched the title.
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Old title", markdown: "# Mine", updatedAt: Date(),
                baseline: DraftBaseline(
                    serverUpdatedAt: Date(timeIntervalSince1970: 0), markdown: "# Base", title: "Old title")))

        await coordinator.syncPendingDrafts()
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        XCTAssertNil(coordinator.conflict(for: documentID), "a rename the user didn't make is merged, not dialogued")
        XCTAssertEqual(
            titles.last, "Renamed on the web",
            "the replay must PATCH the server's title — pushing the draft's reverts the co-author's rename")
    }

    /// The user's own rename, against a server that never touched the title, is just an
    /// edit being replayed — it must reach the server, not be second-guessed.
    func testAReplayPushesTheUsersOwnRenameWhenTheServerDidNotRename() async {
        let titles = PatchedTitleRecorder()
        let serverBody = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Old title", "content": "# Base", "created_at": "2099-01-01T00:00:00Z", "updated_at": "2099-01-01T00:00:00Z"}
            """.utf8)
        let (coordinator, draftStore, _) = makeCoordinator()
        MockURLProtocol.stubHandler = { request in
            titles.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: serverBody, error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "My new title", markdown: "# Mine", updatedAt: Date(),
                baseline: DraftBaseline(
                    serverUpdatedAt: Date(timeIntervalSince1970: 0), markdown: "# Base", title: "Old title")))

        await coordinator.syncPendingDrafts()
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        XCTAssertNil(coordinator.conflict(for: documentID))
        XCTAssertEqual(titles.last, "My new title", "the user's rename is the edit being replayed")
    }

    /// A save in flight carries its own title, and nothing here has reconciled *that* against
    /// the server — so adopting must leave it (and its draft) alone.
    func testAdoptingAServerTitleIsIgnoredWhileASaveIsInFlight() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log, saveDelay: 0.3)
        let (coordinator, draftStore, _) = makeCoordinator()
        coordinator.enqueue(documentID: documentID, title: "Old title", markdown: "# Mine")
        await waitUntil { self.savesInFlight(log) >= 1 }

        coordinator.adoptServerTitle(documentID: documentID, title: "Renamed on the web")

        XCTAssertEqual(
            draftStore.draft(for: documentID)?.title, "Old title",
            "the in-flight save's draft is not rewritten under it")
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
    }

    /// Adopting is **observation, not a push**: the caller may be holding a draft whose save
    /// failed, which is the user's to retry. It must rewrite the draft's title and nothing
    /// else — and start no save.
    func testAdoptingAServerTitleRewritesOnlyTheTitleAndStartsNoSave() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, draftStore, _) = makeCoordinator()
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let baseline = DraftBaseline(
            serverUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000), markdown: "# Base", title: "Old title")
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Old title", markdown: "# Mine", updatedAt: updatedAt,
                baseline: baseline, lastPushedMarkdown: "# Pushed earlier"))

        coordinator.adoptServerTitle(documentID: documentID, title: "Renamed on the web")

        let draft = draftStore.draft(for: documentID)
        XCTAssertEqual(draft?.title, "Renamed on the web")
        XCTAssertEqual(draft?.markdown, "# Mine", "the body is never touched — a title is not content")
        XCTAssertEqual(draft?.updatedAt, updatedAt)
        XCTAssertEqual(
            draft?.lastPushedMarkdown, "# Pushed earlier",
            "dropping this would re-break rule 1 — a false conflict against the user's own write")
        XCTAssertEqual(
            draft?.baseline?.title, "Renamed on the web",
            "the draft now descends from that server title — see adoptedBaseline")
        XCTAssertEqual(draft?.baseline?.markdown, "# Base", "…but its body still descends from the same state")
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }
        XCTAssertEqual(coordinator.state(for: documentID), .idle, "observing a rename is not a save")
    }

    func testAdoptingAServerTitleWithNoStoredDraftCreatesNone() {
        let (coordinator, draftStore, _) = makeCoordinator()

        coordinator.adoptServerTitle(documentID: documentID, title: "Renamed on the web")

        XCTAssertNil(draftStore.draft(for: documentID), "there is no unsaved work to retitle")
    }

    func testDiscardPendingWorkClearsTheKnownServerTitle() {
        let (coordinator, _, _) = makeCoordinator()
        coordinator.noteServerTitle(documentID: documentID, title: "Doc")

        coordinator.discardPendingWork(documentID: documentID)

        XCTAssertNil(coordinator.knownServerTitle(documentID: documentID), "the document is gone")
    }

    /// "Keep mine" on a **title** conflict has to stick exactly as it does on a body one: the
    /// released push usually fails (a conflict is reviewed on the connection that caused it),
    /// and the surviving draft must not re-detect the identical conflict on the next sync —
    /// the user's answer would evaporate and they would be asked forever.
    func testKeepingMineOnATitleConflictSticksAcrossAFailedPush() async {
        let log = RequestRecorder()
        let titles = PatchedTitleRecorder()
        let renamed = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Their title", "content": "# Base", "created_at": "2099-01-01T00:00:00Z", "updated_at": "2099-01-01T00:00:00Z"}
            """.utf8)
        let (coordinator, draftStore, _) = makeCoordinator()
        // The push fails (offline); the GET keeps working.
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            titles.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: renamed, error: nil)
            }
            return .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }
        // Both renamed, differently; the bodies agree — only the titles conflict.
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "My title", markdown: "# Base", updatedAt: Date(),
                baseline: DraftBaseline(
                    serverUpdatedAt: Date(timeIntervalSince1970: 0), markdown: "# Base", title: "Old title")))

        await coordinator.syncPendingDrafts()
        XCTAssertNotNil(coordinator.conflict(for: documentID), "two different renames")

        // They keep theirs — and the released push fails, which is the *common* case: a
        // conflict is reviewed on the same flaky connection that produced it.
        coordinator.resolveConflictKeepingLocal(documentID: documentID)
        await waitUntil {
            if case .pendingSync = coordinator.state(for: self.documentID) { return true }
            return false
        }
        let draft = draftStore.draft(for: documentID)
        XCTAssertEqual(draft?.title, "My title", "their answer survives on the draft")
        XCTAssertEqual(
            draft?.baseline?.title, "Old title",
            "the baseline still records what the SERVER held — writing their title into it would make "
                + "the next reconcile mistake the server's title for a rename and adopt it back over theirs")
        XCTAssertNil(coordinator.conflict(for: documentID), "the record is cleared by the resolution")

        // The connection comes back and the sync trigger fires again (reconnect/foreground).
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
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        XCTAssertNil(
            coordinator.conflict(for: documentID),
            "the answered conflict must not be re-raised — the user's answer would evaporate and they "
                + "would be asked the same question forever")
        XCTAssertEqual(titles.last, "My title", "and the retry finally pushes the title they chose")
    }

    /// Both sides renamed, differently: there is no merge that keeps both, so it takes the
    /// same funnel a body conflict does — the push is held and the pill asks the user. The
    /// bodies are identical here, so nothing but the titles can raise it.
    func testTwoDifferentRenamesConflictInsteadOfPushing() async {
        let log = RequestRecorder()
        let titles = PatchedTitleRecorder()
        let renamedBody = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Their title", "content": "# Base", "created_at": "2099-01-01T00:00:00Z", "updated_at": "2099-01-01T00:00:00Z"}
            """.utf8)
        let (coordinator, draftStore, _) = makeCoordinator()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            titles.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: renamedBody, error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        // The user renamed it too, offline, to something else.
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "My title", markdown: "# Base", updatedAt: Date(),
                baseline: DraftBaseline(
                    serverUpdatedAt: Date(timeIntervalSince1970: 0), markdown: "# Base", title: "Old title")))

        await coordinator.syncPendingDrafts()

        XCTAssertNotNil(coordinator.conflict(for: documentID), "two different renames are a genuine conflict")
        XCTAssertNotNil(draftStore.draft(for: documentID), "the draft waits for the user's choice")
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }  // a save is an unstructured Task
        XCTAssertTrue(titles.all.isEmpty, "a conflict never PATCHes a title")
    }
}
