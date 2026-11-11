import Foundation
import UIKit
import XCTest

@testable import Schrift

/// A y-websocket relay in memory, like Docs 6's collaboration server: it holds
/// its own replica, sends SyncStep1 when a socket connects, answers a step1
/// with the diff, applies every step2/update and relays it to the other
/// sockets. Nothing here touches the network.
@MainActor
private final class FakeYServer {
    let doc = YDoc(clientID: 900, gc: true)
    private(set) var sockets: [FakeWebSocket] = []
    private var handled: [Int] = []
    private var answered: [Int] = []
    /// Like a y-redis-style server: a SyncStep1 after a socket's first is ignored.
    var ignoresLaterStep1 = false
    /// Answers every SyncStep1 with these bytes instead of the diff.
    var step2Override: Data?

    init(state: Data) throws {
        try doc.applyUpdate(YUpdateDecoder.decode(state), origin: .remote)
    }

    static func frame(_ step: SyncStep, _ data: Data) -> Data {
        CollaborationWireProtocol.yWebSocket.encode(
            HocuspocusMessage(
                documentName: "", type: .sync, payload: SyncMessage(step: step, data: data).encodedPayload()))
    }

    /// The sync messages `socket` sent, in order.
    static func sent(_ socket: FakeWebSocket) -> [SyncMessage] {
        socket.sentFrames.compactMap { data in
            guard let message = try? CollaborationWireProtocol.yWebSocket.decode(data, documentName: ""),
                message.type == 0
            else { return nil }
            return try? SyncMessage(decodingPayload: message.payload)
        }
    }

    func connect() -> (CollaborationTransport, FakeWebSocket) {
        let socket = FakeWebSocket()
        sockets.append(socket)
        handled.append(0)
        answered.append(0)
        socket.deliver(message: Self.frame(.step1, YStateEncoder.encodeStateVector(doc)))
        return (CollaborationTransport(socket: socket, wireProtocol: .yWebSocket, documentName: "doc"), socket)
    }

    /// Handles everything the clients sent since the last call.
    func pump() throws {
        for (index, socket) in sockets.enumerated() {
            let frames = Self.sent(socket)
            while handled[index] < frames.count {
                let message = frames[handled[index]]
                handled[index] += 1
                switch message.step {
                case .step1:
                    answered[index] += 1
                    if ignoresLaterStep1, answered[index] > 1 { continue }
                    if let step2Override {
                        socket.deliver(message: Self.frame(.step2, step2Override))
                        continue
                    }
                    let entries = try YUpdateDecoder.decodeStateVector(message.data)
                    let since = Dictionary(entries.map { ($0.client, $0.clock) }, uniquingKeysWith: { _, b in b })
                    socket.deliver(
                        message: Self.frame(.step2, try YStateEncoder.encodeStateAsUpdate(doc, since: since)))
                case .step2, .update:
                    try apply(message.data, relayExcept: index)
                }
            }
        }
    }

    /// A web peer's edit: applied here and relayed to every client.
    func peerEdit(_ update: Data) throws { try apply(update, relayExcept: nil) }

    /// Applied here only: a client learns of it from a later step2.
    func applyUnrelayed(_ update: Data) throws {
        try doc.applyUpdate(YUpdateDecoder.decode(update), origin: .remote)
    }

    private func apply(_ update: Data, relayExcept origin: Int?) throws {
        try doc.applyUpdate(YUpdateDecoder.decode(update), origin: .remote)
        for (index, socket) in sockets.enumerated() where index != origin {
            socket.deliver(message: Self.frame(.update, update))
        }
    }

    func settle(
        timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
        until condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try pump()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try pump()
        if !condition() { XCTFail("the clients did not converge in \(timeout)s", file: file, line: line) }
    }
}

/// PR09a: `NativeCollaborationBinding` over real durable replica sessions and
/// a fake y-websocket server. Each client is its own device: its own store,
/// registry and owner. The journal closure is the production one
/// (`NativeEditorOpen.installTyping`): append, then publish.
@MainActor
final class NativeLiveSyncTests: NativeEditingTestCase {
    private struct Client {
        let registry: NativeSessionRegistry
        let store: ReplicaStore
        let scope: ReplicaScope
        let session: NativeEditorSession
        let binding: NativeCollaborationBinding
    }

    private let documentID = UUID()
    private var nextPeer: UInt32 = 40

