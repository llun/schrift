import SwiftUI
import UIKit
import XCTest

@testable import Schrift

@MainActor
final class NativeEditorWaitingClassicTests: DocumentEngineTestCase {
    private let owner = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    // MARK: - Routing

    func testOfflineClassicDraftRoutesToWaitingClassicWithoutNetworkWhenSwitchOnAndClassicWhenOff() async {
        let env = makeEnvironment()
        defer { env.clean() }
        let server = WaitingClassicServerStub(owner: owner, ydocState: serverYDocState("Server canonical body"))
        server.install()
        env.drafts.save(
            PendingDraft(
                documentID: env.documentID, title: "Offline Title", markdown: "Waiting body text",
                updatedAt: Date()))

        let openOn = NativeEditorOpen(preference: { true })
        defer { openOn.close() }
        await openOn.open(viewModel: env.model, isOffline: true, canUpdate: true)
        guard case .waitingClassicEdits = openOn.route else {
            return XCTFail("switch on + offline classic draft must route to .waitingClassicEdits, got \(openOn.route)")
        }
        XCTAssertTrue(env.model.isNativeRouteActive)
        XCTAssertEqual(env.model.title, "Offline Title")
        XCTAssertEqual(server.log.methods, [], "offline open must issue zero network requests")
        XCTAssertEqual(env.coordinator.nativeOwnership(documentID: env.documentID), .none)
        openOn.close()

        let openOff = NativeEditorOpen(preference: { false })
        defer { openOff.close() }
        await openOff.open(viewModel: env.model, isOffline: true, canUpdate: true)
        guard case .classic = openOff.route else {
            return XCTFail("switch off must keep .classic, got \(openOff.route)")
        }
        XCTAssertEqual(server.log.methods, [])
    }

