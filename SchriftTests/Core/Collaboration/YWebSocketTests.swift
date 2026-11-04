import XCTest

@testable import Schrift

@MainActor
final class YWebSocketTests: DocumentCollaborationManagerTestCase {
    // Read-only yhub capture, s4/ws-frames.json. These are server frames, not
    // generated with the implementation under test. The snapshot has a map marker.
    private let capturedStep1 = Data(base64Encoded: "AAAHAYG+zJYCAQ==")!
    private let capturedStep2 = Data(
        base64Encoded:
            "AAFqAQGBvsyWAgAIAShkb2MtNzJlYmUxYmItYjkyNy00OWQwLTk1NTQtODIzNTgyN2UyYzVhAXczYnJvYWRjYXN0OiBkb2MtNzJlYmUxYmItYjkyNy00OWQwLTk1NTQtODIzNTgyN2UyYzVhAA=="
    )!
    private let keepalive = Data(base64Encoded: "AQEA")!

    private func yhubManager(_ spy: ManagerSocketFactorySpy, enabled: Bool = true) async -> DocumentCollaborationManager
    {
        let config = ServerConfig(
            releaseVersion: "6.0.0", collaborationWsUrl: "wss://untrusted.example/collaboration/ws/v1/team")
        let manager = DocumentCollaborationManager(
            serverBaseURL: baseURL, cookieProvider: { [] }, featureEnabled: { true }, isOffline: { false },
            serverConfigProvider: { config },
            localStateProvider: { LocalAwarenessState(name: "A\"da", color: "#123456") },
            socketFactory: spy.factory, replicaClientIDProvider: { 42 })
        await manager.refreshServerSupport()
        await manager.refreshLocalAwareness()
        // Only tests override this gate. Production remains switched off on Docs 6.
        if enabled { manager.serverSupportsLiveCollaboration = true }
        return manager
    }

    private func frame(_ step: SyncStep, _ data: Data) -> Data {
        var result = Data([0])
        result.append(SyncMessage(step: step, data: data).encodedPayload())
        return result
    }

    private func syncMessages(_ socket: FakeWebSocket, step: SyncStep) -> [SyncMessage] {
        socket.sentFrames.compactMap { data in
            guard data.first == 0, let sync = try? SyncMessage(decodingPayload: Data(data.dropFirst())),
                sync.step == step
            else { return nil }
            return sync
        }
    }

    func testDocs6RemainsUnavailableEvenWithUserFlagEnabled() async {
        let spy = ManagerSocketFactorySpy()
        let manager = await yhubManager(spy, enabled: false)
        XCTAssertEqual(manager.availability, .serverUnavailable)
        XCTAssertNil(manager.session(for: docID, canUpdate: true))
        XCTAssertTrue(spy.sockets.isEmpty)
    }

