import UIKit
import XCTest

@testable import Schrift

/// PR10a: collaborators' awareness on the native editor. Peers' cursors are
/// untrusted wire data resolved on the replica session; our own selection is
/// published as directed relative positions over the scope's one socket.
/// Real `NativeTextView`s over restored durable replicas; sockets are fakes.
@MainActor
final class NativeAwarenessTests: NativeEditingTestCase {
    private final class TestClock {
        var now = ContinuousClock.now
    }

    private let clock = TestClock()

    private func controller(
        _ harness: Harness, timeout: Duration = .seconds(30), publishInterval: Duration = .milliseconds(100)
    ) throws -> NativeAwarenessController {
        let clock = self.clock
        let awareness = NativeAwarenessController(
            replica: try XCTUnwrap(harness.session.replica), timeout: timeout, publishInterval: publishInterval,
            now: { clock.now })
        harness.session.showAwareness(awareness)
        return awareness
    }

    /// A relative position a web peer would publish for `offset` in `blockID`.
    private func position(
        _ harness: Harness, _ blockID: String, _ offset: Int, assoc: Int = 0
    ) async throws -> YRelativePositionJSON {
        try await unwrapped(
            harness.engine { $0.awarenessPosition(EditorPosition(blockID: blockID, offset: offset, assoc: assoc)) })
    }

    private func entry(_ id: UInt, clock: UInt = 1, name: String = "Web Peer", cursor: AwarenessCursor?)
        -> AwarenessEntry
    {
        AwarenessEntry(
            clientID: id, clock: clock,
            stateJSON: LocalAwarenessState(name: name, color: "#123456", cursor: cursor).json(wireProtocol: .yWebSocket)
        )
    }

    private func caret(_ blockID: String, _ offset: Int, assoc: Int = 0) -> PeerCursorPlace {
        .text(EditorPosition(blockID: blockID, offset: offset, assoc: assoc))
    }

