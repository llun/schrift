import XCTest

@testable import Schrift

@MainActor
final class DocumentCollaborationManagerLocalEditTests: DocumentCollaborationManagerTestCase {
    func testApplyLocalEditReturnsUpdateBroadcastsAndConverges() async throws {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        let base = [para("hello", id: blockID)]
        let seed = await seedWritableReplica(manager, socket: spy.sockets[0], blocks: base)
        XCTAssertNotNil(manager.projectedReplica(for: docID, interlinkingOrigin: nil))
        let framesBefore = spy.sockets[0].sentFrames.count

        let edited = [para("heXllo", id: blockID)]
        let update = try manager.applyLocalEdit(old: base, new: edited, for: docID)
        XCTAssertFalse(update.isEmpty, "a local edit must produce non-empty update bytes")

        // Convergence: a second fresh replica seeded from the same base + our update
        // must project to `edited` at the document level.
        let second = YDoc(clientID: 7)
        try second.applyUpdate(try YUpdateDecoder.decode(seed))
        try second.applyUpdate(try YUpdateDecoder.decode(update))
        let projected = YBlockProjection.project(second).blocks
        XCTAssertEqual(projected.map(\.id), edited.map(\.id))
        XCTAssertEqual(projected.map(\.node), edited.map(\.node))
        XCTAssertEqual(projected.map(\.runs), edited.map(\.runs))
        second.destroy()

        // The session broadcast exactly those bytes as a `.sync`/`.update` frame.
        await waitUntil { spy.sockets[0].sentFrames.count == framesBefore + 1 }
        let frame = try HocuspocusMessage(decoding: spy.sockets[0].sentFrames.last!)
        XCTAssertEqual(frame.knownType, .sync)
        let sync = try SyncMessage(decodingPayload: frame.payload)
        XCTAssertEqual(sync.step, .update)
        XCTAssertEqual(sync.data, update, "the broadcast frame must carry exactly the returned update bytes")
        session?.stop()
    }

    func testApplyLocalEditSuppressesLocalEcho() async throws {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        let base = [para("hello", id: blockID)]
        _ = await seedWritableReplica(manager, socket: spy.sockets[0], blocks: base)

        // The inbound remote-change signals the editor observes must NOT move for a
        // local edit — otherwise the editor would try to read-apply its own keystroke.
        let replicaVersion = manager.replicaVersion(for: docID)
        let remoteChange = manager.remoteChangeToken(for: docID)
        XCTAssertEqual(manager.localEditVersion(for: docID), 0)

        _ = try manager.applyLocalEdit(old: base, new: [para("heXllo", id: blockID)], for: docID)

        XCTAssertEqual(manager.replicaVersion(for: docID), replicaVersion, "a local edit must not bump replicaVersion")
        XCTAssertEqual(
            manager.remoteChangeToken(for: docID), remoteChange, "a local edit must not bump remoteChangeToken")
        XCTAssertEqual(manager.localEditVersion(for: docID), 1, "a local edit bumps only localEditVersion")
        session?.stop()
    }

    func testApplyLocalEditThrowsWhenNoReplica() throws {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(spy: spy)
        // No session, no entry, no replica at all — nothing writable.
        do {
            _ = try manager.applyLocalEdit(old: [], new: [para("x", id: blockID)], for: docID)
            XCTFail("expected notWritable when there is no replica")
        } catch CollaborationWriteError.notWritable {
            // expected
        }
        XCTAssertEqual(manager.localEditVersion(for: docID), 0)
        XCTAssertTrue(spy.sockets.isEmpty)
    }

    func testApplyLocalEditThrowsBeforeInitialSync() async throws {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }
        // Wait for the handshake (the only expected send) to land so the later
        // "no broadcast" check isn't racing it — the handshake goes out
        // asynchronously after the socket is created.
        await waitUntil { spy.sockets[0].sentFrames.count == 1 }
        // A socket is open, but no inbound update has arrived ⇒ no replica ⇒ not writable.
        do {
            _ = try manager.applyLocalEdit(old: [], new: [para("x", id: blockID)], for: docID)
            XCTFail("expected notWritable before the initial sync")
        } catch CollaborationWriteError.notWritable {
            // expected
        }
        XCTAssertEqual(manager.localEditVersion(for: docID), 0)
        await waitAndConfirmNever { spy.sockets[0].sentFrames.count > 1 }
        session?.stop()
    }

    func testApplyLocalEditThrowsAfterFailSafe() async throws {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        // A malformed inbound update latches fail-safe and destroys the replica.
        spy.sockets[0].deliver(message: syncUpdateFrame(data: Data([0x00, 0x01, 0x02, 0x99])))
        await waitUntil { manager.replicaIsFailSafe(for: docID) }

        do {
            _ = try manager.applyLocalEdit(old: [], new: [para("x", id: blockID)], for: docID)
            XCTFail("expected notWritable after fail-safe")
        } catch CollaborationWriteError.notWritable {
            // expected
        }
        XCTAssertEqual(manager.localEditVersion(for: docID), 0)
        session?.stop()
    }

    func testApplyLocalEditWithMismatchedOldLatchesFailSafeAndDoesNotCrash() async throws {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }

        let base = [para("hi", id: blockID)]  // the real replica text is 2 UTF-16 units
        _ = await seedWritableReplica(manager, socket: spy.sockets[0], blocks: base)
        XCTAssertFalse(manager.replicaIsFailSafe(for: docID))
        let framesBefore = spy.sockets[0].sentFrames.count

        // `old` lies: it over-claims a 20-unit text with no common prefix/suffix vs
        // `new`, so the in-place text replace deletes past the real 2-unit text and
        // `BlockNoteWrite.applyEdit` throws `YIntegrationError` (never traps).
        let lyingOld = [para("zzzzzzzzzzzzzzzzzzzz", id: blockID)]
        let new = [para("q", id: blockID)]
        do {
            _ = try manager.applyLocalEdit(old: lyingOld, new: new, for: docID)
            XCTFail("expected the mismatched old to make BlockNoteWrite.applyEdit throw")
        } catch is CollaborationWriteError {
            XCTFail("expected the underlying integration error to propagate, not notWritable")
        } catch {
            // expected: the underlying YIntegrationError propagated.
        }

        // Fail-safe latched: the replica is torn down and refuses all further writes.
        XCTAssertTrue(manager.replicaIsFailSafe(for: docID))
        XCTAssertNil(manager.projectedReplica(for: docID, interlinkingOrigin: nil))
        XCTAssertTrue(manager.hasPendingStructs(for: docID))
        XCTAssertEqual(manager.localEditVersion(for: docID), 0, "a failed edit must not bump the local-edit counter")
        await waitAndConfirmNever { spy.sockets[0].sentFrames.count > framesBefore }

        // A subsequent edit now refuses with notWritable (the replica is gone).
        do {
            _ = try manager.applyLocalEdit(old: [], new: new, for: docID)
            XCTFail("expected notWritable after the fail-safe latch")
        } catch CollaborationWriteError.notWritable {
            // expected
        }
        session?.stop()
    }
}
