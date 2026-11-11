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

    // MARK: - Review round 1 (PR #272)

    private func seeded(
        _ blocks: [BlockNoteBlock] = seedBlocks(), persist: @escaping DocumentReplicaSession.Journal
    ) async throws -> NativeEditorSession {
        let session = try await NativeEditorSession.seed(
            state: BlockNoteYjs.encode(blocks, clientID: Self.seedClientID), clientID: 2)
        addTeardownBlock { await session.close().value }
        session.enableTyping(persist: persist)
        return session
    }

    private func caret(_ session: NativeEditorSession, _ blockID: String, _ offset: Int, length: Int = 0) throws {
        let entry = try XCTUnwrap(session.surface.rangeIndex.entry(for: blockID))
        session.textView.selectedRange = NSRange(location: entry.textRange.location + offset, length: length)
        session.input?.textViewDidChangeSelection(session.textView)
    }

    /// F1: a stale barrier's retry acts on the text it was aimed at, moved
    /// through the peer edit that made it stale.
    func testARetriedRangeActionFollowsThePeerEditBeforeIt() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        setSelection(harness, NSRange(location: try location(harness.session, Self.firstID, 6), length: 9))
        let peer = try peerEdit { try $0.replaceText(block: Self.firstID, range: 0..<0, with: "Peer ") }
        harness.session.replica?.mailbox.post(.integrate(peer, reply: nil))
        let bolded = await harness.run { harness.input.toggleMark("bold") }
        XCTAssertTrue(bolded)
        let first = try block(harness.session, Self.firstID)
        XCTAssertEqual(first.runs.filter { $0.marks.contains { $0.key == "bold" } }.map(\.text), ["paragraph"])
        XCTAssertEqual(
            harness.view.selectedRange, NSRange(location: try location(harness.session, Self.firstID, 11), length: 9))

        try select(harness, from: (Self.firstID, 11), to: (Self.secondID, 7))
        let again = try peerEdit { try $0.replaceText(block: Self.firstID, range: 0..<0, with: "Two ") }
        harness.session.replica?.mailbox.post(.integrate(again, reply: nil))
        harness.view.insertText("X")
        await harness.settle()
        // Two concurrent insertions at one point merge in the CRDT's client order.
        XCTAssertEqual(texts(harness.session).first, "Peer Two First Xparagraph has bold words inside it.")
        try await assertConsistent(harness, localCommands: 2)
    }

    /// F2: keys held behind a barrier whose append fails are kept as recovery
    /// text even with no prediction dropped.
    func testHeldKeysAreRecoveredWhenTheBarrierFails() async throws {
        let session = try await seeded(persist: { _, _ in throw DiskError.full })
        try caret(session, Self.firstID, 5)
        session.textView.insertText("\n")
        for key in ["a", "b", "c"] { session.textView.insertText(key) }
        await session.settle()
        XCTAssertEqual(session.input?.noticeKey, .native_editor_storage_failed)
        XCTAssertEqual(session.input?.composition.pendingRecoveries.map(\.text), ["abc"])
    }

    /// F3: a cut whose delete went stale and was retried still fills the pasteboard.
    func testACutWhoseDeleteIsRetriedStillFillsThePasteboard() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        try select(harness, from: (Self.firstID, 6), to: (Self.secondID, 7))
        let peer = try peerEdit { try $0.replaceText(block: Self.thirdID, range: 0..<0, with: "Peer ") }
        harness.session.replica?.mailbox.post(.integrate(peer, reply: nil))
        let cut = await harness.run { harness.input.cutSelection() }
        XCTAssertTrue(cut)
        XCTAssertEqual(harness.pasteboard.string, "paragraph.\nSecond ")
        XCTAssertEqual(texts(harness.session).first, "First paragraph has bold words inside it.")
        try await assertConsistent(harness, localCommands: 1)
    }

    /// F5: typing over a selection the user made while a barrier was in flight
    /// is held and replaces that selection, which wins over the barrier's caret.
    func testTypingOverASelectionDuringABarrierIsHeld() async throws {
        let disk = Latch()
        let harness = try await gated(disk)
        try caret(harness, Self.firstID, 5)
        harness.view.insertText("\n")
        setSelection(harness, NSRange(location: try location(harness.session, Self.thirdID, 0), length: 5))
        XCTAssertFalse(
            harness.input.textView(harness.view, shouldChangeTextIn: harness.view.selectedRange, replacementText: "Z"))
        disk.open()
        await harness.settle()
        XCTAssertEqual(
            texts(harness.session),
            ["First", " paragraph.", "Second paragraph has bold words inside it.", "Z paragraph."])
        try await assertConsistent(harness, localCommands: 2)
    }

    /// F7: a rollback while text is marked waits for the composition to end
    /// instead of rewriting storage under it.
    func testARollbackDuringACompositionWaitsForIt() async throws {
        let gate = Latch()
        let session = try await seeded(persist: { _, _ in
            gate.pass()
            throw DiskError.full
        })
        try caret(session, Self.firstID, 0)
        session.textView.insertText("a")
        session.textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        await waitUntil { gate.waiting == 1 }
        gate.open()
        await session.settle()
        XCTAssertNil(session.input?.noticeKey, "the failure waits for the composition")
        let marked = try XCTUnwrap(session.textView.markedTextRange)
        XCTAssertEqual(session.textView.text(in: marked), "か", "the marked text was not written over")
        session.input?.textViewDidEndEditing(session.textView)
        await session.settle()
        XCTAssertEqual(session.input?.noticeKey, .native_editor_storage_failed)
        XCTAssertEqual(text(of: session.surface.blocks[0]), "First paragraph.")
        let fresh = AttributedDocumentProjection.attributedString(
            blocks: session.surface.blocks, traits: session.surface.traits, labels: session.surface.labels,
            geometry: session.surface.attachmentGeometry)
        XCTAssertEqual(session.textView.textStorage.string, fresh.string, "storage equals the model")
        XCTAssertTrue(session.input?.composition.pendingRecoveries.map(\.text).contains("a") == true)
    }

    /// F7: a composing keyboard's direct character behind a barrier is held.
    func testADirectKeyboardCharacterBehindABarrierIsHeld() async throws {
        let disk = Latch()
        let harness = try await gated(disk)
        harness.input.inputLanguage = { "ja-JP" }
        try caret(harness, Self.firstID, 5)
        harness.view.insertText("\n")
        let range = harness.view.selectedRange
        XCTAssertTrue(harness.input.textView(harness.view, shouldChangeTextIn: range, replacementText: "1"))
        // What UIKit does with an allowed character: write it, move the caret.
        harness.view.textStorage.replaceCharacters(in: range, with: "1")
        harness.view.selectedRange = NSRange(location: range.location + 1, length: 0)
        harness.input.textViewDidChange(harness.view)
        disk.open()
        await harness.settle()
        XCTAssertEqual(texts(harness.session).prefix(2), ["First", "1 paragraph."])
        try await assertConsistent(harness, localCommands: 2)
    }

    /// F8: a prediction the engine echoes as a block rebuild (with no settled
    /// projection) is canonical once journaled, so a later rollback keeps it.
    func testAPredictionEchoedAsARebuildIsKeptByALaterRollback() async throws {
        let disk = Latch()
        let harness = try await gated(disk)
        try caret(harness, Self.firstID, 0)
        harness.view.insertText("a")
        harness.view.insertText("b")
        let pending = harness.session.surface.predictions
        XCTAssertEqual(pending.count, 2)
        var rebuilt = try block(harness.session, Self.firstID)
        rebuilt.runs = [InlineRun("aFirst paragraph.")]
        let stamp = NativePatchStamp(
            commandID: pending[0].commandID, baseRevision: 0, emission: 0, surfaceID: harness.input.surfaceID)
        let echo = BlockPatch(
            [.replaceBlock(blockID: Self.firstID, block: rebuilt)], origin: .localUser, nativeCommand: stamp)
        harness.input.apply(
            ReplicaDelivery(
                revision: 1, events: [.patch(echo, settled: [:])],
                result: .applied(commandID: pending[0].commandID, caret: nil, journaled: true),
                state: ReplicaState(writable: true)))
        harness.input.apply(
            ReplicaDelivery(
                revision: 1, result: .failed(commandID: pending[1].commandID),
                state: ReplicaState(writable: true, frozen: true)))
        XCTAssertEqual(
            text(of: try block(harness.session, Self.firstID)), "aFirst paragraph.", "the journaled key stays")
        XCTAssertEqual(harness.input.composition.pendingRecoveries.map(\.text), ["b"])
    }

    /// F9: undo restores the selection its step stored even after the user's
    /// selection touched a placeholder (which the session does not track).
    func testUndoRestoresItsSelectionAfterAPlaceholderSelection() async throws {
        let harness = try await makeHarness([
            paragraph("a", "Alpha"), BlockNoteBlock(node: "table", props: [], runs: [], id: "table"),
            paragraph("c", "Gamma"),
        ])
        addTeardownBlock { await harness.close() }
        try caret(harness, "a", 5)
        harness.view.insertText("!")
        await harness.settle()
        setSelection(harness, NSRange(location: try location(harness.session, "table", 0), length: 0))
        let undone = await harness.run { harness.input.undo() }
        XCTAssertTrue(undone)
        XCTAssertEqual(text(of: try block(harness.session, "a")), "Alpha")
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(harness.session, "a", 5), length: 0))
    }

    /// F11: `settle` says when work is still in flight after its bound.
    func testSettleReportsWorkStillInFlight() async throws {
        let disk = Latch()
        let harness = try await gated(disk)
        try caret(harness, Self.thirdID, 0)
        for _ in 0..<(NativeInputCoordinator.maxPendingTyping + 4) { harness.view.insertText("k") }
        disk.open()
        let partly = await harness.session.settle(maxRounds: 1)
        XCTAssertFalse(partly, "the held keys were posted after the first drain")
        let fully = await harness.session.settle()
        XCTAssertTrue(fully)
        try await assertConsistent(harness, localCommands: NativeInputCoordinator.maxPendingTyping + 4)
    }

    // MARK: - Review round 2 (PR #272)

    /// G2 and G5b: a key journaled while a composition holds the view stays
    /// canonical when a later key's append fails, and the failure's notice
    /// shows once the composition ends.
    func testAKeyJournaledWhileComposingSurvivesALaterFailure() async throws {
        let gate = Latch()
        let appends = Locked(0)
        let session = try await seeded(persist: { _, _ in
            appends.update { $0 += 1 }
            if appends.value == 1 { gate.pass() } else { throw DiskError.full }
        })
        try caret(session, Self.firstID, 0)
        session.textView.insertText("a")
        session.textView.insertText("b")
        session.textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        await waitUntil { gate.waiting == 1 }
        gate.open()
        await session.settle()
        XCTAssertNil(session.input?.noticeKey, "the failure waits for the composition")
        session.input?.textViewDidEndEditing(session.textView)
        await session.settle()
        XCTAssertEqual(text(of: session.surface.blocks[0]), "aFirst paragraph.", "the journaled key stays")
        XCTAssertEqual(session.input?.noticeKey, .native_editor_storage_failed, "the composition's end keeps it")
        XCTAssertTrue(session.input?.composition.pendingRecoveries.map(\.text).contains("b") == true)
        let fresh = AttributedDocumentProjection.attributedString(
            blocks: session.surface.blocks, traits: session.surface.traits, labels: session.surface.labels,
            geometry: session.surface.attachmentGeometry)
        XCTAssertEqual(session.textView.textStorage.string, fresh.string, "storage equals the model")
    }

    /// G3: a selection the user makes while a barrier that keeps its range is in
    /// flight (bold) is where held keys go, not the kept range.
    func testAUserSelectionWinsOverABarrierThatKeepsItsRange() async throws {
        let disk = Latch()
        let harness = try await gated(disk)
        setSelection(harness, NSRange(location: try location(harness.session, Self.firstID, 0), length: 5))
        XCTAssertTrue(harness.input.toggleMark("bold"))
        setSelection(harness, NSRange(location: try location(harness.session, Self.firstID, 16), length: 0))
        harness.view.insertText("!")
        disk.open()
        await harness.settle()
        let first = try block(harness.session, Self.firstID)
        XCTAssertEqual(text(of: first), "First paragraph.!")
        XCTAssertEqual(first.runs.filter { $0.marks.contains { $0.key == "bold" } }.map(\.text), ["First"])
        try await assertConsistent(harness, localCommands: 2)
    }

    /// G4: a retried range keeps a peer's insertion at its start outside it,
    /// and a peer edit inside it cancels the retry.
    func testARetriedRangeKeepsAnInsertAtItsStartOutsideAndRefusesAnOverlap() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        setSelection(harness, NSRange(location: try location(harness.session, Self.firstID, 0), length: 5))
        let start = try peerEdit { try $0.replaceText(block: Self.firstID, range: 0..<0, with: "Peer ") }
        harness.session.replica?.mailbox.post(.integrate(start, reply: nil))
        let bolded = await harness.run { harness.input.toggleMark("bold") }
        XCTAssertTrue(bolded)
        let first = try block(harness.session, Self.firstID)
        XCTAssertEqual(first.runs.filter { $0.marks.contains { $0.key == "bold" } }.map(\.text), ["First"])

        setSelection(harness, NSRange(location: try location(harness.session, Self.thirdID, 0), length: 5))
        let inside = try peerEdit { try $0.replaceText(block: Self.thirdID, range: 2..<4, with: "") }
        harness.session.replica?.mailbox.post(.integrate(inside, reply: nil))
        let refused = await harness.run { harness.input.toggleMark("bold") }
        XCTAssertFalse(refused, "the range it was aimed at is gone")
        XCTAssertEqual(harness.input.noticeKey, .native_editor_input_unavailable)
        let third = try block(harness.session, Self.thirdID)
        XCTAssertTrue(third.runs.allSatisfy { $0.marks.isEmpty })
        try await assertConsistent(harness, localCommands: 1)
    }

    /// G5a: a rollback while text is marked shows the canonical block before the
    /// peer edit buffered meanwhile, so the display ends equal to the replica.
    func testARollbackUnderACompositionKeepsAPeerEditBufferedBeforeIt() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        try caret(harness, Self.firstID, 3)
        let peer = try peerEdit { try $0.replaceText(block: Self.firstID, range: 0..<6, with: "") }
        harness.session.replica?.mailbox.post(.integrate(peer, reply: nil))
        harness.view.insertText("x")
        harness.view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        await harness.settle()
        harness.input.textViewDidEndEditing(harness.view)
        await harness.settle()
        let replica = await harness.session.replicaDoc {
            NativeBlockProjection.project($0).blocks.map(BlockSnapshot.init)
        }
        XCTAssertEqual(harness.session.surface.blocks, replica)
        XCTAssertEqual(text(of: try block(harness.session, Self.firstID)), "paragraph.")
        XCTAssertTrue(harness.input.composition.pendingRecoveries.map(\.text).contains("x"))
    }

    /// G6a and G6b: a stale barrier retries from the selection it was taken at,
    /// and a selection the user made meanwhile carries over to the retry.
    func testARetriedBarrierRunsFromItsOwnSelectionAndTheUsersCarries() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        try caret(harness, Self.firstID, 5)
        let peer = try peerEdit { try $0.replaceText(block: Self.firstID, range: 0..<0, with: "Peer ") }
        harness.session.replica?.mailbox.post(.integrate(peer, reply: nil))
        harness.input.insertNewline()
        setSelection(harness, NSRange(location: try location(harness.session, Self.thirdID, 0), length: 5))
        XCTAssertFalse(
            harness.input.textView(harness.view, shouldChangeTextIn: harness.view.selectedRange, replacementText: "Z"))
        await harness.settle()
        XCTAssertEqual(
            texts(harness.session),
            ["Peer First", " paragraph.", "Second paragraph has bold words inside it.", "Z paragraph."])
        try await assertConsistent(harness, localCommands: 2)
    }

    /// G6c: a block rebuilt before the user selected in it does not void that
    /// selection.
    func testAUserSelectionInABlockRebuiltBeforeItWasMadeSurvives() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        try caret(harness, Self.firstID, 5)
        let peer = try peerEdit {
            try $0.setBlockType(block: Self.thirdID, to: "paragraph", props: [("textAlignment", .string("center"))])
        }
        harness.session.replica?.mailbox.post(.integrate(peer, reply: nil))
        let third = try location(harness.session, Self.thirdID, 0)
        harness.session.onDelivery = { [weak self] delivery in
            // After the peer's rebuild was shown, before the stale answer.
            guard case .stale? = delivery.result, let self else { return }
            self.setSelection(harness, NSRange(location: third, length: 5))
            _ = harness.input.textView(
                harness.view, shouldChangeTextIn: harness.view.selectedRange, replacementText: "Z")
        }
        harness.input.insertNewline()
        await harness.settle()
        XCTAssertEqual(
            texts(harness.session),
            ["First", " paragraph.", "Second paragraph has bold words inside it.", "Z paragraph."])
        try await assertConsistent(harness, localCommands: 2)
    }

    /// G7: a cut whose delete fails leaves nothing in flight and copies nothing.
    func testAFailedCutLeavesNothingInFlight() async throws {
        let session = try await seeded(persist: { _, _ in throw DiskError.full })
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        session.input?.pasteboard = pasteboard
        let start = try XCTUnwrap(session.surface.rangeIndex.entry(for: Self.firstID)).textRange.location + 6
        let end = try XCTUnwrap(session.surface.rangeIndex.entry(for: Self.secondID)).textRange.location + 7
        session.textView.selectedRange = NSRange(location: start, length: end - start)
        session.input?.textViewDidChangeSelection(session.textView)
        XCTAssertEqual(session.input?.cutSelection(), true)
        let drained = await session.settle()
        XCTAssertTrue(drained, "nothing stays in flight")
        XCTAssertNil(pasteboard.string, "a refused cut copies nothing")
        XCTAssertEqual(session.input?.noticeKey, .native_editor_storage_failed)
    }

    // MARK: - Review round 3 (PR #272)

    /// H1: a stale barrier whose selection is gone (a peer merged its block
    /// away) is not retried on whatever the selection became.
    func testAStaleBarrierWhoseSelectionIsGoneIsNotRetried() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        try caret(harness, Self.secondID, 3)
        let peer = try peerEdit { try $0.joinBlocks(block: Self.secondID) }
        harness.session.replica?.mailbox.post(.integrate(peer, reply: nil))
        let deleted = await harness.run { harness.input.performBlockAction(.delete) }
        XCTAssertFalse(deleted)
        XCTAssertEqual(harness.input.noticeKey, .native_editor_input_unavailable)
        XCTAssertEqual(harness.session.surface.blocks.map(\.id), [Self.firstID, Self.thirdID], "nothing was deleted")
        try await assertConsistent(harness, localCommands: 0)
    }

    /// H2: when a stale barrier's retry is refused, keys held meanwhile go to
    /// the selection the user made, which the view showed during the retry.
    func testARefusedRetryLeavesHeldKeysAtTheUsersSelection() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        try caret(harness, Self.firstID, 0)
        let peer = try peerEdit { try $0.replaceText(block: Self.secondID, range: 0..<0, with: "Peer ") }
        harness.session.replica?.mailbox.post(.integrate(peer, reply: nil))
        harness.input.indent()
        setSelection(harness, NSRange(location: try location(harness.session, Self.thirdID, 0), length: 5))
        XCTAssertFalse(
            harness.input.textView(harness.view, shouldChangeTextIn: harness.view.selectedRange, replacementText: "Z"))
        await harness.settle()
        XCTAssertEqual(
            texts(harness.session),
            ["First paragraph.", "Peer Second paragraph has bold words inside it.", "Z paragraph."])
        try await assertConsistent(harness, localCommands: 1)
    }

    /// H3: a keystroke the display predicted with marks the journal does not
    /// keep (bold in a code block) is repaired, and the caret stays where it
    /// was in that block: the rebuilt slice has the same text, and UIKit keeps
    /// a live first responder's caret through it.
    func testARepairedPredictionKeepsTheCaretInItsBlock() async throws {
        let harness = try await makeHarness([
            BlockNoteBlock(
                node: "codeBlock", props: [("language", .string("swift"))], runs: [InlineRun("let value = 1")],
                id: "code"),
            paragraph("p", "After"),
        ])
        addTeardownBlock { await harness.close() }
        // A live editing view, as on a device: UIKit moves the selection of a
        // first responder whose storage slice is replaced.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        harness.view.frame = window.bounds
        window.addSubview(harness.view)
        window.makeKeyAndVisible()
        harness.view.becomeFirstResponder()
        defer {
            harness.view.resignFirstResponder()
            window.isHidden = true
        }
        try caret(harness, "code", 4)
        XCTAssertTrue(harness.input.toggleMark("bold"))
        harness.view.insertText("x")
        let predicted = try block(harness.session, "code")
        await harness.settle()
        let journaled = try block(harness.session, "code")
        XCTAssertNotEqual(predicted, journaled, "the journal kept other marks than the display guessed")
        XCTAssertEqual(text(of: journaled), "let xvalue = 1")
        XCTAssertEqual(
            harness.view.selectedRange, NSRange(location: try location(harness.session, "code", 5), length: 0))
        try await assertConsistent(harness, localCommands: 1)
    }

    /// H4: a peer patch and a later key's echo for one block, both buffered
    /// while composing, are applied in revision order, so a rollback after them
    /// keeps the journaled key and the display ends equal to the replica.
    func testPatchesBufferedWhileComposingKeepRevisionOrder() async throws {
        let appends = Locked(0)
        let session = try await seeded(persist: { _, _ in
            appends.update { $0 += 1 }
            if appends.value > 1 { throw DiskError.full }
        })
        try caret(session, Self.firstID, 0)
        let peer = try peerEdit { try $0.replaceText(block: Self.firstID, range: 16..<16, with: "Peer") }
        session.replica?.mailbox.post(.integrate(peer, reply: nil))
        session.textView.insertText("a")
        session.textView.insertText("b")
        session.textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        await session.settle()
        session.input?.textViewDidEndEditing(session.textView)
        await session.settle()
        // The journaled state: the peer's text and "a" (the failed "b" reached
        // the unconfirmed graph, which nothing publishes).
        XCTAssertEqual(text(of: session.surface.blocks[0]), "aFirst paragraph.Peer")
        let fresh = AttributedDocumentProjection.attributedString(
            blocks: session.surface.blocks, traits: session.surface.traits, labels: session.surface.labels,
            geometry: session.surface.attachmentGeometry)
        XCTAssertEqual(session.textView.textStorage.string, fresh.string, "storage equals the model")
        XCTAssertTrue(session.input?.composition.pendingRecoveries.map(\.text).contains("b") == true)
    }

    /// H5: when the barrier's own echo rewrites the text of the block the user
    /// selected in meanwhile (a slash command removing "/h1"), the old offset
    /// is not mapped into the new text: the held key goes to the barrier's caret.
    func testABarrierThatRewritesTheUsersBlockDoesNotMapTheirOffset() async throws {
        let disk = Latch()
        let harness = try await gated(disk)
        let id = Self.firstID
        try caret(harness, id, 0)
        harness.view.insertText("/h1")
        disk.open()
        await harness.settle()
        disk.close()
        let item = try XCTUnwrap(NativeInputCoordinator.slashItems.first { $0.id == "heading1" })
        XCTAssertTrue(harness.input.applySlashItem(item))
        setSelection(harness, NSRange(location: try location(harness.session, id, 7), length: 0))
        XCTAssertFalse(
            harness.input.textView(harness.view, shouldChangeTextIn: harness.view.selectedRange, replacementText: "!"))
        disk.open()
        await harness.settle()
        XCTAssertEqual(text(of: try block(harness.session, id)), "!First paragraph.")
        try await assertConsistent(harness, localCommands: 3)
    }

    /// H6: keys held behind a barrier wait while text is marked and replay
    /// after the composition resolves, never into it.
    func testHeldKeysWaitForAComposition() async throws {
        let disk = Latch()
        let harness = try await gated(disk)
        try caret(harness, Self.firstID, 5)
        harness.view.insertText("\n")
        harness.view.insertText("a")
        harness.view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        disk.open()
        _ = await harness.session.settle()
        harness.view.unmarkText()
        await harness.settle()
        XCTAssertEqual(texts(harness.session).prefix(2), ["Firstかa", " paragraph."])
        try await assertConsistent(harness, localCommands: 3)
    }

    // MARK: - Review round 4 (PR #272)

    /// I1: a rollback while composing is deferred whole, so a peer patch
    /// buffered before it still rebases through the dropped keystroke (a
    /// deletion here) instead of landing past the block's shown text.
    func testABufferedPeerPatchRebasesThroughAKeyARollbackDropsLater() async throws {
        let appends = Locked(0)
        let session = try await seeded(persist: { _, _ in
            appends.update { $0 += 1 }
            if appends.value > 1 { throw DiskError.full }
        })
        let peer = try peerEdit { try $0.replaceText(block: Self.firstID, range: 16..<16, with: "Peer") }
        session.replica?.mailbox.post(.integrate(peer, reply: nil))
        try caret(session, Self.firstID, 0)
        session.textView.insertText("a")
        try caret(session, Self.firstID, 17)
        session.textView.deleteBackward()
        session.textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        await session.settle()
        // Storage equals the model after every patch replayed at reconciliation.
        var torn: [String] = []
        let applied = session.surface.onPatchApplied
        session.surface.onPatchApplied = { [weak session] patch in
            applied?(patch)
            guard let session else { return }
            let model = AttributedDocumentProjection.attributedString(
                blocks: session.surface.blocks, traits: session.surface.traits, labels: session.surface.labels,
                geometry: session.surface.attachmentGeometry)
            if session.textView.textStorage.string != model.string { torn.append(session.textView.textStorage.string) }
        }
        session.input?.textViewDidEndEditing(session.textView)
        await session.settle()
        XCTAssertEqual(torn, [], "the peer's text landed in its block")
        XCTAssertEqual(text(of: session.surface.blocks[0]), "aFirst paragraph.Peer")
        let fresh = AttributedDocumentProjection.attributedString(
            blocks: session.surface.blocks, traits: session.surface.traits, labels: session.surface.labels,
            geometry: session.surface.attachmentGeometry)
        XCTAssertEqual(session.textView.textStorage.string, fresh.string, "storage equals the model")
    }

    /// I2: a buffered removal of a predicted block, replayed before the deferred
    /// rollback, does not leave input waiting for an invalidation forever.
    func testABufferedRemovalBeforeARollbackDoesNotWedgeInput() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        try caret(harness, Self.secondID, 3)
        let peer = try peerEdit { try $0.joinBlocks(block: Self.secondID) }
        harness.session.replica?.mailbox.post(.integrate(peer, reply: nil))
        harness.view.insertText("x")
        harness.view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        _ = await harness.session.settle()
        harness.input.textViewDidEndEditing(harness.view)
        await harness.settle()
        XCTAssertFalse(harness.session.surface.expectsInvalidation)
        try caret(harness, Self.thirdID, 0)
        harness.view.insertText("z")
        await harness.settle()
        XCTAssertEqual(text(of: try block(harness.session, Self.thirdID)), "zThird paragraph.")
        try await assertConsistent(harness, localCommands: 1)
    }

    /// I3 (round 5): a barrier that comes back stale while text is marked is
    /// handled after the composition (a retried Return would commit the
    /// marked text), then retried through the committed text (P5, round 8).
    func testAStaleBarrierWaitsForTheComposition() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        try caret(harness, Self.firstID, 5)
        let peer = try peerEdit { try $0.replaceText(block: Self.thirdID, range: 0..<0, with: "Peer ") }
        harness.session.replica?.mailbox.post(.integrate(peer, reply: nil))
        harness.input.insertNewline()
        harness.view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        _ = await harness.session.settle()
        XCTAssertNotNil(harness.view.markedTextRange, "the marked text is still the keyboard's")
        XCTAssertNil(harness.input.noticeKey, "the stale answer waits")
        harness.view.unmarkText()
        await harness.settle()
        XCTAssertNil(harness.input.noticeKey)
        XCTAssertEqual(texts(harness.session).prefix(2), ["First", "か paragraph."])
        try await assertConsistent(harness, localCommands: 2)
    }

    /// I4: a selection the user made during a barrier that rebuilt its block
    /// (an indent) is captured again when the barrier ends, though the view's
    /// range did not move: the session's capture did not survive the rebuild.
    func testAUserSelectionInABlockTheBarrierRebuiltIsCapturedAgain() async throws {
        let disk = Latch()
        let harness = try await gated(disk)
        try caret(harness, Self.secondID, 0)
        XCTAssertTrue(harness.input.indent())
        try caret(harness, Self.secondID, 4)
        disk.open()
        await harness.settle()
        XCTAssertEqual(
            harness.view.selectedRange, NSRange(location: try location(harness.session, Self.secondID, 4), length: 0))
        let head = await harness.engine { engine -> EditorPosition? in (try? engine.currentSelection())?.head }
        XCTAssertEqual(head?.blockID, Self.secondID)
        XCTAssertEqual(head?.offset, 4)
    }

    /// I5: a rollback a result causes while a barrier is in flight is mapped
    /// like any shown change: a selection in the block it rewrote is dropped,
    /// and the barrier's own caret stands.
    func testARollbackDuringABarrierIsMappedLikeAnyShownChange() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        // The peer deletes the characters around the first key: its epoch ends.
        let peer = try peerEdit { try $0.replaceText(block: Self.firstID, range: 0..<6, with: "") }
        harness.session.replica?.mailbox.post(.integrate(peer, reply: nil))
        try caret(harness, Self.firstID, 3)
        harness.view.insertText("x")
        try caret(harness, Self.secondID, 0)
        harness.view.insertText("y")
        try caret(harness, Self.thirdID, 5)
        XCTAssertTrue(harness.input.insertNewline())
        var selected = false
        harness.session.onDelivery = { [weak self] delivery in
            // Before the rollback rewrites the second block.
            guard case .invalidated? = delivery.result, !selected, let self,
                let location = try? self.location(harness.session, Self.secondID, 10)
            else { return }
            selected = true
            self.setSelection(harness, NSRange(location: location, length: 0))
        }
        await harness.settle()
        XCTAssertTrue(selected)
        XCTAssertEqual(
            texts(harness.session),
            ["paragraph.", "Second paragraph has bold words inside it.", "Third", " paragraph."])
        let split = harness.session.surface.blocks[3].id
        XCTAssertEqual(
            harness.view.selectedRange, NSRange(location: try location(harness.session, split, 0), length: 0))
        try await assertConsistent(harness, localCommands: 1)
    }

    /// I6: a barrier on its own target (a checkbox) is retried even when the
    /// caret's block is gone.
    func testABarrierOnItsOwnTargetIsRetriedWhenTheCaretsBlockIsGone() async throws {
        let blocks = [
            paragraph("a", "Alpha"), paragraph("b", "Beta"),
            BlockNoteBlock(
                node: "checkListItem", props: Self.paragraphProps + [("checked", .bool(false))],
                runs: [InlineRun("Task")], id: "c"),
        ]
        let harness = try await makeHarness(blocks)
        addTeardownBlock { await harness.close() }
        try caret(harness, "b", 2)
        let peer = try makeDoc(blocks, clientID: 9)
        defer { peer.destroy() }
        let join = try BlockNoteWriter(doc: peer).joinBlocks(block: "b")
        harness.session.replica?.mailbox.post(.integrate(join, reply: nil))
        let ticked = await harness.run { harness.input.toggleCheckbox(blockID: "c") }
        XCTAssertTrue(ticked)
        XCTAssertTrue(try block(harness.session, "c").props.contains(ProjectedProp(key: "checked", value: .bool(true))))
        try await assertConsistent(harness, localCommands: 1)
    }

    // MARK: - Review round 5 (PR #272)

    /// J1: once a peer change shows a predicted block's canonical snapshot,
    /// its predictions are off screen: a later peer patch to that block is
    /// not shifted by their length.
    func testAPredictionAlreadyOffScreenDoesNotShiftALaterPeerPatch() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let peer = try makeDoc(clientID: 30)
        defer { peer.destroy() }
        let writer = BlockNoteWriter(doc: peer)
        let cut = try writer.replaceText(block: Self.firstID, range: 0..<5, with: "")
        let bang = try writer.replaceText(block: Self.firstID, range: 11..<11, with: "!")
        harness.session.replica?.mailbox.post(.integrate(cut, reply: nil))
        harness.session.replica?.mailbox.post(.integrate(bang, reply: nil))
        try caret(harness, Self.firstID, 2)
        harness.view.insertText("abc")
        await harness.settle()
        XCTAssertEqual(text(of: try block(harness.session, Self.firstID)), " paragraph.!")
        XCTAssertEqual(harness.input.composition.pendingRecoveries.map(\.text), ["abc"])
        try await assertConsistent(harness, localCommands: 0)
    }

    /// J3 (refuted, kept as a guard): a stale slash item placed back at its
    /// origin consumes the token there, not the one the caret had grown since.
    func testARetriedSlashItemConsumesTheTokenItWasOpenedOn() async throws {
        let blocks = [paragraph("a", "/h1Notes"), paragraph("b", "Beta")]
        let harness = try await makeHarness(blocks)
        addTeardownBlock { await harness.close() }
        try caret(harness, "a", 3)
        let peer = try makeDoc(blocks, clientID: 9)
        defer { peer.destroy() }
        let edit = try BlockNoteWriter(doc: peer).replaceText(block: "b", range: 0..<0, with: "Peer ")
        harness.session.replica?.mailbox.post(.integrate(edit, reply: nil))
        let item = try XCTUnwrap(NativeInputCoordinator.slashItems.first { $0.id == "heading1" })
        XCTAssertTrue(harness.input.applySlashItem(item))
        // The caret moves on meanwhile: the token at it is "/h1Notes".
        try caret(harness, "a", 8)
        await harness.settle()
        let heading = try block(harness.session, "a")
        XCTAssertEqual(heading.node, "heading")
        XCTAssertEqual(text(of: heading), "Notes")
        try await assertConsistent(harness, localCommands: 1)
    }

    /// J4: a selection the view keeps through a peer's rebuild of its block,
    /// while a newer capture is in flight, is captured again: the session's
    /// copy did not survive the rebuild.
    func testASelectionFollowedThroughAPeerRebuildIsCapturedAgain() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let peer = try peerEdit { try $0.setBlockType(block: Self.thirdID, to: "heading") }
        harness.session.replica?.mailbox.post(.integrate(peer, reply: nil))
        try caret(harness, Self.thirdID, 4)
        await harness.settle()
        let head = await harness.engine { engine -> EditorPosition? in (try? engine.currentSelection())?.head }
        XCTAssertEqual(head?.blockID, Self.thirdID)
        XCTAssertEqual(head?.offset, 4)
    }

    /// J5: a rollback leaves a block already showing its snapshot alone (a
    /// key and its deletion), so a selection made in it during a barrier stands.
    func testARollbackLeavesABlockAlreadyShowingItsSnapshotAlone() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let peer = try peerEdit { try $0.replaceText(block: Self.firstID, range: 0..<6, with: "") }
        harness.session.replica?.mailbox.post(.integrate(peer, reply: nil))
        try caret(harness, Self.firstID, 3)
        harness.view.insertText("x")
        try caret(harness, Self.secondID, 0)
        harness.view.insertText("y")
        harness.view.deleteBackward()
        try caret(harness, Self.thirdID, 5)
        XCTAssertTrue(harness.input.insertNewline())
        var selected = false
        harness.session.onDelivery = { [weak self] delivery in
            guard case .invalidated? = delivery.result, !selected, let self,
                let location = try? self.location(harness.session, Self.secondID, 10)
            else { return }
            selected = true
            self.setSelection(harness, NSRange(location: location, length: 0))
        }
        await harness.settle()
        XCTAssertTrue(selected)
        XCTAssertEqual(
            texts(harness.session),
            ["paragraph.", "Second paragraph has bold words inside it.", "Third", " paragraph."])
        XCTAssertEqual(
            harness.view.selectedRange, NSRange(location: try location(harness.session, Self.secondID, 10), length: 0))
        try await assertConsistent(harness, localCommands: 1)
    }

    // MARK: - Review round 6 (PR #272)

    /// K1: while composing, a queued invalidation answers every prediction of
    /// its epoch (the session drops the later ones without a delivery).
    func testAQueuedInvalidationAnswersItsWholeEpoch() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let peer = try peerEdit { try $0.replaceText(block: Self.firstID, range: 0..<6, with: "") }
        harness.session.replica?.mailbox.post(.integrate(peer, reply: nil))
        try caret(harness, Self.firstID, 3)
        harness.view.insertText("x")
        try caret(harness, Self.secondID, 0)
        harness.view.insertText("y")
        try caret(harness, Self.thirdID, 0)
        harness.view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        let drained = await harness.session.settle()
        XCTAssertTrue(drained, "nothing waits on the session, only on the composition")
        harness.view.unmarkText()
        await harness.settle()
        XCTAssertEqual(texts(harness.session).first, "paragraph.")
        // The commit is a prediction of the old epoch: rolled back with the keys.
        XCTAssertEqual(harness.input.composition.pendingRecoveries.map(\.text), ["xyか"])
        try await assertConsistent(harness, localCommands: 0)
    }

    /// K2 and K3 (round 9): the commit shows at once, so UIKit's change
    /// notice and a composing keyboard's direct character right after it take
    /// the ordinary path.
    func testInputRightAfterACommitTakesTheOrdinaryPath() async throws {
        let disk = Latch()
        let harness = try await gated(disk)
        harness.input.inputLanguage = { "ja-JP" }
        try caret(harness, Self.firstID, 5)
        harness.view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        harness.view.unmarkText()
        XCTAssertFalse(harness.input.composition.isActive, "the commit shows at once")
        harness.input.textViewDidChange(harness.view)
        XCTAssertNil(harness.input.noticeKey)
        let range = harness.view.selectedRange
        XCTAssertTrue(harness.input.textView(harness.view, shouldChangeTextIn: range, replacementText: "1"))
        // What UIKit does with an allowed character: write it, move the caret.
        harness.view.textStorage.replaceCharacters(in: range, with: "1")
        harness.view.selectedRange = NSRange(location: range.location + 1, length: 0)
        harness.input.textViewDidChange(harness.view)
        disk.open()
        await harness.settle()
        XCTAssertEqual(texts(harness.session).first, "Firstにほん1 paragraph.")
        XCTAssertNil(harness.input.noticeKey)
        try await assertConsistent(harness, localCommands: 2)
    }

    /// L1: the composition's release is applied like a patch, and its caret
    /// is published, so the session's selection is where the view's caret is.
    func testTheCaretAfterACommitIsTheSessionsSelection() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        // A live editing view: UIKit moves a first responder's selection when
        // its storage slice is replaced.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        harness.view.frame = window.bounds
        window.addSubview(harness.view)
        window.makeKeyAndVisible()
        harness.view.becomeFirstResponder()
        defer {
            harness.view.resignFirstResponder()
            window.isHidden = true
        }
        try caret(harness, Self.firstID, 5)
        harness.view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        harness.view.unmarkText()
        await harness.settle()
        XCTAssertEqual(
            harness.view.selectedRange, NSRange(location: try location(harness.session, Self.firstID, 8), length: 0))
        let head = await harness.engine { engine -> EditorPosition? in (try? engine.currentSelection())?.head }
        XCTAssertEqual(head?.blockID, Self.firstID)
        XCTAssertEqual(head?.offset, 8)
    }

    /// L2: a stale answer queued behind a composition is retried after every
    /// queued delivery, at the base revision that includes the commit.
    func testAStaleBarrierQueuedBehindACompositionIsRetriedAfterIt() async throws {
        let blocks = [
            paragraph("a", "Alpha"), paragraph("b", "Beta"),
            BlockNoteBlock(
                node: "checkListItem", props: Self.paragraphProps + [("checked", .bool(false))],
                runs: [InlineRun("Task")], id: "c"),
        ]
        let harness = try await makeHarness(blocks)
        addTeardownBlock { await harness.close() }
        let peer = try makeDoc(blocks, clientID: 9)
        defer { peer.destroy() }
        let edit = try BlockNoteWriter(doc: peer).replaceText(block: "b", range: 0..<0, with: "Peer ")
        harness.session.replica?.mailbox.post(.integrate(edit, reply: nil))
        try caret(harness, "a", 5)
        XCTAssertTrue(harness.input.toggleCheckbox(blockID: "c"))
        harness.view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        harness.view.unmarkText()
        await harness.settle()
        XCTAssertTrue(try block(harness.session, "c").props.contains(ProjectedProp(key: "checked", value: .bool(true))))
        XCTAssertNil(harness.input.noticeKey)
        XCTAssertEqual(texts(harness.session).prefix(2), ["Alphaか", "Peer Beta"])
        try await assertConsistent(harness, localCommands: 2)
    }

    /// L3: a local storage failure while composing waits for the composition
    /// instead of rolling storage back under the marked text.
    func testALocalFailureWhileComposingWaitsForTheComposition() async throws {
        let disk = Latch()
        let harness = try await gated(disk)
        try caret(harness, Self.thirdID, 0)
        harness.view.insertText("x")
        try caret(harness, Self.firstID, 5)
        harness.view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        let before = harness.view.textStorage.string
        harness.session.freezeAuthoring()
        XCTAssertEqual(harness.view.textStorage.string, before, "storage under marked text is untouched")
        XCTAssertNil(harness.input.noticeKey)
        disk.open()
        harness.view.unmarkText()
        _ = await harness.session.settle()
        XCTAssertEqual(harness.input.noticeKey, .native_editor_storage_failed)
        XCTAssertFalse(harness.view.isEditable)
        XCTAssertTrue(harness.session.surface.storageMatchesModel)
        XCTAssertEqual(texts(harness.session).first, "Firstにほん paragraph.")
        XCTAssertEqual(texts(harness.session).last, "xThird paragraph.")
    }

    /// L3: a composition whose begin or commit cannot be posted (a full
    /// mailbox) never starts, or is resolved locally as orphaned.
    func testACompositionWhosePostFailsResolvesLocally() async throws {
        let blocked = Latch()
        let first = try await gated(Latch(open: true), mailbox: blocked)
        let replica = try XCTUnwrap(first.session.replica)
        try caret(first, Self.firstID, 5)
        while replica.mailbox.post(.writeProvisional([])) {}
        first.view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertFalse(first.input.composition.isActive)
        XCTAssertNil(first.view.markedTextRange)
        XCTAssertEqual(first.input.noticeKey, .native_editor_storage_failed, "N5: the refusal keeps it")
        blocked.open()

        let gate = Latch()
        let second = try await gated(Latch(open: true), mailbox: gate)
        let mailbox = try XCTUnwrap(second.session.replica).mailbox
        try caret(second, Self.firstID, 5)
        second.view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        XCTAssertTrue(second.input.composition.isActive)
        while mailbox.post(.writeProvisional([])) {}
        second.view.unmarkText()
        XCTAssertFalse(second.input.composition.isActive)
        XCTAssertEqual(second.input.composition.pendingRecoveries.map(\.text), ["にほん"])
        XCTAssertEqual(second.input.noticeKey, .native_editor_storage_failed)
        XCTAssertTrue(second.session.surface.storageMatchesModel)
        gate.open()
    }

    /// L4: a prediction journaled in a block whose display went canonical (a
    /// later key there could not be rebased) is shown at once.
    func testAJournaledKeyInAnOffScreenBlockIsShown() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let peer = try peerEdit { try $0.replaceText(block: Self.firstID, range: 8..<14, with: "") }
        harness.session.replica?.mailbox.post(.integrate(peer, reply: nil))
        try caret(harness, Self.firstID, 0)
        harness.view.insertText("a")
        try caret(harness, Self.firstID, 12)
        harness.view.insertText("b")
        var shown: String?
        harness.session.onDelivery = { [weak self] delivery in
            guard case .invalidated? = delivery.result, shown == nil, let self else { return }
            shown = try? self.text(of: self.block(harness.session, Self.firstID))
        }
        await harness.settle()
        XCTAssertEqual(shown, "aFirst pah.", "the journaled key showed before the invalidation")
        XCTAssertEqual(text(of: try block(harness.session, Self.firstID)), "aFirst pah.")
        XCTAssertEqual(harness.input.composition.pendingRecoveries.map(\.text), ["b"])
        try await assertConsistent(harness, localCommands: 1)
    }

    // MARK: - Review round 7 (PR #272)

    /// N5: the next IME key while the previous commit is still in flight is
    /// held and begins once that commit is applied; the editor is not locked.
    func testMarkedTextBehindACommitInFlightIsHeldNotRefused() async throws {
        let disk = Latch()
        let harness = try await gated(disk)
        try caret(harness, Self.firstID, 5)
        harness.view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        harness.view.unmarkText()
        harness.view.setMarkedText("ご", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertTrue(harness.view.isEditable, "not refused")
        XCTAssertNil(harness.input.noticeKey)
        disk.open()
        _ = await harness.session.settle()
        XCTAssertEqual(harness.view.markedTextRange.flatMap { harness.view.text(in: $0) }, "ご")
        harness.view.unmarkText()
        await harness.settle()
        XCTAssertEqual(texts(harness.session).first, "Firstにほんご paragraph.")
        try await assertConsistent(harness, localCommands: 2)
    }

    /// N7a: a cut while a barrier is in flight is refused with the busy notice
    /// (a held delete would leave its copy unwritten); nothing is deleted.
    func testACutWhileBusyIsRefused() async throws {
        let disk = Latch()
        let harness = try await gated(disk)
        harness.pasteboard.string = "kept"
        try caret(harness, Self.firstID, 5)
        harness.view.insertText("\n")
        setSelection(harness, NSRange(location: try location(harness.session, Self.thirdID, 0), length: 5))
        XCTAssertFalse(harness.input.cutSelection())
        XCTAssertEqual(harness.input.noticeKey, .native_editor_input_busy)
        disk.open()
        await harness.settle()
        XCTAssertEqual(harness.pasteboard.string, "kept")
        XCTAssertEqual(texts(harness.session).last, "Third paragraph.")
        try await assertConsistent(harness, localCommands: 1)
    }

    /// N7b (round 9): there is no commit in flight any more: copy right after
    /// a commit copies the selection.
    func testCopyRightAfterACommitCopiesTheSelection() async throws {
        let disk = Latch()
        let harness = try await gated(disk)
        harness.pasteboard.string = "kept"
        try caret(harness, Self.firstID, 5)
        harness.view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        harness.view.unmarkText()
        harness.view.selectedRange = NSRange(location: try location(harness.session, Self.secondID, 0), length: 6)
        harness.view.copy(nil)
        XCTAssertEqual(harness.pasteboard.string, "Second")
        disk.open()
        await harness.settle()
        try await assertConsistent(harness, localCommands: 1)
    }

    /// N1 and N2: a cancel that cannot be posted is answered as cancelled: no
    /// recovery entry, and the storage notice stays.
    func testACancelWhosePostFailsIsCancelledAndKeepsTheNotice() async throws {
        let gate = Latch()
        let harness = try await gated(Latch(open: true), mailbox: gate)
        let mailbox = try XCTUnwrap(harness.session.replica).mailbox
        try caret(harness, Self.firstID, 5)
        harness.view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        while mailbox.post(.writeProvisional([])) {}
        harness.view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        XCTAssertFalse(harness.input.composition.isActive)
        XCTAssertEqual(harness.input.noticeKey, .native_editor_storage_failed)
        XCTAssertEqual(harness.input.composition.pendingRecoveries.map(\.text), [])
        XCTAssertTrue(harness.session.surface.storageMatchesModel)
        gate.open()
    }

    /// N3: a stale barrier retried after a composition keeps the
    /// composition's caret, the user's latest selection.
    func testACompositionsCaretSurvivesAStaleRetryQueuedBehindIt() async throws {
        let blocks = [paragraph("a", "Alpha"), paragraph("b", "Beta"), paragraph("c", "Gamma")]
        let harness = try await makeHarness(blocks)
        addTeardownBlock { await harness.close() }
        let peer = try makeDoc(blocks, clientID: 9)
        defer { peer.destroy() }
        let edit = try BlockNoteWriter(doc: peer).replaceText(block: "a", range: 0..<0, with: "Peer ")
        harness.session.replica?.mailbox.post(.integrate(edit, reply: nil))
        try caret(harness, "c", 2)
        XCTAssertTrue(harness.input.indent())
        try caret(harness, "b", 4)
        harness.view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        harness.view.unmarkText()
        await harness.settle()
        XCTAssertEqual(text(of: try block(harness.session, "b")), "Betaか")
        XCTAssertEqual(try block(harness.session, "c").parentID, "b", "the retried indent ran")
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(harness.session, "b", 5), length: 0))
        try await assertConsistent(harness, localCommands: 2)
    }

    /// N4: a failure that waited for a composition stops authoring before a
    /// stale barrier queued behind it could be retried.
    func testAFailureThatWaitedForACompositionStopsAStaleRetry() async throws {
        let blocks = [
            paragraph("a", "Alpha"), paragraph("b", "Beta"),
            BlockNoteBlock(
                node: "checkListItem", props: Self.paragraphProps + [("checked", .bool(false))],
                runs: [InlineRun("Task")], id: "c"),
        ]
        let harness = try await makeHarness(blocks)
        addTeardownBlock { await harness.close() }
        let peer = try makeDoc(blocks, clientID: 9)
        defer { peer.destroy() }
        let edit = try BlockNoteWriter(doc: peer).replaceText(block: "b", range: 0..<0, with: "Peer ")
        harness.session.replica?.mailbox.post(.integrate(edit, reply: nil))
        try caret(harness, "a", 5)
        XCTAssertTrue(harness.input.toggleCheckbox(blockID: "c"))
        harness.view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        harness.session.freezeAuthoring()
        harness.view.unmarkText()
        _ = await harness.session.settle()
        XCTAssertFalse(
            try block(harness.session, "c").props.contains(ProjectedProp(key: "checked", value: .bool(true))))
        XCTAssertEqual(harness.input.noticeKey, .native_editor_storage_failed)
        XCTAssertEqual(harness.log.commands.count, 1, "the commit only")
    }

    /// N8: a composition begun before the main actor saw its epoch end is not
    /// captured (its offsets count a dropped prediction): the commit is orphaned.
    func testACompositionBegunBeforeAnInvalidationArrivesIsOrphaned() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let peer = try peerEdit { try $0.replaceText(block: Self.firstID, range: 0..<6, with: "") }
        harness.session.replica?.mailbox.post(.integrate(peer, reply: nil))
        try caret(harness, Self.firstID, 3)
        harness.view.insertText("x")
        try caret(harness, Self.secondID, 0)
        harness.view.insertText("yy")
        var began = false
        harness.session.onDelivery = { delivery in
            guard case .invalidated? = delivery.result, !began else { return }
            began = true
            harness.view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        }
        _ = await harness.session.settle()
        XCTAssertTrue(began)
        harness.view.unmarkText()
        await harness.settle()
        XCTAssertEqual(texts(harness.session).prefix(2), ["paragraph.", "Second paragraph has bold words inside it."])
        XCTAssertEqual(Set(harness.input.composition.pendingRecoveries.map(\.text)), ["xyy", "か"])
        try await assertConsistent(harness, localCommands: 0)
    }

    // MARK: - Review round 8 (PR #272)

    /// A gated harness whose first composition commit is still in flight, with
    /// `held` sent by the keyboard behind it.
    private func commitInFlight(_ disk: Latch, held: String) async throws -> Harness {
        let harness = try await gated(disk)
        try caret(harness, Self.firstID, 5)
        harness.view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        harness.view.unmarkText()
        harness.view.setMarkedText(held, selectedRange: NSRange(location: held.utf16.count, length: 0))
        XCTAssertTrue(harness.input.composition.isActive, "the next marked text begins at once")
        return harness
    }

    /// P1: held marked text begins even when replayed keys leave input busy,
    /// and the keyboard's next marked string supersedes it (no second copy).
    func testHeldMarkedTextIsSupersededByTheKeyboardsNextString() async throws {
        let disk = Latch()
        let harness = try await gated(disk)
        try caret(harness, Self.firstID, 5)
        harness.view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        harness.view.unmarkText()
        harness.view.insertText("\n")
        harness.view.insertText("y")
        harness.view.setMarkedText("ご", selectedRange: NSRange(location: 1, length: 0))
        // The replayed Return's append waits, so "y" stays held behind it.
        harness.session.onDelivery = { delivery in
            if case .composition? = delivery.result { disk.close() }
        }
        disk.open()
        await waitUntil { disk.waiting == 1 }
        harness.session.onDelivery = nil
        harness.view.setMarkedText("ごは", selectedRange: NSRange(location: 2, length: 0))
        disk.open()
        harness.view.unmarkText()
        await harness.settle()
        XCTAssertNil(harness.view.markedTextRange)
        XCTAssertEqual(texts(harness.session).joined().components(separatedBy: "ご").count, 2, "one ご")
        try await assertConsistent(harness, localCommands: 4)
    }

    /// P3: Return commits held marked text like a composition (no split), and
    /// a candidate replaces it.
    func testReturnCommitsHeldMarkedTextAndACandidateReplacesIt() async throws {
        let disk = Latch()
        let harness = try await commitInFlight(disk, held: "ご")
        harness.view.insertText("\n")
        disk.open()
        await harness.settle()
        XCTAssertEqual(texts(harness.session).first, "Firstにほんご paragraph.")
        XCTAssertEqual(harness.session.surface.blocks.count, 3, "no split")

        disk.close()
        harness.view.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
        harness.view.unmarkText()
        harness.view.setMarkedText("き", selectedRange: NSRange(location: 1, length: 0))
        harness.view.replace(try XCTUnwrap(harness.view.markedTextRange), withText: "木")
        disk.open()
        await harness.settle()
        XCTAssertNil(harness.view.markedTextRange)
        XCTAssertEqual(texts(harness.session).first, "Firstにほんごかな木 paragraph.")
        try await assertConsistent(harness, localCommands: 4)
    }

    /// P4: editing that ends while marked text is held keeps it as a recovery
    /// entry; nothing composes later and deliveries keep applying.
    func testEndingEditingRecoversHeldMarkedText() async throws {
        let disk = Latch()
        let harness = try await commitInFlight(disk, held: "ご")
        harness.input.textViewDidEndEditing(harness.view)
        disk.open()
        await harness.settle()
        XCTAssertFalse(harness.input.composition.isActive)
        XCTAssertTrue(harness.input.composition.pendingRecoveries.map(\.text).contains("ご"))
        let peer = try peerEdit { try $0.replaceText(block: Self.thirdID, range: 0..<0, with: "Peer ") }
        harness.session.replica?.mailbox.post(.integrate(peer, reply: nil))
        await harness.settle()
        XCTAssertEqual(texts(harness.session).last, "Peer Third paragraph.")
    }

    /// P5: a stale barrier in the block a composition committed into is
    /// retried through the committed text, not dropped as a rebuilt block.
    func testAStaleBarrierInTheComposedBlockIsRetriedThroughTheCommit() async throws {
        let blocks = [paragraph("a", "Alpha"), paragraph("b", "Beta")]
        let harness = try await makeHarness(blocks)
        addTeardownBlock { await harness.close() }
        let peer = try makeDoc(blocks, clientID: 9)
        defer { peer.destroy() }
        let edit = try BlockNoteWriter(doc: peer).replaceText(block: "b", range: 0..<0, with: "Peer ")
        harness.session.replica?.mailbox.post(.integrate(edit, reply: nil))
        try caret(harness, "a", 2)
        XCTAssertTrue(harness.input.insertNewline())
        harness.view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        harness.view.unmarkText()
        await harness.settle()
        XCTAssertNil(harness.input.noticeKey)
        XCTAssertEqual(texts(harness.session), ["Al", "かpha", "Peer Beta"])
        try await assertConsistent(harness, localCommands: 2)
    }

    /// P5: a cancelled composition's caret is not taken as the user's
    /// selection (nor is the editor's own placement during the barrier): an
    /// undo retried behind it puts the caret where its step was.
    func testACancelledCompositionLeavesAStaleUndoItsSelection() async throws {
        let blocks = [paragraph("a", "Alpha"), paragraph("b", "Beta")]
        let harness = try await makeHarness(blocks)
        addTeardownBlock { await harness.close() }
        try caret(harness, "a", 5)
        harness.view.insertText("!")
        await harness.settle()
        let peer = try makeDoc(blocks, clientID: 9)
        defer { peer.destroy() }
        let edit = try BlockNoteWriter(doc: peer).replaceText(block: "b", range: 0..<0, with: "Peer ")
        harness.session.replica?.mailbox.post(.integrate(edit, reply: nil))
        try caret(harness, "b", 2)
        XCTAssertTrue(harness.input.undo())
        harness.view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        harness.view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        await harness.settle()
        XCTAssertEqual(texts(harness.session), ["Alpha", "Peer Beta"])
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: try location(harness.session, "a", 5), length: 0))
    }

    // MARK: - Round 9: the optimistic commit (PR #272)

    /// A commit shows at once as a prediction, and the next marked text
    /// begins at once after it: its begin, posted before the commit's echo,
    /// rebases cleanly in the session.
    func testACommitShowsAtOnceAndTheNextCompositionBeginsBehindIt() async throws {
        let disk = Latch()
        let harness = try await gated(disk)
        try caret(harness, Self.firstID, 5)
        harness.view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        harness.view.unmarkText()
        XCTAssertEqual(text(of: try block(harness.session, Self.firstID)), "Firstにほん paragraph.", "shown at once")
        harness.view.setMarkedText("ご", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertTrue(harness.input.composition.isActive)
        XCTAssertEqual(harness.view.markedTextRange.flatMap { harness.view.text(in: $0) }, "ご")
        harness.view.unmarkText()
        XCTAssertEqual(text(of: try block(harness.session, Self.firstID)), "Firstにほんご paragraph.")
        disk.open()
        await harness.settle()
        XCTAssertEqual(text(of: try block(harness.session, Self.firstID)), "Firstにほんご paragraph.")
        XCTAssertEqual(harness.input.composition.pendingRecoveries.map(\.text), [])
        try await assertConsistent(harness, localCommands: 2)
    }

    /// When a commit's rebuild folds in a peer edit the composition discarded,
    /// the session keeps it in the surface's unseen ring: a composition begun
    /// before that echo arrived is orphaned and kept as a recovery entry.
    func testACompositionBehindACommitThatFoldedAPeerEditIsKept() async throws {
        let disk = Latch()
        let harness = try await gated(disk)
        try caret(harness, Self.firstID, 5)
        harness.view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        let peer = try peerEdit { try $0.replaceText(block: Self.firstID, range: 16..<16, with: "!") }
        harness.session.replica?.mailbox.post(.integrate(peer, reply: nil))
        harness.view.unmarkText()
        harness.view.setMarkedText("ご", selectedRange: NSRange(location: 1, length: 0))
        harness.view.unmarkText()
        disk.open()
        await harness.settle()
        XCTAssertEqual(text(of: try block(harness.session, Self.firstID)), "Firstにほん paragraph.!")
        XCTAssertEqual(harness.input.composition.pendingRecoveries.map(\.text), ["ご"])
        try await assertConsistent(harness, localCommands: 1)
    }
}
