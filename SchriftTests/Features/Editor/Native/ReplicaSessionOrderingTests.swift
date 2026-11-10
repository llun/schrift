import Foundation
import UIKit
import XCTest

@testable import Schrift

/// A gate a background thread waits at until the test opens it; once open it
/// stays open (it latches), so nothing can strand behind it.
final class Latch: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false
    private var waiters = 0
    /// How many threads passed the gate (or wait at it).
    private var arrivals = 0

    init(open: Bool = false) { isOpen = open }

    func pass() {
        condition.lock()
        arrivals += 1
        waiters += 1
        while !isOpen { condition.wait() }
        waiters -= 1
        condition.unlock()
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }

    func close() {
        condition.lock()
        isOpen = false
        condition.unlock()
    }

    var waiting: Int {
        condition.lock()
        defer { condition.unlock() }
        return waiters
    }

    var arrived: Int {
        condition.lock()
        defer { condition.unlock() }
        return arrivals
    }
}

/// PR08b: the replica session's ordering guarantees under option A, with a
/// latching disk gate on `ReplicaStore`'s interrupt hook (the session waits
/// inside its journal append) and a mailbox gate (the session waits before
/// handling a message). Fixed client ids, no sleeps. Scenario 13 (an open
/// whose generation moved during the off-main restore) needs the open route's
/// environment: `NativeEditorActivationTests.testAnOpenClosedDuringTheRestoreDropsTheRestoredSession`.
@MainActor
final class ReplicaSessionOrderingTests: NativeEditingTestCase {
    private enum DiskError: Error { case full }

    /// A harness whose journal appends wait at `disk` (closed: every append
    /// waits until the test opens it).
    private func gated(_ disk: Latch, mailbox: Latch? = nil, work: (@Sendable () -> Void)? = nil) async throws
        -> Harness
    {
        let interrupt: @Sendable (ReplicaStore.Operation, ReplicaStore.Boundary) throws -> Void = {
            operation, boundary in
            if operation == .append, boundary == .payloadWritten { disk.pass() }
        }
        var before: (@Sendable () -> Void)?
        if let mailbox { before = { mailbox.pass() } }
        let hooks = DocumentReplicaSession.Hooks(beforeMessage: before, onReplicaWork: work)
        let harness = try await makeHarness(interrupt: interrupt, hooks: hooks)
        addTeardownBlock {
            disk.open()
            mailbox?.open()
            await harness.close()
        }
        return harness
    }

    private func caret(_ harness: Harness, _ blockID: String, _ offset: Int) throws {
        setSelection(harness, NSRange(location: try location(harness.session, blockID, offset), length: 0))
    }

    /// A peer's update from the shared seed (a fresh client each time: two
    /// peers with one id would collide).
    private var nextPeer: UInt32 = 7

    private func peerEdit(_ edit: (BlockNoteWriter) throws -> Data) throws -> Data {
        nextPeer += 1
        let peer = try makeDoc(clientID: nextPeer)
        defer { peer.destroy() }
        return try edit(BlockNoteWriter(doc: peer))
    }

