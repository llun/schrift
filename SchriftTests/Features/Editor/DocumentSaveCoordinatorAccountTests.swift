import XCTest

@testable import Schrift

/// A draft is shown and replayed only for the signed-in account it belongs to, while the
/// protections that hold whoever is signed in still see every account's.
@MainActor
final class DocumentSaveCoordinatorAccountTests: DocumentSaveCoordinatorTestCase {
    private let otherAccount = UUID(uuidString: "6B6B6B6B-6B6B-4B6B-8B6B-6B6B6B6B6B6B")!

    private func signIn(_ account: UUID?) {
        guard let suite = draftSuiteNames.last else { return XCTFail("no coordinator suite") }
        let signedIn = SignedInUserStore(userDefaults: UserDefaults(suiteName: suite)!)
        signedIn.clear()
        signedIn.remember(account)
    }

    func testAnotherAccountsDraftIsNeitherShownNorReplayed() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, draftStore, _) = makeCoordinator()
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Theirs", updatedAt: Date(),
                ownerUserID: otherAccount))

        await coordinator.syncPendingDrafts()

        XCTAssertNil(coordinator.storedDraft(documentID: documentID))
        XCTAssertEqual(log.methods, [], "nothing of another account's is fetched or sent")
        XCTAssertEqual(draftStore.allDraftsOfEveryAccount().map(\.markdown), ["# Theirs"], "and it is kept")
    }

    func testWithNoKnownAccountNoDraftIsReplayed() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, draftStore, _) = makeCoordinator()
        draftStore.save(PendingDraft(documentID: documentID, title: "Doc", markdown: "# Mine", updatedAt: Date()))
        signIn(nil)

        await coordinator.syncPendingDrafts()

        XCTAssertNil(coordinator.storedDraft(documentID: documentID))
        XCTAssertEqual(log.methods, [])
        signIn(signedInUserID)
        XCTAssertEqual(coordinator.storedDraft(documentID: documentID)?.markdown, "# Mine")
    }

    /// A fresh sign-in builds the coordinator before `/users/me/` names the account; the hold
    /// must already be in force when the account is learned and the draft is shown again.
    func testAConflictHoldIsRehydratedWhileTheAccountIsStillUnknown() {
        let (_, draftStore, _) = makeCoordinator()
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Mine", updatedAt: Date(),
                conflictServerUpdatedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        signIn(nil)

        let relaunched = DocumentSaveCoordinator(
            client: DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] }),
            draftStore: draftStore, contentCache: DocumentContentCacheStore(directory: cacheDirectory),
            backgroundTasks: .noop, sleep: neverSleep)
        signIn(signedInUserID)

        XCTAssertNotNil(relaunched.conflict(for: documentID))
    }

    /// A save parked behind a conflict is the account's that made it. Another account signing in
    /// under the same coordinator neither sees it nor can release it, and it is back for its owner.
    func testAnotherAccountNeitherSeesNorSendsAParkedSave() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, _, _) = makeCoordinator()
        coordinator.recordConflict(documentID: documentID, serverUpdatedAt: Date())
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine")

        signIn(otherAccount)
        XCTAssertNil(coordinator.pendingSave(documentID: documentID))
        XCTAssertNil(coordinator.conflict(for: documentID), "another account's hold is not shown")
        coordinator.resolveConflictKeepingLocal(documentID: documentID)
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }

        signIn(signedInUserID)
        XCTAssertEqual(coordinator.pendingSave(documentID: documentID)?.markdown, "# Mine")
        XCTAssertNotNil(coordinator.conflict(for: documentID), "and the owner's hold still stands")
    }

    /// A screen left open across a switch flushes under the account it loaded for: filed under
    /// that account, never sent under this one, never shown to it.
    func testAnEditFromAnotherSessionIsKeptForItsAccountAndNotSent() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, draftStore, _) = makeCoordinator()
        let loadedFor = coordinator.signedInSession
        signIn(otherAccount)

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# From A's screen", editedIn: loadedFor)
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }

        XCTAssertNil(draftStore.draft(for: documentID))
        signIn(signedInUserID)
        XCTAssertEqual(draftStore.draft(for: documentID)?.markdown, "# From A's screen")
    }

    /// A save that lands after another account signed in settles under the account that started
    /// it: its draft is that account's to clear, and its body reaches no one's cache.
    func testASaveLandingAfterASwitchSettlesUnderTheAccountThatStartedIt() async {
        let log = RequestRecorder()
        let gate = MockURLProtocol.ResponseGate()
        stubSavePipeline(log: log, releasedBy: gate)
        let (coordinator, draftStore, contentCache) = makeCoordinator(accountScopedCache: true)
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# A's")
        await waitUntil { MockURLProtocol.deferredDeliveryCount >= 1 }
        signIn(otherAccount)
        draftStore.save(PendingDraft(documentID: documentID, title: "Doc", markdown: "# B's", updatedAt: Date()))

        gate.open()
        await waitUntil { !coordinator.hasSaveInFlight(documentID: self.documentID) }

        XCTAssertNil(contentCache.content(for: documentID), "nothing in B's folder")
        XCTAssertEqual(draftStore.draft(for: documentID)?.markdown, "# B's")
        XCTAssertNil(draftStore.draft(for: documentID)?.lastPushedMarkdown, "nor stamped with A's push")
        signIn(signedInUserID)
        XCTAssertNil(draftStore.draft(for: documentID), "A's landed draft is cleared")
        XCTAssertNil(contentCache.content(for: documentID))
    }

    /// Native mode must not seed a replica over another account's waiting classic edits.
    func testAnotherAccountsClassicDraftCountsAsWaitingClassicEdits() {
        let (coordinator, draftStore, _) = makeCoordinator()
        XCTAssertFalse(coordinator.hasClassicDraftOfAnyAccount(documentID: documentID))
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Theirs", updatedAt: Date(),
                ownerUserID: otherAccount))
        XCTAssertTrue(coordinator.hasClassicDraftOfAnyAccount(documentID: documentID))
    }

    /// A save that settles after a switch drains its own account's parked follow-up, not the
    /// current account's bucket: left behind, the follow-up would wedge the document for its owner.
    func testASaveSettlingAfterASwitchLeavesNothingParkedForItsAccount() async {
        let log = RequestRecorder()
        let gate = MockURLProtocol.ResponseGate()
        stubSavePipeline(log: log, releasedBy: gate)
        let (coordinator, draftStore, _) = makeCoordinator()
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# v1")
        await waitUntil { MockURLProtocol.deferredDeliveryCount >= 1 }
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# v2")
        signIn(otherAccount)

        gate.open()
        await waitUntil { !coordinator.hasSaveInFlight(documentID: self.documentID) }

        signIn(signedInUserID)
        XCTAssertNil(coordinator.pendingSave(documentID: documentID), "nothing wedged behind a dead slot")
        XCTAssertEqual(draftStore.draft(for: documentID)?.markdown, "# v2", "the newer edit waits on disk")
    }

    /// A screen's flush made after a switch is newer than what its account parked earlier: the
    /// parked copy must not win over it when the account returns.
    func testANewerEditFromAnotherSessionReplacesWhatThatAccountParked() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, draftStore, _) = makeCoordinator()
        let loadedFor = coordinator.signedInSession
        coordinator.recordConflict(documentID: documentID, serverUpdatedAt: Date())
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# v1")
        signIn(otherAccount)

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# v2", editedIn: loadedFor)

        signIn(signedInUserID)
        XCTAssertNil(coordinator.pendingSave(documentID: documentID))
        XCTAssertEqual(draftStore.draft(for: documentID)?.markdown, "# v2")
    }

    /// One account's failed save is not another's: it neither shows nor holds anything for B.
    func testAnotherAccountsFailureIsNotShownToThisOne() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log, contentStatus: 400)
        let (coordinator, _, _) = makeCoordinator()
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Mine")
        await waitUntil { self.isFailed(coordinator.state(for: self.documentID)) }

        signIn(otherAccount)
        XCTAssertEqual(coordinator.state(for: documentID), .idle)
        XCTAssertNil(coordinator.failureReport(for: documentID))

        signIn(signedInUserID)
        XCTAssertTrue(isFailed(coordinator.state(for: documentID)), "still the owner's to answer")
    }

    /// Pages are read-only while no account is known, and nothing that reaches the coordinator
    /// then is sent or parked: it is set aside, kept for nobody.
    func testNothingIsSentOrParkedWhileNoAccountIsKnown() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, draftStore, _) = makeCoordinator()
        signIn(nil)

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Unconfirmed")
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }

        XCTAssertNil(coordinator.pendingSave(documentID: documentID))
        signIn(signedInUserID)
        XCTAssertNil(draftStore.draft(for: documentID), "nobody's, not the account named next")
        XCTAssertEqual(draftStore.allDraftsOfEveryAccount().map(\.markdown), ["# Unconfirmed"], "but kept")
    }
}
