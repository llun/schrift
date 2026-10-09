import XCTest

@testable import Schrift

@MainActor
final class DocumentCollaborationManagerSyncProtocolTests: DocumentCollaborationManagerTestCase {
    /// The load-bearing authority move: an inbound `.update` that arrives BEFORE
    /// our own SyncStep1 reply (a peer's incremental edit interleaved ahead of the
    /// initial sync) builds the replica and bumps `replicaVersion`, but must NOT
    /// mark it synced — a replica assembled from a partial update is not the room's
    /// full state, so it stays un-projectable/un-writable/un-snapshottable until the
    /// first `.step2` fires `onInitialSync`.
    func testInboundUpdateBeforeInitialSyncBuildsReplicaButRefusesWrites() async throws {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        let blocks = [para("hi", id: blockID)]
        let update = BlockNoteYjs.encode(blocks, clientID: 1)
        spy.sockets[0].deliver(message: syncUpdateFrame(data: update))
        await waitUntil { manager.replicaVersion(for: docID) == 1 }

        // The replica exists and integrated cleanly (no fail-safe, no pending), but
        // the initial sync has not landed ⇒ every write-eligibility surface refuses.
        XCTAssertFalse(manager.replicaIsFailSafe(for: docID))
        XCTAssertFalse(manager.hasPendingStructs(for: docID), "the early update integrated cleanly")
        XCTAssertNil(manager.projectedReplica(for: docID, interlinkingOrigin: nil), "no projection before the step2")
        XCTAssertNil(manager.encodeSnapshotForSave(for: docID), "no snapshot before the step2")
        do {
            _ = try manager.applyLocalEdit(old: blocks, new: [para("hiX", id: blockID)], for: docID)
            XCTFail("expected notWritable before the initial sync")
        } catch CollaborationWriteError.notWritable {
            // expected
        }

        // The `.step2` reply to our SyncStep1 marks the initial sync applied ⇒ the
        // same replica is now writable/projectable/snapshottable.
        spy.sockets[0].deliver(message: syncStep2Frame(data: update))
        await waitUntil { manager.projectedReplica(for: docID, interlinkingOrigin: nil) != nil }
        XCTAssertNotNil(manager.encodeSnapshotForSave(for: docID))
        session?.stop()
    }

    /// The impact of the SyncReply(4) routing fix, end to end: a production
    /// Hocuspocus server answers our `Sync`(0)+SyncStep1 with a `SyncReply`(4)+
    /// SyncStep2, not a `Sync`(0)+SyncStep2. Delivering that real reply through the
    /// socket → session → manager path must fire `onInitialSync` and mark the
    /// replica synced, so `canWriteReplica` flips true — projection, the save
    /// snapshot, and `applyLocalEdit` all become available. Before the fix the
    /// type-4 frame was dropped, so the replica never became writable.
    func testSyncReplyStep2SeedsWritableReplicaLikeSyncStep2() async throws {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }
        XCTAssertNil(manager.projectedReplica(for: docID, interlinkingOrigin: nil))
        XCTAssertNil(manager.encodeSnapshotForSave(for: docID))

        let base = [para("hello", id: blockID)]
        spy.sockets[0].deliver(message: syncReplyStep2Frame(data: BlockNoteYjs.encode(base, clientID: 1)))
        await waitUntil { manager.replicaVersion(for: docID) == 1 }