    private func seedState() -> Data { BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID) }

    /// Reconnect timing short enough for tests (PR09b).
    static let fastBackoff = NativeCollaborationBinding.Backoff(
        base: .milliseconds(10), cap: .milliseconds(80), stableAfter: .milliseconds(300))

    /// `relaunching` opens the same durable replica again with a new registry,
    /// as a cold launch does (close the previous client's registry first).
    private func makeClient(
        state: Data? = nil, hooks: DocumentReplicaSession.Hooks = .init(),
        interrupt: (@Sendable (ReplicaStore.Operation, ReplicaStore.Boundary) throws -> Void)? = nil,
        relaunching previous: Client? = nil
    ) async throws -> Client {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scope =
            previous?.scope
            ?? ReplicaScope(
                serverOrigin: "https://example.test", ownerUserID: UUID(), org: "docs", documentID: documentID)
        let store = previous?.store ?? ReplicaStore(directory: directory, interrupt: interrupt)
        if previous == nil { _ = try store.create(for: scope, checkpoint: state ?? seedState()) }
        let registry = NativeSessionRegistry()
        registry.liveBackoff = Self.fastBackoff
        addTeardownBlock {
            await registry.closeAll().value
            try? FileManager.default.removeItem(at: directory)
        }
        let session = try await unwrapped(registry.open(store: store, scope: scope, hooks: hooks))
        let binding = try unwrapped(registry.liveBinding(for: scope))
        let outbox = binding.outbox
        registry.setWritable(
            { command, update in
                try store.append(
                    update, for: scope, commandID: command.id, baseRevision: command.baseRevision, origin: .local)
                outbox.publish(update)
            }, for: scope)
        session.enableTyping(persist: nil)
        return Client(registry: registry, store: store, scope: scope, session: session, binding: binding)
    }

    /// Dials through the binding (it reads the state vector first) and
    /// returns the socket the server accepted.
    @discardableResult
    private func connect(
        _ client: Client, to server: FakeYServer, isCurrent: @escaping @MainActor () -> Bool = { true },
        isReader: @escaping @MainActor () async -> Bool = { false }, becameReader: @escaping @MainActor () -> Void = {}
    ) async throws -> FakeWebSocket {
        let before = server.sockets.count
        client.binding.connect(
            dial: { server.connect().0 }, wireProtocol: .yWebSocket, documentName: "doc", isCurrent: isCurrent,
            isReader: isReader, becameReader: becameReader)
        await waitUntil { server.sockets.count > before }
        return try XCTUnwrap(server.sockets.last)
    }

    private func type(_ text: String, _ client: Client, _ blockID: String, at offset: Int) async throws {
        let session = client.session
        session.textView.selectedRange = NSRange(location: try location(session, blockID, offset), length: 0)
        session.input?.textViewDidChangeSelection(session.textView)
        session.textView.insertText(text)
        let settled = await session.settle()
        XCTAssertTrue(settled)
    }

    private func updates(_ socket: FakeWebSocket) -> [Data] {
        FakeYServer.sent(socket).filter { $0.step == .update }.map(\.data)
    }

    private func step1Count(_ socket: FakeWebSocket) -> Int {
        FakeYServer.sent(socket).filter { $0.step == .step1 }.count
    }

    /// A peer replica of the server's current state, as a web client has it.
    private func peer(of server: FakeYServer) throws -> YDoc {
        nextPeer += 1
        let peer = YDoc(clientID: UInt(nextPeer), gc: true)
        try peer.applyUpdate(YUpdateDecoder.decode(YStateEncoder.encodeStateAsUpdate(server.doc)), origin: .remote)
        return peer
    }

    private func outboxCount(_ client: Client) throws -> Int {
        try XCTUnwrap(client.store.manifest(for: client.scope)).outbox.count
    }

    // MARK: - Two and three clients

    func testTwoNativeClientsSyncBothWaysAndPublishEachEditOnce() async throws {
        let server = try FakeYServer(state: seedState())
        defer { server.doc.destroy() }
        let a = try await makeClient()
        let b = try await makeClient()
        let socketA = try await connect(a, to: server)
        let socketB = try await connect(b, to: server)
        try await server.settle { self.step1Count(socketA) == 1 && self.step1Count(socketB) == 1 }

        try await type("A", a, Self.firstID, at: 5)
        try await server.settle { self.texts(b.session)[0] == "FirstA paragraph." }
        try await type("B", b, Self.firstID, at: 0)
        try await server.settle { self.texts(a.session)[0] == "BFirstA paragraph." }

        XCTAssertEqual(projection(server.doc), a.session.surface.blocks)
        XCTAssertEqual(a.session.surface.blocks, b.session.surface.blocks)
        XCTAssertEqual(updates(socketA).count, 1, "one keystroke, one frame")
        XCTAssertEqual(updates(socketB).count, 1)
        // The frame is exactly the journaled local entry, and a remote edit
        // never enters the HTTP outbox.
        let journal = try XCTUnwrap(a.store.restore(for: a.scope)).updates
        XCTAssertTrue(journal.contains(try XCTUnwrap(updates(socketA).first)))
        XCTAssertEqual(try outboxCount(a), 1)
        XCTAssertEqual(try outboxCount(b), 1)
        XCTAssertFalse(a.session.state.frozen)
    }

    func testThreeClientsConvergeOnAWebPeerFormatAndLaterTyping() async throws {
        let server = try FakeYServer(state: seedState())
        defer { server.doc.destroy() }
        let a = try await makeClient()
        let b = try await makeClient()
        let socketA = try await connect(a, to: server)
        let socketB = try await connect(b, to: server)
        try await server.settle { self.step1Count(socketA) == 1 && self.step1Count(socketB) == 1 }

        let web = try peer(of: server)
        defer { web.destroy() }
        try server.peerEdit(
            BlockNoteWriter(doc: web).formatRange(block: Self.thirdID, range: 0..<5, attributes: ["bold": "{}"]))
        func boldFirstRun(_ client: Client) -> Bool {
            (try? block(client.session, Self.thirdID).runs.first?.marks.map(\.key)) == ["bold"]
        }
        try await server.settle { boldFirstRun(a) && boldFirstRun(b) }
        try await type("!", a, Self.thirdID, at: 16)
        try await server.settle { self.texts(b.session)[2] == "Third paragraph.!" }

        XCTAssertEqual(projection(server.doc), a.session.surface.blocks)
        XCTAssertEqual(a.session.surface.blocks, b.session.surface.blocks)
        try web.applyUpdate(
            YUpdateDecoder.decode(YStateEncoder.encodeStateAsUpdate(server.doc)), origin: .remote)
        XCTAssertEqual(projection(web), a.session.surface.blocks, "the web peer converges too")
    }

    // MARK: - Delivery order

    func testDuplicateAndOutOfOrderUpdatesConvergeWithoutFreezing() async throws {
        let server = try FakeYServer(state: seedState())
        defer { server.doc.destroy() }
        let a = try await makeClient()
        let socket = try await connect(a, to: server)
        try await server.settle { self.step1Count(socket) == 1 && self.a(isLive: a) }
        // A mid-session SyncStep1 would never be answered: only a redial recovers.
        server.ignoresLaterStep1 = true

        let web = try peer(of: server)
        defer { web.destroy() }
        let writer = BlockNoteWriter(doc: web)
        let first = try writer.replaceText(block: Self.firstID, range: 0..<0, with: "x")
        let second = try writer.replaceText(block: Self.firstID, range: 1..<1, with: "y")
        try server.applyUnrelayed(first)
        try server.applyUnrelayed(second)
        // The second overtakes the first, and the first arrives twice.
        socket.deliver(message: FakeYServer.frame(.update, second))
        socket.deliver(message: FakeYServer.frame(.update, first))
        socket.deliver(message: FakeYServer.frame(.update, first))
        try await server.settle { self.texts(a.session)[0] == "xyFirst paragraph." }

        XCTAssertEqual(server.sockets.count, 2, "the refused update came back with a fresh handshake")
        XCTAssertFalse(a.session.state.frozen, "a missing dependency never freezes the editor")
        let replay = try XCTUnwrap(a.store.restore(for: a.scope))
        XCTAssertFalse(replay.updates.isEmpty)
        let restored = try makeClientRestoring(a)
        XCTAssertEqual(restored, a.session.surface.blocks, "the journal replays with no pending structs")
    }

    func testAnUpdateThatOvertakesTheInitialStepTwoWaitsForIt() async throws {
        let server = try FakeYServer(state: seedState())
        defer { server.doc.destroy() }
        let web = try peer(of: server)
        defer { web.destroy() }
        let writer = BlockNoteWriter(doc: web)
        let first = try writer.replaceText(block: Self.firstID, range: 0..<0, with: "x")
        let second = try writer.replaceText(block: Self.firstID, range: 1..<1, with: "y")
        try server.applyUnrelayed(first)
        try server.applyUnrelayed(second)
        let a = try await makeClient()
        let socket = try await connect(a, to: server)
        // Before the server answers our SyncStep1, a relayed frame that needs
        // the first edit arrives.
        socket.deliver(message: FakeYServer.frame(.update, second))
        try await server.settle { self.texts(a.session)[0] == "xyFirst paragraph." }
        XCTAssertFalse(a.session.state.frozen)
        XCTAssertEqual(projection(server.doc), a.session.surface.blocks)
    }

    func testAnInboundBurstPastTheBoundIsFetchedAgain() async throws {
        let gate = Latch(open: true)
        let server = try FakeYServer(state: seedState())
        defer { server.doc.destroy() }
        let a = try await makeClient(hooks: .init(beforeMessage: { gate.pass() }))
        let socket = try await connect(a, to: server)
        try await server.settle { self.step1Count(socket) == 1 && self.a(isLive: a) }
        let web = try peer(of: server)
        defer { web.destroy() }
        let writer = BlockNoteWriter(doc: web)
        server.ignoresLaterStep1 = true
        gate.close()
        let burst = NativeCollaborationBinding.inboundBound + 6
        for index in 0..<burst {
            try server.peerEdit(writer.replaceText(block: Self.thirdID, range: index..<index, with: "z"))
        }
        try server.pump()
        try await Task.sleep(for: .milliseconds(100))
        gate.open()
        let expected = String(repeating: "z", count: burst) + "Third paragraph."
        try await server.settle { self.texts(a.session)[2] == expected }
        XCTAssertEqual(server.sockets.count, 2, "the skipped frames come back in one fresh handshake")
        XCTAssertFalse(a.session.state.frozen)
    }

    // MARK: - Journal before publication

    func testOnlyJournaledBytesAreSentAndAFrozenReplicaAnswersNothing() async throws {
        let failing = Locked(false)
        let server = try FakeYServer(state: seedState())
        defer { server.doc.destroy() }
        let a = try await makeClient(interrupt: { operation, boundary in
            if failing.value, operation == .append, boundary == .payloadWritten {
                throw CocoaError(.fileWriteNoPermission)
            }
        })
        let socket = try await connect(a, to: server)
        try await server.settle { self.step1Count(socket) == 1 && self.a(isLive: a) }
        try await type("A", a, Self.firstID, at: 0)
        try await server.settle { self.updates(socket).count == 1 }

        failing.value = true
        try await type("B", a, Self.firstID, at: 1)
        XCTAssertTrue(a.session.state.frozen, "the failed append froze authoring")
        let sent = socket.sentFrames.count
        // A peer asking for our state now gets nothing: the graph may hold the
        // unjournaled keystroke.
        socket.deliver(message: FakeYServer.frame(.step1, Data([0x00])))
        await a.session.settle()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(socket.sentFrames.count, sent, "nothing unjournaled leaves")
        try server.pump()
        XCTAssertEqual(texts(a.session)[0].first, "A")
        XCTAssertEqual(projection(server.doc)[0].runs.map(\.text).joined(), "AFirst paragraph.")
    }

    func testEditsJournaledBeforeConnectingAreOfferedInTheHandshake() async throws {
        let server = try FakeYServer(state: seedState())
        defer { server.doc.destroy() }
        let a = try await makeClient()
        try await type("Offline ", a, Self.firstID, at: 0)
        XCTAssertEqual(try outboxCount(a), 1)
        let socket = try await connect(a, to: server)
        try await server.settle { self.text(of: self.projection(server.doc)[0]) == "Offline First paragraph." }
        XCTAssertTrue(updates(socket).isEmpty, "the server's SyncStep1 is answered with a step2, not a replay")
        XCTAssertEqual(try outboxCount(a), 1, "the HTTP outbox still owns the acknowledgment")
    }

    // MARK: - Readers

    func testAReadOnlyReplicaReceivesButSendsNothing() async throws {
        let server = try FakeYServer(state: seedState())
        defer { server.doc.destroy() }
        let a = try await makeClient()
        let socket = try await connect(a, to: server)
        try await server.settle { self.step1Count(socket) == 1 && self.a(isLive: a) }
        XCTAssertTrue(a.registry.setWritable(nil, for: a.scope))
        await a.session.settle()
        let sent = socket.sentFrames.count

        let web = try peer(of: server)
        defer { web.destroy() }
        try server.peerEdit(BlockNoteWriter(doc: web).replaceText(block: Self.firstID, range: 0..<0, with: "w"))
        try await server.settle { self.texts(a.session)[0] == "wFirst paragraph." }
        try await type("r", a, Self.firstID, at: 0)
        socket.deliver(message: FakeYServer.frame(.step1, Data([0x00])))
        try await Task.sleep(for: .milliseconds(100))
        await a.session.settle()
        XCTAssertEqual(socket.sentFrames.count, sent, "a reader sends no edit and answers no SyncStep1")
        XCTAssertEqual(texts(a.session)[0], "wFirst paragraph.")
    }

    // MARK: - Dependency check

    func testMissingDependenciesAreFoundBeforeIntegration() throws {
        let doc = try makeDoc(clientID: 2)
        defer { doc.destroy() }
        let web = try makeDoc(clientID: 3)
        defer { web.destroy() }
        let writer = BlockNoteWriter(doc: web)
        let first = try YUpdateDecoder.decode(writer.replaceText(block: Self.firstID, range: 0..<0, with: "x"))
        let second = try YUpdateDecoder.decode(writer.replaceText(block: Self.firstID, range: 1..<1, with: "y"))
        let deletion = try YUpdateDecoder.decode(writer.replaceText(block: Self.firstID, range: 0..<2, with: ""))
        XCTAssertFalse(first.missesDependencies(in: doc.store))
        XCTAssertTrue(second.missesDependencies(in: doc.store), "a run that starts past the store's clock")
        XCTAssertTrue(deletion.missesDependencies(in: doc.store), "a deletion of clocks the store lacks")
        try doc.applyUpdate(first, origin: .remote)
        XCTAssertFalse(second.missesDependencies(in: doc.store))
        let foreign = YUpdate(
            blocks: [
                YClientBlock(
                    client: 77,
                    structs: [
                        .item(
                            YItemRecord(
                                id: YID(client: 77, clock: 0), info: 0x80 | 4, origin: YID(client: 55, clock: 3),
                                rightOrigin: nil, parent: nil, parentSub: nil, content: .string("q")))
                    ])
            ], deleteSet: [])
        XCTAssertTrue(foreign.missesDependencies(in: doc.store), "an origin no one holds")
    }

    // MARK: - Hostile frames (PR #274 security review)

    /// S1: a delete range whose end overflows `UInt` is refused at decode; it
    /// used to trap in the dependency check, a remote crash.
    func testADeleteRangeThatOverflowsIsRefusedNotATrap() async throws {
        let frame = YUpdateReencoder.encode(
            YUpdate(
                blocks: [], deleteSet: [YDeleteBlock(client: 5, ranges: [YDeleteRange(clock: UInt.max - 1, length: 4)])]
            ))
        XCTAssertThrowsError(try YUpdateDecoder.decode(frame)) { error in
            XCTAssertEqual(error as? YWireError, .clockOutOfRange)
        }
        let server = try FakeYServer(state: seedState())
        defer { server.doc.destroy() }
        let a = try await makeClient()
        let socket = try await connect(a, to: server)
        try await server.settle { self.step1Count(socket) == 1 && self.a(isLive: a) }
        socket.deliver(message: FakeYServer.frame(.update, frame))
        await waitUntil { a.binding.isStopped }
        XCTAssertFalse(a.session.state.frozen)
    }

    /// S2: a collaborator's frame that passes the checks but fails inside
    /// integration, after another client's structs already went in, must not
    /// freeze authoring or leave the replica half-mutated: the replica is
    /// rebuilt from the journal, only the live binding stops, and typing goes on.
    func testAFrameThatFailsMidIntegrationStopsLiveWithoutFreezingOrMutating() async throws {
        let server = try FakeYServer(state: seedState())
        defer { server.doc.destroy() }
        let a = try await makeClient()
        let socket = try await connect(a, to: server)
        try await server.settle { self.step1Count(socket) == 1 && self.a(isLive: a) }
        let before = a.session.surface.blocks
        let peer = YDoc(clientID: 200, gc: true)
        defer { peer.destroy() }
        try peer.applyUpdate(YUpdateDecoder.decode(YStateEncoder.encodeStateAsUpdate(server.doc)), origin: .remote)
        var crafted = try YUpdateDecoder.decode(
            BlockNoteWriter(doc: peer).replaceText(block: Self.firstID, range: 0..<0, with: "half"))
        // Integrated after client 200: an item whose origin is itself, which
        // the store cannot resolve.
        crafted.blocks.append(
            YClientBlock(
                client: 100,
                structs: [
                    .item(
                        YItemRecord(
                            id: YID(client: 100, clock: 0), info: 0x80 | 4, origin: YID(client: 100, clock: 0),
                            rightOrigin: nil, parent: nil, parentSub: nil, content: .string("q")))
                ]))
        socket.deliver(message: FakeYServer.frame(.update, YUpdateReencoder.encode(crafted)))
        await waitUntil { a.binding.isStopped }
        let drained = await a.session.settle()
        XCTAssertTrue(drained)
        XCTAssertFalse(a.session.state.frozen, "a peer's frame never freezes authoring")
        XCTAssertEqual(a.session.surface.blocks, before, "nothing of the failed frame is shown")
        let graph = await a.session.replicaDoc { Self.projectionOf($0) }
        XCTAssertEqual(graph, before, "nothing of the failed frame stays in the replica")
        try await type("ok ", a, Self.firstID, at: 0)
        XCTAssertEqual(texts(a.session)[0], "ok First paragraph.")
        XCTAssertEqual(try makeClientRestoring(a), a.session.surface.blocks)
    }

    /// S3a: a duplicate or empty frame is not journaled, and remote entries
    /// compact while the document is only read.
    func testDuplicateFramesAreNotJournaledAndRemoteGrowthCompacts() async throws {
        let server = try FakeYServer(state: seedState())
        defer { server.doc.destroy() }
        let a = try await makeClient()
        let socket = try await connect(a, to: server)
        try await server.settle { self.step1Count(socket) == 1 && self.a(isLive: a) }
        let journaled = try XCTUnwrap(a.store.manifest(for: a.scope)).journal.count
        let web = try peer(of: server)
        defer { web.destroy() }
        let edit = try BlockNoteWriter(doc: web).replaceText(block: Self.firstID, range: 0..<0, with: "d")
        try server.peerEdit(edit)
        socket.deliver(message: FakeYServer.frame(.update, edit))
        socket.deliver(message: FakeYServer.frame(.update, Data([0, 0])))
        try await server.settle { self.texts(a.session)[0] == "dFirst paragraph." }
        let drained = await a.session.settle()
        XCTAssertTrue(drained)
        XCTAssertEqual(try XCTUnwrap(a.store.manifest(for: a.scope)).journal.count, journaled + 1)

        let writer = BlockNoteWriter(doc: web)
        let threshold = ReplicaSaveAdapter.compactionJournalThreshold
        for index in 0..<threshold + 4 {
            try server.peerEdit(writer.replaceText(block: Self.thirdID, range: index..<index, with: "c"))
            try server.pump()
        }
        let expected = String(repeating: "c", count: threshold + 4) + "Third paragraph."
        try await server.settle { self.texts(a.session)[2] == expected }
        let compacted = await a.session.settle()
        XCTAssertTrue(compacted)
        XCTAssertLessThan(
            try XCTUnwrap(a.store.manifest(for: a.scope)).journal.count, threshold, "remote entries compacted")
        XCTAssertEqual(try makeClientRestoring(a), a.session.surface.blocks)
    }

    /// S3b: a burst of SyncStep1 frames keeps at most one answer in the
    /// mailbox, so the next keystroke still finds room and is journaled.
    func testASyncStepOneBurstLeavesRoomForTyping() async throws {
        let gate = Latch(open: true)
        let server = try FakeYServer(state: seedState())
        defer { server.doc.destroy() }
        let a = try await makeClient(hooks: .init(beforeMessage: { gate.pass() }))
        let socket = try await connect(a, to: server)
        try await server.settle { self.step1Count(socket) == 1 && self.a(isLive: a) }
        gate.close()
        for _ in 0..<(ReplicaCommandMailbox.capacity + 44) {
            socket.deliver(message: FakeYServer.frame(.step1, Data([0x00])))
        }
        try await Task.sleep(for: .milliseconds(300))
        let session = a.session
        session.textView.selectedRange = NSRange(location: try location(session, Self.firstID, 0), length: 0)
        session.input?.textViewDidChangeSelection(session.textView)
        session.textView.insertText("k")
        gate.open()
        let drained = await session.settle()
        XCTAssertTrue(drained)
        XCTAssertFalse(session.state.frozen, "a full mailbox would have frozen authoring")
        XCTAssertEqual(texts(session)[0], "kFirst paragraph.")
        XCTAssertEqual(try outboxCount(a), 1)
    }

    /// The redial cap counts recoveries in a row: a socket whose step2
    /// integrates starts it again, so more stalls than the cap in one open
    /// each recover and live keeps going.
    func testEachSeparateStallRecoversPastTheRedialCap() async throws {
        let server = try FakeYServer(state: seedState())
        defer { server.doc.destroy() }
        let a = try await makeClient()
        try await connect(a, to: server)
        try await server.settle { self.a(isLive: a) }
        let web = try peer(of: server)
        defer { web.destroy() }
        let writer = BlockNoteWriter(doc: web)
        var expected = "First paragraph."
        let stalls = NativeCollaborationBinding.redialLimit + 1
        for stall in 0..<stalls {
            let socket = try XCTUnwrap(server.sockets.last)
            let first = try writer.replaceText(block: Self.firstID, range: 0..<0, with: "x")
            let second = try writer.replaceText(block: Self.firstID, range: 1..<1, with: "y")
            try server.applyUnrelayed(first)
            try server.applyUnrelayed(second)
            // Only the second reaches this socket: the first was lost in a stall.
            socket.deliver(message: FakeYServer.frame(.update, second))
            expected = "xy" + expected
            try await server.settle { self.texts(a.session)[0] == expected && self.a(isLive: a) }
            XCTAssertEqual(server.sockets.count, stall + 2, "stall \(stall) recovered with one redial")
        }
        XCTAssertFalse(a.binding.isStopped, "separate stalls never exhaust the cap")
    }

    /// T1: a step2 the replica refuses would come back with every handshake;
    /// live stops instead of looping on SyncStep1.
    func testARefusedStepTwoStopsLiveInsteadOfLooping() async throws {
        let server = try FakeYServer(state: seedState())
        defer { server.doc.destroy() }
        let web = try peer(of: server)
        defer { web.destroy() }
        let writer = BlockNoteWriter(doc: web)
        _ = try writer.replaceText(block: Self.firstID, range: 0..<0, with: "x")
        server.step2Override = try writer.replaceText(block: Self.firstID, range: 1..<1, with: "y")
        let a = try await makeClient()
        let socket = try await connect(a, to: server)
        try await server.settle { a.binding.isStopped }
        try await Task.sleep(for: .milliseconds(150))
        try server.pump()
        XCTAssertEqual(step1Count(socket), 1, "no SyncStep1 loop")
        XCTAssertEqual(server.sockets.count, 1, "no redial loop")
        XCTAssertFalse(a.session.state.frozen)
    }

    /// T3: once the open is no longer current (a cookie handover forgot the
    /// account), no journaled update or state answer leaves on the socket.
    func testNothingIsSentOnceTheOpenIsNoLongerCurrent() async throws {
        let current = Locked(true)
        let server = try FakeYServer(state: seedState())
        defer { server.doc.destroy() }
        let a = try await makeClient()
        let socket = try await connect(a, to: server, isCurrent: { current.value })
        try await server.settle { self.step1Count(socket) == 1 && self.a(isLive: a) }
        current.value = false
        let sent = socket.sentFrames.count
        try await type("z", a, Self.firstID, at: 0)
        socket.deliver(message: FakeYServer.frame(.step1, Data([0x00])))
        try await Task.sleep(for: .milliseconds(150))
        let drained = await a.session.settle()
        XCTAssertTrue(drained)
        XCTAssertEqual(socket.sentFrames.count, sent, "no update and no step2 for another account")
        XCTAssertEqual(try outboxCount(a), 1, "the keystroke is still journaled for HTTP")
    }

    /// T4: a state vector the full mailbox could not answer dials nothing,
    /// rather than a handshake asking for the whole document.
    func testAFullMailboxDialsNothing() async throws {
        let gate = Latch(open: true)
        let server = try FakeYServer(state: seedState())
        defer { server.doc.destroy() }
        let a = try await makeClient(hooks: .init(beforeMessage: { gate.pass() }))
        let replica = try XCTUnwrap(a.session.replica)
        gate.close()
        replica.mailbox.post(.writeProvisional([]))
        await waitUntil { gate.waiting == 1 }
        for _ in 0..<ReplicaCommandMailbox.capacity { replica.mailbox.post(.writeProvisional([])) }
        a.binding.connect(
            dial: { server.connect().0 }, wireProtocol: .yWebSocket, documentName: "doc", isCurrent: { true })
        try await Task.sleep(for: .milliseconds(200))
        gate.open()
        XCTAssertTrue(server.sockets.isEmpty, "no handshake with an empty state vector")
        XCTAssertFalse(a.binding.isConnected)
    }

    // MARK: - Reconnect and the failure matrix (PR09b)

    private func serverText(_ server: FakeYServer, _ index: Int = 0) -> String {
        text(of: projection(server.doc)[index])
    }

    /// A dropped socket dials again after its backoff, and the handshake
    /// offers what was typed while it was down.
    func testADropReconnectsAndDeliversWhatWasTypedMeanwhile() async throws {
        let server = try FakeYServer(state: seedState())
        defer { server.doc.destroy() }
        let a = try await makeClient()
        let socket = try await connect(a, to: server)
        try await server.settle { self.a(isLive: a) }
        socket.failTransport()
        try await type("D", a, Self.firstID, at: 0)
        try await server.settle { self.serverText(server) == "DFirst paragraph." }
        XCTAssertEqual(server.sockets.count, 2, "one reconnect")
        XCTAssertEqual(texts(a.session)[0], "DFirst paragraph.")
    }

    /// Background closes the socket and nothing dials until foreground, which
    /// dials at once; a deletion made in between (the state vector does not
    /// move) still reaches the server.
    func testBackgroundSuspendsAndForegroundDeliversADeleteOnlyEdit() async throws {
        let server = try FakeYServer(state: seedState())
        defer { server.doc.destroy() }
        let manager = DocumentCollaborationManager(
            serverBaseURL: URL(string: "https://example.test/api/v1.0/")!, cookieProvider: { [] },
            featureEnabled: { true }, isOffline: { false }, serverConfigProvider: { nil },
            socketFactory: { _ in FakeWebSocket() })
        let a = try await makeClient()
        manager.addLifecycleObserver(a.binding)
        let socket = try await connect(a, to: server)
        try await server.settle { self.a(isLive: a) }
        manager.suspend()
        await waitUntil { socket.cancelCloseCode == .goingAway }
        XCTAssertTrue(try XCTUnwrap(a.session.input).replace(range: NSRange(location: 0, length: 6), with: ""))
        let drained = await a.session.settle()
        XCTAssertTrue(drained)
        await waitAndConfirmNever { server.sockets.count > 1 }
        manager.resume()
        try await server.settle { self.serverText(server) == "paragraph." }
        XCTAssertEqual(server.sockets.count, 2)
    }

    /// Cold relaunch: what an ended process journaled but never sent is
    /// offered by the next launch's handshake.
    func testColdRelaunchOffersWhatTheEndedProcessJournaled() async throws {
        let server = try FakeYServer(state: seedState())
        defer { server.doc.destroy() }
        let first = try await makeClient()
        try await type("K", first, Self.firstID, at: 0)
        await first.registry.closeAll().value
        let relaunched = try await makeClient(relaunching: first)
        XCTAssertEqual(texts(relaunched.session)[0], "KFirst paragraph.")
        try await connect(relaunched, to: server)
        try await server.settle { self.serverText(server) == "KFirst paragraph." }
    }

    /// The server applied an update (live, or an HTTP save whose answer was
    /// lost) that the client still holds unacknowledged: the next handshake
    /// sends it again and nothing is duplicated.
    func testAnAppliedButUnacknowledgedEditIsNeverDuplicated() async throws {
        let server = try FakeYServer(state: seedState())
        defer { server.doc.destroy() }
        let a = try await makeClient()
        // HTTP half-land: the server took the bytes, the client kept its outbox.
        try await type("H", a, Self.firstID, at: 0)
        let journaled = try XCTUnwrap(a.store.restore(for: a.scope)).updates
        for update in journaled { try server.applyUnrelayed(update) }
        let socket = try await connect(a, to: server)
        try await server.settle { self.a(isLive: a) }
        // Live: applied by the server, then the socket drops.
        try await type("L", a, Self.firstID, at: 1)
        try await server.settle { self.serverText(server) == "HLFirst paragraph." }
        socket.failTransport()
        try await server.settle { server.sockets.count == 2 && self.a(isLive: a) }
        try await Task.sleep(for: .milliseconds(100))
        try server.pump()
        XCTAssertEqual(serverText(server), "HLFirst paragraph.")
        XCTAssertEqual(texts(a.session)[0], "HLFirst paragraph.")
        XCTAssertEqual(try outboxCount(a), 2, "HTTP still owns the acknowledgment")
    }

    /// Server rejection and a permission change both close with 1000: the
    /// binding asks for the ability. A writer dials again; a reader answer
    /// makes the scope read-only and no socket opens.
    func testA1000CloseAsksForTheAbilityAndAReaderStopsLive() async throws {
        let server = try FakeYServer(state: seedState())
        defer { server.doc.destroy() }
        let a = try await makeClient()
        let reader = Locked(false)
        let asked = Locked(0)
        let socket = try await connect(
            a, to: server,
            isReader: {
                asked.update { $0 += 1 }
                return reader.value
            }, becameReader: { a.registry.setWritable(nil, for: a.scope) })
        try await server.settle { self.a(isLive: a) }
        try await type("w", a, Self.firstID, at: 0)
        socket.serverClose(code: .normalClosure)
        try await server.settle { server.sockets.count == 2 && self.a(isLive: a) }
        XCTAssertEqual(asked.value, 1, "a writer is asked once and dials again")

        reader.value = true
        try XCTUnwrap(server.sockets.last).serverClose(code: .normalClosure)
        await waitUntil { asked.value == 2 }
        let drained = await a.session.settle()
        XCTAssertTrue(drained)
        XCTAssertFalse(a.session.state.writable, "the reader answer made the replica read-only")
        await waitAndConfirmNever { server.sockets.count > 2 }
        XCTAssertEqual(try outboxCount(a), 1, "what was journaled stays for HTTP")
        XCTAssertEqual(serverText(server), "wFirst paragraph.")
    }

    /// 401 re-authentication: while the open is not current (a cookie
    /// handover forgot the account) a drop dials nothing; once current again,
    /// the path's return dials and the handshake delivers what was typed.
    func testNothingDialsDuringReauthenticationAndTheEditsArriveAfter() async throws {
        let current = Locked(true)
        let server = try FakeYServer(state: seedState())
        defer { server.doc.destroy() }
        let a = try await makeClient()
        let socket = try await connect(a, to: server, isCurrent: { current.value })
        try await server.settle { self.a(isLive: a) }
        current.value = false
        socket.failTransport()
        try await type("r", a, Self.firstID, at: 0)
        await waitAndConfirmNever { server.sockets.count > 1 }
        current.value = true
        a.binding.collaborationResumed()
        try await server.settle { self.serverText(server) == "rFirst paragraph." }
    }

    /// The per-open budget: a peer that keeps sending refused updates between
    /// good handshakes stops live after `recoveryBudget` redials, instead of
    /// driving reconnects forever.
    func testRefusedUpdatesBetweenGoodHandshakesExhaustTheOpensBudget() async throws {
        let server = try FakeYServer(state: seedState())
        defer { server.doc.destroy() }
        let a = try await makeClient()
        try await connect(a, to: server)
        try await server.settle { self.a(isLive: a) }
        let web = try peer(of: server)
        defer { web.destroy() }
        let writer = BlockNoteWriter(doc: web)
        let budget = NativeCollaborationBinding.recoveryBudget
        for round in 0...budget {
            guard !a.binding.isStopped else { break }
            let socket = try XCTUnwrap(server.sockets.last)
            let first = try writer.replaceText(block: Self.thirdID, range: 0..<0, with: "x")
            let second = try writer.replaceText(block: Self.thirdID, range: 1..<1, with: "y")
            try server.applyUnrelayed(first)
            try server.applyUnrelayed(second)
            socket.deliver(message: FakeYServer.frame(.update, second))
            if round < budget {
                try await server.settle { server.sockets.count == round + 2 && self.a(isLive: a) }
            }
        }
        await waitUntil { a.binding.isStopped }
        XCTAssertEqual(server.sockets.count, budget + 1, "\(budget) recoveries, then live stops")
        XCTAssertFalse(a.session.state.frozen)
    }

    // MARK: - Helpers

    private nonisolated static func projectionOf(_ doc: YDoc) -> [BlockSnapshot] {
        NativeBlockProjection.project(doc).blocks.map(BlockSnapshot.init)
    }

    private func a(isLive client: Client) -> Bool { client.binding.session?.state == .live }

    /// The client's journal replayed into a fresh replica, as a cold relaunch does.
    private func makeClientRestoring(_ client: Client) throws -> [BlockSnapshot] {
        let restored = try XCTUnwrap(client.store.restore(for: client.scope))
        let replica = YDoc(clientID: 99)
        defer { replica.destroy() }
        try replica.applyUpdate(YUpdateDecoder.decode(restored.checkpoint), origin: .remote)
        for update in restored.updates { try replica.applyUpdate(YUpdateDecoder.decode(update), origin: .remote) }
        XCTAssertNil(replica.store.pendingStructs)
        XCTAssertNil(replica.store.pendingDs)
        return projection(replica)
    }
}
