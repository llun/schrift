import XCTest

@testable import Schrift

/// yjs emits `'update'` for the formatting-cleanup transaction too (origin
/// `null`), and a provider broadcasts every update whose origin is not itself.
/// The manager must do the same — but only for a writer: a reader never publishes.
@MainActor
final class DocumentCollaborationManagerCleanupBroadcastTests: DocumentCollaborationManagerTestCase {
    /// A nested `Text("abc")` under map key "k" — the shape whose formatting
    /// cleanup fires (a bare root type is never a concrete text in yjs).
    private let nestedText = "010201002701016d016b02040001000361626300"
    /// Two peers concurrently bold [0,3); the second one's arrival makes the
    /// replica delete the redundant `ContentFormat` (client 2's `2:0`).
    private let boldClient2 = "0102020046010104626f6c64047472756586010304626f6c64046e756c6c00"
    private let boldClient3 = "0102030046010104626f6c64047472756586010304626f6c64046e756c6c00"
    /// yjs's cleanup update for that sequence: a delete-only update for `2:0`.
    private let cleanupUpdate = "000102010001"

    func testInboundUpdateThatTriggersFormattingCleanupBroadcastsTheCleanupUpdate() async throws {
        let spy = ManagerSocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: docID)
        await waitUntil { spy.sockets.count == 1 }
        let socket = spy.sockets[0]
        await waitUntil { socket.sentFrames.count == 1 }  // our SyncStep1 handshake

        socket.deliver(message: syncStep2Frame(data: Data(hex: nestedText)))
        await waitUntil { manager.replicaVersion(for: docID) == 1 }
        socket.deliver(message: syncUpdateFrame(data: Data(hex: boldClient2)))
        await waitUntil { manager.replicaVersion(for: docID) == 2 }
        socket.deliver(message: syncUpdateFrame(data: Data(hex: boldClient3)))

        // The cleanup transaction (origin nil) is broadcast as its own `.sync`/`.update`.
        await waitUntil { socket.sentFrames.count == 2 }
        let frame = try HocuspocusMessage(decoding: XCTUnwrap(socket.sentFrames.dropFirst().first))
        XCTAssertEqual(frame.knownType, .sync)
        let sync = try SyncMessage(decodingPayload: frame.payload)
        XCTAssertEqual(sync.step, .update)
        XCTAssertEqual(sync.data, Data(hex: cleanupUpdate))
        // The cleanup is derived from the inbound update: no counter moves for it.
        let token = manager.remoteChangeToken(for: docID)
        await waitAndConfirmNever {
            manager.replicaVersion(for: self.docID) != 3 || manager.localEditVersion(for: self.docID) != 0
                || manager.remoteChangeToken(for: self.docID) != token
        }
        session?.stop()
    }

    func testReaderNeverBroadcastsTheCleanupUpdate() async throws {
        let writerSpy = ManagerSocketFactorySpy()
        let writer = makeManager(spy: writerSpy)
        let writerSession = writer.session(for: docID)
        await waitUntil { writerSpy.sockets.count == 1 }
        let writerSocket = writerSpy.sockets[0]
        await waitUntil { writerSocket.sentFrames.count == 1 }

        let readerSpy = ManagerSocketFactorySpy()
        let reader = makeManager(spy: readerSpy)
        let readerSession = reader.session(for: docID, canUpdate: false)
        await waitUntil { readerSpy.sockets.count == 1 }
        let readerSocket = readerSpy.sockets[0]
        await waitUntil { readerSocket.sentFrames.count == 1 }

        for (socket, manager) in [(writerSocket, writer), (readerSocket, reader)] {
            socket.deliver(message: syncStep2Frame(data: Data(hex: nestedText)))
            await waitUntil { manager.replicaVersion(for: docID) == 1 }
            socket.deliver(message: syncUpdateFrame(data: Data(hex: boldClient2)))
            await waitUntil { manager.replicaVersion(for: docID) == 2 }
            socket.deliver(message: syncUpdateFrame(data: Data(hex: boldClient3)))
            await waitUntil { manager.replicaVersion(for: docID) == 3 }
        }

        // The writer publishes the cleanup; the reader's replica runs the same
        // cleanup but must never publish (A4).
        await waitUntil { writerSocket.sentFrames.count == 2 }
        let frame = try HocuspocusMessage(decoding: XCTUnwrap(writerSocket.sentFrames.dropFirst().first))
        XCTAssertEqual(try SyncMessage(decodingPayload: frame.payload).data, Data(hex: cleanupUpdate))
        await waitAndConfirmNever { readerSocket.sentFrames.count > 1 }
        writerSession?.stop()
        readerSession?.stop()
    }
}