    // 1
    func testPredictedKeysShowAtOnceAndJournalInOrderBehindTheDisk() async throws {
        let disk = Latch()
        let harness = try await gated(disk)
        try caret(harness, Self.firstID, 0)
        for key in ["a", "b", "c"] { harness.view.insertText(key) }
        XCTAssertEqual(text(of: try block(harness.session, Self.firstID)), "abcFirst paragraph.", "shown at once")
        await waitUntil { disk.waiting == 1 }
        XCTAssertEqual(harness.session.revision, 0, "nothing is canonical while the append waits")
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: 3, length: 0))
        disk.open()
        await harness.settle()
        XCTAssertEqual(harness.log.commands.map(\.replacement), ["a", "b", "c"])
        XCTAssertEqual(harness.log.commands.map(\.baseRevision), [0, 1, 2], "journaled in order")
        XCTAssertEqual(harness.session.revision, 3)
        try await assertConsistent(harness, localCommands: 3)
    }

    // 2
    func testAPredictionRebasesThroughAPeerChangeItHadNotSeen() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        try caret(harness, Self.firstID, 5)
        let peer = try peerEdit { try $0.replaceText(block: Self.firstID, range: 0..<0, with: "Peer ") }
        // The peer's bytes reach the session first; the key is predicted on the
        // display that has not seen them.
        harness.session.replica?.mailbox.post(.integrate(peer, reply: nil))
        harness.view.insertText("X")
        XCTAssertEqual(text(of: try block(harness.session, Self.firstID)), "FirstX paragraph.")
        await harness.settle()
        XCTAssertEqual(text(of: try block(harness.session, Self.firstID)), "Peer FirstX paragraph.")
        guard case .replace(let range, _, _)? = harness.log.commands.last?.kind else {
            return XCTFail("one typing command")
        }
        XCTAssertEqual(range, 10..<10, "rebased past the peer's text, as the display was")
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: 11, length: 0))
        try await assertConsistent(harness, localCommands: 1)
        // Both sides agree on an insertion at the same point: the peer's first.
        try caret(harness, Self.thirdID, 0)
        let same = try peerEdit { try $0.replaceText(block: Self.thirdID, range: 0..<0, with: "P") }
        harness.session.replica?.mailbox.post(.integrate(same, reply: nil))
        harness.view.insertText("L")
        await harness.settle()
        XCTAssertEqual(text(of: try block(harness.session, Self.thirdID)), "PLThird paragraph.")
        try await assertConsistent(harness, localCommands: 2)
    }

    // 3
    func testAPredictionThatCannotBeRebasedRollsBackIntoARecoveryEntry() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        try caret(harness, Self.firstID, 3)
        // The peer deletes the characters around the caret: no place to land.
        let peer = try peerEdit { try $0.replaceText(block: Self.firstID, range: 0..<6, with: "") }
        harness.session.replica?.mailbox.post(.integrate(peer, reply: nil))
        harness.view.insertText("x")
        harness.view.insertText("y")
        await harness.settle()
        XCTAssertEqual(
            text(of: try block(harness.session, Self.firstID)), "paragraph.", "canonical, no lost-place text")
        XCTAssertEqual(harness.input.composition.pendingRecoveries.map(\.text), ["xy"])
        XCTAssertEqual(harness.input.composition.pendingRecoveries.first?.state, .orphaned)
        XCTAssertTrue(harness.log.commands.isEmpty, "nothing of the old epoch was journaled")
        // The new epoch types normally.
        try caret(harness, Self.thirdID, 0)
        harness.view.insertText("z")
        await harness.settle()
        XCTAssertEqual(text(of: try block(harness.session, Self.thirdID)), "zThird paragraph.")
        try await assertConsistent(harness, localCommands: 1)
    }

    // 4
    func testKeysTypedDuringABarrierAreHeldAndReplayed() async throws {
        let disk = Latch()
        let harness = try await gated(disk)
        try caret(harness, Self.firstID, 5)
        harness.view.insertText("\n")
        harness.view.insertText("x")
        harness.view.insertText("y")
        // The software keyboard's delegate path is held the same way.
        XCTAssertFalse(
            harness.input.textView(
                harness.view, shouldChangeTextIn: harness.view.selectedRange, replacementText: "z"))
        harness.view.deleteBackward()
        await waitUntil { disk.waiting == 1 }
        XCTAssertEqual(harness.session.surface.blocks.count, 3, "a barrier shows on its result")
        XCTAssertEqual(
            text(of: try block(harness.session, Self.firstID)), "First paragraph.", "held keys are not shown")
        disk.open()
        await harness.settle()
        XCTAssertEqual(
            texts(harness.session),
            ["First", "xy paragraph.", "Second paragraph has bold words inside it.", "Third paragraph."])
        XCTAssertEqual(harness.log.commands.count, 5, "split, x, y, z, delete")
        try await assertConsistent(harness, localCommands: 5)
    }

    // 5
    func testAStaleBarrierIsRetriedOnceAgainstTheNewDisplay() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        try caret(harness, Self.firstID, 5)
        let peer = try peerEdit { try $0.replaceText(block: Self.firstID, range: 0..<0, with: "Peer ") }
        harness.session.replica?.mailbox.post(.integrate(peer, reply: nil))
        let split = await harness.run { harness.input.insertNewline() }
        XCTAssertTrue(split)
        XCTAssertEqual(harness.log.commands.count, 1, "one split journaled, after the retry")
        XCTAssertEqual(texts(harness.session).prefix(2), ["Peer First", " paragraph."].prefix(2))
        try await assertConsistent(harness, localCommands: 1)
    }

    // 6
    func testAFailedAppendRollsTheDisplayBackFreezesAndKeepsTheText() async throws {
        let session = try await NativeEditorSession.seed(
            state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID), clientID: 2)
        addTeardownBlock { await session.close().value }
        let appends = Locked(0)
        session.enableTyping(persist: { _, _ in
            appends.update { $0 += 1 }
            if appends.value > 1 { throw DiskError.full }
        })
        let input = try XCTUnwrap(session.input)
        session.textView.selectedRange = NSRange(location: 0, length: 0)
        input.textViewDidChangeSelection(session.textView)
        for key in ["a", "b", "c"] { session.textView.insertText(key) }
        await session.settle()
        XCTAssertEqual(text(of: session.surface.blocks[0]), "aFirst paragraph.", "back to the journaled state")
        XCTAssertEqual(input.noticeKey, .native_editor_storage_failed)
        XCTAssertFalse(session.textView.isEditable)
        XCTAssertEqual(input.composition.pendingRecoveries.map(\.text), ["bc"])
        XCTAssertEqual(session.state.frozen, true)
    }

    // 7
    func testPublicationWaitsForTheJournal() async throws {
        let disk = Latch()
        let harness = try await gated(disk)
        let scheduler = NativeReplicaSaveScheduler(interval: .seconds(3600), enqueue: { true }, onFailure: { _ in })
        harness.input.onJournaled = { scheduler.schedule() }
        try caret(harness, Self.firstID, 0)
        harness.view.insertText("a")
        await waitUntil { disk.waiting == 1 }
        XCTAssertEqual(text(of: try block(harness.session, Self.firstID)), "aFirst paragraph.", "provisional UI")
        XCTAssertFalse(scheduler.hasPendingSave, "no save is scheduled before the append")
        XCTAssertEqual(harness.session.revision, 0, "the canonical display has not advanced")
        harness.input.insertNewline()
        XCTAssertEqual(harness.session.surface.blocks.count, 3, "a barrier is not shown before its append")
        disk.open()
        await harness.settle()
        XCTAssertTrue(scheduler.hasPendingSave)
        XCTAssertEqual(harness.session.revision, 2)
        XCTAssertEqual(harness.log.blocksAtPersist.last?.count, 3, "the split was journaled before it was shown")
        scheduler.cancel()
        try await assertConsistent(harness, localCommands: 2)
    }

    // 8
    func testNoReplicaWorkRunsOnTheMainThread() async throws {
        let onMain = Locked(0)
        let work = Locked(0)
        let harness = try await makeHarness(
            hooks: DocumentReplicaSession.Hooks(onReplicaWork: {
                work.update { $0 += 1 }
                if Thread.isMainThread { onMain.update { $0 += 1 } }
            }))
        addTeardownBlock { await harness.close() }
        try caret(harness, Self.firstID, 0)
        harness.view.insertText("a")
        harness.input.insertNewline()
        await harness.settle()
        let undone = await harness.run { harness.input.undo() }
        XCTAssertTrue(undone)
        XCTAssertGreaterThan(work.value, 3)
        XCTAssertEqual(onMain.value, 0, "the replica is never touched on main")
    }

    /// The main-actor editor files never name the live graph's types, and the
    /// session file has no unchecked sendability.
    func testMainActorFilesDoNotReferenceTheLiveGraph() throws {
        let native = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Schrift/Features/Editor/Native")
        let files = try FileManager.default.contentsOfDirectory(at: native, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        // Owner decision (PR08): the save capture's throwaway decode stays on main.
        let exempt: Set<String> = ["ReplicaSaveAdapter.swift"]
        let forbidden = ["YDoc", "DocumentEngine", "YUndoManager", "ReplicaHistory"]
        for file in files where !exempt.contains(file.lastPathComponent) {
            let code = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            guard code.contains("@MainActor") else { continue }
            for name in forbidden {
                XCTAssertNil(
                    code.range(of: "\\b\(name)\\b", options: .regularExpression),
                    "\(file.lastPathComponent) names \(name)")
            }
        }
        let session = try String(
            contentsOf: native.appendingPathComponent("DocumentReplicaSession.swift"), encoding: .utf8)
        XCTAssertFalse(session.contains("@unchecked"))
        XCTAssertFalse(session.contains("nonisolated(unsafe)"))
    }

    // 9
    func testPendingTypingIntentsAndTheMailboxAreBounded() async throws {
        let disk = Latch()
        let harness = try await gated(disk)
        try caret(harness, Self.thirdID, 0)
        let max = NativeInputCoordinator.maxPendingTyping
        let held = NativeInputCoordinator.maxIntents
        for _ in 0..<max { harness.view.insertText("p") }
        for _ in 0..<held { harness.view.insertText("h") }
        XCTAssertEqual(
            text(of: try block(harness.session, Self.thirdID)).prefix(max + 1), String(repeating: "p", count: max) + "T"
        )
        XCTAssertNil(harness.input.noticeKey)
        harness.view.insertText("!")
        XCTAssertEqual(harness.input.noticeKey, .native_editor_input_busy, "the key past the bound is not kept")
        disk.open()
        await harness.settle()
        XCTAssertEqual(
            text(of: try block(harness.session, Self.thirdID)),
            String(repeating: "p", count: max) + String(repeating: "h", count: held) + "Third paragraph.")
        try await assertConsistent(harness, localCommands: max + held)

        // A full mailbox drops the message and stops authoring.
        let mailbox = Latch()
        let blocked = try await gated(Latch(open: true), mailbox: mailbox)
        let replica = try XCTUnwrap(blocked.session.replica)
        var posted = 0
        while replica.mailbox.post(.writeProvisional([])) { posted += 1 }
        XCTAssertLessThanOrEqual(posted, ReplicaCommandMailbox.capacity + 1)
        try caret(blocked, Self.firstID, 0)
        blocked.view.insertText("x")
        XCTAssertEqual(blocked.input.noticeKey, .native_editor_storage_failed)
        XCTAssertFalse(blocked.view.isEditable)
        mailbox.open()
    }

    // 10
    func testCompositionBeginIsPostedAndItsCommitIsABarrier() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        try caret(harness, Self.firstID, 5)
        harness.view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        harness.view.unmarkText()
        harness.view.insertText("x")
        await harness.settle()
        XCTAssertEqual(text(of: try block(harness.session, Self.firstID)), "Firstにほんx paragraph.")
        XCTAssertEqual(harness.log.commands.count, 2, "one commit, then the held key")
        // A target deleted before the session sees the begin: the commit is orphaned.
        try caret(harness, Self.thirdID, 2)
        let peer = try peerEdit { try $0.replaceText(block: Self.thirdID, range: 0..<16, with: "") }
        harness.session.replica?.mailbox.post(.integrate(peer, reply: nil))
        harness.view.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
        harness.view.unmarkText()
        await harness.settle()
        XCTAssertEqual(harness.input.composition.pendingRecoveries.map(\.text), ["かな"])
        XCTAssertEqual(harness.log.commands.count, 2, "an orphaned commit writes nothing")
        try await assertConsistent(harness, localCommands: 2)
    }

    // 11
    func testUndoFollowsPendingTypingAndMirrorsTheSharedHistory() async throws {
        let disk = Latch()
        let harness = try await gated(disk)
        try caret(harness, Self.firstID, 0)
        harness.view.insertText("a")
        XCTAssertTrue(harness.input.canUndo, "a pending keystroke is undoable")
        XCTAssertTrue(harness.input.undo())
        disk.open()
        await harness.settle()
        XCTAssertEqual(text(of: try block(harness.session, Self.firstID)), "First paragraph.")
        XCTAssertFalse(harness.input.canUndo)
        XCTAssertTrue(harness.input.canRedo, "mirrored from the session's history")
        try await assertConsistent(harness, localCommands: 2)
    }

    // 12
    func testCloseDrainsEverythingPostedBeforeIt() async throws {
        let disk = Latch()
        let harness = try await gated(disk)
        try caret(harness, Self.firstID, 0)
        harness.view.insertText("a")
        harness.input.insertNewline()
        await waitUntil { disk.waiting == 1 }
        let closing = harness.session.close()
        XCTAssertTrue(harness.session.isClosed)
        XCTAssertFalse(harness.view.isEditable)
        disk.open()
        await closing.value
        let restored = try XCTUnwrap(harness.store.restore(for: harness.scope))
        XCTAssertEqual(restored.manifest.journal.count, 2, "both commands were journaled before the close")
        let detached = await harness.session.engine { $0.isDetached }
        XCTAssertNil(detached, "the session is gone")
    }

    // 14
    func testTimingsReportTheEngineAndTheJournal() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let log = PatchLog(harness.session)
        try caret(harness, Self.firstID, 0)
        harness.view.insertText("a")
        harness.input.insertNewline()
        await harness.settle()
        let timings = log.deliveries.compactMap(\.timings)
        XCTAssertEqual(timings.count, 2)
        for timing in timings {
            XCTAssertGreaterThan(timing.journal, .zero)
            XCTAssertGreaterThanOrEqual(timing.engine, timing.journal)
        }
    }
}
