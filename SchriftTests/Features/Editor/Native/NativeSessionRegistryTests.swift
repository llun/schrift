import Foundation
import UIKit
import XCTest

@testable import Schrift

/// PR08c: one replica session per scope, shared by every surface open on it,
/// with a serial lifecycle per scope, and bounded delivery. Real replica
/// sessions over durable stores, fixed seeds, latches instead of sleeps.
@MainActor
final class NativeSessionRegistryTests: NativeEditingTestCase {
    private struct Fixture {
        let registry: NativeSessionRegistry
        let store: ReplicaStore
        let scope: ReplicaScope
        let log: WriteLog
    }

    private func makeFixture(
        registry: NativeSessionRegistry = NativeSessionRegistry(), owner: UUID = UUID(),
        interrupt: (@Sendable (ReplicaStore.Operation, ReplicaStore.Boundary) throws -> Void)? = nil
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scope = ReplicaScope(
            serverOrigin: "https://example.test", ownerUserID: owner, org: "docs", documentID: UUID())
        let store = ReplicaStore(directory: directory, interrupt: interrupt)
        _ = try store.create(
            for: scope, checkpoint: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID))
        addTeardownBlock {
            await registry.closeAll().value
            try? FileManager.default.removeItem(at: directory)
        }
        return Fixture(registry: registry, store: store, scope: scope, log: WriteLog())
    }

    /// A typing surface leased from the registry; the scope's journal is
    /// installed once, by its first surface.
    private func open(
        _ fixture: Fixture, hooks: DocumentReplicaSession.Hooks = .init(), scheduler: NativeReplicaSaveScheduler? = nil
    ) async throws -> NativeEditorSession {
        let session = try await unwrapped(
            fixture.registry.open(store: fixture.store, scope: fixture.scope, hooks: hooks))
        let (store, scope, log) = (fixture.store, fixture.scope, fixture.log)
        fixture.registry.setWritable(
            { command, update in
                log.record(command, blocks: [])
                try store.append(
                    update, for: scope, commandID: command.id, baseRevision: command.baseRevision, origin: .local)
            }, for: scope)
        session.enableTyping(persist: nil, scheduler: scheduler)
        return session
    }

    private func caret(_ session: NativeEditorSession, _ blockID: String, _ offset: Int) throws {
        session.textView.selectedRange = NSRange(location: try location(session, blockID, offset), length: 0)
        session.input?.textViewDidChangeSelection(session.textView)
    }

    private func settle(_ sessions: NativeEditorSession..., file: StaticString = #filePath, line: UInt = #line) async {
        for session in sessions {
            let drained = await session.settle()
            XCTAssertTrue(drained, "the session settled", file: file, line: line)
        }
    }

    /// The journal replayed into a fresh replica.
    private func replayed(_ fixture: Fixture) throws -> [BlockSnapshot] {
        let restored = try XCTUnwrap(fixture.store.restore(for: fixture.scope))
        let replica = YDoc(clientID: 99)
        defer { replica.destroy() }
        try replica.applyUpdate(YUpdateDecoder.decode(restored.checkpoint), origin: .remote)
        for update in restored.updates { try replica.applyUpdate(YUpdateDecoder.decode(update), origin: .remote) }
        return projection(replica)
    }

    private var nextPeer: UInt32 = 7

    private func peerEdit(_ edit: (BlockNoteWriter) throws -> Data) throws -> Data {
        nextPeer += 1
        let peer = try makeDoc(clientID: nextPeer)
        defer { peer.destroy() }
        return try edit(BlockNoteWriter(doc: peer))
    }

    private func diskGate(_ disk: Latch) -> @Sendable (ReplicaStore.Operation, ReplicaStore.Boundary) throws -> Void {
        { operation, boundary in
            if operation == .append, boundary == .payloadWritten { disk.pass() }
        }
    }

    // 1
    func testTwoOpensOfOneScopeShareOneReplicaAndFanOut() async throws {
        let fixture = try makeFixture()
        let a = try await open(fixture)
        let b = try await open(fixture)
        XCTAssertTrue(a.replica === b.replica, "one replica per scope")
        XCTAssertEqual(fixture.registry.openScopes, [fixture.scope])
        XCTAssertEqual(fixture.registry.surfaces(of: fixture.scope).count, 2)
        try caret(a, Self.firstID, 5)
        a.textView.insertText("A")
        await settle(a, b)
        try caret(b, Self.firstID, 0)
        b.textView.insertText("B")
        await settle(a, b)
        for session in [a, b] {
            XCTAssertEqual(texts(session)[0], "BFirstA paragraph.", "every surface shows every change")
        }
        // The one engine selection is B's now: A's caret follows B's insertion
        // instead of jumping to B's caret.
        XCTAssertEqual(a.textView.selectedRange, NSRange(location: 7, length: 0))
        XCTAssertEqual(b.textView.selectedRange, NSRange(location: 1, length: 0))
        XCTAssertEqual(fixture.log.commands.count, 2, "one journal for both surfaces")
        let replay = try replayed(fixture)
        XCTAssertEqual(a.surface.blocks, replay)
        XCTAssertEqual(b.surface.blocks, replay)
        // Read-only for both at once: a key becomes a recovery entry, nothing is journaled.
        XCTAssertFalse(
            fixture.registry.setWritable({ _, _ in }, for: fixture.scope), "the scope has its journal already")
        XCTAssertTrue(fixture.registry.setWritable(nil, for: fixture.scope))
        await settle(a, b)
        try caret(a, Self.thirdID, 0)
        a.textView.insertText("q")
        await settle(a, b)
        XCTAssertEqual(a.input?.composition.pendingRecoveries.map(\.text), ["q"])
        XCTAssertEqual(texts(b)[2], "Third paragraph.")
        XCTAssertEqual(fixture.log.commands.count, 2)
    }

    // 2
    func testOpensDuringARestoreShareIt() async throws {
        let fixture = try makeFixture()
        async let first = fixture.registry.open(store: fixture.store, scope: fixture.scope)
        async let second = fixture.registry.open(store: fixture.store, scope: fixture.scope)
        let (a, b) = try await (first, second)
        XCTAssertNotNil(a)
        XCTAssertTrue(a?.replica === b?.replica, "the second open waited for the first's restore")
        XCTAssertNotEqual(a?.surfaceID, b?.surfaceID)
        XCTAssertEqual(fixture.registry.surfaces(of: fixture.scope).count, 2)
    }

    // 3
    func testClosingOneSurfaceKeepsTheReplicaAndTheLastClosesIt() async throws {
        let fixture = try makeFixture()
        let a = try await open(fixture)
        let b = try await open(fixture)
        let replica = try XCTUnwrap(a.replica)
        await a.close().value
        XCTAssertTrue(a.isClosed)
        XCTAssertEqual(fixture.registry.openScopes, [fixture.scope], "B still holds the replica")
        try caret(b, Self.secondID, 0)
        b.textView.insertText("b")
        await settle(b)
        XCTAssertEqual(fixture.log.commands.count, 1, "B journals after A left")
        XCTAssertEqual(texts(b)[1], "bSecond paragraph has bold words inside it.")
        await b.close().value
        XCTAssertTrue(fixture.registry.openScopes.isEmpty)
        await replica.waitUntilClosed()
        XCTAssertEqual(try replayed(fixture), b.surface.blocks)
    }

    // 4
    func testAReopenWaitsForThePreviousReplicaOfItsScopeToClose() async throws {
        let disk = Latch()
        let fixture = try makeFixture(interrupt: diskGate(disk))
        addTeardownBlock { disk.open() }
        let a = try await open(fixture)
        try caret(a, Self.firstID, 0)
        a.textView.insertText("x")
        await waitUntil { disk.waiting == 1 }
        let closed = a.close()
        let reopened = Locked<Bool>(false)
        let reopen = Task { @MainActor in
            defer { reopened.value = true }
            return try await fixture.registry.open(store: fixture.store, scope: fixture.scope)
        }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertFalse(reopened.value, "never two replica sessions journaling into one scope")
        disk.open()
        await closed.value
        let b = try await unwrapped(reopen.value)
        XCTAssertFalse(b.replica === a.replica)
        XCTAssertEqual(texts(b)[0], "xFirst paragraph.", "the reopened replica has what the closed one journaled")
        XCTAssertEqual(fixture.log.commands.count, 1)
    }

    // 5
    func testEachSurfaceKeepsItsOwnEpoch() async throws {
        let fixture = try makeFixture()
        let a = try await open(fixture)
        let b = try await open(fixture)
        try caret(a, Self.firstID, 3)
        try caret(b, Self.thirdID, 0)
        // A peer deletes the characters around A's caret: A's key has no place to land.
        let peer = try peerEdit { try $0.replaceText(block: Self.firstID, range: 0..<6, with: "") }
        a.replica?.mailbox.post(.integrate(peer, reply: nil))
        a.textView.insertText("x")
        b.textView.insertText("y")
        await settle(a, b)
        XCTAssertEqual(a.input?.composition.pendingRecoveries.map(\.text), ["x"], "A's epoch ended")
        XCTAssertEqual(b.input?.composition.pendingRecoveries.map(\.text), [], "B's did not")
        for session in [a, b] {
            XCTAssertEqual(texts(session)[0], "paragraph.")
            XCTAssertEqual(texts(session)[2], "yThird paragraph.")
        }
        // A types again in its new epoch.
        try caret(a, Self.secondID, 0)
        a.textView.insertText("z")
        await settle(a, b)
        XCTAssertEqual(texts(b)[1], "zSecond paragraph has bold words inside it.")
        XCTAssertEqual(fixture.log.commands.count, 2)
        XCTAssertEqual(try replayed(fixture), a.surface.blocks)
    }

    // 6
    func testOneCompositionPerReplica() async throws {
        let fixture = try makeFixture()
        let a = try await open(fixture)
        let b = try await open(fixture)
        a.textView.selectedRange = NSRange(location: try location(a, Self.firstID, 0), length: 0)
        a.textView.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
        await settle(a, b)
        // The engine composes for A: B's begin is not captured, so B's commit
        // cannot land (it would have committed A's composition) and becomes B's
        // recovery entry.
        b.textView.selectedRange = NSRange(location: try location(b, Self.thirdID, 0), length: 0)
        b.textView.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0))
        await settle(a, b)
        b.textView.unmarkText()
        await settle(a, b)
        XCTAssertEqual(b.input?.composition.pendingRecoveries.map(\.text), ["中"])
        XCTAssertEqual(fixture.log.commands.count, 0)
        a.textView.unmarkText()
        await settle(a, b)
        for session in [a, b] {
            XCTAssertEqual(texts(session)[0], "日本First paragraph.")
            XCTAssertEqual(texts(session)[2], "Third paragraph.")
        }
        XCTAssertEqual(fixture.log.commands.count, 1, "A's commit, once")
        XCTAssertEqual(try replayed(fixture), b.surface.blocks)
    }

    // 7
    func testDrainAllHandsTheSharedSaveOverOnceSlowAppendsAreJournaled() async throws {
        let disk = Latch()
        let fixture = try makeFixture(interrupt: diskGate(disk))
        addTeardownBlock { disk.open() }
        let enqueued = Locked(0)
        let make = {
            NativeReplicaSaveScheduler(
                interval: .seconds(600),
                enqueue: {
                    enqueued.update { $0 += 1 }
                    return true
                }, onFailure: { _ in })
        }
        let session = try await unwrapped(fixture.registry.open(store: fixture.store, scope: fixture.scope))
        let scheduler = fixture.registry.scheduler(for: fixture.scope, make: make)
        let other = try await unwrapped(fixture.registry.open(store: fixture.store, scope: fixture.scope))
        XCTAssertTrue(fixture.registry.scheduler(for: fixture.scope, make: make) === scheduler, "one per scope")
        let (store, scope) = (fixture.store, fixture.scope)
        fixture.registry.setWritable(
            { command, update in
                try store.append(
                    update, for: scope, commandID: command.id, baseRevision: command.baseRevision, origin: .local)
            }, for: scope)
        session.enableTyping(persist: nil, scheduler: scheduler)
        other.enableTyping(persist: nil, scheduler: scheduler)
        try caret(session, Self.firstID, 0)
        session.textView.insertText("s")
        try caret(other, Self.thirdID, 0)
        other.textView.insertText("o")
        await waitUntil { disk.waiting == 1 }
        let drained = fixture.registry.drainAll()
        XCTAssertEqual(enqueued.value, 0, "nothing was journaled yet")
        disk.open()
        await drained.value
        await settle(session, other)
        XCTAssertEqual(enqueued.value, 1, "both surfaces' keys, handed over once")
        XCTAssertFalse(scheduler.hasPendingSave)
        XCTAssertEqual(try replayed(fixture), session.surface.blocks)
    }

    // 8
    func testCloseAllClosesMatchingScopesAndAnOpenInFlightReturnsNil() async throws {
        let registry = NativeSessionRegistry()
        let kept = try makeFixture(registry: registry)
        let leaving = try makeFixture(registry: registry, owner: UUID())
        let staying = try await open(kept)
        let attach = Latch()
        let hooks = DocumentReplicaSession.Hooks(onReplicaWork: { attach.pass() })
        addTeardownBlock { attach.open() }
        let inFlight = Task { @MainActor in
            try await registry.open(store: leaving.store, scope: leaving.scope, hooks: hooks)
        }
        await waitUntil { attach.waiting == 1 }
        XCTAssertEqual(registry.openScopes, [kept.scope, leaving.scope])
        // The account that owns `leaving` signs out.
        let closed = registry.closeAll { $0.ownerUserID == leaving.scope.ownerUserID }
        XCTAssertEqual(registry.openScopes, [kept.scope])
        attach.open()
        let late = try await inFlight.value
        XCTAssertNil(late, "a stale open never shows another account's replica")
        await closed.value
        try caret(staying, Self.firstID, 0)
        staying.textView.insertText("k")
        await settle(staying)
        XCTAssertEqual(kept.log.commands.count, 1, "the other scope keeps typing")
        XCTAssertFalse(staying.isClosed)
    }

    // 9
    func testSignOutDuringAPendingAppendJournalsItAndAReopenShowsIt() async throws {
        let disk = Latch()
        let fixture = try makeFixture(interrupt: diskGate(disk))
        addTeardownBlock { disk.open() }
        let checked = Locked(true)
        let offMain = DocumentReplicaSession.Hooks(onReplicaWork: {
            if Thread.isMainThread { checked.value = false }
        })
        let a = try await open(fixture, hooks: offMain)
        try caret(a, Self.firstID, 0)
        for key in ["s", "i", "g", "n"] { a.textView.insertText(key) }
        await waitUntil { disk.waiting == 1 }
        let closed = fixture.registry.closeAll()
        XCTAssertTrue(a.isClosed)
        XCTAssertFalse(a.textView.isEditable)
        disk.open()
        await closed.value
        XCTAssertEqual(fixture.log.commands.map(\.replacement), ["s", "i", "g", "n"], "posted before the close")
        XCTAssertTrue(fixture.registry.openScopes.isEmpty)
        let b = try await open(fixture, hooks: offMain)
        XCTAssertEqual(texts(b)[0], "signFirst paragraph.")
        XCTAssertEqual(try replayed(fixture), b.surface.blocks)
        XCTAssertTrue(checked.value, "no replica work ran on the main thread")
    }

    // MARK: - Bounded delivery

    /// Posts one message, retrying while the mailbox is full, with the main
    /// thread held (no surface can read its deliveries meanwhile).
    private func postHolding(_ replica: DocumentReplicaSession, _ message: () -> ReplicaMessage) {
        while !replica.mailbox.post(message()) { usleep(500) }
    }

    func testASurfacePastTheDeliveryBoundResyncsFromAResetWithoutLosingKeys() async throws {
        let handled = Locked(0)
        let mailbox = Latch(open: true)
        let harness = try await makeHarness(
            hooks: DocumentReplicaSession.Hooks(beforeMessage: {
                mailbox.pass()
                handled.update { $0 += 1 }
            }))
        addTeardownBlock {
            mailbox.open()
            await harness.close()
        }
        let session = harness.session
        let replica = try XCTUnwrap(session.replica)
        let log = PatchLog(session)
        try caret(session, Self.firstID, 5)
        await harness.settle()
        let before = log.deliveries.count
        // The main thread stays busy (no await) while the session answers far
        // more than the bound: drain markers and a few peer edits.
        let peers = try (0..<8).map { index in
            try peerEdit { try $0.replaceText(block: Self.thirdID, range: 0..<0, with: "\(index)") }
        }
        let start = handled.value
        let total = DocumentReplicaSession.deliveryBound + 40
        for index in 0..<total {
            if index % 40 == 0, index / 40 < peers.count {
                let peer = peers[index / 40]
                postHolding(replica) { .integrate(peer, reply: nil) }
            } else {
                postHolding(replica) { .drain(surfaceID: session.surfaceID, token: UUID()) }
            }
        }
        while handled.value < start + total { usleep(500) }
        // Keys typed on the stale display are answered while the surface is held
        // (the mailbox is in order: before the resync the surface will ask for).
        for key in ["a", "b", "c"] { harness.view.insertText(key) }
        // Hold the session before its next messages, so the reset is still on
        // its way when the next key is typed: that key is held, not lost.
        mailbox.close()
        await waitUntil { log.deliveries.contains { $0.resync == .requested } }
        let marker = try XCTUnwrap(log.deliveries.firstIndex { $0.resync == .requested })
        // The bound's worth waited (the first may have gone straight to the waiting consumer).
        let bound = DocumentReplicaSession.deliveryBound
        XCTAssertTrue((bound...bound + 1).contains(marker - before), "the marker takes the slot past the bound")
        XCTAssertTrue(session.input?.hasInFlightWork == true, "the reset is awaited")
        harness.view.insertText("d")
        XCTAssertFalse(text(of: try block(session, Self.firstID)).contains("d"), "held until the reset")
        mailbox.open()
        await harness.settle()
        XCTAssertTrue(log.didReset, "the rest came as one reset")
        XCTAssertEqual(text(of: try block(session, Self.firstID)), "Firstabcd paragraph.")
        let third = text(of: try block(session, Self.thirdID))
        XCTAssertTrue(third.hasSuffix("Third paragraph."))
        XCTAssertEqual(
            Set(third.prefix(peers.count)), Set((0..<peers.count).map { Character("\($0)") }), "every peer edit")
        XCTAssertEqual(harness.input.composition.pendingRecoveries.map(\.text), [], "no key became a recovery entry")
        // The new epoch types normally.
        harness.view.insertText("e")
        await harness.settle()
        XCTAssertEqual(text(of: try block(session, Self.firstID)), "Firstabcde paragraph.")
        try await assertConsistent(harness, localCommands: 5)
    }

    func testMarkedTextHoldingTheBoundAsksForAResetAndItsCommitLandsOnce() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let replica = try XCTUnwrap(session.replica)
        let log = PatchLog(session)
        try caret(session, Self.firstID, 0)
        session.textView.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
        await harness.settle()
        // Marked text owns the view: deliveries queue behind it, here past the bound.
        let peer = try peerEdit { try $0.replaceText(block: Self.thirdID, range: 0..<0, with: "P") }
        replica.mailbox.post(.integrate(peer, reply: nil))
        // In batches the surface reads as they come: its stream never holds the bound.
        for _ in 0..<3 {
            let seen = log.deliveries.count
            for _ in 0..<100 { replica.mailbox.post(.drain(surfaceID: session.surfaceID, token: UUID())) }
            await waitUntil { log.deliveries.count >= seen + 100 }
        }
        await waitUntil { log.deliveries.contains { if case .reset? = $0.resync { true } else { false } } }
        XCTAssertFalse(log.deliveries.contains { $0.resync == .requested }, "asked by the queue, not the stream")
        XCTAssertNotNil(session.textView.markedTextRange, "the composition still owns the view")
        // The commit waits for the reset like a held key, then lands once.
        session.textView.unmarkText()
        await harness.settle()
        XCTAssertEqual(text(of: try block(session, Self.firstID)), "日本First paragraph.")
        XCTAssertEqual(text(of: try block(session, Self.thirdID)), "PThird paragraph.")
        XCTAssertEqual(harness.input.composition.pendingRecoveries.map(\.text), [])
        try await assertConsistent(harness, localCommands: 1)
    }
}
