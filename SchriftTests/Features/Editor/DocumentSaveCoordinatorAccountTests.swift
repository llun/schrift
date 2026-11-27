import XCTest

@testable import Schrift

/// A draft is shown and replayed only for the signed-in account it belongs to, while the
/// protections that hold whoever is signed in still see every account's.
@MainActor
final class DocumentSaveCoordinatorAccountTests: DocumentSaveCoordinatorTestCase {
    private let otherAccount = UUID(uuidString: "6B6B6B6B-6B6B-4B6B-8B6B-6B6B6B6B6B6B")!

    private func signIn(_ account: UUID?) {
        let signedIn = SignedInUserStore(userDefaults: UserDefaults(suiteName: draftSuiteNames.last!)!)
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
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        XCTAssertNil(contentCache.content(for: documentID), "nothing in B's folder")
        XCTAssertEqual(draftStore.draft(for: documentID)?.markdown, "# B's")
        XCTAssertNil(draftStore.draft(for: documentID)?.lastPushedMarkdown, "nor stamped with A's push")
        signIn(signedInUserID)
        XCTAssertNil(draftStore.draft(for: documentID), "A's landed draft is cleared")
        XCTAssertNil(contentCache.content(for: documentID))
    }

    /// Drafts saved while the sign-in was unnamed go to the account it is then named as.
    func testDraftsSavedWhileUnknownAreAdoptedWhenTheSameSignInIsNamed() {
        let (coordinator, draftStore, _) = makeCoordinator()
        signIn(nil)
        let unnamed = coordinator.signedInSession
        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Typed meanwhile")
        XCTAssertNil(draftStore.draft(for: documentID))

        SignedInUserStore(userDefaults: UserDefaults(suiteName: draftSuiteNames.last!)!).remember(signedInUserID)
        coordinator.adoptDraftsSavedWhileUnknown(epoch: unnamed.epoch, owner: signedInUserID)

        XCTAssertEqual(draftStore.draft(for: documentID)?.markdown, "# Typed meanwhile")
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
}
