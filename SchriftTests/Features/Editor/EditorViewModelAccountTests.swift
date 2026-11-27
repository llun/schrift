import XCTest

@testable import Schrift

/// A screen reads through the live session but files its writes under the session it loaded
/// for, so once another account is signed in under it, it must read, reconcile and purge
/// nothing.
@MainActor
final class EditorViewModelAccountTests: EditorViewModelTestCase {
    private let accountB = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    private func signIn(_ account: UUID?) {
        guard let suite = draftSuiteNames.first else { return XCTFail("no editor suite") }
        let signedIn = SignedInUserStore(userDefaults: UserDefaults(suiteName: suite)!)
        signedIn.clear()
        signedIn.remember(account)
    }

    /// B's own draft of the same document must never be taken for the A screen's and enqueued
    /// into A's.
    func testAScreenLoadedForAnotherAccountNeverTakesThisAccountsDraft() async {
        stubLoad(content: "# Server")
        let env = makeEnvironment()
        await env.viewModel.load()
        signIn(accountB)
        env.draftStore.save(
            PendingDraft(documentID: documentID, title: "Doc", markdown: "# B's private draft", updatedAt: Date()))
        // Saves fail, so anything filed under A would stay on disk to be seen.
        let body = formattedBody(content: "# Server")
        MockURLProtocol.stubHandler = { request in
            if request.url?.absoluteString.contains("formatted-content") == true {
                return .init(statusCode: 200, headers: [:], body: body, error: nil)
            }
            return .init(statusCode: 503, headers: [:], body: Data(), error: nil)
        }

        await env.viewModel.refresh()

        signIn(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
        XCTAssertNil(env.draftStore.draft(for: documentID), "nothing of B's was filed under A")
    }

    /// A 404 the A screen sees after B signed in must not purge B's cached body.
    func testALateUnavailableForAnotherAccountPurgesNothing() async {
        stubLoad(content: "# Server")
        let env = makeEnvironment()
        await env.viewModel.load()
        signIn(accountB)
        env.contentCache.save(
            CachedDocumentContent(documentID: documentID, title: "Doc", markdown: "# B's copy", syncedAt: Date()))
        MockURLProtocol.stubHandler = { _ in
            .init(
                statusCode: 404, headers: ["Content-Type": "application/json"],
                body: Data(#"{"detail":"Not found."}"#.utf8), error: nil)
        }

        await env.viewModel.refresh()

        XCTAssertEqual(env.contentCache.content(for: documentID)?.markdown, "# B's copy")
        XCTAssertFalse(env.viewModel.isUnavailable)
    }

    /// While a re-login's account is not confirmed the page is read-only, with a note, and
    /// editing comes back by itself once it is.
    func testAPageIsReadOnlyUntilTheAccountIsConfirmed() async {
        stubLoad(content: "# Server")
        let env = makeEnvironment()
        await env.viewModel.load()
        XCTAssertTrue(env.viewModel.canStartEditing)

        signIn(nil)
        XCTAssertFalse(env.viewModel.canStartEditing)
        XCTAssertEqual(env.viewModel.readOnlyNoteKey, .editor_read_only_account_unconfirmed)
        env.viewModel.startEditing()
        XCTAssertFalse(env.viewModel.isEditing)

        signIn(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
        XCTAssertNil(env.viewModel.readOnlyNoteKey)
        XCTAssertTrue(env.viewModel.canStartEditing)
    }

    /// Another account's unsent classic edits keep a shared page read-only for this account,
    /// with a note, until they sync. A draft set aside for nobody locks nobody out.
    func testAnotherAccountsUnsentEditsKeepTheSharedPageReadOnly() async {
        stubLoad(content: "# Server")
        let env = makeEnvironment()
        await env.viewModel.load()
        env.draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Unsent elsewhere", updatedAt: Date(),
                ownerUserID: accountB))

        XCTAssertEqual(env.viewModel.readOnlyNoteKey, .editor_read_only_another_account)
        XCTAssertFalse(env.viewModel.canStartEditing)
    }

    func testADraftSetAsideForNobodyLocksNobodyOut() async {
        stubLoad(content: "# Server")
        let env = makeEnvironment()
        await env.viewModel.load()
        signIn(nil)
        env.draftStore.save(
            PendingDraft(documentID: documentID, title: "Doc", markdown: "# Set aside", updatedAt: Date()))
        signIn(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)

        XCTAssertNil(env.viewModel.readOnlyNoteKey)
        XCTAssertTrue(env.viewModel.canStartEditing)
    }
}
