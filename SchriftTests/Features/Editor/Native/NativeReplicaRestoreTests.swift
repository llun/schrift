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

    func testOfflineReopenUsesJournalRevisionAndNewNonCollidingAuthor() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReplicaStore(directory: directory)
        let scope = ReplicaScope(
            serverOrigin: "https://docs.example", ownerUserID: UUID(), org: "docs", documentID: UUID())
        let seed = BlockNoteYjs.encode(Self.seedBlocks(), clientID: 1)
        _ = try store.create(for: scope, checkpoint: seed)
        let first = try XCTUnwrap(NativeEditorSession.restore(store: store, scope: scope, editable: true))
        XCTAssertTrue(try XCTUnwrap(first.input).replace(range: NSRange(location: 0, length: 0), with: "x"))
        let before = first.surface.blocks
        let oldClients = Set(
            try XCTUnwrap(store.restore(for: scope)).updates.flatMap {
                try YUpdateDecoder.decode($0).blocks.map(\.client)
            })
        first.close()
        let reopened = try XCTUnwrap(NativeEditorSession.restore(store: store, scope: scope, editable: true))
        defer { reopened.close() }
        XCTAssertEqual(reopened.engine.revision, 1)
        XCTAssertEqual(reopened.surface.blocks, before)
        XCTAssertTrue(try XCTUnwrap(reopened.input).replace(range: NSRange(location: 0, length: 0), with: "y"))
        let restored = try XCTUnwrap(store.restore(for: scope))
        XCTAssertEqual(restored.manifest.revision, 2)
        let newClients = Set(try YUpdateDecoder.decode(try XCTUnwrap(restored.updates.last)).blocks.map(\.client))
        XCTAssertFalse(newClients.isEmpty)
        XCTAssertTrue(newClients.isDisjoint(with: oldClients.union([1])))
        let readonly = try XCTUnwrap(NativeEditorSession.restore(store: store, scope: scope))
        defer { readonly.close() }
        XCTAssertEqual(readonly.surface.blocks, reopened.surface.blocks)
        XCTAssertFalse(readonly.textView.isEditable)
    }

    func testReconnectIntegrationIsDurableAndDuplicateReplayDoesNotDuplicateDisplay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReplicaStore(directory: directory)
        let scope = ReplicaScope(
            serverOrigin: "https://docs.example", ownerUserID: UUID(), org: "docs", documentID: UUID())
        let seed = BlockNoteYjs.encode(Self.seedBlocks(), clientID: 1)
        _ = try store.create(for: scope, checkpoint: seed)
        let session = try XCTUnwrap(NativeEditorSession.restore(store: store, scope: scope, editable: true))
        defer { session.close() }
        XCTAssertTrue(try XCTUnwrap(session.input).replace(range: NSRange(location: 0, length: 0), with: "local"))
        let peer = try makeDoc(clientID: 2)
        defer { peer.destroy() }
        _ = try BlockNoteWriter(doc: peer).replaceText(block: Self.thirdID, range: 0..<0, with: "server")
        let serverState = try YStateEncoder.encodeStateAsUpdate(peer)
        try session.integrateServerState(serverState)
        let after = session.surface.blocks
        XCTAssertTrue(after[0].runs.map(\.text).joined().hasPrefix("local"))
        XCTAssertTrue(after[2].runs.map(\.text).joined().hasPrefix("server"))
        try session.integrateServerState(serverState)
        XCTAssertEqual(session.surface.blocks, after)
        XCTAssertEqual(session.engine.revision, 3)
        XCTAssertEqual(
            try store.restore(for: scope)?.manifest.outbox, [1], "remote updates never enter the local outbox")
        let reopened = try XCTUnwrap(NativeEditorSession.restore(store: store, scope: scope, editable: true))
        defer { reopened.close() }
        XCTAssertEqual(reopened.surface.blocks, after)
        XCTAssertEqual(reopened.engine.revision, 3)
        XCTAssertTrue(try XCTUnwrap(reopened.input).replace(range: NSRange(location: 0, length: 0), with: "more"))
        XCTAssertEqual(try store.restore(for: scope)?.manifest.revision, 4)
    }

    func testRemoteAppendFailureFreezesBeforeDisplayAndKeepsPriorDurableState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let failAppend = Flag()
        let store = ReplicaStore(directory: directory) { operation, boundary in
            if failAppend.isOn && operation == .append && boundary == .payloadWritten { throw Interrupted.disk }
        }
        let scope = ReplicaScope(
            serverOrigin: "https://docs.example", ownerUserID: UUID(), org: "docs", documentID: UUID())
        _ = try store.create(for: scope, checkpoint: BlockNoteYjs.encode(Self.seedBlocks(), clientID: 1))
        let session = try XCTUnwrap(NativeEditorSession.restore(store: store, scope: scope, editable: true))
        defer { session.close() }
        let original = session.textView.textStorage.string
        let peer = try makeDoc(clientID: 2)
        defer { peer.destroy() }
        let update = try BlockNoteWriter(doc: peer).replaceText(block: Self.firstID, range: 0..<0, with: "uncommitted")
        failAppend.isOn = true
        do {
            try session.integrateServerState(update)
            XCTFail("a failed append must not integrate")
        } catch Interrupted.disk {}
        XCTAssertEqual(session.textView.textStorage.string, original)
        XCTAssertFalse(session.textView.isEditable)
        XCTAssertTrue(session.engine.nativeWriteFailed)
        XCTAssertEqual(session.engine.unconfirmedNativeUpdate, update)
        XCTAssertEqual(session.input?.noticeKey, .native_editor_storage_failed)
        XCTAssertEqual(try store.restore(for: scope)?.manifest.revision, 0)
        let reopened = try XCTUnwrap(NativeEditorSession.restore(store: store, scope: scope))
        defer { reopened.close() }
        XCTAssertEqual(reopened.textView.textStorage.string, original)
    }

    func testAnotherAccountCannotRestoreAndCorruptionCannotBecomeAnEmptySession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReplicaStore(directory: directory)
        let scope = ReplicaScope(
            serverOrigin: "https://docs.example", ownerUserID: UUID(), org: "docs", documentID: UUID())
        _ = try store.create(for: scope, checkpoint: BlockNoteYjs.encode(Self.seedBlocks(), clientID: 1))
        let other = ReplicaScope(
            serverOrigin: scope.serverOrigin, ownerUserID: UUID(), org: scope.org, documentID: scope.documentID)
        XCTAssertNil(try NativeEditorSession.restore(store: store, scope: other))
        let manifest = try XCTUnwrap(store.restore(for: scope)).manifest
        let checkpoint = directory.appendingPathComponent(try scope.directoryName()).appendingPathComponent(
            manifest.checkpoint.name)
        try Data([0xff]).write(to: checkpoint)
        do {
            _ = try NativeEditorSession.restore(store: store, scope: scope)
            XCTFail("a corrupt checkpoint must not restore")
        } catch ReplicaStoreError.corrupt {}
    }

    func testUnjournaledTransactionFreezesADurableSessionInsteadOfDriftingItsRevision() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReplicaStore(directory: directory)
        let scope = ReplicaScope(
            serverOrigin: "https://docs.example", ownerUserID: UUID(), org: "docs", documentID: UUID())
        _ = try store.create(for: scope, checkpoint: BlockNoteYjs.encode(Self.seedBlocks(), clientID: 1))
        let session = try XCTUnwrap(NativeEditorSession.restore(store: store, scope: scope, editable: true))
        defer { session.close() }
        let input = try XCTUnwrap(session.input)
        XCTAssertTrue(input.replace(range: NSRange(location: 0, length: 0), with: "x"))
        let display = session.textView.textStorage.string
        _ = try session.engine.replaceText(block: Self.thirdID, range: 0..<0, with: "unjournaled")
        XCTAssertEqual(session.engine.revision, 1, "the engine revision stays the journal's")
        XCTAssertTrue(session.engine.nativeWriteFailed)
        XCTAssertEqual(session.textView.textStorage.string, display)
        XCTAssertEqual(try store.restore(for: scope)?.manifest.revision, 1)
        XCTAssertEqual(input.noticeKey, .native_editor_storage_failed)
        XCTAssertFalse(session.textView.isEditable)
        XCTAssertFalse(input.replace(range: NSRange(location: 0, length: 0), with: "y"))
    }
}
