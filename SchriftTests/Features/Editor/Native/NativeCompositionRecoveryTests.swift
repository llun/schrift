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

    final class Replica: Sendable {
        let directory: URL
        let scope: ReplicaScope
        let store: ReplicaStore
        let writes = Locked<[NativeEditCommand]>([])
        let failNextAppend = Locked<Bool>(false)

        init(directory: URL, scope: ReplicaScope, store: ReplicaStore) {
            self.directory = directory
            self.scope = scope
            self.store = store
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeReplica(_ blocks: [BlockNoteBlock] = seedBlocks()) throws -> Replica {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scope = ReplicaScope(
            serverOrigin: "https://example.test", ownerUserID: UUID(), org: "docs", documentID: UUID())
        let store = ReplicaStore(directory: directory)
        _ = try store.create(for: scope, checkpoint: BlockNoteYjs.encode(blocks, clientID: 1))
        return Replica(directory: directory, scope: scope, store: store)
    }

    /// One app launch over the replica: restore, then durable typing.
    private func launch(_ replica: Replica) async throws -> NativeEditorSession {
        let session = try unwrapped(try await NativeEditorSession.restore(store: replica.store, scope: replica.scope))
        let store = replica.store
        let scope = replica.scope
        let failNext = replica.failNextAppend
        let writes = replica.writes
        session.enableTyping(persist: { command, update in
            var shouldFail = false
            failNext.update { failing in
                if failing {
                    failing = false
                    shouldFail = true
                }
            }
            if shouldFail {
                throw DiskError.full
            }
            try store.append(
                update, for: scope, commandID: command.id, baseRevision: command.baseRevision, origin: .local)
            writes.update { $0.append(command) }
        })
        return session
    }

    private func caret(_ session: NativeEditorSession, _ blockID: String, _ offset: Int) throws -> Int {
        try XCTUnwrap(session.surface.rangeIndex.entry(for: blockID)).textRange.location + offset
    }

    private func text(_ session: NativeEditorSession, _ blockID: String) throws -> String {
        let position = try XCTUnwrap(session.surface.rangeIndex.position(for: blockID))
        return session.surface.blocks[position].runs.map(\.text).joined()
    }

    private func compose(_ session: NativeEditorSession, _ marked: [String], at location: Int) async {
        session.textView.selectedRange = NSRange(location: location, length: 0)
        for text in marked {
            session.textView.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
        }
        await session.settle()
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

    func testProvisionalTextIsPersistedOnEveryChangeOutsideTheJournal() async throws {
        let replica = try makeReplica()
        let session = try await launch(replica)
        addTeardownBlock { await session.close().value }

        await compose(session, ["に"], at: try caret(session, Self.firstID, 0))
        XCTAssertEqual(replica.store.provisionalRecoveries(for: replica.scope).map(\.text), ["に"])
        await compose(session, ["にほん", "日本"], at: try caret(session, Self.firstID, 0))

        let entries = replica.store.provisionalRecoveries(for: replica.scope)
        XCTAssertEqual(entries.map(\.text), ["日本"])
        XCTAssertEqual(entries.map(\.state), [.composing])
        XCTAssertEqual(entries.map(\.blockID), [Self.firstID])
        XCTAssertTrue(session.input?.composition.pendingRecoveries.isEmpty == true, "the live one is not a recovery")
        try assertNothingCommitted(replica)
    }

    func testCommitWritesOnceAndClearsTheProvisionalFile() async throws {
        let replica = try makeReplica()
        let session = try await launch(replica)
        addTeardownBlock { await session.close().value }
        await compose(session, ["にほん", "日本"], at: try caret(session, Self.firstID, 6))

        session.textView.unmarkText()
        await session.settle()

        XCTAssertEqual(replica.writes.value.map(\.replacement), ["日本"])
        XCTAssertTrue(replica.store.provisionalRecoveries(for: replica.scope).isEmpty)
        XCTAssertTrue(session.input?.composition.pendingRecoveries.isEmpty == true)
        XCTAssertEqual(try replica.store.manifest(for: replica.scope)?.outbox, [1])
    }

    func testCancelWritesNothingAndClearsTheProvisionalFile() async throws {
        let replica = try makeReplica()
        let session = try await launch(replica)
        addTeardownBlock { await session.close().value }
        await compose(session, ["にほん"], at: try caret(session, Self.firstID, 6))

        session.textView.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        await session.settle()

        XCTAssertTrue(replica.store.provisionalRecoveries(for: replica.scope).isEmpty)
        XCTAssertTrue(session.input?.composition.pendingRecoveries.isEmpty == true)
        try assertNothingCommitted(replica)
        assertMatches(session)
    }

    // MARK: - Crash and relaunch

    func testRelaunchMidCompositionOffersRecoveryAndNeverAutoCommits() async throws {
        let replica = try makeReplica()
        let crashed = try await launch(replica)
        await compose(crashed, ["にほん"], at: try caret(crashed, Self.firstID, 6))
        // A crash runs no commit, cancel or cleanup; only the files remain.
        await crashed.close().value

        let session = try await launch(replica)
        addTeardownBlock { await session.close().value }

        let pending = try XCTUnwrap(session.input?.composition.pendingRecoveries)
        XCTAssertEqual(pending.map(\.text), ["にほん"])
        XCTAssertEqual(pending.map(\.state), [.composing])
        XCTAssertEqual(try text(session, Self.firstID), "First paragraph.", "never inserted silently")
        XCTAssertFalse(session.textView.textStorage.string.contains("にほん"))
        let rev = await session.engine { $0.revision }
        XCTAssertEqual(rev, 0)
        try assertNothingCommitted(replica)
        XCTAssertTrue(replica.writes.value.isEmpty)
        assertMatches(session)

        // A further relaunch still offers it: only an explicit choice resolves it.
        await session.close().value
        let again = try await launch(replica)
        addTeardownBlock { await again.close().value }
        XCTAssertEqual(again.input?.composition.pendingRecoveries.map(\.text), ["にほん"])
    }

    func testInsertingRecoveredTextAtTheCaretIsOneDurableWrite() async throws {
        let replica = try makeReplica()
        let crashed = try await launch(replica)
        await compose(crashed, ["にほん", "日本"], at: try caret(crashed, Self.firstID, 6))
        await crashed.close().value
        let session = try await launch(replica)
        addTeardownBlock { await session.close().value }
        let input = try XCTUnwrap(session.input)
        let recovery = try XCTUnwrap(input.composition.pendingRecoveries.first)
        session.textView.selectedRange = NSRange(location: try caret(session, Self.thirdID, 5), length: 0)

        let inserted = await session.run { input.insertRecovery(recovery) }
        XCTAssertTrue(inserted)

        XCTAssertEqual(replica.writes.value.map(\.replacement), ["日本"])
        XCTAssertEqual(try text(session, Self.thirdID), "Third日本 paragraph.", "at the chosen caret")
        XCTAssertTrue(input.composition.pendingRecoveries.isEmpty)
        XCTAssertTrue(replica.store.provisionalRecoveries(for: replica.scope).isEmpty)
        assertMatches(session)
        await session.close().value
        let relaunched = try await launch(replica)
        addTeardownBlock { await relaunched.close().value }
        XCTAssertTrue(relaunched.input?.composition.pendingRecoveries.isEmpty == true)
        XCTAssertEqual(try text(relaunched, Self.thirdID), "Third日本 paragraph.")
    }

    func testCopyAndDiscardResolveRecoveryWithoutWriting() async throws {
        let replica = try makeReplica()
        let crashed = try await launch(replica)
        await compose(crashed, ["かな"], at: try caret(crashed, Self.firstID, 0))
        await crashed.close().value
        var session = try await launch(replica)
        var input = try XCTUnwrap(session.input)
        // Never the general pasteboard: reading another app's content there (the
        // simulator's host sync, another test app) shows the paste consent alert,
        // and the read blocks until someone answers it (the test hung).
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        input.pasteboard = pasteboard

        input.copyRecovery(try XCTUnwrap(input.composition.pendingRecoveries.first))
        await session.settle()

        XCTAssertEqual(pasteboard.string, "かな")
        XCTAssertTrue(input.composition.pendingRecoveries.isEmpty)
        XCTAssertTrue(replica.store.provisionalRecoveries(for: replica.scope).isEmpty)
        await session.close().value

        session = try await launch(replica)
        await compose(session, ["すて"], at: try caret(session, Self.firstID, 0))
        await session.close().value
        session = try await launch(replica)
        let last = session
        addTeardownBlock { await last.close().value }
        input = try XCTUnwrap(session.input)
        input.discardRecovery(try XCTUnwrap(input.composition.pendingRecoveries.first))
        await session.settle()

        XCTAssertTrue(input.composition.pendingRecoveries.isEmpty)
        XCTAssertTrue(replica.store.provisionalRecoveries(for: replica.scope).isEmpty)
        XCTAssertEqual(try text(session, Self.firstID), "First paragraph.")
        try assertNothingCommitted(replica)
    }

    func testRecoveryInsertAtAnUnownedCaretKeepsTheEntry() async throws {
        let replica = try makeReplica()
        let crashed = try await launch(replica)
        await compose(crashed, ["に"], at: try caret(crashed, Self.firstID, 0))
        await crashed.close().value
        let session = try await launch(replica)
        addTeardownBlock { await session.close().value }
        let input = try XCTUnwrap(session.input)
        // After the last separator, which no block owns.
        session.textView.selectedRange = NSRange(location: session.textView.textStorage.length, length: 0)

        let recovery = try XCTUnwrap(input.composition.pendingRecoveries.first)
        let inserted = await session.run { input.insertRecovery(recovery) }
        XCTAssertFalse(inserted)

        XCTAssertEqual(input.noticeKey, .native_editor_input_unavailable)
        XCTAssertEqual(input.composition.pendingRecoveries.map(\.text), ["に"])
        try assertNothingCommitted(replica)
    }

    // MARK: - Orphaned commit

    func testOrphanedCommitIsPersistedForRecoveryAcrossRelaunch() async throws {
        let replica = try makeReplica()
        let session = try await launch(replica)
        addTeardownBlock { await session.close().value }
        let peer = try makeDoc(clientID: 2)
        defer { peer.destroy() }
        let peerEngine = DocumentEngine(doc: peer, surface: HeadlessSurface(blocks: projection(peer)))
        await compose(session, ["にほん"], at: try caret(session, Self.secondID, 6))
        let joinUpdate = try peerEngine.joinBlocks(block: Self.secondID)
        try await session.integrateServerState(joinUpdate)

        session.textView.unmarkText()
        await session.settle()

        XCTAssertTrue(replica.writes.value.isEmpty, "never redirected into another block")
        XCTAssertEqual(session.input?.composition.pendingRecoveries.map(\.state), [.orphaned])
        assertMatches(session)
        await session.close().value

        let relaunched = try await launch(replica)
        addTeardownBlock { await relaunched.close().value }
        let pending = try XCTUnwrap(relaunched.input?.composition.pendingRecoveries)
        XCTAssertEqual(pending.map(\.text), ["にほん"])
        XCTAssertEqual(pending.map(\.state), [.orphaned])
        XCTAssertEqual(try replica.store.manifest(for: replica.scope)?.outbox, [], "the peer join is remote only")
    }

    func testANewCompositionKeepsAnEarlierRecoveryEntry() async throws {
        let replica = try makeReplica()
        let crashed = try await launch(replica)
        await compose(crashed, ["まえ"], at: try caret(crashed, Self.firstID, 0))
        await crashed.close().value
        let session = try await launch(replica)
        addTeardownBlock { await session.close().value }

        await compose(session, ["あと"], at: try caret(session, Self.thirdID, 0))
        XCTAssertEqual(session.input?.composition.pendingRecoveries.map(\.text), ["まえ"])
        session.textView.unmarkText()
        await session.settle()

        XCTAssertEqual(replica.writes.value.map(\.replacement), ["あと"])
        XCTAssertEqual(replica.store.provisionalRecoveries(for: replica.scope).map(\.text), ["まえ"])
    }

    // MARK: - Failure and crash windows

    func testFailedCommitAppendKeepsTheTextOnDiskAndPublishesNothing() async throws {
        let replica = try makeReplica()
        let session = try await launch(replica)
        let before = session.surface.blocks
        await compose(session, ["日本"], at: try caret(session, Self.firstID, 0))
        replica.failNextAppend.value = true

        session.textView.unmarkText()
        await session.settle()

        XCTAssertEqual(session.input?.noticeKey, .native_editor_storage_failed)
        XCTAssertFalse(session.textView.isEditable)
        XCTAssertEqual(session.surface.blocks, before, "no publication without the journal")
        assertMatches(session)
        try assertNothingCommitted(replica)
        await session.close().value

        let relaunched = try await launch(replica)
        addTeardownBlock { await relaunched.close().value }
        XCTAssertEqual(relaunched.input?.composition.pendingRecoveries.map(\.text), ["日本"])
        XCTAssertEqual(try text(relaunched, Self.firstID), "First paragraph.")
    }

    func testAnEntryWhoseCommandReachedTheJournalIsDroppedAsCommitted() async throws {
        let replica = try makeReplica()
        let session = try await launch(replica)
        await compose(session, ["日本"], at: try caret(session, Self.firstID, 0))
        let live = try XCTUnwrap(replica.store.provisionalRecoveries(for: replica.scope).first)
        session.textView.unmarkText()
        await session.settle()
        await session.close().value
        // A crash between the journal append and the provisional cleanup.
        try replica.store.writeProvisionalRecoveries([live], for: replica.scope)

        XCTAssertEqual(replica.writes.value.map(\.id), [live.commandID], "the commit used the persisted id")
        XCTAssertTrue(replica.store.provisionalRecoveries(for: replica.scope).isEmpty)
        XCTAssertNil(try provisionalFile(replica), "the read purges the committed entry from disk")
        let relaunched = try await launch(replica)
        addTeardownBlock { await relaunched.close().value }
        XCTAssertTrue(relaunched.input?.composition.pendingRecoveries.isEmpty == true)
        XCTAssertEqual(try text(relaunched, Self.firstID), "日本First paragraph.", "committed exactly once")
    }

    func testAFailedPurgeRewriteStillReturnsTheUncommittedEntries() async throws {
        let replica = try makeReplica()
        let session = try await launch(replica)
        await compose(session, ["日本"], at: try caret(session, Self.firstID, 0))
        let committed = try XCTUnwrap(replica.store.provisionalRecoveries(for: replica.scope).first)
        session.textView.unmarkText()
        await session.settle()
        await session.close().value
        let live = ProvisionalRecovery(commandID: UUID(), blockID: Self.thirdID, text: "まだ", state: .composing)
        try replica.store.writeProvisionalRecoveries([committed, live], for: replica.scope)
        let failing = ReplicaStore(directory: replica.directory) { operation, _ in
            if operation == .provisional { throw DiskError.full }
        }

        XCTAssertEqual(failing.provisionalRecoveries(for: replica.scope), [live], "the only copy of uncommitted text")
        XCTAssertEqual(replica.store.provisionalRecoveries(for: replica.scope), [live], "a later read purges")
    }

    func testCompactionPurgesACommittedEntryBeforeDroppingItsJournalProof() async throws {
        let replica = try makeReplica()
        let session = try await launch(replica)
        await compose(session, ["日本"], at: try caret(session, Self.firstID, 0))
        let live = try XCTUnwrap(replica.store.provisionalRecoveries(for: replica.scope).first)
        session.textView.unmarkText()
        await session.settle()
        await session.close().value
        // A crash between the journal append and the provisional cleanup,
        // then a save acknowledges the edit and compaction drops its entry.
        try replica.store.writeProvisionalRecoveries([live], for: replica.scope)
        try replica.store.acknowledge(try XCTUnwrap(replica.store.outbox(for: replica.scope)))
        let revision = try XCTUnwrap(replica.store.manifest(for: replica.scope)).revision

        try replica.store.compact(for: replica.scope, checkpoint: Data([9]), baseRevision: revision)

        XCTAssertEqual(try replica.store.manifest(for: replica.scope)?.journal, [])
        XCTAssertNil(try provisionalFile(replica))
        XCTAssertTrue(
            replica.store.provisionalRecoveries(for: replica.scope).isEmpty, "committed text never comes back")
    }

    private func provisionalFile(_ replica: Replica) throws -> Data? {
        let file = replica.directory.appendingPathComponent(try replica.scope.directoryName())
            .appendingPathComponent("provisional.json")
        return FileManager.default.contents(atPath: file.path)
    }

    func testRemovingTheReplicaRemovesItsProvisionalText() async throws {
        let replica = try makeReplica()
        let session = try await launch(replica)
        await compose(session, ["に"], at: try caret(session, Self.firstID, 0))
        await session.close().value

        try replica.store.remove(for: replica.scope)

        XCTAssertTrue(replica.store.provisionalRecoveries(for: replica.scope).isEmpty)
        let stale = ProvisionalRecovery(commandID: UUID(), blockID: Self.firstID, text: "に", state: .composing)
        XCTAssertThrowsError(
            try replica.store.writeProvisionalRecoveries([stale], for: replica.scope), "no folder, no recovery")
    }
}
