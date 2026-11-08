import UIKit
import XCTest

@testable import Schrift

/// Provisional IME text is persisted beside the journal, never in it: no
/// outbox entry, no broadcast, no automatic commit after a crash. A relaunch
/// (a new session over the same store, which is all a crash leaves behind) or
/// an orphaned commit offers explicit recovery: insert at the caret, copy or
/// discard. Deterministic synthetic `setMarkedText`/`unmarkText`, no sleeps.
@MainActor
final class NativeCompositionRecoveryTests: DocumentEngineTestCase {
    private enum DiskError: Error { case full }

    @MainActor
    private final class Replica {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scope = ReplicaScope(
            serverOrigin: "https://example.test", ownerUserID: UUID(), org: "docs", documentID: UUID())
        lazy var store = ReplicaStore(directory: directory)
        var writes: [NativeEditCommand] = []
        var failNextAppend = false

        isolated deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeReplica(_ blocks: [BlockNoteBlock] = seedBlocks()) throws -> Replica {
        let replica = Replica()
        _ = try replica.store.create(for: replica.scope, checkpoint: BlockNoteYjs.encode(blocks, clientID: 1))
        return replica
    }

    /// One app launch over the replica: restore, then durable typing.
    private func launch(_ replica: Replica) throws -> NativeEditorSession {
        let session = try XCTUnwrap(NativeEditorSession.restore(store: replica.store, scope: replica.scope))
        session.enableTyping { command, update in
            if replica.failNextAppend {
                replica.failNextAppend = false
                throw DiskError.full
            }
            try replica.store.append(
                update, for: replica.scope, commandID: command.id, baseRevision: command.baseRevision, origin: .local)
            replica.writes.append(command)
        }
        return session
    }

    private func caret(_ session: NativeEditorSession, _ blockID: String, _ offset: Int) throws -> Int {
        try XCTUnwrap(session.surface.rangeIndex.entry(for: blockID)).textRange.location + offset
    }

    private func text(_ session: NativeEditorSession, _ blockID: String) throws -> String {
        let position = try XCTUnwrap(session.surface.rangeIndex.position(for: blockID))
        return session.surface.blocks[position].runs.map(\.text).joined()
    }

    private func compose(_ session: NativeEditorSession, _ marked: [String], at location: Int) {
        session.textView.selectedRange = NSRange(location: location, length: 0)
        for text in marked {
            session.textView.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
        }
    }

    private func assertMatches(_ session: NativeEditorSession, file: StaticString = #filePath, line: UInt = #line) {
        let fresh = AttributedDocumentProjection.attributedString(
            blocks: session.surface.blocks, traits: session.surface.traits, labels: session.surface.labels)
        XCTAssertTrue(session.textView.textStorage.isEqual(to: fresh), file: file, line: line)
    }

    /// Nothing provisional ever reaches committed state: no journal entry, no
    /// outbox sequence, no replayed text.
    private func assertNothingCommitted(
        _ replica: Replica, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let manifest = try XCTUnwrap(replica.store.manifest(for: replica.scope), file: file, line: line)
        XCTAssertEqual(manifest.revision, 0, file: file, line: line)
        XCTAssertTrue(manifest.journal.isEmpty, file: file, line: line)
        XCTAssertTrue(manifest.outbox.isEmpty, file: file, line: line)
        XCTAssertNil(try replica.store.outbox(for: replica.scope), file: file, line: line)
    }

    // MARK: - Persistence

    func testProvisionalTextIsPersistedOnEveryChangeOutsideTheJournal() throws {
        let replica = try makeReplica()
        let session = try launch(replica)
        defer { session.close() }

        compose(session, ["に"], at: try caret(session, Self.firstID, 0))
        XCTAssertEqual(replica.store.provisionalRecoveries(for: replica.scope).map(\.text), ["に"])
        compose(session, ["にほん", "日本"], at: try caret(session, Self.firstID, 0))

        let entries = replica.store.provisionalRecoveries(for: replica.scope)
        XCTAssertEqual(entries.map(\.text), ["日本"])
        XCTAssertEqual(entries.map(\.state), [.composing])
        XCTAssertEqual(entries.map(\.blockID), [Self.firstID])
        XCTAssertTrue(session.input?.composition.pendingRecoveries.isEmpty == true, "the live one is not a recovery")
        try assertNothingCommitted(replica)
    }

    func testCommitWritesOnceAndClearsTheProvisionalFile() throws {
        let replica = try makeReplica()
        let session = try launch(replica)
        defer { session.close() }
        compose(session, ["にほん", "日本"], at: try caret(session, Self.firstID, 6))

        session.textView.unmarkText()

        XCTAssertEqual(replica.writes.map(\.replacement), ["日本"])
        XCTAssertTrue(replica.store.provisionalRecoveries(for: replica.scope).isEmpty)
        XCTAssertTrue(session.input?.composition.pendingRecoveries.isEmpty == true)
        XCTAssertEqual(try replica.store.manifest(for: replica.scope)?.outbox, [1])
    }