    func testPreDocs6ServerKeepsClassicRouteEvenWithSwitchOn() async {
        let env = makeEnvironment()
        defer { env.clean() }
        env.coordinator.noteServerConfig(ServerConfig(releaseVersion: "5.2.0", collaborationWsUrl: nil))
        env.drafts.save(
            PendingDraft(
                documentID: env.documentID, title: "Legacy Title", markdown: "Legacy body", updatedAt: Date()))

        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: true, canUpdate: true)
        guard case .classic = open.route else {
            return XCTFail("pre-Docs 6 servers must keep .classic, got \(open.route)")
        }
    }

    func testFailedClassicDraftOpensOnWaitingRouteInFailedStateWithoutAutoRetry() async {
        let env = makeEnvironment()
        defer { env.clean() }
        let server = WaitingClassicServerStub(owner: owner, ydocState: serverYDocState("Server body"))
        server.formattedStatus = 404
        server.install()
        env.drafts.save(
            PendingDraft(
                documentID: env.documentID, title: "Rejected Title", markdown: "Unsynced body",
                updatedAt: Date()))

        await env.coordinator.syncPendingDrafts()
        XCTAssertTrue(env.model.isWaitingClassicFailed)
        let requestsBeforeOpen = server.log.methods.count

        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
        guard case .waitingClassicEdits = open.route else {
            return XCTFail("failed classic draft must open on .waitingClassicEdits, got \(open.route)")
        }
        XCTAssertTrue(env.model.isWaitingClassicFailed)
        XCTAssertFalse(open.isWaitingClassicSyncing)
        await waitAndConfirmNever { server.log.methods.count > requestsBeforeOpen }
    }

    // MARK: - Online Drain & Reconnect Transition

    func testOnlineOpenPushesClassicDraftAndTransitionsToNativeSeededFromServerYDoc() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let baselineDate = ISO8601DateFormatter().date(from: "2026-11-07T10:00:00Z")!
        let serverUniqueText = "Authoritative server ydoc text — not built from markdown"
        let server = WaitingClassicServerStub(owner: owner, ydocState: serverYDocState(serverUniqueText))
        server.serverTitle = "Server Title"
        server.serverContent = "Old body"
        server.serverUpdatedAt = "2026-11-07T10:00:00Z"
        server.install()

        env.drafts.save(
            PendingDraft(
                documentID: env.documentID,
                title: "Local Edited Title",
                markdown: "Local classic markdown edit",
                updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: baselineDate, markdown: "Old body", title: "Server Title")))

        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: false, canUpdate: true)

        await waitUntil {
            if case .native = open.route { return true }
            return false
        }
        guard case .native(let session) = open.route else {
            return XCTFail("expected transition to .native after classic push ack, got \(open.route)")
        }
        XCTAssertFalse(env.coordinator.hasWaitingClassicWork(documentID: env.documentID))
        XCTAssertNil(env.drafts.draft(for: env.documentID))
        XCTAssertGreaterThanOrEqual(server.log.count(ofMethod: "PATCH"), 1, "classic draft must have been pushed")
        let renderedText = session.surface.blocks.map(\.visibleText).joined(separator: "\n")
        XCTAssertEqual(
            renderedText, serverUniqueText,
            "native replica must be seeded from the server ydoc state, never built from MarkdownYjs")
    }

    func testReconnectOnWaitingRouteDrainsClassicDraftAndTransitionsToNative() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let baselineDate = ISO8601DateFormatter().date(from: "2026-11-07T10:00:00Z")!
        let serverText = "Seeded from server after reconnect"
        let server = WaitingClassicServerStub(owner: owner, ydocState: serverYDocState(serverText))
        server.serverTitle = "Server Title"
        server.serverContent = "Initial"
        server.serverUpdatedAt = "2026-11-07T10:00:00Z"
        server.install()

        env.drafts.save(
            PendingDraft(
                documentID: env.documentID,
                title: "Offline Edit",
                markdown: "Offline edited body",
                updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: baselineDate, markdown: "Initial", title: "Server Title")))

        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: true, canUpdate: true)
        guard case .waitingClassicEdits = open.route else {
            return XCTFail("expected .waitingClassicEdits offline")
        }
        XCTAssertEqual(server.log.methods, [])

        open.handleConnectivityChange(viewModel: env.model, isOffline: false)
        await waitUntil {
            if case .native = open.route { return true }
            return false
        }
        guard case .native(let session) = open.route else {
            return XCTFail("expected .native after reconnect drain")
        }
        XCTAssertEqual(session.surface.blocks.map(\.visibleText).joined(separator: "\n"), serverText)
    }

    func testCheckpointedCreateFinishesMigrationWhileWaitingScreenIsOpen() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let serverText = "Migrated server ydoc content"
        let server = WaitingClassicServerStub(owner: owner, ydocState: serverYDocState(serverText))
        server.serverTitle = "Offline Created"
        server.serverContent = ""
        server.serverUpdatedAt = "2026-11-07T10:00:00Z"
        server.install()

        let local = env.coordinator.createLocalDocument(
            title: "Offline Created", parentID: nil, ownerUserID: owner, seedMarkdown: "Checkpointed classic body")
        var record = try XCTUnwrap(env.creates.create(for: local.id))
        record.syncedServerID = env.documentID
        env.creates.save(record)
        let relaunched = env.relaunch()

        // Simulate NativeDocumentShellView.onAppear having registered the open editor hold.
        relaunched.noteEditorAppeared()
        XCTAssertTrue(relaunched.saveCoordinator.hasOpenEditorForTesting(documentID: env.documentID))

        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: relaunched, isOffline: false, canUpdate: true)

        await waitUntil {
            if case .native = open.route { return true }
            return false
        }
        guard case .native(let session) = open.route else {
            return XCTFail("read-only waiting route must not deadlock checkpointed-create migration")
        }
        XCTAssertFalse(relaunched.saveCoordinator.hasCheckpointedCreate(forServerID: env.documentID))
        XCTAssertTrue(
            relaunched.saveCoordinator.hasWritableOpenEditorForTesting(documentID: env.documentID),
            "writable open-editor hold must be restored once native opens")
        XCTAssertEqual(session.surface.blocks.map(\.visibleText).joined(separator: "\n"), serverText)
    }

    // MARK: - Conflict Resolution

    func testConflictKeepServerSeedsNativeFromServerYDoc() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let oldBaseline = ISO8601DateFormatter().date(from: "2026-11-07T09:00:00Z")!
        let serverText = "Winning server version"
        let server = WaitingClassicServerStub(owner: owner, ydocState: serverYDocState(serverText))
        server.serverTitle = "Server Title"
        server.serverContent = "Diverged server body"
        server.serverUpdatedAt = "2026-11-07T11:00:00Z"
        server.install()

        env.drafts.save(
            PendingDraft(
                documentID: env.documentID,
                title: "Local Title",
                markdown: "Local diverged body",
                updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: oldBaseline, markdown: "Original", title: "Server Title")))

        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
        await waitUntil { env.model.visibleNativeSyncConflict != nil }
        guard case .waitingClassicEdits = open.route else {
            return XCTFail("conflicted classic draft must remain on .waitingClassicEdits until resolved")
        }

        await open.resolveConflictKeepingServer(viewModel: env.model, isOffline: false, canUpdate: true)
        guard case .native(let session) = open.route else {
            return XCTFail("Keep server must transition to .native, got \(open.route)")
        }
        XCTAssertNil(env.model.visibleNativeSyncConflict)
        XCTAssertNil(env.drafts.draft(for: env.documentID))
        XCTAssertEqual(session.surface.blocks.map(\.visibleText).joined(separator: "\n"), serverText)
    }

    func testConflictKeepMinePushesClassicDraftThenTransitionsToNative() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let oldBaseline = ISO8601DateFormatter().date(from: "2026-11-07T09:00:00Z")!
        let serverText = "Post-push server ydoc state"
        let server = WaitingClassicServerStub(owner: owner, ydocState: serverYDocState(serverText))
        server.serverTitle = "Server Title"
        server.serverContent = "Diverged server body"
        server.serverUpdatedAt = "2026-11-07T11:00:00Z"
        server.install()

        env.drafts.save(
            PendingDraft(
                documentID: env.documentID,
                title: "Local Title",
                markdown: "Local winning body",
                updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: oldBaseline, markdown: "Original", title: "Server Title")))

        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
        await waitUntil { env.model.visibleNativeSyncConflict != nil }

        open.resolveConflictKeepingMine(viewModel: env.model)
        await waitUntil {
            if case .native = open.route { return true }
            return false
        }
        guard case .native(let session) = open.route else {
            return XCTFail("Keep mine must push and then transition to .native")
        }
        XCTAssertNil(env.model.visibleNativeSyncConflict)
        XCTAssertNil(env.drafts.draft(for: env.documentID))
        XCTAssertGreaterThanOrEqual(server.log.count(ofMethod: "PATCH"), 1)
        XCTAssertEqual(session.surface.blocks.map(\.visibleText).joined(separator: "\n"), serverText)
    }

    // MARK: - Failed: Retry & Discard

    func testRetryClearsFailedEntersSavingAndTransitionsToNativeOnRecovery() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let baselineDate = ISO8601DateFormatter().date(from: "2026-11-07T10:00:00Z")!
        let serverText = "Recovered server ydoc"
        let server = WaitingClassicServerStub(owner: owner, ydocState: serverYDocState(serverText))
        server.formattedStatus = 403
        server.serverTitle = "Server Title"
        server.serverContent = "Old body"
        server.serverUpdatedAt = "2026-11-07T10:00:00Z"
        server.install()

        env.drafts.save(
            PendingDraft(
                documentID: env.documentID,
                title: "Local Title",
                markdown: "Edited body",
                updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: baselineDate, markdown: "Old body", title: "Server Title")))

        await env.coordinator.syncPendingDrafts()
        XCTAssertTrue(env.model.isWaitingClassicFailed)

        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
        guard case .waitingClassicEdits = open.route else {
            return XCTFail("expected .waitingClassicEdits")
        }

        // Hold the next formattedContent fetch on a gate so we can assert immediate syncing/saving state.
        let gate = MockURLProtocol.ResponseGate()
        server.formattedStatus = 200
        server.formattedGate = gate
        let retryTask = Task { await open.retryWaitingClassicEdits(viewModel: env.model) }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        XCTAssertTrue(open.isWaitingClassicSyncing, "Retry must immediately switch notice to syncing")
        XCTAssertFalse(env.model.isWaitingClassicFailed, "Retry must clear .failed before the pass finishes")
        XCTAssertEqual(env.coordinator.state(for: env.documentID), .saving)

        gate.open()
        await retryTask.value
        await waitUntil {
            if case .native = open.route { return true }
            return false
        }
        guard case .native(let session) = open.route else {
            return XCTFail("Retry recovery must transition to .native")
        }
        XCTAssertEqual(session.surface.blocks.map(\.visibleText).joined(separator: "\n"), serverText)
    }

    func testRetryWhenServerStillRejectsReturnsToFailedAndDivergenceRecordsConflict() async {
        let env = makeEnvironment()
        defer { env.clean() }
        let oldBaseline = ISO8601DateFormatter().date(from: "2026-11-07T09:00:00Z")!
        let server = WaitingClassicServerStub(owner: owner, ydocState: serverYDocState("Server"))
        server.formattedStatus = 404
        server.serverTitle = "Server Title"
        server.serverContent = "Diverged server body"
        server.serverUpdatedAt = "2026-11-07T11:00:00Z"
        server.install()

        env.drafts.save(
            PendingDraft(
                documentID: env.documentID,
                title: "Local Title",
                markdown: "Local body",
                updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: oldBaseline, markdown: "Original", title: "Server Title")))

        await env.coordinator.syncPendingDrafts()
        XCTAssertTrue(env.model.isWaitingClassicFailed)

        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
        guard case .waitingClassicEdits = open.route else { return XCTFail("expected .waitingClassicEdits") }

        // 1. Server still returns 404 -> Retry finishes back in .failed.
        await open.retryWaitingClassicEdits(viewModel: env.model)
        XCTAssertTrue(env.model.isWaitingClassicFailed, "persisting 404 must land back in .failed")
        XCTAssertFalse(open.isWaitingClassicSyncing)

        // 2. Server is reachable again but diverged -> Retry records conflict instead of blind overwrite.
        server.formattedStatus = 200
        await open.retryWaitingClassicEdits(viewModel: env.model)
        XCTAssertNotNil(env.model.visibleNativeSyncConflict, "Retry must run draftSyncDecision and record conflict")
        XCTAssertEqual(server.log.count(ofMethod: "PATCH"), 0, "Retry must never blindly overwrite a diverged server")
    }

    func testDiscardCheckpointedCreateClearsCheckpointAndDraftWithoutDeletingServerDocument() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let serverText = "Server doc after discarding checkpoint"
        let server = WaitingClassicServerStub(owner: owner, ydocState: serverYDocState(serverText))
        server.install()

        let local = env.coordinator.createLocalDocument(
            title: "Offline Created", parentID: nil, ownerUserID: owner, seedMarkdown: "Local body")
        let child = env.coordinator.createLocalDocument(
            title: "Offline Subpage", parentID: local.id, ownerUserID: owner, seedMarkdown: "Child body")
        var record = try XCTUnwrap(env.creates.create(for: local.id))
        record.syncedServerID = env.documentID
        env.creates.save(record)
        let relaunched = env.relaunch()

        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: relaunched, isOffline: true, canUpdate: true)
        guard case .waitingClassicEdits = open.route else {
            return XCTFail("expected .waitingClassicEdits for checkpointed create")
        }

        await open.discardWaitingClassicEdits(viewModel: relaunched, isOffline: false, canUpdate: true)
        XCTAssertFalse(relaunched.saveCoordinator.hasCheckpointedCreate(forServerID: env.documentID))
        XCTAssertNil(env.drafts.draft(for: local.id))
        XCTAssertEqual(env.creates.create(for: child.id)?.parentID, env.documentID, "subpage must be re-parented")
        XCTAssertEqual(server.log.count(ofMethod: "DELETE"), 0)
        guard case .native(let session) = open.route else {
            return XCTFail("expected .native after discarding checkpointed create")
        }
        XCTAssertEqual(session.surface.blocks.map(\.visibleText).joined(separator: "\n"), serverText)
    }

    func testDiscardRemovesDraftQueuedAttachmentsAndFailureAndReopensNatively() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let serverText = "Clean server document"
        let server = WaitingClassicServerStub(owner: owner, ydocState: serverYDocState(serverText))
        server.formattedStatus = 404
        server.install()

        let placeholder = try XCTUnwrap(
            env.coordinator.queuePendingAttachment(
                documentID: env.documentID, ownerUserID: owner, jpegData: Data([0x89, 0x50, 0x4E, 0x47])))
        let photoLocalID = try XCTUnwrap(pendingAttachmentID(fromPlaceholderURL: placeholder))
        env.drafts.save(
            PendingDraft(
                documentID: env.documentID,
                title: "Doomed Title",
                markdown: "Local edit\n\n![pic](\(placeholder))",
                updatedAt: Date()))
        env.coordinator.enqueue(
            documentID: env.documentID, title: "Doomed Title", markdown: "Local edit\n\n![pic](\(placeholder))")
        await env.coordinator.syncPendingDrafts()

        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: true, canUpdate: true)
        guard case .waitingClassicEdits = open.route else {
            return XCTFail("expected .waitingClassicEdits")
        }
        XCTAssertNotNil(env.coordinator.pendingAttachment(localID: photoLocalID))

        // Server is reachable again when discarding online: must reopen natively, never DELETE the server doc.
        server.formattedStatus = 200
        await open.discardWaitingClassicEdits(viewModel: env.model, isOffline: false, canUpdate: true)

        XCTAssertNil(env.drafts.draft(for: env.documentID), "Discard must remove stored classic draft")
        XCTAssertNil(env.coordinator.pendingSave(documentID: env.documentID), "Discard must clear queued save")
        XCTAssertNil(env.coordinator.pendingAttachment(localID: photoLocalID), "Discard must remove queued photos")
        XCTAssertEqual(env.coordinator.state(for: env.documentID), .idle, "Discard must clear failure state")
        XCTAssertNil(env.coordinator.failureReport(for: env.documentID))
        XCTAssertEqual(server.log.count(ofMethod: "DELETE"), 0, "Discard must never DELETE the server document")
        guard case .native(let session) = open.route else {
            return XCTFail("Discard online against a reachable server must reopen .native, got \(open.route)")
        }
        XCTAssertEqual(session.surface.blocks.map(\.visibleText).joined(separator: "\n"), serverText)
    }

    func testDiscardOnlineAgainstMissingServerDocumentShowsUnavailableOpenFailed() async {
        let env = makeEnvironment()
        defer { env.clean() }
        let server = WaitingClassicServerStub(owner: owner, ydocState: serverYDocState("Unused"))
        server.formattedStatus = 404
        server.ydocStatus = 404
        server.install()

        env.drafts.save(
            PendingDraft(documentID: env.documentID, title: "Gone", markdown: "Unsynced", updatedAt: Date()))
        await env.coordinator.syncPendingDrafts()
        XCTAssertTrue(env.model.isWaitingClassicFailed)

        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
        guard case .waitingClassicEdits = open.route else {
            return XCTFail("expected .waitingClassicEdits")
        }

        await open.discardWaitingClassicEdits(viewModel: env.model, isOffline: false, canUpdate: true)
        XCTAssertNil(env.drafts.draft(for: env.documentID))
        XCTAssertEqual(env.coordinator.state(for: env.documentID), .idle)
        guard case .unavailable(.openFailed) = open.route else {
            return XCTFail("Discard when server has no document must show .unavailable(.openFailed), got \(open.route)")
        }
    }

    func testDiscardOfflineWithStaleClassicCacheNeverFallsBackToClassic() async {
        let env = makeEnvironment()
        defer { env.clean() }
        DocumentContentCacheStore(directory: env.directory).save(
            CachedDocumentContent(
                documentID: env.documentID, title: "Stale Cache", markdown: "Stale body", syncedAt: Date()))
        env.drafts.save(
            PendingDraft(documentID: env.documentID, title: "Unsynced", markdown: "Body", updatedAt: Date()))

        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: true, canUpdate: true)
        guard case .waitingClassicEdits = open.route else {
            return XCTFail("expected .waitingClassicEdits")
        }

        await open.discardWaitingClassicEdits(viewModel: env.model, isOffline: true, canUpdate: true)
        XCTAssertNil(env.drafts.draft(for: env.documentID))
        guard case .unavailable(.offlineNeverOpened) = open.route else {
            return XCTFail("offline discard must land on .unavailable(.offlineNeverOpened), never .classic")
        }
    }

    func testDiscardRefusesWhileClassicSaveIsInFlight() async {
        let env = makeEnvironment()
        defer { env.clean() }
        let patchGate = MockURLProtocol.ResponseGate()
        let server = WaitingClassicServerStub(owner: owner, ydocState: serverYDocState("Server"))
        server.patchGate = patchGate
        server.install()

        env.coordinator.enqueue(documentID: env.documentID, title: "In Flight", markdown: "Saving now")
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        XCTAssertFalse(
            env.coordinator.discardClassicDraft(documentID: env.documentID),
            "discardClassicDraft must be a no-op while a save is actively on the wire")
        XCTAssertNotNil(env.drafts.draft(for: env.documentID))
        patchGate.open()
        await waitUntil { !env.coordinator.isWaitingClassicInFlight(documentID: env.documentID) }
    }

    func testOnlineOpenWhileClassicPatchIsInFlightStaysWaitingUntilPatchLandsThenOpensNative() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let patchGate = MockURLProtocol.ResponseGate()
        defer { patchGate.open() }
        let serverText = "Authoritative server state after in-flight PATCH"
        let server = WaitingClassicServerStub(owner: owner, ydocState: serverYDocState(serverText))
        server.patchGate = patchGate
        server.install()

        env.coordinator.enqueue(documentID: env.documentID, title: "In-Flight Title", markdown: "In-flight body")
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        XCTAssertTrue(env.coordinator.isWaitingClassicInFlight(documentID: env.documentID))

        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
        guard case .waitingClassicEdits = open.route else {
            return XCTFail("in-flight classic PATCH must keep route on .waitingClassicEdits, got \(open.route)")
        }
        XCTAssertTrue(env.model.isWaitingClassicInFlight)
        await waitAndConfirmNever {
            if case .waitingClassicEdits = open.route { return false }
            return true
        }

        patchGate.open()
        await waitUntil {
            if case .native = open.route { return true }
            return false
        }
        guard case .native(let session) = open.route else {
            return XCTFail("route must transition to .native once in-flight classic PATCH lands, got \(open.route)")
        }
        XCTAssertFalse(env.coordinator.isWaitingClassicInFlight(documentID: env.documentID))
        XCTAssertFalse(env.coordinator.hasWaitingClassicWork(documentID: env.documentID))
        XCTAssertEqual(session.surface.blocks.map(\.visibleText).joined(separator: "\n"), serverText)
    }

    // MARK: - Ownership, Failure Classification, Never-Classic & Drain Lifecycle

    func testOwnCheckpointedCreateWithUnknownUserWaitsEmptyWithoutBlockingMigrationThenReopensWithDraft() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let serverText = "Migrated server ydoc after identity resolves"
        let server = WaitingClassicServerStub(owner: owner, ydocState: serverYDocState(serverText))
        server.serverTitle = "Offline Created"
        server.serverContent = ""
        server.serverUpdatedAt = "2026-11-07T10:00:00Z"
        server.install()

        let local = env.coordinator.createLocalDocument(
            title: "Offline Created", parentID: nil, ownerUserID: owner, seedMarkdown: "Checkpointed classic body")
        var record = try XCTUnwrap(env.creates.create(for: local.id))
        record.syncedServerID = env.documentID
        env.creates.save(record)

        // (a) Before /users/me/ resolves (`signedInUser.userID == nil`), route stays `.waitingClassicEdits`
        // with empty body, waiting notice, and no writable open-editor count blocking migration.
        env.model.signedInUser.clear()
        let relaunchedOffline = env.relaunch()
        relaunchedOffline.noteEditorAppeared()
        XCTAssertTrue(relaunchedOffline.saveCoordinator.hasOpenEditorForTesting(documentID: env.documentID))

        let openOffline = NativeEditorOpen(preference: { true })
        defer { openOffline.close() }
        await openOffline.open(viewModel: relaunchedOffline, isOffline: true, canUpdate: true)
        guard case .waitingClassicEdits = openOffline.route else {
            return XCTFail(
                "unknown user + own checkpointed create offline must route to .waitingClassicEdits, "
                    + "got \(openOffline.route)"
            )
        }
        XCTAssertNil(relaunchedOffline.waitingClassicContent, "body must stay empty while user is unknown")
        XCTAssertFalse(openOffline.isWaitingClassicSyncing)
        XCTAssertFalse(relaunchedOffline.isWaitingClassicFailed)
        XCTAssertEqual(
            waitingClassicNoticeState(
                hasConflict: relaunchedOffline.visibleNativeSyncConflict != nil,
                isSyncing: openOffline.isWaitingClassicSyncing || relaunchedOffline.isWaitingClassicInFlight,
                isFailed: relaunchedOffline.isWaitingClassicFailed),
            .waitingOffline)
        XCTAssertFalse(
            relaunchedOffline.saveCoordinator.hasWritableOpenEditorForTesting(documentID: env.documentID),
            "waiting route must release writable open-editor count so migration is not blocked")
        XCTAssertFalse(relaunchedOffline.saveCoordinator.discardClassicDraft(documentID: env.documentID))
        await openOffline.retryWaitingClassicEdits(viewModel: relaunchedOffline)
        XCTAssertFalse(openOffline.isWaitingClassicSyncing)

        // (b) Setting the signed-in user id to the owner reopens and reveals the draft.
        relaunchedOffline.signedInUser.remember(owner)
        relaunchedOffline.saveCoordinator.pins.sessionIdentityDidChange()
        await waitUntil {
            relaunchedOffline.title == "Offline Created"
                && relaunchedOffline.waitingClassicContent?.markdown == "Checkpointed classic body"
        }
        guard case .waitingClassicEdits = openOffline.route else {
            return XCTFail(
                "offline reopen after owner resolves must stay .waitingClassicEdits, got \(openOffline.route)")
        }
        XCTAssertEqual(relaunchedOffline.waitingClassicContent?.title, "Offline Created")
        XCTAssertEqual(relaunchedOffline.waitingClassicContent?.markdown, "Checkpointed classic body")
        openOffline.close()

        // Same check online: stays on `.waitingClassicEdits` with empty body and non-blocking open count
        // until identity resolves, then reopens, drains/migrates, and lands on `.native`.
        env.model.signedInUser.clear()
        let relaunchedOnline = env.relaunch()
        relaunchedOnline.noteEditorAppeared()

        let openOnline = NativeEditorOpen(preference: { true })
        defer { openOnline.close() }
        await openOnline.open(viewModel: relaunchedOnline, isOffline: false, canUpdate: true)
        guard case .waitingClassicEdits = openOnline.route else {
            return XCTFail(
                "unknown user + own checkpointed create online must route to .waitingClassicEdits, "
                    + "got \(openOnline.route)"
            )
        }
        XCTAssertNil(relaunchedOnline.waitingClassicContent)
        XCTAssertFalse(openOnline.isWaitingClassicSyncing)
        XCTAssertFalse(
            relaunchedOnline.saveCoordinator.hasWritableOpenEditorForTesting(documentID: env.documentID),
            "online waiting route with unknown user must not hold a writable open-editor count")

        relaunchedOnline.signedInUser.remember(owner)
        relaunchedOnline.saveCoordinator.pins.sessionIdentityDidChange()
        await waitUntil {
            if case .native = openOnline.route { return true }
            return false
        }
        guard case .native(let session) = openOnline.route else {
            return XCTFail("online reopen after owner resolves must migrate and open .native, got \(openOnline.route)")
        }
        XCTAssertFalse(relaunchedOnline.saveCoordinator.hasCheckpointedCreate(forServerID: env.documentID))
        XCTAssertEqual(session.surface.blocks.map(\.visibleText).joined(separator: "\n"), serverText)
    }

    func testOtherAccountCheckpointedCreateIsNotShownOrDiscardedWhenSignedOutOrDifferentUser() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let otherOwner = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
        let serverText = "Server canonical document"
        let server = WaitingClassicServerStub(owner: owner, ydocState: serverYDocState(serverText))
        server.install()

        let local = env.coordinator.createLocalDocument(
            title: "Other Account Title", parentID: nil, ownerUserID: otherOwner,
            seedMarkdown: "Private other account draft")
        var record = try XCTUnwrap(env.creates.create(for: local.id))
        record.syncedServerID = env.documentID
        env.creates.save(record)

        // 1. signedInUser is nil: fail closed onto `.waitingClassicEdits` with empty body, waiting notice,
        // no writable open-editor count, and Retry/Discard refused (never exposing private draft or `.classic`).
        env.model.signedInUser.clear()
        let relaunchedNil = env.relaunch()
        relaunchedNil.noteEditorAppeared()
        XCTAssertNil(relaunchedNil.waitingClassicContent)
        XCTAssertFalse(relaunchedNil.hasWaitingClassicWork)
        XCTAssertFalse(relaunchedNil.isWaitingClassicFailed)
        XCTAssertFalse(
            relaunchedNil.saveCoordinator.discardClassicDraft(documentID: env.documentID),
            "Discard must refuse when signedInUser is nil")
        XCTAssertNotNil(env.creates.create(for: local.id), "checkpointed record must stay intact")
        XCTAssertEqual(
            env.drafts.allDraftsOfEveryAccount().first { $0.documentID == local.id }?.markdown,
            "Private other account draft")

        let openNilOffline = NativeEditorOpen(preference: { true })
        defer { openNilOffline.close() }
        await openNilOffline.open(viewModel: relaunchedNil, isOffline: true, canUpdate: true)
        guard case .waitingClassicEdits = openNilOffline.route else {
            return XCTFail(
                "signed-out offline open must fail closed onto .waitingClassicEdits, got \(openNilOffline.route)")
        }
        XCTAssertNil(relaunchedNil.waitingClassicContent, "must not display other account's draft while signed out")
        XCTAssertFalse(relaunchedNil.saveCoordinator.hasWritableOpenEditorForTesting(documentID: env.documentID))
        openNilOffline.close()

        let openNilOnline = NativeEditorOpen(preference: { true })
        defer { openNilOnline.close() }
        await openNilOnline.open(viewModel: relaunchedNil, isOffline: false, canUpdate: true)
        guard case .waitingClassicEdits = openNilOnline.route else {
            return XCTFail(
                "signed-out online open must fail closed onto .waitingClassicEdits, got \(openNilOnline.route)")
        }
        XCTAssertNil(relaunchedNil.waitingClassicContent)
        XCTAssertFalse(relaunchedNil.saveCoordinator.hasWritableOpenEditorForTesting(documentID: env.documentID))

        // Once identity resolves to a different known account (`owner` != `otherOwner`), the waiting route
        // reopens natively on the server document while keeping the other account's record untouched.
        relaunchedNil.signedInUser.remember(owner)
        relaunchedNil.saveCoordinator.pins.sessionIdentityDidChange()
        await waitUntil {
            if case .native = openNilOnline.route { return true }
            return false
        }
        guard case .native(let reopenedSession) = openNilOnline.route else {
            return XCTFail("different account resolution must reopen server doc natively, got \(openNilOnline.route)")
        }
        XCTAssertEqual(reopenedSession.surface.blocks.map(\.visibleText).joined(separator: "\n"), serverText)
        XCTAssertNotNil(env.creates.create(for: local.id))
        XCTAssertEqual(
            env.drafts.allDraftsOfEveryAccount().first { $0.documentID == local.id }?.markdown,
            "Private other account draft")
        openNilOnline.close()

        // 2. Fresh open as a different KNOWN account (`owner` != `otherOwner`) excludes the record directly.
        let relaunchedOther = env.relaunch()
        XCTAssertFalse(relaunchedOther.saveCoordinator.hasCheckpointedCreate(forServerID: env.documentID))
        XCTAssertNil(relaunchedOther.waitingClassicContent)
        XCTAssertFalse(relaunchedOther.hasWaitingClassicWork)
        XCTAssertFalse(relaunchedOther.isWaitingClassicFailed)
        XCTAssertFalse(
            relaunchedOther.saveCoordinator.discardClassicDraft(documentID: env.documentID),
            "Discard must refuse for another account's checkpointed create")
        XCTAssertNotNil(env.creates.create(for: local.id), "other account's checkpointed record must stay intact")
        XCTAssertEqual(
            env.drafts.allDraftsOfEveryAccount().first { $0.documentID == local.id }?.markdown,
            "Private other account draft")

        let openOther = NativeEditorOpen(preference: { true })
        defer { openOther.close() }
        await openOther.open(viewModel: relaunchedOther, isOffline: false, canUpdate: true)
        guard case .native(let otherSession) = openOther.route else {
            return XCTFail(
                "different account must open server doc natively, got \(openOther.route)")
        }
        XCTAssertEqual(otherSession.surface.blocks.map(\.visibleText).joined(separator: "\n"), serverText)
        XCTAssertNotNil(env.creates.create(for: local.id))
        XCTAssertEqual(
            env.drafts.allDraftsOfEveryAccount().first { $0.documentID == local.id }?.markdown,
            "Private other account draft")
    }

    func testSessionExpiredAndRouteNotFoundLeaveClassicDraftWaiting() async {
        let env = makeEnvironment()
        defer { env.clean() }
        let server = WaitingClassicServerStub(owner: owner, ydocState: serverYDocState("Server"))
        server.formattedStatus = 401
        server.install()

        env.drafts.save(
            PendingDraft(
                documentID: env.documentID, title: "Waiting Title", markdown: "Waiting body",
                updatedAt: Date()))

        await env.coordinator.syncPendingDrafts()
        XCTAssertFalse(
            env.coordinator.isWaitingClassicFailed(documentID: env.documentID),
            "401 (.sessionExpired) on formattedContent must not mark a classic draft .failed")
        XCTAssertNotNil(env.drafts.draft(for: env.documentID))

        // An HTML 404 maps to `.routeNotFound`: a fact about the route (often a proxy mid-deploy),
        // deferred like create and delete replay defer it.
        server.formattedStatus = 404
        server.formattedContentType = "text/html"
        await env.coordinator.syncPendingDrafts()
        XCTAssertFalse(
            env.coordinator.isWaitingClassicFailed(documentID: env.documentID),
            ".routeNotFound on formattedContent must leave a classic draft waiting, not failed")
        XCTAssertNotNil(env.drafts.draft(for: env.documentID))
        // Online and still waiting, the card offers Couldn't sync's buttons all the same.
        XCTAssertEqual(
            waitingClassicNoticeState(hasConflict: false, isSyncing: false, isFailed: false, isStalledOnline: true),
            .failed)
    }

    func testPostDiscardReopenGoingOfflineMidFetchWithCachedCopyNeverFallsBackToClassic() async {
        let env = makeEnvironment()
        defer { env.clean() }
        let ydocGate = MockURLProtocol.ResponseGate()
        let server = WaitingClassicServerStub(owner: owner, ydocState: serverYDocState("Server body"))
        server.ydocGate = ydocGate
        server.install()

        // Seed BOTH a cached classic copy and a waiting classic draft.
        env.model.contentCache.save(
            CachedDocumentContent(
                documentID: env.documentID, title: "Cached Title", markdown: "Cached body",
                syncedAt: Date(timeIntervalSince1970: 1), serverUpdatedAt: Date(timeIntervalSince1970: 2)))
        env.drafts.save(
            PendingDraft(
                documentID: env.documentID, title: "Draft Title", markdown: "Draft body",
                updatedAt: Date()))

        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: true, canUpdate: true)
        guard case .waitingClassicEdits = open.route else {
            return XCTFail("expected .waitingClassicEdits before discard")
        }

        let discardTask = Task {
            await open.discardWaitingClassicEdits(viewModel: env.model, isOffline: false, canUpdate: true)
        }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        // Availability flips offline while post-Discard reopen is waiting on the network.
        env.defaults.set(true, forKey: "schrift.workOffline")
        env.model.availability.preferencesChanged()
        ydocGate.open()
        await discardTask.value

        guard case .unavailable(.offlineNeverOpened) = open.route else {
            return XCTFail(
                "post-Discard offline reopen must settle on .unavailable(.offlineNeverOpened), got \(open.route)")
        }
        XCTAssertTrue(env.model.isNativeRouteActive)
    }

    func testReconnectWhileOpenAwaitsClosingStartsDrainAndReopensNatively() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let baselineDate = ISO8601DateFormatter().date(from: "2026-11-07T10:00:00Z")!
        let serverText = "Reconnected native state"
        let server = WaitingClassicServerStub(owner: owner, ydocState: serverYDocState(serverText))
        server.serverTitle = "Server Title"
        server.serverContent = "Initial"
        server.serverUpdatedAt = "2026-11-07T10:00:00Z"
        server.install()

        let closeGate = Latch(open: true)
        defer { closeGate.open() }
        let open = NativeEditorOpen(
            preference: { true },
            replicaHooks: .init(beforeMessage: { await closeGate.passing() }))
        defer { open.close() }

        // 1. Open document A natively so `close()` creates a `closing` task on its replica.
        await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
        guard case .native = open.route else {
            return XCTFail("expected initial .native session")
        }

        // 2. Prepare document B with a waiting classic draft while Work Offline is enabled.
        let waitingDocID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        env.drafts.save(
            PendingDraft(
                documentID: waitingDocID,
                title: "Offline Waiting Title",
                markdown: "Offline waiting body",
                updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: baselineDate, markdown: "Initial", title: "Server Title")))
        let waitingModel = EditorViewModel(
            client: env.model.client,
            documentID: waitingDocID,
            title: "Initial Row Title",
            saveCoordinator: env.coordinator,
            signedInUser: env.model.signedInUser,
            contentCache: env.model.contentCache,
            childrenCache: env.model.childrenCache,
            listCache: env.model.listCache,
            availability: env.model.availability,
            nativeEditorEnabled: { true })

        env.defaults.set(true, forKey: "schrift.workOffline")
        waitingModel.availability.preferencesChanged()

        // 3. Hold `closing` behind `closeGate`, then start opening document B while offline.
        closeGate.close()
        open.close()
        let openTask = Task {
            await open.open(viewModel: waitingModel, isOffline: true, canUpdate: true)
        }
        await waitUntil { closeGate.waiting == 1 && waitingModel.isNativeRouteActive }

        // 4. Reconnect while `open()` is still awaiting `closing` (`.loading`).
        env.defaults.set(false, forKey: "schrift.workOffline")
        waitingModel.availability.preferencesChanged()
        closeGate.open()
        await openTask.value

        await waitUntil {
            if case .native = open.route { return true }
            return false
        }
        guard case .native(let session) = open.route else {
            return XCTFail("reconnect during closing await must start drain and reopen .native, got \(open.route)")
        }
        XCTAssertNil(env.drafts.draft(for: waitingDocID))
        XCTAssertGreaterThanOrEqual(server.log.count(ofMethod: "PATCH"), 1)
        XCTAssertEqual(session.surface.blocks.map(\.visibleText).joined(separator: "\n"), serverText)
    }

    func testConflictKeepServerWithNilAccountOpensNativeReadOnlyInsteadOfClassic() async {
        let env = makeEnvironment()
        defer { env.clean() }
        let oldBaseline = ISO8601DateFormatter().date(from: "2026-11-07T09:00:00Z")!
        let serverDate = ISO8601DateFormatter().date(from: "2026-11-07T11:00:00Z")!
        let serverText = "Authoritative server content"
        let server = WaitingClassicServerStub(owner: owner, ydocState: serverYDocState(serverText))
        server.serverTitle = "Server Title"
        server.serverContent = "Diverged server body"
        server.serverUpdatedAt = "2026-11-07T11:00:00Z"
        server.install()

        env.drafts.save(
            PendingDraft(
                documentID: env.documentID,
                title: "Local Title",
                markdown: "Local diverged body",
                updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: oldBaseline, markdown: "Original", title: "Server Title")))
        env.coordinator.recordConflict(documentID: env.documentID, serverUpdatedAt: serverDate)
        env.model.signedInUser.clear()

        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: true, canUpdate: true)
        // With no account known the draft is shown to nobody, so it never routes to its edits.
        if case .waitingClassicEdits = open.route { return XCTFail("the draft must not be shown") }
        if case .classic = open.route { return XCTFail("nil account must never open classic") }

        await open.resolveConflictKeepingServer(viewModel: env.model, isOffline: false, canUpdate: true)
        guard case .native(let session) = open.route else {
            return XCTFail(
                "Keep server with nil signedInUser must open native read-only instead of .classic, got \(open.route)")
        }
        XCTAssertNil(session.input, "nil account native session must be read-only")
        XCTAssertEqual(open.editUnavailableReason, .signedOut)
        XCTAssertEqual(session.surface.blocks.map(\.visibleText).joined(separator: "\n"), serverText)
    }

    func testClosingWaitingPageMidPassDoesNotCancelSharedSyncPassForOtherDocument() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let createGate = MockURLProtocol.ResponseGate()
        defer { createGate.open() }
        let createdServerID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
        let server = WaitingClassicServerStub(owner: owner, ydocState: serverYDocState("Server"))
        server.createGate = createGate
        server.createdDocumentID = createdServerID
        server.install()

        // Document A: waiting classic draft opened online on the waiting route.
        env.drafts.save(
            PendingDraft(
                documentID: env.documentID, title: "Doc A", markdown: "Waiting body", updatedAt: Date()))
        // Document B: another local document whose create POST runs first in the shared pass.
        // Disable native conversion so Document B stays a classic create that POSTs cleanly.
        env.coordinator.nativeEditorEnabled = { false }
        let otherLocal = env.coordinator.createLocalDocument(
            title: "Other Local Doc", parentID: nil, ownerUserID: owner, seedMarkdown: "Other body")
        // Retain a writable open editor on `createdServerID` so `replayCreate` POSTs and checkpoints
        // `syncedServerID` then defers migration, giving a deterministic assertion that the POST landed.
        env.coordinator.retainOpenEditor(documentID: createdServerID, isWritable: true)
        defer { env.coordinator.releaseOpenEditor(documentID: createdServerID, wasWritable: true) }

        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
        guard case .waitingClassicEdits = open.route else {
            return XCTFail("expected .waitingClassicEdits")
        }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }

        // Close Document A's waiting page while Document B's create POST is in flight.
        open.close()
        createGate.open()

        await waitUntil {
            env.creates.create(for: otherLocal.id)?.syncedServerID == createdServerID
        }
        XCTAssertEqual(
            env.creates.create(for: otherLocal.id)?.syncedServerID, createdServerID,
            "closing the waiting page must not cancel another document's create POST in the shared pass")
    }

    func testConflictKeepMineWithQueuedPhotoKicksAttachmentPassAndTransitionsToNative() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let oldBaseline = ISO8601DateFormatter().date(from: "2026-11-07T09:00:00Z")!
        let serverDate = ISO8601DateFormatter().date(from: "2026-11-07T11:00:00Z")!
        let serverText = "Post-photo-upload server ydoc"

        // Persist the queued photo and conflicted draft as if created offline before relaunching online.
        let attachmentStore = PendingAttachmentStore(
            userDefaults: env.defaults, directory: env.directory.appendingPathComponent("attachments"))
        let photoLocalID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        XCTAssertTrue(attachmentStore.saveData(Data([0xFF, 0xD8, 0xFF, 0xD9]), for: photoLocalID))
        attachmentStore.save(
            PendingAttachment(
                localID: photoLocalID, documentID: env.documentID, createdAt: Date(),
                serverOrigin: env.model.client.serverOrigin, ownerUserID: owner))
        let placeholder = pendingAttachmentPlaceholderURL(for: photoLocalID)
        env.drafts.save(
            PendingDraft(
                documentID: env.documentID,
                title: "Local Photo Title",
                markdown: "Body with photo\n\n![photo](\(placeholder))",
                updatedAt: Date(),
                baseline: DraftBaseline(serverUpdatedAt: oldBaseline, markdown: "Original", title: "Server Title"),
                conflictServerUpdatedAt: serverDate))
        let relaunched = env.relaunch()

        let server = WaitingClassicServerStub(owner: owner, ydocState: serverYDocState(serverText))
        server.attachmentUploadStatus = 201
        server.serverTitle = "Server Title"
        server.serverContent = "Diverged server body"
        server.serverUpdatedAt = "2026-11-07T11:00:00Z"
        server.install()

        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: relaunched, isOffline: false, canUpdate: true)
        guard case .waitingClassicEdits = open.route else {
            return XCTFail("expected .waitingClassicEdits with conflict")
        }
        XCTAssertNotNil(relaunched.visibleNativeSyncConflict)
        XCTAssertEqual(server.log.count(ofMethod: "POST", urlContaining: "attachment-upload"), 0)

        open.resolveConflictKeepingMine(viewModel: relaunched)
        await waitUntil {
            if case .native = open.route { return true }
            return false
        }
        guard case .native(let session) = open.route else {
            return XCTFail(
                "Keep mine with a queued photo must run attachment pass and open .native, got \(open.route)")
        }
        XCTAssertEqual(server.log.count(ofMethod: "POST", urlContaining: "attachment-upload"), 1)
        XCTAssertGreaterThanOrEqual(server.log.count(ofMethod: "PATCH"), 1)
        XCTAssertNil(env.drafts.draft(for: env.documentID))
        XCTAssertEqual(session.surface.blocks.map(\.visibleText).joined(separator: "\n"), serverText)
    }

    // MARK: - Copy Text & View-Level Notice Tests

    func testWaitingClassicNoticeStateMappingAndCopyTextFormatting() {
        XCTAssertEqual(
            waitingClassicNoticeState(hasConflict: false, isSyncing: false, isFailed: false),
            .waitingOffline)
        XCTAssertEqual(
            waitingClassicNoticeState(hasConflict: false, isSyncing: true, isFailed: false),
            .syncing)
        XCTAssertEqual(
            waitingClassicNoticeState(hasConflict: false, isSyncing: true, isFailed: true),
            .syncing, "active Retry must immediately show syncing")
        XCTAssertEqual(
            waitingClassicNoticeState(hasConflict: false, isSyncing: false, isFailed: true),
            .failed)
        XCTAssertEqual(
            waitingClassicNoticeState(hasConflict: true, isSyncing: false, isFailed: true),
            .hidden, "conflicts are surfaced by the conflict pill and sheet")
        XCTAssertEqual(
            waitingClassicNoticeState(hasConflict: false, isSyncing: false, isFailed: false, isStalledOnline: true),
            .failed, "online with edits still waiting offers Retry / Copy text / Discard")
        XCTAssertEqual(
            waitingClassicNoticeState(hasConflict: false, isSyncing: true, isFailed: false, isStalledOnline: true),
            .syncing)

        XCTAssertEqual(
            waitingClassicCopyText(title: "My Page", markdown: "Line 1\n\nLine 2"),
            "My Page\n\nLine 1\n\nLine 2")
        XCTAssertEqual(waitingClassicCopyText(title: "", markdown: "Only body"), "Only body")
        XCTAssertEqual(waitingClassicCopyText(title: "Only title", markdown: ""), "Only title")
        XCTAssertEqual(waitingClassicCopyText(title: "", markdown: ""), "")
    }

    func testWaitingClassicNoticeViewRendersStatesAndCopyWritesFormattedPayload() async throws {
        let suite = "NativeEditorWaitingClassicTests.NoticeView.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let loc = LocalizationStore(userDefaults: defaults)
        loc.language = .english

        // Only a refused draft offers recovery buttons, in this order.
        XCTAssertEqual(WaitingClassicNoticeState.waitingOffline.actions, [])
        XCTAssertEqual(WaitingClassicNoticeState.syncing.actions, [])
        XCTAssertEqual(WaitingClassicNoticeState.hidden.actions, [])
        XCTAssertEqual(WaitingClassicNoticeState.failed.actions, [.retry, .copyText, .discard])

        // Each button runs its own handler (the view's buttons call `perform`).
        var copiedPayload: String?
        var retryTapped = false
        var discardTapped = false
        let notice = WaitingClassicEditsNotice(
            state: .failed,
            onRetry: { retryTapped = true },
            onCopyText: { copiedPayload = waitingClassicCopyText(title: "Draft Title", markdown: "Body text") },
            onDiscard: { discardTapped = true })
        notice.perform(.copyText)
        XCTAssertEqual(copiedPayload, "Draft Title\n\nBody text")
        XCTAssertFalse(retryTapped)
        XCTAssertFalse(discardTapped)
        notice.perform(.retry)
        XCTAssertTrue(retryTapped)
        notice.perform(.discard)
        XCTAssertTrue(discardTapped)

        XCTAssertEqual(loc[.native_editor_waiting_classic_offline], "Waiting to sync your offline edits")
        XCTAssertEqual(loc[.native_editor_waiting_classic_syncing], "Syncing…")
        XCTAssertEqual(loc[.native_editor_waiting_classic_failed], "Couldn't sync")
        XCTAssertEqual(loc[.native_editor_waiting_classic_copy_text], "Copy text")
        XCTAssertEqual(loc[.toast_text_copied], "Text copied")
        XCTAssertEqual(loc[.native_editor_waiting_classic_discard_title], "Discard offline edits?")
        XCTAssertEqual(
            loc[.native_editor_waiting_classic_discard_message],
            "Your unsynced changes on this device will be permanently deleted.")
    }

    func testShellViewHostsWaitingClassicRouteReadOnlyWithoutClassicEditor() async throws {
        let env = makeEnvironment()
        defer { env.clean() }
        let server = WaitingClassicServerStub(owner: owner, ydocState: serverYDocState("Server"))
        server.formattedStatus = 404
        server.install()
        let locSuite = "NativeEditorWaitingClassicTests.Shell.\(UUID().uuidString)"
        let locDefaults = UserDefaults(suiteName: locSuite)!
        defer { locDefaults.removePersistentDomain(forName: locSuite) }
        let loc = LocalizationStore(userDefaults: locDefaults)
        loc.language = .english

        let bodyMarkdown = "# Heading\n\n- [ ] Checklist item\n\nBody paragraph"
        env.drafts.save(
            PendingDraft(
                documentID: env.documentID,
                title: "Read-Only Title",
                markdown: bodyMarkdown,
                updatedAt: Date()))
        await env.coordinator.syncPendingDrafts()
        XCTAssertTrue(env.model.isWaitingClassicFailed)

        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
        guard case .waitingClassicEdits = open.route else {
            return XCTFail("expected .waitingClassicEdits")
        }

        var pasted: String?
        let emptyPickerSource = NativeInlinePickerSource(
            canInsertPageLink: { false },
            pageLinkCandidates: { [] },
            excludedDocumentID: env.documentID,
            onRecordDocumentTitle: { _, _ in },
            canMention: { false },
            mentionState: { .idle },
            requestMentions: { _ in })
        let shell = NativeDocumentShellView(
            route: open.route,
            nativeOpen: open,
            viewModel: env.model,
            reach: .restricted,
            serverHost: "docs.example.org",
            serverOrigin: "https://docs.example.org",
            childrenCache: env.model.childrenCache,
            linkRole: nil,
            initialIsFavorite: false,
            pinRow: nil,
            isOffline: false,
            onDeleted: nil,
            onOpenDocument: nil,
            onCreatedDocument: nil,
            makeInlinePickerSource: { emptyPickerSource },
            onReopenAfterUndo: {},
            copyTextToPasteboard: { pasted = $0 }
        )

        let host = UIHostingController(rootView: shell.environment(loc))
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        host.view.layoutIfNeeded()
        XCTAssertEqual(host.view.bounds.size, CGSize(width: 390, height: 844))
        XCTAssertFalse(env.model.isEditing, "waiting route must stay read-only")
        XCTAssertNil(pasted)

        // Trigger the shell's Copy text action path and verify the formatted payload reaches the pasteboard.
        XCTAssertTrue(shell.copyWaitingClassicPayload())
        XCTAssertEqual(pasted, "Read-Only Title\n\n\(bodyMarkdown)")
    }

    // MARK: - Helpers

    @MainActor
    private struct Env {
        let documentID: UUID
        let defaults: UserDefaults
        let suite: String
        let directory: URL
        let drafts: PendingDraftStore
        let creates: PendingDocumentCreateStore
        let deletes: PendingDocumentDeleteStore
        let replicaStore: ReplicaStore
        let coordinator: DocumentSaveCoordinator
        let model: EditorViewModel

        func relaunch() -> EditorViewModel {
            let coordinator = DocumentSaveCoordinator(
                client: model.client,
                draftStore: PendingDraftStore(userDefaults: defaults),
                replicaStore: replicaStore,
                contentCache: model.contentCache,
                createStore: PendingDocumentCreateStore(userDefaults: defaults),
                deleteStore: PendingDocumentDeleteStore(userDefaults: defaults),
                attachmentStore: PendingAttachmentStore(
                    userDefaults: defaults, directory: directory.appendingPathComponent("attachments")),
                listCache: model.listCache,
                childrenCache: model.childrenCache,
                serverOrigin: model.client.serverOrigin,
                backgroundTasks: .noop, sleep: neverSleep)
            coordinator.nativeEditorEnabled = { true }
            return EditorViewModel(
                client: model.client,
                documentID: documentID,
                title: model.title,
                saveCoordinator: coordinator,
                signedInUser: model.signedInUser,
                contentCache: model.contentCache,
                childrenCache: model.childrenCache,
                listCache: model.listCache,
                availability: model.availability,
                nativeEditorEnabled: { true })
        }

        func clean() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
            MockURLProtocol.reset()
        }
    }

    private func makeEnvironment() -> Env {
        MockURLProtocol.reset()
        let suite = "NativeEditorWaitingClassicTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaitingClassic-\(UUID().uuidString)", isDirectory: true)
        let client = DocsAPIClient(
            baseURL: URL(string: "https://docs.example.org/api/v1.0/")!,
            session: MockURLProtocol.makeSession(),
            cookieProvider: { [] })
        let signedIn = SignedInUserStore(userDefaults: defaults)
        signedIn.remember(owner)
        let ownership = ReplicaOwnershipStore(userDefaults: defaults)
        let replicaStore = ReplicaStore(
            directory: directory.appendingPathComponent("ReplicaDrafts"),
            ownershipStore: ownership)
        let drafts = PendingDraftStore(userDefaults: defaults)
        let creates = PendingDocumentCreateStore(userDefaults: defaults)
        let deletes = PendingDocumentDeleteStore(userDefaults: defaults)
        let attachments = PendingAttachmentStore(
            userDefaults: defaults, directory: directory.appendingPathComponent("attachments"))
        let contentCache = DocumentContentCacheStore(directory: directory)
        let childrenCache = DocumentChildrenCacheStore(userDefaults: defaults)
        let listCache = DocumentCacheStore(userDefaults: defaults)
        let availability = OnlineAvailability(userDefaults: defaults)
        let coordinator = DocumentSaveCoordinator(
            client: client,
            draftStore: drafts,
            replicaStore: replicaStore,
            contentCache: contentCache,
            createStore: creates,
            deleteStore: deletes,
            attachmentStore: attachments,
            listCache: listCache,
            childrenCache: childrenCache,
            serverOrigin: client.serverOrigin,
            backgroundTasks: .noop, sleep: neverSleep)
        coordinator.nativeEditorEnabled = { true }
        let documentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let model = EditorViewModel(
            client: client,
            documentID: documentID,
            title: "Initial Row Title",
            saveCoordinator: coordinator,
            signedInUser: signedIn,
            contentCache: contentCache,
            childrenCache: childrenCache,
            listCache: listCache,
            availability: availability,
            nativeEditorEnabled: { true })
        return Env(
            documentID: documentID, defaults: defaults, suite: suite, directory: directory,
            drafts: drafts, creates: creates, deletes: deletes, replicaStore: replicaStore,
            coordinator: coordinator, model: model)
    }

    private func serverYDocState(_ text: String) -> Data {
        BlockNoteYjs.encode(
            [BlockNoteBlock(node: "paragraph", props: Self.paragraphProps, runs: [InlineRun(text)], id: "srv-1")],
            clientID: Self.seedClientID)
    }
}