    @discardableResult
    private func host(_ view: NativeTextView, width: CGFloat = 390, height: CGFloat = 2_000) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        return window
    }

    /// The overlay's painted marks, by accessibility identifier.
    private func painted(_ harness: Harness) -> Set<String> {
        harness.view.layoutIfNeeded()
        return Set(harness.view.cursorOverlay.subviews.compactMap(\.accessibilityIdentifier))
    }

    /// Everything a hostile cursor could have touched: the root names, the
    /// store's state and the write latch.
    private func replicaFingerprint(_ harness: Harness) async throws -> String {
        let doc = try await unwrapped(
            harness.session.replicaDoc { doc in
                "\(doc.share.keys.sorted())|\(YStateEncoder.encodeStateVector(doc).base64EncodedString())"
            })
        let failed = try await unwrapped(harness.engine { $0.nativeWriteFailed })
        return "\(doc)|\(failed)"
    }

    // MARK: - Resolution

    /// A web peer's backward selection keeps its direction, and each endpoint
    /// its affinity: at the end of a paragraph, assoc 0 follows appended text
    /// and assoc -1 stays before it.
    func testBackwardSelectionKeepsDirectionAndAffinityThroughEdits() async throws {
        let harness = try await makeHarness()
        let awareness = try controller(harness)
        let anchor = try await position(harness, Self.firstID, 16, assoc: 0)
        let head = try await position(harness, Self.firstID, 16, assoc: -1)
        let second = try await position(harness, Self.secondID, 3)
        awareness.receive([
            entry(7, cursor: AwarenessCursor(anchor: anchor, head: head)),
            entry(
                8, name: "Other",
                cursor: AwarenessCursor(anchor: try await position(harness, Self.secondID, 10), head: second)),
        ])
        await waitUntil { awareness.places.count == 2 }
        XCTAssertEqual(
            awareness.places[8], PeerCursorPlaces(anchor: caret(Self.secondID, 10), head: caret(Self.secondID, 3)))
        XCTAssertEqual(awareness.peers.map(\.name), ["Web Peer", "Other"])

        setSelection(harness, NSRange(location: try location(harness.session, Self.firstID, 16), length: 0))
        let typed = await harness.run {
            harness.input.typeKey("X")
            harness.input.typeKey("Y")
            return true
        }
        XCTAssertTrue(typed)
        await waitUntil { awareness.places[7]?.anchor == self.caret(Self.firstID, 18) }
        XCTAssertEqual(
            awareness.places[7]?.head, caret(Self.firstID, 16, assoc: -1), "assoc -1 stays before the insertion")
        XCTAssertEqual(awareness.places[8]?.head, caret(Self.secondID, 3), "another block is untouched")
        try await assertConsistent(harness, localCommands: 2)
        await harness.close()
    }

    /// Oversized states are ignored, malformed cursors hide only the cursor,
    /// and nothing a peer sends reaches the replica or its fail-safe.
    func testMalformedAndOversizedPayloadsNeverTouchTheReplica() async throws {
        let harness = try await makeHarness()
        let awareness = try controller(harness)
        let before = try await replicaFingerprint(harness)
        let huge =
            "{\"user\":{\"name\":\"Big\",\"color\":\"#000\"},\"pad\":\"\(String(repeating: "x", count: 9_000))\"}"
        let malformed = [
            "{\"user\":{\"name\":\"A\",\"color\":\"#0\"},\"cursor\":{\"anchor\":\"x\",\"head\":1}}",
            "{\"user\":{\"name\":\"B\",\"color\":\"#0\"},\"cursor\":{\"anchor\":{},\"head\":{}}}",
            "{\"user\":{\"name\":\"C\",\"color\":\"#0\"},\"cursor\":{\"anchor\":{\"item\":{\"client\":-1,\"clock\":0}},"
                + "\"head\":{\"item\":{\"client\":1,\"clock\":99999999999999999999999}}}}",
            "{\"user\":{\"name\":\"D\",\"color\":\"#0\"},\"cursor\":{\"anchor\":{\"item\":{\"client\":1,\"clock\":"
                + "18446744073709551615},\"assoc\":0},\"head\":{\"type\":{\"client\":4242,\"clock\":7}}}}",
            "{\"user\":{\"name\":\"E\",\"color\":\"#0\"},\"cursor\":{\"anchor\":{\"item\":{\"client\":1,\"clock\":3},"
                + "\"assoc\":9223372036854775807},\"head\":{\"type\":{\"client\":1,\"clock\":0},\"assoc\":-5}}}",
            "{\"user\":{\"name\":\"F\",\"color\":\"#0\"},\"cursor\":" + String(repeating: "[", count: 100)
                + String(repeating: "]", count: 100) + "}",
            "{\"user\":{\"name\":\"G\",\"color\":\"#0\"},\"cursor\":" + String(repeating: "[", count: 3_000)
                + String(repeating: "]", count: 3_000) + "}",
        ]
        awareness.receive(
            [
                AwarenessEntry(clientID: 1, clock: 1, stateJSON: huge),
                AwarenessEntry(clientID: 2, clock: 1, stateJSON: "{"),
            ]
                + malformed.enumerated().map { AwarenessEntry(clientID: UInt(10 + $0), clock: 1, stateJSON: $1) })
        // G nests past the JSON parser's depth limit: dropped or kept, never a crash.
        XCTAssertEqual(
            awareness.peers.map(\.name).filter { $0 != "G" }, ["A", "B", "C", "D", "E", "F"], "kept, without a cursor")
        // Resolution of what did parse runs on the replica, in mailbox order.
        await harness.settle()
        await waitUntil { awareness.places.count == 3 }
        XCTAssertEqual(awareness.places[11], PeerCursorPlaces(anchor: nil, head: nil), "an empty position")
        XCTAssertEqual(awareness.places[13]?.anchor, nil, "a clock past the store")
        XCTAssertNil(awareness.places[13]?.head, "a type no client wrote")
        XCTAssertNotNil(awareness.places[14]?.anchor, "an in-range item still resolves")
        let after = try await replicaFingerprint(harness)
        XCTAssertEqual(after, before)
        let typed = await harness.run {
            harness.input.typeKey("!")
            return true
        }
        XCTAssertTrue(typed, "typing goes on")
        await harness.close()
    }

    /// An unknown root name is never resolved (yjs's `doc.get` would create
    /// it): the peer stays, its cursor hides, `share` keeps its keys.
    func testUnknownRootNamesAreNeverCreated() async throws {
        let harness = try await makeHarness()
        let awareness = try controller(harness)
        let before = try await replicaFingerprint(harness)
        let evil = YRelativePositionJSON(type: nil, tname: "evil-root", item: nil, assoc: 0)
        let fragment = YRelativePositionJSON(type: nil, tname: BlockNoteYjs.fragmentField, item: nil, assoc: 0)
        awareness.receive([
            entry(7, cursor: AwarenessCursor(anchor: evil, head: evil)),
            entry(8, name: "Root", cursor: AwarenessCursor(anchor: fragment, head: evil)),
        ])
        await waitUntil { awareness.places.count == 2 }
        XCTAssertEqual(awareness.places[7], PeerCursorPlaces(anchor: nil, head: nil))
        XCTAssertEqual(awareness.places[8], PeerCursorPlaces(anchor: nil, head: nil), "the root itself is no block")
        XCTAssertEqual(awareness.peers.count, 2)
        let after = try await replicaFingerprint(harness)
        XCTAssertEqual(after, before)
        XCTAssertFalse(after.contains("evil-root"))
        await harness.close()
    }

    /// Two peers; deleting one's block hides only that cursor, and the peer
    /// stays present.
    func testDeletingAPeersBlockHidesItsCursorButKeepsThePeer() async throws {
        let harness = try await makeHarness()
        let awareness = try controller(harness)
        let third = try await position(harness, Self.thirdID, 4)
        let first = try await position(harness, Self.firstID, 2)
        awareness.receive([
            entry(7, cursor: AwarenessCursor(anchor: third, head: third)),
            entry(8, name: "Other", cursor: AwarenessCursor(anchor: first, head: first)),
        ])
        await waitUntil { awareness.places[7]?.head != nil && awareness.places[8]?.head != nil }
        setSelection(harness, NSRange(location: try location(harness.session, Self.thirdID, 1), length: 0))
        let deleted = await harness.run { harness.input.performBlockAction(.delete) }
        XCTAssertTrue(deleted)
        await waitUntil { awareness.places[7]?.head == nil }
        XCTAssertEqual(awareness.places[8]?.head, caret(Self.firstID, 2))
        XCTAssertEqual(awareness.peers.count, 2, "an unresolvable cursor keeps its peer")
        await harness.close()
    }

    // MARK: - Lifetime

    /// y-protocols' clock rules, expiry after the timeout and a socket's end.
    func testStaleClocksExpiryAndDisconnect() async throws {
        let harness = try await makeHarness()
        let awareness = try controller(harness)
        awareness.receive([entry(7, clock: 2, name: "Newer", cursor: nil)])
        awareness.receive([entry(7, clock: 1, name: "Older", cursor: nil)])
        awareness.receive([entry(7, clock: 2, name: "Same clock", cursor: nil)])
        XCTAssertEqual(awareness.peers.map(\.name), ["Newer"], "an older or equal clock is stale")
        awareness.receive([AwarenessEntry(clientID: 7, clock: 2, stateJSON: "null")])
        XCTAssertTrue(awareness.peers.isEmpty, "null at the same clock removes")

        awareness.receive([entry(8, cursor: nil), entry(9, cursor: nil)])
        clock.now += .seconds(20)
        awareness.receive([entry(9, clock: 2, cursor: nil)])
        clock.now += .seconds(15)
        awareness.sweep()
        XCTAssertEqual(awareness.peers.map(\.clientID), [9], "only the renewed peer stays")
        clock.now += .seconds(31)
        awareness.sweep()
        XCTAssertTrue(awareness.peers.isEmpty)

        awareness.receive([entry(8, clock: 5, cursor: nil)])
        awareness.clear()
        XCTAssertTrue(awareness.peers.isEmpty, "a socket's end drops everyone")
        XCTAssertTrue(awareness.places.isEmpty)
        await harness.close()
    }

    /// At most `maxPeers` are tracked; more never grow the table.
    func testThePeerTableIsBounded() async throws {
        let harness = try await makeHarness()
        let awareness = try controller(harness)
        awareness.receive((1...200).map { entry(UInt($0), name: "P\($0)", cursor: nil) })
        XCTAssertEqual(awareness.peers.count, NativeAwarenessController.maxPeers)
        await harness.close()
    }

    // MARK: - Painting

    /// Only cursors in TextKit's viewport are painted; scrolling and a width
    /// change re-place them. The overlay never takes touches.
    func testOverlayPaintsOnlyVisibleCursorsAcrossScrollAndRotation() async throws {
        let blocks = (0..<60).map { paragraph("p\($0)", "Paragraph \($0) with a few words to wrap.") }
        let harness = try await makeHarness(blocks)
        let window = host(harness.view, height: 400)
        let awareness = try controller(harness)
        let top = try await position(harness, "p0", 3)
        let bottom = try await position(harness, "p59", 3)
        awareness.receive([
            entry(7, cursor: AwarenessCursor(anchor: top, head: top)),
            entry(8, name: "Far", cursor: AwarenessCursor(anchor: bottom, head: bottom)),
        ])
        await waitUntil { awareness.places.count == 2 }
        XCTAssertEqual(painted(harness), ["nativeEditor.peerCursor.7"])
        XCTAssertFalse(harness.view.cursorOverlay.isUserInteractionEnabled)

        // TextKit 2 estimates the height: scroll to the end until it settles.
        for _ in 0..<8 {
            let bottom = max(0, harness.view.contentSize.height - harness.view.bounds.height)
            harness.view.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            harness.view.layoutIfNeeded()
        }
        XCTAssertEqual(painted(harness), ["nativeEditor.peerCursor.8"])

        harness.view.setContentOffset(.zero, animated: false)
        XCTAssertEqual(painted(harness), ["nativeEditor.peerCursor.7"])
        window.frame = CGRect(x: 0, y: 0, width: 700, height: 400)
        harness.view.frame = window.bounds
        XCTAssertEqual(painted(harness), ["nativeEditor.peerCursor.7"], "rotation re-places it")
        XCTAssertEqual(harness.view.cursorOverlay.frame, harness.view.bounds)
        await harness.close()
    }

    /// A peer in folded content badges the toggle that owns it until it is
    /// opened; a preview (math) or a leaf (image) badges its own block.
    func testFoldedAndStructuredContentBadgesItsOwner() async throws {
        let image = BlockNoteBlock(
            node: "image",
            props: [
                ("backgroundColor", .string("default")), ("caption", .string("")), ("name", .string("a.png")),
                ("showPreview", .bool(true)), ("textAlignment", .string("left")),
                ("url", .string("https://example.test/a.png")),
            ], runs: [], id: "img")
        let harness = try await makeHarness([
            paragraph("intro", "Intro"),
            BlockNoteBlock(
                node: "toggleListItem", props: Self.paragraphProps, runs: [InlineRun("Title")], id: "t",
                children: [paragraph("c1", "Hidden child")]),
            BlockNoteBlock(node: "mathBlock", props: [], runs: [InlineRun("x^2")], id: "math"),
            image,
            paragraph("after", "After"),
        ])
        host(harness.view)
        let awareness = try controller(harness)
        let folded = try await position(harness, "c1", 2)
        let math = try await position(harness, "math", 1)
        let found = await harness.session.replicaDoc { doc -> YRelativePositionJSON? in
            BlockIndex(doc: doc).entries["img"].flatMap {
                try? YRelativePosition.fromTypeIndex($0.container, index: 0).json
            }
        }
        let leaf = try XCTUnwrap(found ?? nil)
        awareness.receive([
            entry(7, cursor: AwarenessCursor(anchor: folded, head: folded)),
            entry(8, name: "Math", cursor: AwarenessCursor(anchor: math, head: math)),
            entry(9, name: "Leaf", cursor: AwarenessCursor(anchor: leaf, head: leaf)),
        ])
        await waitUntil { awareness.places.count == 3 }
        XCTAssertEqual(awareness.places[7]?.head, caret("c1", 2), "resolved on the replica, folded or not")
        XCTAssertEqual(awareness.places[9]?.head, .block("img"))
        XCTAssertEqual(
            painted(harness), ["nativeEditor.peerBadge.7", "nativeEditor.peerBadge.8", "nativeEditor.peerBadge.9"])

        harness.session.surface.setExpanded("t", true)
        XCTAssertEqual(
            painted(harness), ["nativeEditor.peerCursor.7", "nativeEditor.peerBadge.8", "nativeEditor.peerBadge.9"],
            "opened, the caret replaces the badge")
        await harness.close()
    }

    // MARK: - Publication

    private func awarenessFrames(_ socket: FakeWebSocket) -> [AwarenessEntry] {
        socket.sentFrames.compactMap { data in
            guard let message = try? CollaborationWireProtocol.yWebSocket.decode(data, documentName: ""),
                message.type == 1
            else { return nil }
            return try? AwarenessCodec.decodePayload(message.payload).first
        }
    }

    private func liveSession(
        _ socket: FakeWebSocket, canUpdate: Bool = true
    ) -> DocumentCollaborationSession {
        let session = DocumentCollaborationSession(
            documentName: "doc",
            transport: CollaborationTransport(socket: socket, wireProtocol: .yWebSocket, documentName: "doc"),
            localState: LocalAwarenessState(name: "Me", color: "#abcdef"), wireProtocol: .yWebSocket,
            canUpdate: canUpdate)
        session.start()
        return session
    }

    /// Our backward selection goes out as directed anchor/head relative
    /// positions beside `user`, throttled: the latest of a burst wins.
    func testLocalSelectionIsPublishedDirectedAndThrottled() async throws {
        let harness = try await makeHarness()
        let awareness = try controller(harness, publishInterval: .milliseconds(400))
        let socket = FakeWebSocket()
        let live = liveSession(socket)
        awareness.session = live
        await waitUntil { !self.awarenessFrames(socket).isEmpty }

        try select(harness, from: (Self.secondID, 10), to: (Self.secondID, 3))
        await harness.settle()
        await waitUntil {
            self.awarenessFrames(socket).last.flatMap { AwarenessCursor.parse(stateJSON: $0.stateJSON) } != nil
        }
        let published = try XCTUnwrap(awarenessFrames(socket).last)
        let cursor = try XCTUnwrap(AwarenessCursor.parse(stateJSON: published.stateJSON))
        XCTAssertEqual(
            CollaborationPeer(clientID: 1, stateJSON: published.stateJSON, wireProtocol: .yWebSocket)?.name, "Me")
        let places = try await unwrapped(
            harness.engine { PeerCursorPlaces(anchor: $0.peerPlace(cursor.anchor), head: $0.peerPlace(cursor.head)) })
        XCTAssertEqual(places.anchor?.blockID, Self.secondID)
        if case .text(let anchor)? = places.anchor, case .text(let head)? = places.head {
            XCTAssertEqual([anchor.offset, head.offset], [10, 3], "direction kept")
        } else {
            XCTFail("both endpoints are carets")
        }

        // A burst inside the interval: the first change waits, the last wins.
        let count = awarenessFrames(socket).count
        let clocks = awarenessFrames(socket).map(\.clock)
        setSelection(harness, NSRange(location: try location(harness.session, Self.firstID, 1), length: 0))
        setSelection(harness, NSRange(location: try location(harness.session, Self.thirdID, 2), length: 0))
        await harness.settle()
        let expected = try await unwrapped(harness.engine { $0.awarenessCursor() })
        await waitUntil(timeout: 3) {
            self.awarenessFrames(socket).last.flatMap { AwarenessCursor.parse(stateJSON: $0.stateJSON) } == expected
        }
        XCTAssertEqual(awarenessFrames(socket).count, count + 1, "one frame for the burst")
        XCTAssertGreaterThan(awarenessFrames(socket).last?.clock ?? 0, clocks.max() ?? 0, "a strictly higher clock")
        live.stop()
        await harness.close()
    }

    /// A reader publishes nothing: its replica reports no cursor, and a
    /// reader's socket sends no awareness however its cursor changes.
    func testReadersPublishNoAwareness() async throws {
        let reader = try await NativeEditorSession.seed(state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: 1))
        let replica = try XCTUnwrap(reader.replica)
        let awareness = NativeAwarenessController(replica: replica, publishInterval: .zero)
        let selection = EditorSelection(
            anchor: EditorPosition(blockID: Self.firstID, offset: 1),
            head: EditorPosition(blockID: Self.firstID, offset: 4))
        replica.mailbox.post(.select(surfaceID: reader.surfaceID, seq: 1, baseRevision: reader.revision, selection))
        await reader.settle()
        let engineCursor = await reader.engine { $0.awarenessCursor() }
        XCTAssertNotNil(engineCursor ?? nil, "the engine holds a selection")
        await waitAndConfirmNever { awareness.localCursor != nil }

        let socket = FakeWebSocket()
        let live = liveSession(socket, canUpdate: false)
        awareness.session = live
        live.updateLocalCursor(try XCTUnwrap(engineCursor ?? nil))
        await waitAndConfirmNever { !self.awarenessFrames(socket).isEmpty }
        live.stop()
        await reader.close().value
    }

    // MARK: - The binding's socket

    /// Awareness rides the live binding's socket: our user goes out with the
    /// handshake, a peer's frame shows them, and the socket's end clears them.
    func testAwarenessRidesTheBindingSocketAndEndsWithIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = ReplicaScope(
            serverOrigin: "https://example.test", ownerUserID: UUID(), org: "docs", documentID: UUID())
        let store = ReplicaStore(directory: directory)
        _ = try store.create(
            for: scope, checkpoint: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID))
        let registry = NativeSessionRegistry()
        registry.liveBackoff = .init(base: .seconds(30), cap: .seconds(30), stableAfter: .seconds(30))
        let session = try await unwrapped(registry.open(store: store, scope: scope))
        let binding = try unwrapped(registry.liveBinding(for: scope))
        session.showAwareness(binding.awareness)
        var sockets: [FakeWebSocket] = []
        binding.connect(
            dial: {
                let socket = FakeWebSocket()
                sockets.append(socket)
                return CollaborationTransport(socket: socket, wireProtocol: .yWebSocket, documentName: "doc")
            }, wireProtocol: .yWebSocket, documentName: "doc", isCurrent: { true },
            localState: LocalAwarenessState(name: "Me", color: "#abcdef"))
        await waitUntil { sockets.first.map { !self.awarenessFrames($0).isEmpty } == true }
        let socket = try XCTUnwrap(sockets.first)
        let own = try XCTUnwrap(awarenessFrames(socket).first)
        XCTAssertEqual(
            CollaborationPeer(clientID: own.clientID, stateJSON: own.stateJSON, wireProtocol: .yWebSocket)?.name, "Me")

        let frame = CollaborationWireProtocol.yWebSocket.encode(
            HocuspocusMessage(
                documentName: "", type: .awareness,
                payload: AwarenessCodec.encodePayload([entry(77, cursor: nil), own])))
        socket.deliver(message: frame)
        await waitUntil { binding.awareness.peers.map(\.clientID) == [77] }
        XCTAssertEqual(sockets.count, 1, "no second socket")

        socket.failTransport()
        await waitUntil { binding.awareness.peers.isEmpty }
        await registry.closeAll().value
    }
}
