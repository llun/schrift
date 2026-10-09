import XCTest

@testable import Schrift

@MainActor
final class DocumentCollaborationManagerReplicaTests: DocumentCollaborationManagerTestCase {
    func testRemoteChangeTokenIncrementsOnEachSyncSignal() async {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }
        XCTAssertEqual(manager.remoteChangeToken(for: docID), 0)

        spy.sockets[0].deliver(message: syncFrame())
        await waitUntil { manager.remoteChangeToken(for: docID) == 1 }
        spy.sockets[0].deliver(message: syncFrame())
        await waitUntil { manager.remoteChangeToken(for: docID) == 2 }
        session?.stop()
    }

    func testRemoteChangeTokenResetsWhenTheDocumentIsTornDown() async {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(linger: 0.05, spy: spy)
        _ = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }
        spy.sockets[0].deliver(message: syncFrame())
        await waitUntil { manager.remoteChangeToken(for: docID) == 1 }

        manager.release(docID)
        await waitUntil { manager.activeDocumentCount == 0 }
        XCTAssertEqual(manager.remoteChangeToken(for: docID), 0)
    }

    func testAppliesInitialSyncBumpsReplicaVersionAndProjects() async throws {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }
        XCTAssertEqual(manager.replicaVersion(for: docID), 0)
        XCTAssertNil(manager.projectedReplica(for: docID, interlinkingOrigin: nil))

        // The initial full state arrives as the `.step2` reply to our SyncStep1 —
        // which fires `onInitialSync` and marks the replica synced (writable/
        // projectable). A bare `.update` would build the replica but leave it
        // un-synced (see `testInboundUpdateBeforeInitialSyncBuildsReplicaButRefusesWrites`).
        let update = MarkdownYjs.encode(markdown: "# Title\n\nBody", serverOrigin: "", clientID: 1)
        spy.sockets[0].deliver(message: syncStep2Frame(data: update))

        await waitUntil { manager.replicaVersion(for: docID) == 1 }
        let projected = try XCTUnwrap(manager.projectedReplica(for: docID, interlinkingOrigin: nil))
        XCTAssertEqual(projected.blocks.map(\.node), ["heading", "paragraph"])
        XCTAssertEqual(projected.blocks[1].runs, [InlineRun("Body")])
        XCTAssertTrue(projected.isFullyRenderable)
        XCTAssertFalse(manager.replicaIsFailSafe(for: docID))
        session?.stop()
    }

    /// C2c: a registered replica observer fires **synchronously, in the same main-actor
    /// turn** an inbound update integrates and bumps `replicaVersion` — this is what lets
    /// the editor bridge re-sync its write baseline before any keystroke can race in. The
    /// observer records the version it *sees* when fired; requiring it to already equal the
    /// post-integrate value (never a stale `0`) pins the "same turn as the bump" contract,
    /// since a deferred fire could only ever observe a value set in an earlier turn.
    func testInboundIntegrateFiresTheReplicaObserverSynchronouslyAfterTheVersionBump() async throws {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        var fireCount = 0
        var versionsSeenAtFire: [Int] = []
        // `[weak manager]` avoids a retain cycle (the manager stores this closure).
        manager.setReplicaObserver(
            { [weak manager] in
                fireCount += 1
                versionsSeenAtFire.append(manager?.replicaVersion(for: self.docID) ?? -1)
            }, for: docID)

        let update = MarkdownYjs.encode(markdown: "# Title\n\nBody", serverOrigin: "", clientID: 1)
        spy.sockets[0].deliver(message: syncStep2Frame(data: update))
        await waitUntil { manager.replicaVersion(for: docID) == 1 }

        XCTAssertEqual(fireCount, 1, "the observer fires exactly once per integrated update")
        XCTAssertEqual(
            versionsSeenAtFire, [1],
            "it fires AFTER the version bump, in the same turn — never a deferred stale read")
        session?.stop()
    }

    /// The observer is strictly the *integrated-cleanly* edge: a malformed update
    /// fail-safes the replica and does **not** bump `replicaVersion`, so there is no
    /// trustworthy state to hand the editor and the observer must stay silent (the
    /// change-signal fallback via `remoteChangeToken` still fires — tested separately).
    func testMalformedInboundUpdateDoesNotFireTheReplicaObserver() async {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        var fireCount = 0
        manager.setReplicaObserver({ fireCount += 1 }, for: docID)

        let garbage = Data([0x00, 0x01, 0x02, 0x99])
        spy.sockets[0].deliver(message: syncUpdateFrame(data: garbage))
        await waitUntil { manager.replicaIsFailSafe(for: docID) }
        XCTAssertEqual(fireCount, 0, "a fail-safed (non-integrated) update never fires the read-apply observer")
        session?.stop()
    }

    /// The observer's lifecycle is tied to the per-document ENTRY, not the bridge: it is
    /// dropped when the document is torn down after linger and must be RE-REGISTERED when the
    /// document is reopened. The `LiveEditingBridge` (held in `EditorView.@State`) outlives a
    /// teardown, and its init does NOT register — the view re-registers on every session
    /// (re)acquisition. This pins that contract: teardown clears the observer, a bare reopen
    /// therefore fires nothing (the stale-baseline race the synchronous observer exists to
    /// close), and re-registration on reopen restores the synchronous read-apply.
    func testReplicaObserverIsClearedOnTeardownAndRestoredByReRegistrationOnReopen() async {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(linger: 0.05, spy: spy)
        _ = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        var fireCount = 0
        manager.setReplicaObserver({ fireCount += 1 }, for: docID)
        let update = MarkdownYjs.encode(markdown: "# Title\n\nBody", serverOrigin: "", clientID: 1)
        spy.sockets[0].deliver(message: syncStep2Frame(data: update))
        await waitUntil { manager.replicaVersion(for: docID) == 1 }
        XCTAssertEqual(fireCount, 1, "the observer fires while registered and the entry is live")

        // Tear the document down after linger — the entry (and its observer) is dropped.
        manager.release(docID)
        await waitUntil { manager.activeDocumentCount == 0 }

        // Reopen: a fresh entry+session is acquired for the SAME document, but WITHOUT the view
        // re-registering the observer. An inbound update integrates and bumps the version, yet
        // fires nothing — this is exactly the gap that reopened the race before the fix.
        _ = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 2 }
        spy.sockets[1].deliver(message: syncStep2Frame(data: update))
        await waitUntil { manager.replicaVersion(for: docID) == 1 }
        XCTAssertEqual(fireCount, 1, "teardown cleared the observer; a bare reopen fires nothing")

        // The view re-registers on acquisition (`LiveEditingBridge.registerReplicaObserver`) —
        // model that, and the synchronous read-apply is restored for the reopened document.
        manager.setReplicaObserver({ fireCount += 1 }, for: docID)
        spy.sockets[1].deliver(message: syncStep2Frame(data: update))
        await waitUntil { manager.replicaVersion(for: docID) == 2 }
        XCTAssertEqual(fireCount, 2, "re-registering on reopen restores the synchronous observer")

        manager.release(docID)
    }

    func testMalformedUpdateSetsFailSafeStopsProjectingButStillSignals() async {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        // Truncated mid-varint: 0x00 clients of structs, then a delete-set client
        // count (1) and client id (2) whose range count (0x99) demands a
        // continuation byte the buffer never supplies — decode throws.
        let garbage = Data([0x00, 0x01, 0x02, 0x99])
        spy.sockets[0].deliver(message: syncUpdateFrame(data: garbage))

        await waitUntil { manager.remoteChangeToken(for: docID) == 1 }
        await waitUntil { manager.replicaIsFailSafe(for: docID) }
        XCTAssertNil(manager.projectedReplica(for: docID, interlinkingOrigin: nil))

        // A second, real update after failSafe must NOT resurrect projection.
        let update = MarkdownYjs.encode(markdown: "# Title\n\nBody", serverOrigin: "", clientID: 1)
        spy.sockets[0].deliver(message: syncUpdateFrame(data: update))
        await waitUntil { manager.remoteChangeToken(for: docID) == 2 }
        XCTAssertTrue(manager.replicaIsFailSafe(for: docID))
        XCTAssertNil(manager.projectedReplica(for: docID, interlinkingOrigin: nil))
        session?.stop()
    }

    func testDeeplyNestedAnyUpdateFailsSafeInsteadOfCrashingTheProcess() async {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        // A hostile peer's frame: one ContentAny value that is 20k nested
        // single-element arrays. `readAny` recurses per level, so without its
        // depth cap this overflows the stack — and a stack overflow is a machine
        // fault, not an error, so `applyReplicaUpdate`'s fail-safe `catch` could
        // not contain it and the whole app would die on a peer's say-so. Reaching
        // the assertions below at all is the regression test; fail-safe latching
        // proves the throw lands where every other malformed frame lands. A
        // regression reads as "Restarting after unexpected exit" (a process
        // crash), NOT a normal failure — don't misfile it as the worktree flake.
        spy.sockets[0].deliver(message: syncUpdateFrame(data: NestedAnyFixtures.contentAnyUpdate(depth: 20_000)))

        await waitUntil { manager.remoteChangeToken(for: docID) == 1 }
        await waitUntil { manager.replicaIsFailSafe(for: docID) }
        XCTAssertNil(manager.projectedReplica(for: docID, interlinkingOrigin: nil))
        session?.stop()
    }

    func testDeepNestingUpdateEngagesFailSafeInsteadOfCrashing() async {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        // A hostile peer's frame: a nested-type chain far deeper than
        // maxTypeNestingDepth, with a delete set that removes the root. The
        // delete cascade recurses one native frame per level; unbounded it
        // stack-overflows — a machine fault this fail-safe catch could not
        // contain, crashing the app on a peer's say-so. Reaching the assertions
        // is the regression test; the depth cap makes it a thrown error the
        // manager fail-safes on, exactly like any other malformed frame. (A
        // regression here reads as "Restarting after unexpected exit", a process
        // crash — not a normal failure.)
        let frame = DeepNestingFixtures.nestedTypeChain(depth: 6000, deleteRoot: true)
        spy.sockets[0].deliver(message: syncUpdateFrame(data: frame))

        await waitUntil { manager.remoteChangeToken(for: docID) == 1 }
        await waitUntil { manager.replicaIsFailSafe(for: docID) }
        XCTAssertNil(manager.projectedReplica(for: docID, interlinkingOrigin: nil))
        XCTAssertNil(manager.encodeSnapshotForSave(for: docID))

        // A later real update must not resurrect projection, and nothing crashed.
        let update = MarkdownYjs.encode(markdown: "# Title\n\nBody", serverOrigin: "", clientID: 1)
        spy.sockets[0].deliver(message: syncUpdateFrame(data: update))
        await waitUntil { manager.remoteChangeToken(for: docID) == 2 }
        XCTAssertTrue(manager.replicaIsFailSafe(for: docID))
        session?.stop()
    }

    func testPendingStructsSuppressProjection() async throws {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        // `Y.mergeUpdates` output where a dropped middle update leaves a `Skip`
        // (the only realistic source of Skips, per docs/architecture.md): the
        // third block's container item has its `origin` inside the gap and can
        // never integrate, so it stays in `pendingStructs` forever. Copied from
        // `YBlockProjectionOracleTests.mergedWithDroppedMiddleHex` (Fixture 4;
        // see that file's header comment for the regeneration script).
        let mergedWithDroppedMiddleHex =
            "0112010007010e646f63756d656e742d73746f7265030a626c6f636b47726f757007000100030e626c6f636b436f6e7461696e6572070001010309706172616772617068070001020604000103056669727374280001020f6261636b67726f756e64436f6c6f7201770764656661756c74280001020974657874436f6c6f7201770764656661756c74280001020d74657874416c69676e6d656e740177046c6566742800010102696401772431313131313131312d313131312d343131312d383131312d3131313131313131313131310a1787010d030e626c6f636b436f6e7461696e6572070001240309706172616772617068070001250604000126057468697264280001250f6261636b67726f756e64436f6c6f7201770764656661756c74280001250974657874436f6c6f7201770764656661756c74280001250d74657874416c69676e6d656e740177046c6566742800012402696401772433333333333333332d333333332d343333332d383333332d33333333333333333333333300"
        // As a `.step2`, `onInitialSync` fires ⇒ `initialSyncApplied` is set, so the
        // *only* thing suppressing projection here is the unintegrated pending struct.
        spy.sockets[0].deliver(message: syncStep2Frame(data: Data(hex: mergedWithDroppedMiddleHex)))

        await waitUntil { manager.replicaVersion(for: docID) == 1 }
        XCTAssertFalse(manager.replicaIsFailSafe(for: docID))
        XCTAssertNil(
            manager.projectedReplica(for: docID, interlinkingOrigin: nil), "pendingStructs must suppress projection")
        session?.stop()
    }

    func testHasPendingStructsTrueForUnknownDocument() {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(spy: spy)
        // No entry at all for this document — nothing writable.
        XCTAssertTrue(manager.hasPendingStructs(for: docID))
    }

    func testHasPendingStructsFalseAfterCleanInitialSync() async throws {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }
        XCTAssertTrue(manager.hasPendingStructs(for: docID), "no replica yet")

        let update = MarkdownYjs.encode(markdown: "# Title\n\nBody", serverOrigin: "", clientID: 1)
        spy.sockets[0].deliver(message: syncStep2Frame(data: update))

        await waitUntil { manager.replicaVersion(for: docID) == 1 }
        XCTAssertFalse(manager.hasPendingStructs(for: docID))
        session?.stop()
    }

    func testHasPendingStructsTrueWhilePendingStructsExist() async throws {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        // Same `Y.mergeUpdates`-with-a-dropped-middle-update fixture as
        // `testPendingStructsSuppressProjection`: the third block's container
        // item can never integrate and stays in `pendingStructs` forever.
        let mergedWithDroppedMiddleHex =
            "0112010007010e646f63756d656e742d73746f7265030a626c6f636b47726f757007000100030e626c6f636b436f6e7461696e6572070001010309706172616772617068070001020604000103056669727374280001020f6261636b67726f756e64436f6c6f7201770764656661756c74280001020974657874436f6c6f7201770764656661756c74280001020d74657874416c69676e6d656e740177046c6566742800010102696401772431313131313131312d313131312d343131312d383131312d3131313131313131313131310a1787010d030e626c6f636b436f6e7461696e6572070001240309706172616772617068070001250604000126057468697264280001250f6261636b67726f756e64436f6c6f7201770764656661756c74280001250974657874436f6c6f7201770764656661756c74280001250d74657874416c69676e6d656e740177046c6566742800012402696401772433333333333333332d333333332d343333332d383333332d33333333333333333333333300"
        spy.sockets[0].deliver(message: syncStep2Frame(data: Data(hex: mergedWithDroppedMiddleHex)))

        await waitUntil { manager.replicaVersion(for: docID) == 1 }
        XCTAssertFalse(manager.replicaIsFailSafe(for: docID))
        XCTAssertTrue(manager.hasPendingStructs(for: docID), "an unintegrated dependency must read as pending")
        session?.stop()
    }

    func testHasPendingStructsTrueAfterFailSafeLatches() async {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        let garbage = Data([0x00, 0x01, 0x02, 0x99])
        spy.sockets[0].deliver(message: syncUpdateFrame(data: garbage))
        await waitUntil { manager.replicaIsFailSafe(for: docID) }

        // A failed decode/apply destroys the replica — nothing writable.
        XCTAssertTrue(manager.hasPendingStructs(for: docID))
        session?.stop()
    }

    func testHasPendingStructsTrueAfterTeardown() async {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(linger: 0.05, spy: spy)
        _ = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        let update = MarkdownYjs.encode(markdown: "# Title\n\nBody", serverOrigin: "", clientID: 1)
        spy.sockets[0].deliver(message: syncStep2Frame(data: update))
        await waitUntil { manager.replicaVersion(for: docID) == 1 }
        XCTAssertFalse(manager.hasPendingStructs(for: docID))

        manager.release(docID)
        await waitUntil { manager.activeDocumentCount == 0 }
        XCTAssertTrue(manager.hasPendingStructs(for: docID))
    }

    func testTeardownDestroysReplicaAndResetsVersion() async {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(linger: 0.05, spy: spy)
        _ = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        let update = MarkdownYjs.encode(markdown: "# Title\n\nBody", serverOrigin: "", clientID: 1)
        spy.sockets[0].deliver(message: syncStep2Frame(data: update))
        await waitUntil { manager.replicaVersion(for: docID) == 1 }

        manager.release(docID)
        await waitUntil { manager.activeDocumentCount == 0 }
        XCTAssertEqual(manager.replicaVersion(for: docID), 0)
        XCTAssertFalse(manager.replicaIsFailSafe(for: docID))
        XCTAssertNil(manager.projectedReplica(for: docID, interlinkingOrigin: nil))
    }
}