private final class WaitingClassicServerStub: @unchecked Sendable {
    let log = RequestRecorder()
    private let lock = NSLock()
    private let owner: UUID
    private var _ydocState: Data
    private var _serverTitle = "Server Title"
    private var _serverContent = "Server body"
    private var _serverUpdatedAt = "2026-11-07T10:00:00Z"
    private var _formattedStatus = 200
    private var _formattedContentType = "application/json"
    private var _ydocStatus = 200
    private var _attachmentUploadStatus = 404
    var formattedGate: MockURLProtocol.ResponseGate?
    var patchGate: MockURLProtocol.ResponseGate?
    var ydocGate: MockURLProtocol.ResponseGate?
    var createGate: MockURLProtocol.ResponseGate?
    var createdDocumentID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!

    init(owner: UUID, ydocState: Data) {
        self.owner = owner
        self._ydocState = ydocState
    }

    var serverTitle: String {
        get { locked { _serverTitle } }
        set { locked { _serverTitle = newValue } }
    }
    var serverContent: String {
        get { locked { _serverContent } }
        set { locked { _serverContent = newValue } }
    }
    var serverUpdatedAt: String {
        get { locked { _serverUpdatedAt } }
        set { locked { _serverUpdatedAt = newValue } }
    }
    var formattedStatus: Int {
        get { locked { _formattedStatus } }
        set { locked { _formattedStatus = newValue } }
    }
    var formattedContentType: String {
        get { locked { _formattedContentType } }
        set { locked { _formattedContentType = newValue } }
    }
    var ydocStatus: Int {
        get { locked { _ydocStatus } }
        set { locked { _ydocStatus = newValue } }
    }
    var attachmentUploadStatus: Int {
        get { locked { _attachmentUploadStatus } }
        set { locked { _attachmentUploadStatus = newValue } }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func install() {
        MockURLProtocol.stubHandler = { [weak self] request in
            guard let self else {
                return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
            }
            self.log.record(request)
            let url = request.url?.absoluteString ?? ""
            let method = request.httpMethod ?? "GET"
            let json = ["Content-Type": "application/json"]
            if url.hasSuffix("/config/") {
                return .init(
                    statusCode: 200, headers: json,
                    body: Data(#"{"RELEASE_VERSION":"6.0.0"}"#.utf8), error: nil)
            }
            if url.hasSuffix("/users/me/") {
                let id = self.owner.uuidString.lowercased()
                return .init(
                    statusCode: 200, headers: json,
                    body: Data(#"{"id":"\#(id)","email":"u@example.org","full_name":"User"}"#.utf8), error: nil)
            }
            if url.contains("/collaboration/ydoc/") {
                if method == "PATCH" {
                    return .init(
                        statusCode: 204, headers: [:], body: Data(), error: nil, releasedBy: self.patchGate)
                }
                let status = self.ydocStatus
                guard status == 200 else {
                    return .init(
                        statusCode: status, headers: json, body: Data("{}".utf8), error: nil,
                        releasedBy: self.ydocGate)
                }
                let body =
                    (try? JSONSerialization.data(
                        withJSONObject: ["doc": self.locked { self._ydocState }.base64EncodedString()])) ?? Data()
                return .init(statusCode: 200, headers: json, body: body, error: nil, releasedBy: self.ydocGate)
            }
            if url.contains("attachment-upload"), method == "POST" {
                let status = self.attachmentUploadStatus
                guard status == 201 else {
                    return .init(statusCode: status, headers: json, body: Data("{}".utf8), error: nil)
                }
                let docID =
                    request.url?.path.split(separator: "/").first { UUID(uuidString: String($0)) != nil }
                    .map(String.init) ?? "11111111-1111-4111-8111-111111111111"
                let body =
                    "{\"file\": \"/api/v1.0/documents/\(docID)/media-check/?key=\(docID)%2Fattachments%2Fphoto.jpg\"}"
                return .init(statusCode: 201, headers: json, body: Data(body.utf8), error: nil)
            }
            if url.contains("media-check"), method == "GET" {
                let docID =
                    request.url?.path.split(separator: "/").first { UUID(uuidString: String($0)) != nil }
                    .map(String.init) ?? "11111111-1111-4111-8111-111111111111"
                let body = "{\"status\": \"ready\", \"file\": \"/media/\(docID)/attachments/photo.jpg\"}"
                return .init(statusCode: 200, headers: json, body: Data(body.utf8), error: nil)
            }
            if url.hasSuffix("/documents/"), method == "POST" {
                let id = self.createdDocumentID.uuidString.lowercased()
                let payload: [String: Any] = [
                    "id": id,
                    "title": self.serverTitle,
                    "excerpt": NSNull(),
                    "abilities": ["update": true, "mention": false],
                    "computed_link_reach": "restricted",
                    "computed_link_role": NSNull(),
                    "created_at": self.serverUpdatedAt,
                    "creator": NSNull(),
                    "depth": 1,
                    "link_role": "reader",
                    "link_reach": "restricted",
                    "numchild": 0,
                    "path": "0001",
                    "updated_at": self.serverUpdatedAt,
                    "user_role": "owner",
                    "is_favorite": false,
                ]
                let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
                return .init(statusCode: 201, headers: json, body: data, error: nil, releasedBy: self.createGate)
            }
            if url.contains("formatted-content") || (url.contains("/content/") && method == "GET") {
                let status = self.formattedStatus
                if status != 200 {
                    let headers = ["Content-Type": self.formattedContentType]
                    let body =
                        self.formattedContentType == "text/html" ? Data("<html>404</html>".utf8) : Data("{}".utf8)
                    return .init(
                        statusCode: status, headers: headers, body: body, error: nil,
                        releasedBy: self.formattedGate)
                }
                let id =
                    request.url?.path.split(separator: "/").first { UUID(uuidString: String($0)) != nil }
                    .map(String.init) ?? "11111111-1111-4111-8111-111111111111"
                let payload: [String: Any] = [
                    "id": id,
                    "title": self.serverTitle,
                    "content": self.serverContent,
                    "created_at": "2026-11-07T10:00:00Z",
                    "updated_at": self.serverUpdatedAt,
                ]
                let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
                return .init(
                    statusCode: 200, headers: json, body: data, error: nil, releasedBy: self.formattedGate)
            }
            if url.contains("/children/") {
                return .init(
                    statusCode: 200, headers: json, body: Data(#"{"count":0,"results":[]}"#.utf8), error: nil)
            }
            if url.hasSuffix("/content/"), method == "PATCH" {
                return .init(
                    statusCode: 200, headers: json, body: Data("{}".utf8), error: nil, releasedBy: self.patchGate)
            }
            if url.contains("/documents/"), method == "PATCH" {
                return .init(statusCode: 200, headers: json, body: Data("{}".utf8), error: nil)
            }
            if url.contains("/documents/"), method == "GET" {
                let docID =
                    request.url?.path.split(separator: "/").first { UUID(uuidString: String($0)) != nil }
                    .map(String.init) ?? "11111111-1111-4111-8111-111111111111"
                let payload: [String: Any] = [
                    "id": docID,
                    "title": self.serverTitle,
                    "excerpt": NSNull(),
                    "abilities": ["update": true, "mention": false],
                    "computed_link_reach": "restricted",
                    "computed_link_role": NSNull(),
                    "created_at": self.serverUpdatedAt,
                    "creator": NSNull(),
                    "depth": 1,
                    "link_role": "reader",
                    "link_reach": "restricted",
                    "numchild": 0,
                    "path": "0001",
                    "updated_at": self.serverUpdatedAt,
                    "user_role": "owner",
                    "is_favorite": false,
                ]
                let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
                return .init(statusCode: 200, headers: json, body: data, error: nil)
            }
            return .init(statusCode: 404, headers: [:], body: Data(), error: nil)
        }
    }
}
