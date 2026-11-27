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

        XCTAssertNotNil(relaunched.conflict(for: documentID))
    }
}
