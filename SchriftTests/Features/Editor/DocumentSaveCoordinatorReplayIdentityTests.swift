import XCTest

@testable import Schrift

/// The create replay authorises on a live `/users/me/` but reads the body through the stored
/// identity, so it must change nothing while the two disagree: an unknown stored identity reads
/// the body as absent and would POST an empty document, then drop the record.
@MainActor
final class DocumentSaveCoordinatorReplayIdentityTests: DocumentSaveCoordinatorReplayTestCase {
    private let otherUser = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!

    func testAPassWithNoKnownAccountPostsNothing() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        env.coordinator.enqueue(documentID: local.id, title: "Notes", markdown: "# Written offline")
        SignedInUserStore(userDefaults: env.defaults).clear()

        await env.coordinator.syncPendingDrafts()

        XCTAssertEqual(creates(log), 0)
        XCTAssertNotNil(env.creates.create(for: local.id), "the record waits for its owner")
        SignedInUserStore(userDefaults: env.defaults).remember(user)
        XCTAssertEqual(env.drafts.draft(for: local.id)?.markdown, "# Written offline")
    }

    /// Another account signing in while the POST is on the wire: the record is checkpointed, and
    /// the migration — which reads and moves the owner's draft — waits for the owner's next pass.
    func testAnAccountSwitchDuringThePostMigratesNothing() async {
        let log = RequestRecorder()
        let gate = MockURLProtocol.ResponseGate()
        stubReplayPipeline(log: log, releasedBy: gate)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        env.coordinator.enqueue(documentID: local.id, title: "Notes", markdown: "# Written offline")

        let coordinator = env.coordinator
        let pass = Task { await coordinator.syncPendingDrafts() }
        await waitUntil { MockURLProtocol.deferredDeliveryCount >= 1 }
        let signedIn = SignedInUserStore(userDefaults: env.defaults)
        signedIn.clear()
        signedIn.remember(otherUser)
        gate.open()
        await pass.value

        XCTAssertEqual(env.creates.create(for: local.id)?.syncedServerID, serverID, "checkpointed, kept")
        signedIn.clear()
        signedIn.remember(user)
        XCTAssertEqual(env.drafts.draft(for: local.id)?.markdown, "# Written offline")
        XCTAssertNil(env.drafts.draft(for: serverID))
    }
}