    func testCancelWritesNothingAndClearsTheProvisionalFile() throws {
        let replica = try makeReplica()
        let session = try launch(replica)
        defer { session.close() }
        compose(session, ["にほん"], at: try caret(session, Self.firstID, 6))

        session.textView.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))

        XCTAssertTrue(replica.store.provisionalRecoveries(for: replica.scope).isEmpty)
        XCTAssertTrue(session.input?.composition.pendingRecoveries.isEmpty == true)
        try assertNothingCommitted(replica)
        assertMatches(session)
    }

    // MARK: - Crash and relaunch

    func testRelaunchMidCompositionOffersRecoveryAndNeverAutoCommits() throws {
        let replica = try makeReplica()
        let crashed = try launch(replica)
        compose(crashed, ["にほん"], at: try caret(crashed, Self.firstID, 6))
        // A crash runs no commit, cancel or cleanup; only the files remain.
        crashed.close()

        let session = try launch(replica)
        defer { session.close() }

        let pending = try XCTUnwrap(session.input?.composition.pendingRecoveries)
        XCTAssertEqual(pending.map(\.text), ["にほん"])
        XCTAssertEqual(pending.map(\.state), [.composing])
        XCTAssertEqual(try text(session, Self.firstID), "First paragraph.", "never inserted silently")
        XCTAssertFalse(session.textView.textStorage.string.contains("にほん"))
        XCTAssertEqual(session.engine.revision, 0)
        try assertNothingCommitted(replica)
        XCTAssertTrue(replica.writes.isEmpty)
        assertMatches(session)

        // A further relaunch still offers it: only an explicit choice resolves it.
        session.close()
        let again = try launch(replica)
        defer { again.close() }
        XCTAssertEqual(again.input?.composition.pendingRecoveries.map(\.text), ["にほん"])
    }

    func testInsertingRecoveredTextAtTheCaretIsOneDurableWrite() throws {
        let replica = try makeReplica()
        let crashed = try launch(replica)
        compose(crashed, ["にほん", "日本"], at: try caret(crashed, Self.firstID, 6))
        crashed.close()
        let session = try launch(replica)
        defer { session.close() }
        let input = try XCTUnwrap(session.input)
        let recovery = try XCTUnwrap(input.composition.pendingRecoveries.first)
        session.textView.selectedRange = NSRange(location: try caret(session, Self.thirdID, 5), length: 0)

        XCTAssertTrue(input.insertRecovery(recovery))

        XCTAssertEqual(replica.writes.map(\.replacement), ["日本"])
        XCTAssertEqual(try text(session, Self.thirdID), "Third日本 paragraph.", "at the chosen caret")
        XCTAssertTrue(input.composition.pendingRecoveries.isEmpty)
        XCTAssertTrue(replica.store.provisionalRecoveries(for: replica.scope).isEmpty)
        assertMatches(session)
        session.close()
        let relaunched = try launch(replica)
        defer { relaunched.close() }
        XCTAssertTrue(relaunched.input?.composition.pendingRecoveries.isEmpty == true)
        XCTAssertEqual(try text(relaunched, Self.thirdID), "Third日本 paragraph.")
    }

    func testCopyAndDiscardResolveRecoveryWithoutWriting() throws {
        let replica = try makeReplica()
        let crashed = try launch(replica)
        compose(crashed, ["かな"], at: try caret(crashed, Self.firstID, 0))
        crashed.close()
        var session = try launch(replica)
        var input = try XCTUnwrap(session.input)

        input.copyRecovery(try XCTUnwrap(input.composition.pendingRecoveries.first))

        XCTAssertEqual(UIPasteboard.general.string, "かな")
        XCTAssertTrue(input.composition.pendingRecoveries.isEmpty)
        XCTAssertTrue(replica.store.provisionalRecoveries(for: replica.scope).isEmpty)
        session.close()

        session = try launch(replica)
        compose(session, ["すて"], at: try caret(session, Self.firstID, 0))
        session.close()
        session = try launch(replica)
        defer { session.close() }
        input = try XCTUnwrap(session.input)
        input.discardRecovery(try XCTUnwrap(input.composition.pendingRecoveries.first))

        XCTAssertTrue(input.composition.pendingRecoveries.isEmpty)
        XCTAssertTrue(replica.store.provisionalRecoveries(for: replica.scope).isEmpty)
        XCTAssertEqual(try text(session, Self.firstID), "First paragraph.")
        try assertNothingCommitted(replica)
    }

    func testRecoveryInsertAtAnUnownedCaretKeepsTheEntry() throws {
        let replica = try makeReplica()
        let crashed = try launch(replica)
        compose(crashed, ["に"], at: try caret(crashed, Self.firstID, 0))
        crashed.close()
        let session = try launch(replica)
        defer { session.close() }
        let input = try XCTUnwrap(session.input)
        // After the last separator, which no block owns.
        session.textView.selectedRange = NSRange(location: session.textView.textStorage.length, length: 0)

        XCTAssertFalse(input.insertRecovery(try XCTUnwrap(input.composition.pendingRecoveries.first)))

        XCTAssertEqual(input.noticeKey, .native_editor_input_unavailable)
        XCTAssertEqual(input.composition.pendingRecoveries.map(\.text), ["に"])
        try assertNothingCommitted(replica)
    }

    // MARK: - Orphaned commit

    func testOrphanedCommitIsPersistedForRecoveryAcrossRelaunch() throws {
        let replica = try makeReplica()
        let session = try launch(replica)
        let peer = try makeDoc(clientID: 2)
        defer { peer.destroy() }
        let peerEngine = DocumentEngine(doc: peer, surface: HeadlessSurface(blocks: projection(peer)))
        compose(session, ["にほん"], at: try caret(session, Self.secondID, 6))
        try session.integrateServerState(peerEngine.joinBlocks(block: Self.secondID))

        session.textView.unmarkText()

        XCTAssertTrue(replica.writes.isEmpty, "never redirected into another block")
        XCTAssertEqual(session.input?.composition.pendingRecoveries.map(\.state), [.orphaned])
        assertMatches(session)
        session.close()

        let relaunched = try launch(replica)
        defer { relaunched.close() }
        let pending = try XCTUnwrap(relaunched.input?.composition.pendingRecoveries)
        XCTAssertEqual(pending.map(\.text), ["にほん"])
        XCTAssertEqual(pending.map(\.state), [.orphaned])
        XCTAssertEqual(try replica.store.manifest(for: replica.scope)?.outbox, [], "the peer join is remote only")
    }

    func testANewCompositionKeepsAnEarlierRecoveryEntry() throws {
        let replica = try makeReplica()
        let crashed = try launch(replica)
        compose(crashed, ["まえ"], at: try caret(crashed, Self.firstID, 0))
        crashed.close()
        let session = try launch(replica)
        defer { session.close() }

        compose(session, ["あと"], at: try caret(session, Self.thirdID, 0))
        XCTAssertEqual(session.input?.composition.pendingRecoveries.map(\.text), ["まえ"])
        session.textView.unmarkText()

        XCTAssertEqual(replica.writes.map(\.replacement), ["あと"])
        XCTAssertEqual(replica.store.provisionalRecoveries(for: replica.scope).map(\.text), ["まえ"])
    }

    // MARK: - Failure and crash windows

    func testFailedCommitAppendKeepsTheTextOnDiskAndPublishesNothing() throws {
        let replica = try makeReplica()
        let session = try launch(replica)
        let before = session.surface.blocks
        compose(session, ["日本"], at: try caret(session, Self.firstID, 0))
        replica.failNextAppend = true

        session.textView.unmarkText()

        XCTAssertEqual(session.input?.noticeKey, .native_editor_storage_failed)
        XCTAssertFalse(session.textView.isEditable)
        XCTAssertEqual(session.surface.blocks, before, "no publication without the journal")
        assertMatches(session)
        try assertNothingCommitted(replica)
        session.close()

        let relaunched = try launch(replica)
        defer { relaunched.close() }
        XCTAssertEqual(relaunched.input?.composition.pendingRecoveries.map(\.text), ["日本"])
        XCTAssertEqual(try text(relaunched, Self.firstID), "First paragraph.")
    }

    func testAnEntryWhoseCommandReachedTheJournalIsDroppedAsCommitted() throws {
        let replica = try makeReplica()
        let session = try launch(replica)
        compose(session, ["日本"], at: try caret(session, Self.firstID, 0))
        let live = try XCTUnwrap(replica.store.provisionalRecoveries(for: replica.scope).first)
        session.textView.unmarkText()
        session.close()
        // A crash between the journal append and the provisional cleanup.
        try replica.store.writeProvisionalRecoveries([live], for: replica.scope)

        XCTAssertEqual(replica.writes.map(\.id), [live.commandID], "the commit used the persisted id")
        XCTAssertTrue(replica.store.provisionalRecoveries(for: replica.scope).isEmpty)
        let relaunched = try launch(replica)
        defer { relaunched.close() }
        XCTAssertTrue(relaunched.input?.composition.pendingRecoveries.isEmpty == true)
        XCTAssertEqual(try text(relaunched, Self.firstID), "日本First paragraph.", "committed exactly once")
    }

    func testRemovingTheReplicaRemovesItsProvisionalText() throws {
        let replica = try makeReplica()
        let session = try launch(replica)
        compose(session, ["に"], at: try caret(session, Self.firstID, 0))
        session.close()

        try replica.store.remove(for: replica.scope)

        XCTAssertTrue(replica.store.provisionalRecoveries(for: replica.scope).isEmpty)
        let stale = ProvisionalRecovery(commandID: UUID(), blockID: Self.firstID, text: "に", state: .composing)
        XCTAssertThrowsError(
            try replica.store.writeProvisionalRecoveries([stale], for: replica.scope), "no folder, no recovery")
    }
}
