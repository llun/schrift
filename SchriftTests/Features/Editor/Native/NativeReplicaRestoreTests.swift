import Synchronization
import XCTest

@testable import Schrift

@MainActor
final class NativeReplicaRestoreTests: DocumentEngineTestCase {
    private enum Interrupted: Error { case disk }
    /// A flag the store's `@Sendable` interrupt hook can read.
    private final class Flag: Sendable {
        private let state = Mutex(false)
        var isOn: Bool {
            get { state.withLock { $0 } }
            set { state.withLock { $0 = newValue } }
        }
    }

    func testOfflineReopenUsesJournalRevisionAndNewNonCollidingAuthor() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReplicaStore(directory: directory)
        let scope = ReplicaScope(
            serverOrigin: "https://docs.example", ownerUserID: UUID(), org: "docs", documentID: UUID())
        let seed = BlockNoteYjs.encode(Self.seedBlocks(), clientID: 1)
        _ = try store.create(for: scope, checkpoint: seed)
        let first = try unwrapped(try await NativeEditorSession.restore(store: store, scope: scope, editable: true))
        XCTAssertTrue(try XCTUnwrap(first.input).replace(range: NSRange(location: 0, length: 0), with: "x"))
        await first.settle()
        let before = first.surface.blocks
        let oldClients = Set(
            try XCTUnwrap(store.restore(for: scope)).updates.flatMap {
                try YUpdateDecoder.decode($0).blocks.map(\.client)
            })
        await first.close().value
        let reopened = try unwrapped(try await NativeEditorSession.restore(store: store, scope: scope, editable: true))
        addTeardownBlock { await reopened.close().value }
        let rev1 = await reopened.engine { $0.revision }
        XCTAssertEqual(rev1, 1)
        XCTAssertEqual(reopened.surface.blocks, before)
        XCTAssertTrue(try XCTUnwrap(reopened.input).replace(range: NSRange(location: 0, length: 0), with: "y"))
        await reopened.settle()
        let restored = try XCTUnwrap(store.restore(for: scope))
        XCTAssertEqual(restored.manifest.revision, 2)
        let newClients = Set(try YUpdateDecoder.decode(try XCTUnwrap(restored.updates.last)).blocks.map(\.client))
        XCTAssertFalse(newClients.isEmpty)
        XCTAssertTrue(newClients.isDisjoint(with: oldClients.union([1])))
        let readonly = try unwrapped(try await NativeEditorSession.restore(store: store, scope: scope))
        addTeardownBlock { await readonly.close().value }
        XCTAssertEqual(readonly.surface.blocks, reopened.surface.blocks)
        XCTAssertFalse(readonly.textView.isEditable)
    }

    func testReconnectIntegrationIsDurableAndDuplicateReplayDoesNotDuplicateDisplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReplicaStore(directory: directory)
        let scope = ReplicaScope(
            serverOrigin: "https://docs.example", ownerUserID: UUID(), org: "docs", documentID: UUID())
        let seed = BlockNoteYjs.encode(Self.seedBlocks(), clientID: 1)
        _ = try store.create(for: scope, checkpoint: seed)
        let session = try unwrapped(try await NativeEditorSession.restore(store: store, scope: scope, editable: true))
        addTeardownBlock { await session.close().value }
        XCTAssertTrue(try XCTUnwrap(session.input).replace(range: NSRange(location: 0, length: 0), with: "local"))
        await session.settle()
        let peer = try makeDoc(clientID: 2)
        defer { peer.destroy() }
        _ = try BlockNoteWriter(doc: peer).replaceText(block: Self.thirdID, range: 0..<0, with: "server")
        let serverState = try YStateEncoder.encodeStateAsUpdate(peer)
        try await session.integrateServerState(serverState)
        let after = session.surface.blocks
        XCTAssertTrue(after[0].runs.map(\.text).joined().hasPrefix("local"))
        XCTAssertTrue(after[2].runs.map(\.text).joined().hasPrefix("server"))
        try await session.integrateServerState(serverState)
        XCTAssertEqual(session.surface.blocks, after)
        // The duplicate adds nothing, so it is not journaled (PR09a).
        let rev2 = await session.engine { $0.revision }
        XCTAssertEqual(rev2, 2)
        XCTAssertEqual(
            try store.restore(for: scope)?.manifest.outbox, [1], "remote updates never enter the local outbox")
        let reopened = try unwrapped(try await NativeEditorSession.restore(store: store, scope: scope, editable: true))
        addTeardownBlock { await reopened.close().value }
        XCTAssertEqual(reopened.surface.blocks, after)
        let revReopened = await reopened.engine { $0.revision }
        XCTAssertEqual(revReopened, 2)
        XCTAssertTrue(try XCTUnwrap(reopened.input).replace(range: NSRange(location: 0, length: 0), with: "more"))
        await reopened.settle()
        XCTAssertEqual(try store.restore(for: scope)?.manifest.revision, 3)
    }

    func testRemoteAppendFailureFreezesBeforeDisplayAndKeepsPriorDurableState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let failAppend = Flag()
        let store = ReplicaStore(directory: directory) { operation, boundary in
            if failAppend.isOn && operation == .append && boundary == .payloadWritten { throw Interrupted.disk }
        }
        let scope = ReplicaScope(
            serverOrigin: "https://docs.example", ownerUserID: UUID(), org: "docs", documentID: UUID())
        _ = try store.create(for: scope, checkpoint: BlockNoteYjs.encode(Self.seedBlocks(), clientID: 1))
        let session = try unwrapped(try await NativeEditorSession.restore(store: store, scope: scope, editable: true))
        addTeardownBlock { await session.close().value }
        let original = session.textView.textStorage.string
        let peer = try makeDoc(clientID: 2)
        defer { peer.destroy() }
        let update = try BlockNoteWriter(doc: peer).replaceText(block: Self.firstID, range: 0..<0, with: "uncommitted")
        failAppend.isOn = true
        do {
            try await session.integrateServerState(update)
            XCTFail("a failed append must not integrate")
        } catch Interrupted.disk {}
        await session.settle()
        XCTAssertEqual(session.textView.textStorage.string, original)
        XCTAssertFalse(session.textView.isEditable)
        let failed = await session.engine { $0.nativeWriteFailed }
        XCTAssertEqual(failed, true)
        let unconfirmed = await session.engine { $0.unconfirmedNativeUpdate }
        XCTAssertEqual(unconfirmed, update)
        XCTAssertEqual(session.input?.noticeKey, .native_editor_storage_failed)
        XCTAssertEqual(try store.restore(for: scope)?.manifest.revision, 0)
        let reopened = try unwrapped(try await NativeEditorSession.restore(store: store, scope: scope))
        addTeardownBlock { await reopened.close().value }
        XCTAssertEqual(reopened.textView.textStorage.string, original)
    }

    func testAnotherAccountCannotRestoreAndCorruptionCannotBecomeAnEmptySession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReplicaStore(directory: directory)
        let scope = ReplicaScope(
            serverOrigin: "https://docs.example", ownerUserID: UUID(), org: "docs", documentID: UUID())
        _ = try store.create(for: scope, checkpoint: BlockNoteYjs.encode(Self.seedBlocks(), clientID: 1))
        let other = ReplicaScope(
            serverOrigin: scope.serverOrigin, ownerUserID: UUID(), org: scope.org, documentID: scope.documentID)
        let restoredOther = try await NativeEditorSession.restore(store: store, scope: other)
        XCTAssertNil(restoredOther)
        let manifest = try XCTUnwrap(store.restore(for: scope)).manifest
        let checkpoint = directory.appendingPathComponent(try scope.directoryName()).appendingPathComponent(
            manifest.checkpoint.name)
        try Data([0xff]).write(to: checkpoint)
        do {
            _ = try await NativeEditorSession.restore(store: store, scope: scope)
            XCTFail("a corrupt checkpoint must not restore")
        } catch ReplicaStoreError.corrupt {}
    }

    func testUnjournaledTransactionFreezesADurableSessionInsteadOfDriftingItsRevision() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReplicaStore(directory: directory)
        let scope = ReplicaScope(
            serverOrigin: "https://docs.example", ownerUserID: UUID(), org: "docs", documentID: UUID())
        _ = try store.create(for: scope, checkpoint: BlockNoteYjs.encode(Self.seedBlocks(), clientID: 1))
        let session = try unwrapped(try await NativeEditorSession.restore(store: store, scope: scope, editable: true))
        addTeardownBlock { await session.close().value }
        let input = try XCTUnwrap(session.input)
        XCTAssertTrue(input.replace(range: NSRange(location: 0, length: 0), with: "x"))
        await session.settle()
        let display = session.textView.textStorage.string
        _ = await session.engine { try? $0.replaceText(block: Self.thirdID, range: 0..<0, with: "unjournaled") }
        await session.settle()
        let rev = await session.engine { $0.revision }
        XCTAssertEqual(rev, 1, "the engine revision stays the journal's")
        let failed = await session.engine { $0.nativeWriteFailed }
        XCTAssertEqual(failed, true)
        XCTAssertEqual(session.textView.textStorage.string, display)
        XCTAssertEqual(try store.restore(for: scope)?.manifest.revision, 1)
        XCTAssertEqual(input.noticeKey, .native_editor_storage_failed)
        XCTAssertFalse(session.textView.isEditable)
        let taken = await session.run { input.replace(range: NSRange(location: 0, length: 0), with: "y") }
        XCTAssertFalse(taken)
    }
}