        // canWriteReplica is now true across every write-eligibility surface.
        XCTAssertNotNil(
            manager.projectedReplica(for: docID, interlinkingOrigin: nil),
            "the SyncReply(4) initial sync makes the replica projectable")
        XCTAssertNotNil(
            manager.encodeSnapshotForSave(for: docID), "the SyncReply(4) initial sync makes the save snapshot available"
        )
        let update = try manager.applyLocalEdit(old: base, new: [para("heXllo", id: blockID)], for: docID)
        XCTAssertFalse(update.isEmpty, "applyLocalEdit succeeds once the SyncReply-seeded replica is writable")
        XCTAssertEqual(manager.localEditVersion(for: docID), 1)
        session?.stop()
    }

    func testEncodeSnapshotForSaveNilForUnknownDocumentAndBeforeInitialSync() async {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(spy: spy)
        // An unknown document has no entry at all.
        XCTAssertNil(manager.encodeSnapshotForSave(for: docID))

        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }
        // A socket is open, but no inbound frame has arrived ⇒ no replica ⇒ no snapshot.
        XCTAssertNil(manager.encodeSnapshotForSave(for: docID), "no replica yet ⇒ no snapshot")
        session?.stop()
    }

    func testEncodeSnapshotForSaveNilWhilePendingStructs() async throws {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        // Same `Y.mergeUpdates`-with-a-dropped-middle fixture: an unintegrated
        // dependency stays in `pendingStructs`, so the replica is not safe to
        // snapshot even though the initial sync (a `.step2`) landed.
        let mergedWithDroppedMiddleHex =
            "0112010007010e646f63756d656e742d73746f7265030a626c6f636b47726f757007000100030e626c6f636b436f6e7461696e6572070001010309706172616772617068070001020604000103056669727374280001020f6261636b67726f756e64436f6c6f7201770764656661756c74280001020974657874436f6c6f7201770764656661756c74280001020d74657874416c69676e6d656e740177046c6566742800010102696401772431313131313131312d313131312d343131312d383131312d3131313131313131313131310a1787010d030e626c6f636b436f6e7461696e6572070001240309706172616772617068070001250604000126057468697264280001250f6261636b67726f756e64436f6c6f7201770764656661756c74280001250974657874436f6c6f7201770764656661756c74280001250d74657874416c69676e6d656e740177046c6566742800012402696401772433333333333333332d333333332d343333332d383333332d33333333333333333333333300"
        spy.sockets[0].deliver(message: syncStep2Frame(data: Data(hex: mergedWithDroppedMiddleHex)))

        await waitUntil { manager.replicaVersion(for: docID) == 1 }
        XCTAssertTrue(manager.hasPendingStructs(for: docID))
        XCTAssertNil(manager.encodeSnapshotForSave(for: docID), "pending structs must suppress the snapshot")
        session?.stop()
    }

    func testEncodeSnapshotForSaveNilAfterFailSafe() async {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        spy.sockets[0].deliver(message: syncStep2Frame(data: Data([0x00, 0x01, 0x02, 0x99])))
        await waitUntil { manager.replicaIsFailSafe(for: docID) }
        XCTAssertNil(manager.encodeSnapshotForSave(for: docID), "a fail-safed replica must not be snapshotted")
        session?.stop()
    }

    func testEncodeSnapshotForSaveReturnsFullSnapshotThatReproducesTheDocument() async throws {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        let blocks = [para("hello", id: blockID)]
        spy.sockets[0].deliver(message: syncStep2Frame(data: BlockNoteYjs.encode(blocks, clientID: 1)))
        await waitUntil { manager.projectedReplica(for: docID, interlinkingOrigin: nil) != nil }

        let snapshot = try XCTUnwrap(manager.encodeSnapshotForSave(for: docID))
        XCTAssertFalse(snapshot.isEmpty, "a synced replica must produce a non-empty full snapshot")

        // The full snapshot applied to a fresh replica reproduces the document.
        let fresh = YDoc(clientID: 99)
        try fresh.applyUpdate(try YUpdateDecoder.decode(snapshot))
        let projected = YBlockProjection.project(fresh).blocks
        XCTAssertEqual(projected.map(\.id), blocks.map(\.id))
        XCTAssertEqual(projected.map(\.node), blocks.map(\.node))
        XCTAssertEqual(projected.map(\.runs), blocks.map(\.runs))
        fresh.destroy()
        session?.stop()
    }

    /// A peer's SyncStep1 (their state vector) is answered with a `.step2` diff of
    /// exactly what they lack, and applying that reply converges the peer onto our
    /// state — this is how our local edits are re-offered on (re)connect.
    func testStateReplyReturnsOnlyWhatPeerLacksAndConverges() async throws {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        // Seed A (the manager's replica) and B (a plain oracle YDoc) from the SAME
        // base, so they share those structs exactly.
        let secondBlockID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let base = [para("shared", id: blockID)]
        let seed = await seedWritableReplica(manager, socket: spy.sockets[0], blocks: base)
        let peer = YDoc(clientID: 9)
        try peer.applyUpdate(try YUpdateDecoder.decode(seed))

        // A diverges by a local edit B does not have yet (a pure block insert,
        // authored by A's replica client id).
        let edited = [para("shared", id: blockID), para("added", id: secondBlockID)]
        _ = try manager.applyLocalEdit(old: base, new: edited, for: docID)

        // B asks A for its state (a SyncStep1 carrying B's state vector); A replies
        // with a `.step2` diff of only what B lacks (A's insert).
        let framesBefore = spy.sockets[0].sentFrames.count
        spy.sockets[0].deliver(message: step1Frame(stateVector: YStateEncoder.encodeStateVector(peer)))
        await waitUntil { spy.sockets[0].sentFrames.count > framesBefore }
        let reply = try XCTUnwrap(
            spy.sockets[0].sentFrames.compactMap { frame -> Data? in
                guard let message = try? HocuspocusMessage(decoding: frame), message.knownType == .sync,
                    let sync = try? SyncMessage(decodingPayload: message.payload), sync.step == .step2
                else { return nil }
                return sync.data
            }.last, "A must answer B's step1 with a step2 diff")

        // The reply is a genuine diff, not a whole snapshot: it is smaller than A's
        // full snapshot of the same document.
        let fullSnapshot = try XCTUnwrap(manager.encodeSnapshotForSave(for: docID))
        XCTAssertLessThan(reply.count, fullSnapshot.count, "a step2 diff carries less than the full state")

        // Applying the reply to B converges B onto A's document.
        try peer.applyUpdate(try YUpdateDecoder.decode(reply))
        let converged = YBlockProjection.project(peer).blocks
        XCTAssertEqual(converged.map(\.id), edited.map(\.id))
        XCTAssertEqual(converged.map(\.node), edited.map(\.node))
        XCTAssertEqual(converged.map(\.runs), edited.map(\.runs))
        peer.destroy()
        session?.stop()
    }

    /// The first session handshakes with the empty state vector (no replica yet),
    /// but after an initial sync a reconnect rebuilds the session whose SyncStep1
    /// now carries the replica's real state vector — so the relay replies with only
    /// what we lack and we re-offer our own accumulated state.
    func testReconnectHandshakeReOffersReplicaStateVector() async throws {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(spy: spy)
        _ = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 && spy.sockets[0].sentFrames.count == 1 }

        // First handshake: the signal-only empty state vector (no replica yet).
        let firstHandshake = try SyncMessage(
            decodingPayload: HocuspocusMessage(decoding: spy.sockets[0].sentFrames[0]).payload)
        XCTAssertEqual(firstHandshake.step, .step1)
        XCTAssertEqual(firstHandshake.data, Data([0x00]), "no replica yet ⇒ empty state vector")

        // Land an initial sync.
        let blocks = [para("hello", id: blockID)]
        spy.sockets[0].deliver(message: syncStep2Frame(data: BlockNoteYjs.encode(blocks, clientID: 1)))
        await waitUntil { manager.projectedReplica(for: docID, interlinkingOrigin: nil) != nil }

        // Reconnect rebuilds the session; its handshake re-offers the replica's
        // state vector, which equals a fresh mirror of the replica's snapshot.
        manager.reconnect()
        await waitUntil { spy.sockets.count == 2 && spy.sockets[1].sentFrames.count >= 1 }
        let reconnectHandshake = try SyncMessage(
            decodingPayload: HocuspocusMessage(decoding: spy.sockets[1].sentFrames[0]).payload)
        XCTAssertEqual(reconnectHandshake.step, .step1)
        XCTAssertNotEqual(
            reconnectHandshake.data, Data([0x00]), "the rebuilt session offers the replica's state vector")

        let snapshot = try XCTUnwrap(manager.encodeSnapshotForSave(for: docID))
        let mirror = YDoc(clientID: 5)
        try mirror.applyUpdate(try YUpdateDecoder.decode(snapshot))
        XCTAssertEqual(
            reconnectHandshake.data, YStateEncoder.encodeStateVector(mirror),
            "the handshake state vector is exactly the replica's")
        mirror.destroy()
    }
}