    func testCapturedHandshakeAppliesSnapshotAndKeepalive() async throws {
        let spy = ManagerSocketFactorySpy()
        let manager = await yhubManager(spy)
        let session = try XCTUnwrap(manager.session(for: docID, canUpdate: true))
        defer { manager.suspend() }
        await waitUntil { spy.sockets[0].sentFrames.count == 2 }
        let socket = spy.sockets[0]
        XCTAssertEqual(socket.sentFrames[0], Data([0, 0, 1, 0]), "plain y-websocket, no room prefix")
        XCTAssertEqual(spy.requests[0].url?.path, "/collaboration/ws/v1/team/\(docID.uuidString.lowercased())")
        XCTAssertEqual(spy.requests[0].url?.host, baseURL.host)
        XCTAssertEqual(spy.requests[0].value(forHTTPHeaderField: "Origin"), "https://docs.example.org")
        XCTAssertNil(manager.encodeSnapshotForSave(for: docID))
        socket.deliver(message: capturedStep1)
        socket.deliver(message: capturedStep2)
        await waitUntil { manager.encodeSnapshotForSave(for: self.docID) != nil }
        let captured = try SyncMessage(decodingPayload: Data(capturedStep2.dropFirst())).data
        let expected = YDoc(clientID: 99)
        defer { expected.destroy() }
        try expected.applyUpdate(try YUpdateDecoder.decode(captured))
        XCTAssertEqual(manager.encodeSnapshotForSave(for: docID), try YStateEncoder.encodeStateAsUpdate(expected))

        let awareness = try AwarenessCodec.decodePayload(Data(socket.sentFrames[1].dropFirst()))
        let state = try XCTUnwrap(awareness.first?.stateJSON.data(using: .utf8))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: state) as? [String: Any])
        XCTAssertNil(object["name"])
        XCTAssertEqual((object["user"] as? [String: String])?["name"], "A\"da")

        socket.deliver(
            message: Data([1])
                + AwarenessCodec.encodePayload([
                    AwarenessEntry(
                        clientID: 7, clock: 1,
                        stateJSON: ##"{"user":{"name":"Peer","color":"#abcdef"},"cursor":{"anchor":1,"head":2}}"##)
                ]))
        await waitUntil { session.peers.count == 1 }
        let version = manager.replicaVersion(for: docID)
        socket.deliver(message: keepalive)
        // A following state request is a deterministic barrier after the keepalive.
        socket.deliver(message: capturedStep1)
        await waitUntil { self.syncMessages(socket, step: .step2).count == 1 }
        XCTAssertEqual(session.peers.map(\.name), ["Peer"])
        XCTAssertEqual(manager.replicaVersion(for: docID), version)
        XCTAssertEqual(session.state, .live)
    }

    func testLocalAndRemoteUpdatesConvergeWithoutDocumentPrefix() async throws {
        let spy = ManagerSocketFactorySpy()
        let manager = await yhubManager(spy)
        _ = try XCTUnwrap(manager.session(for: docID, canUpdate: true))
        defer { manager.suspend() }
        let socket = spy.sockets[0]
        let base = [para("hello", id: blockID)]
        let seed = BlockNoteYjs.encode(base, clientID: 1)
        socket.deliver(message: frame(.step2, seed))
        await waitUntil { manager.encodeSnapshotForSave(for: self.docID) != nil }
        let peer = YDoc(clientID: 7)
        defer { peer.destroy() }
        try peer.applyUpdate(try YUpdateDecoder.decode(seed))
        let edited = [para("hello local", id: blockID)]
        let update = try manager.applyLocalEdit(old: base, new: edited, for: docID)
        await waitUntil { self.syncMessages(socket, step: .update).count == 1 }
        XCTAssertEqual(syncMessages(socket, step: .update).first?.data, update)
        XCTAssertEqual(socket.sentFrames.last, frame(.update, update))
        try peer.applyUpdate(try YUpdateDecoder.decode(update))
        let remote = [para("hello local remote", id: blockID)]
        let remoteUpdate = try BlockNoteWrite.applyEdit(old: edited, new: remote, to: peer)
        socket.deliver(message: frame(.update, remoteUpdate))
        await waitUntil { manager.replicaVersion(for: self.docID) == 2 }
        XCTAssertEqual(
            manager.projectedReplica(for: docID, interlinkingOrigin: nil)?.blocks, YBlockProjection.project(peer).blocks
        )
    }

    func testResumeResendsSuspendedInsertionViaStep2() async throws {
        try await checkResume(deleting: false)
    }

    func testResumeResendsSuspendedDeletionOnlyViaStep2() async throws {
        try await checkResume(deleting: true)
    }

    private func checkResume(deleting: Bool) async throws {
        let spy = ManagerSocketFactorySpy()
        let manager = await yhubManager(spy)
        _ = try XCTUnwrap(manager.session(for: docID, canUpdate: true))
        defer { manager.suspend() }
        let base = [para("hello", id: blockID)]
        let seed = BlockNoteYjs.encode(base, clientID: 1)
        spy.sockets[0].deliver(message: frame(.step2, seed))
        await waitUntil { manager.encodeSnapshotForSave(for: self.docID) != nil }
        let server = YDoc(clientID: 7)
        defer { server.destroy() }
        try server.applyUpdate(try YUpdateDecoder.decode(seed))
        let vector = YStateEncoder.encodeStateVector(server)
        manager.suspend()
        let edited = [para(deleting ? "heo" : "hello!", id: blockID)]
        let update = try manager.applyLocalEdit(old: base, new: edited, for: docID)
        if deleting {
            XCTAssertEqual(update.first, 0, "the edit contains no new structs; only a delete set")
        }
        manager.resume()
        await waitUntil { spy.sockets.count == 2 && spy.sockets[1].sentFrames.count == 2 }
        let socket = spy.sockets[1]
        let handshake = try XCTUnwrap(syncMessages(socket, step: .step1).first)
        if deleting { XCTAssertEqual(handshake.data, vector, "state vectors do not represent deletions") }
        socket.deliver(message: frame(.step1, vector))
        socket.deliver(message: frame(.step2, Data([0, 0])))
        await waitUntil { self.syncMessages(socket, step: .step2).count == 1 }
        let reply = try XCTUnwrap(syncMessages(socket, step: .step2).first)
        try server.applyUpdate(try YUpdateDecoder.decode(reply.data))
        XCTAssertEqual(YBlockProjection.project(server).blocks.map(\.runs), edited.map(\.runs))
        XCTAssertEqual(
            manager.projectedReplica(for: docID, interlinkingOrigin: nil)?.blocks,
            YBlockProjection.project(server).blocks)
        XCTAssertTrue(
            syncMessages(socket, step: .update).isEmpty, "reconnect recovers through sync, not a queued broadcast")
    }

    func testMissingYHubUpdateAbilityFailsClosedAcrossResume() async throws {
        let spy = ManagerSocketFactorySpy()
        let manager = await yhubManager(spy)
        _ = try XCTUnwrap(manager.session(for: docID))  // omitted ability is not permission
        defer { manager.suspend() }
        let socket = spy.sockets[0]
        socket.deliver(message: frame(.step2, BlockNoteYjs.encode([para("reader", id: blockID)], clientID: 1)))
        await waitUntil { manager.replicaVersion(for: self.docID) == 1 }
        manager.suspend()
        manager.resume()
        await waitUntil { spy.sockets.count == 2 && spy.sockets[1].sentFrames.count == 1 }
        XCTAssertFalse(manager.canWriteReplica(for: docID))
        XCTAssertNil(manager.encodeSnapshotForSave(for: docID))
        XCTAssertEqual(spy.sockets[1].sentFrames.first?.first, 0)
        await waitAndConfirmNever { spy.sockets[1].sentFrames.contains { $0.first == 1 } }
    }

    func testQueryAwarenessPublishesNestedUserAndIgnoresUnknownFrames() async throws {
        let spy = ManagerSocketFactorySpy()
        let manager = await yhubManager(spy)
        _ = try XCTUnwrap(manager.session(for: docID, canUpdate: true))
        defer { manager.suspend() }
        let socket = spy.sockets[0]
        await waitUntil { socket.sentFrames.count == 2 }
        socket.deliver(message: Data([0x80]))  // truncated type varUint
        socket.deliver(message: Data([99]))  // unknown type
        socket.deliver(message: Data([4]) + SyncMessage(step: .step2, data: Data([0, 0])).encodedPayload())
        socket.deliver(message: Data([3]))
        await waitUntil { socket.sentFrames.count == 3 }
        XCTAssertEqual(socket.sentFrames[2], socket.sentFrames[1])
        XCTAssertEqual(manager.replicaVersion(for: docID), 0, "type 4 is not y-websocket sync")
    }

    func testReaderReceivesUpdatesButNeverPublishesAwarenessOrEdits() async throws {
        let spy = ManagerSocketFactorySpy()
        let manager = await yhubManager(spy)
        let session = try XCTUnwrap(manager.session(for: docID, canUpdate: false))
        defer { manager.suspend() }
        let socket = spy.sockets[0]
        await waitUntil { socket.sentFrames.count == 1 }
        let blocks = [para("read only", id: blockID)]
        socket.deliver(message: frame(.step2, BlockNoteYjs.encode(blocks, clientID: 1)))
        await waitUntil { manager.replicaVersion(for: self.docID) == 1 }
        XCTAssertNotNil(manager.projectedReplica(for: docID, interlinkingOrigin: nil))
        XCTAssertFalse(manager.canWriteReplica(for: docID))
        XCTAssertNil(manager.encodeSnapshotForSave(for: docID))
        XCTAssertThrowsError(try manager.applyLocalEdit(old: blocks, new: [], for: docID)) {
            XCTAssertEqual($0 as? CollaborationWriteError, .notWritable)
        }
        await session.broadcast(update: Data([0, 0]))
        socket.deliver(message: Data([3]))  // queryAwareness must not make a reader publish.
        socket.deliver(message: keepalive)
        socket.deliver(message: frame(.step1, Data([0])))
        await waitUntil { self.syncMessages(socket, step: .step2).count == 1 }
        XCTAssertFalse(socket.sentFrames.contains { $0.first == 1 })
        XCTAssertTrue(syncMessages(socket, step: .update).isEmpty)
        XCTAssertEqual(manager.localEditVersion(for: docID), 0)
    }
    func testDowngradeToReaderDropsTheReplicaSoStep2CarriesNoWriterEdits() async throws {
        let spy = ManagerSocketFactorySpy()
        let manager = await yhubManager(spy)
        _ = try XCTUnwrap(manager.session(for: docID, canUpdate: true))
        defer { manager.suspend() }
        let writer = spy.sockets[0]
        await waitUntil { writer.sentFrames.count == 2 }
        let blocks = [para("server", id: blockID)]
        writer.deliver(message: frame(.step2, BlockNoteYjs.encode(blocks, clientID: 1)))
        await waitUntil { manager.canWriteReplica(for: self.docID) }
        _ = try manager.applyLocalEdit(old: blocks, new: blocks + [para("writer only", id: "writer-block")], for: docID)

        _ = try XCTUnwrap(manager.session(for: docID, canUpdate: false))
        await waitUntil { spy.sockets.count == 2 }
        let reader = spy.sockets[1]
        await waitUntil { reader.sentFrames.count == 1 }
        let version = manager.replicaVersion(for: docID)
        reader.deliver(message: frame(.step1, Data([0])))
        // Frames are handled in order, so once this step2 lands the step1 reply (if any) was sent.
        reader.deliver(message: frame(.step2, BlockNoteYjs.encode(blocks, clientID: 1)))
        await waitUntil { manager.replicaVersion(for: self.docID) > version }
        let marker = Data("writer only".utf8)
        // The step2 reply is sent from an unstructured task, so keep watching for it.
        await waitAndConfirmNever { reader.sentFrames.contains { $0.range(of: marker) != nil } }
        XCTAssertFalse(manager.canWriteReplica(for: docID))
    }
}
