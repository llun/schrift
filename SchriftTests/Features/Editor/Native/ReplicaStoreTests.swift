import XCTest

@testable import Schrift

@MainActor
final class ReplicaStoreTests: XCTestCase {
    private enum Interrupted: Error { case crash }
    private var directory: URL!
    private var ownershipSuite: String!
    private var ownershipDefaults: UserDefaults!
    private let scope = ReplicaScope(
        serverOrigin: "https://docs.example", ownerUserID: UUID(), org: "docs", documentID: UUID())
    private let baseline = Data([0, 0])

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        ownershipSuite = "ReplicaStoreTests.\(UUID().uuidString)"
        ownershipDefaults = UserDefaults(suiteName: ownershipSuite)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        ownershipDefaults?.removePersistentDomain(forName: ownershipSuite)
        ownershipDefaults = nil
        ownershipSuite = nil
    }

    private func store(
        interrupt: ((ReplicaStore.Operation, ReplicaStore.Boundary) throws -> Void)? = nil
    ) -> ReplicaStore {
        ReplicaStore(directory: directory, interrupt: interrupt)
    }

    private func ownedStore(
        interrupt: ((ReplicaStore.Operation, ReplicaStore.Boundary) throws -> Void)? = nil
    ) -> (ReplicaStore, ReplicaOwnershipStore) {
        let ownership = ReplicaOwnershipStore(userDefaults: ownershipDefaults)
        return (ReplicaStore(directory: directory, ownershipStore: ownership, interrupt: interrupt), ownership)
    }

    func testCreateAppendAndRelaunchRetainsScopeAndOrderedLocalAndRemoteUpdates() throws {
        let first = store()
        XCTAssertNil(try first.restore(for: scope))
        let created = try first.create(for: scope, checkpoint: baseline)
        XCTAssertEqual(created.revision, 0)
        let local = try first.append(
            Data([1, 2]), for: scope, commandID: UUID(), baseRevision: 0, origin: .local)
        _ = try first.append(Data([3, 4]), for: scope, commandID: UUID(), baseRevision: 1, origin: .remote)

        let restored = try XCTUnwrap(store().restore(for: scope))
        XCTAssertEqual(restored.checkpoint, baseline)
        XCTAssertEqual(restored.updates, [Data([1, 2]), Data([3, 4])])
        XCTAssertEqual(restored.manifest.revision, 2)
        XCTAssertEqual(restored.manifest.outbox, [1])
        XCTAssertEqual(restored.manifest.generation, local.generation)
        XCTAssertThrowsError(try first.create(for: scope, checkpoint: Data([9])))
    }

    func testDuplicateCommandIsIdempotentButDifferentBytesAndStaleRevisionAreRefused() throws {
        let store = store()
        _ = try store.create(for: scope, checkpoint: baseline)
        let command = UUID()
        let committed = try store.append(Data([1]), for: scope, commandID: command, baseRevision: 0, origin: .local)
        XCTAssertEqual(
            try store.append(Data([1]), for: scope, commandID: command, baseRevision: 0, origin: .local), committed)
        XCTAssertThrowsError(
            try store.append(Data([2]), for: scope, commandID: command, baseRevision: 0, origin: .local))
        XCTAssertThrowsError(
            try store.append(Data([1]), for: scope, commandID: UUID(), baseRevision: 0, origin: .local))
        XCTAssertEqual(try store.restore(for: scope)?.manifest.revision, 1)
    }

    func testAcknowledgmentCoversOnlyCapturedBatchAndIsIdempotent() throws {
        let store = store()
        _ = try store.create(for: scope, checkpoint: baseline)
        _ = try store.append(Data([1]), for: scope, commandID: UUID(), baseRevision: 0, origin: .local)
        let batch = try XCTUnwrap(store.outbox(for: scope))
        _ = try store.append(Data([2]), for: scope, commandID: UUID(), baseRevision: 1, origin: .local)
        try store.acknowledge(batch)
        try store.acknowledge(batch)
        let restored = try XCTUnwrap(store.restore(for: scope))
        XCTAssertEqual(restored.manifest.outbox, [2])
        XCTAssertEqual(restored.manifest.httpAcknowledgedThrough, 1)
        XCTAssertEqual(try store.outbox(for: scope)?.updates, [Data([2])])
    }

    func testCompactionPreservesUnacknowledgedBytesAndRejectsStaleSnapshot() throws {
        let store = store()
        _ = try store.create(for: scope, checkpoint: baseline)
        _ = try store.append(Data([1]), for: scope, commandID: UUID(), baseRevision: 0, origin: .local)
        let batch = try XCTUnwrap(store.outbox(for: scope))
        XCTAssertThrowsError(try store.compact(for: scope, checkpoint: Data([8]), baseRevision: 0))
        try store.compact(for: scope, checkpoint: Data([9]), baseRevision: 1)
        let compacted = try XCTUnwrap(store.restore(for: scope))
        XCTAssertEqual(compacted.checkpoint, Data([9]))
        XCTAssertTrue(compacted.updates.isEmpty)
        XCTAssertEqual(try store.outbox(for: scope)?.updates, [Data([1])])
        try store.acknowledge(batch)
        try store.compact(for: scope, checkpoint: Data([9]), baseRevision: 1)
        XCTAssertTrue(try XCTUnwrap(store.restore(for: scope)).manifest.journal.isEmpty)
    }

    func testEveryCreateAndAppendBoundaryRestoresOnlyACommittedRevision() throws {
        for operation in [ReplicaStore.Operation.create, .append] {
            for boundary in ReplicaStore.Boundary.commitBoundaries {
                let root = directory.appendingPathComponent(UUID().uuidString)
                let healthy = ReplicaStore(directory: root)
                if operation == .append { _ = try healthy.create(for: scope, checkpoint: baseline) }
                let crashing = ReplicaStore(directory: root) { op, point in
                    if op == operation && point == boundary { throw Interrupted.crash }
                }
                XCTAssertThrowsError(
                    try {
                        if operation == .create {
                            _ = try crashing.create(for: scope, checkpoint: baseline)
                        } else {
                            _ = try crashing.append(
                                Data([7]), for: scope, commandID: UUID(), baseRevision: 0, origin: .local)
                        }
                    }(), "\(operation) at \(boundary)")
                let restored = try healthy.restore(for: scope)
                if operation == .create {
                    XCTAssertEqual(restored?.checkpoint, boundary.manifestIsVisible ? baseline : nil)
                } else {
                    XCTAssertEqual(restored?.manifest.revision, boundary.manifestIsVisible ? 1 : 0)
                    XCTAssertEqual(restored?.updates, boundary.manifestIsVisible ? [Data([7])] : [])
                }
            }
        }
    }

    func testEveryAckBoundaryRetainsOutboxUnlessAckManifestWasSwitched() throws {
        for boundary in ReplicaStore.Boundary.manifestBoundaries {
            let root = directory.appendingPathComponent(UUID().uuidString)
            let healthy = ReplicaStore(directory: root)
            _ = try healthy.create(for: scope, checkpoint: baseline)
            _ = try healthy.append(Data([7]), for: scope, commandID: UUID(), baseRevision: 0, origin: .local)
            let batch = try XCTUnwrap(healthy.outbox(for: scope))
            let crashing = ReplicaStore(directory: root) { op, point in
                if op == .acknowledge && point == boundary { throw Interrupted.crash }
            }
            XCTAssertThrowsError(try crashing.acknowledge(batch))
            XCTAssertEqual(try healthy.restore(for: scope)?.manifest.outbox, boundary.manifestIsVisible ? [] : [1])
            try healthy.acknowledge(batch)
            XCTAssertNil(try healthy.outbox(for: scope))
        }
    }

    func testEveryCompactionBoundaryKeepsReplayAndUnsentOutbox() throws {
        for boundary in ReplicaStore.Boundary.commitBoundaries + [.obsoleteFilesRemoved] {
            let root = directory.appendingPathComponent(UUID().uuidString)
            let healthy = ReplicaStore(directory: root)
            _ = try healthy.create(for: scope, checkpoint: baseline)
            _ = try healthy.append(Data([7]), for: scope, commandID: UUID(), baseRevision: 0, origin: .local)
            let crashing = ReplicaStore(directory: root) { op, point in
                if op == .compact && point == boundary { throw Interrupted.crash }
            }
            XCTAssertThrowsError(try crashing.compact(for: scope, checkpoint: Data([9]), baseRevision: 1))
            let restored = try XCTUnwrap(healthy.restore(for: scope))
            XCTAssertEqual(restored.checkpoint, boundary.manifestIsVisible ? Data([9]) : baseline)
            XCTAssertEqual(restored.updates, boundary.manifestIsVisible ? [] : [Data([7])])
            XCTAssertEqual(try healthy.outbox(for: scope)?.updates, [Data([7])])
        }
    }

    func testCorruptCommittedSegmentIsQuarantinedAndNeverReplayedOrOverwritten() throws {
        let store = store()
        _ = try store.create(for: scope, checkpoint: baseline)
        let manifest = try store.append(Data([7]), for: scope, commandID: UUID(), baseRevision: 0, origin: .local)
        let folder = directory.appendingPathComponent(try scope.directoryName())
        let file = folder.appendingPathComponent(manifest.journal[0].file.name)
        try Data([8]).write(to: file)
        XCTAssertThrowsError(try store.restore(for: scope))
        XCTAssertThrowsError(try self.store().restore(for: scope))
        XCTAssertThrowsError(
            try store.append(Data([9]), for: scope, commandID: UUID(), baseRevision: 1, origin: .local))
        XCTAssertThrowsError(try store.create(for: scope, checkpoint: baseline))
        XCTAssertEqual(try Data(contentsOf: file), Data([8]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Recovery/blocked").path))
    }

    func testFailedDiskAppendDoesNotAdvanceManifest() throws {
        let store = store()
        _ = try store.create(for: scope, checkpoint: baseline)
        // A regular file in place of the journal directory forces a real I/O
        // failure, independently of the injected interruption tests above.
        let folder = directory.appendingPathComponent(try scope.directoryName())
        try Data([0]).write(to: folder.appendingPathComponent("Journal"))
        XCTAssertThrowsError(
            try store.append(Data([1]), for: scope, commandID: UUID(), baseRevision: 0, origin: .local))
        XCTAssertEqual(try store.restore(for: scope)?.manifest.revision, 0)
        XCTAssertNil(try store.outbox(for: scope))
    }

    func testDuplicateYjsReplayAndDeleteOnlyUpdateSurviveRelaunch() throws {
        let blocks = DocumentEngineTestCase.seedBlocks()
        let seed = BlockNoteYjs.encode(blocks, clientID: 1)
        let author = YDoc(clientID: 2)
        let reopened = YDoc(clientID: 3)
        defer {
            author.destroy()
            reopened.destroy()
        }
        try author.applyUpdate(YUpdateDecoder.decode(seed), origin: .remote)
        let writer = BlockNoteWriter(doc: author)
        let before = YStateEncoder.encodeStateVector(author)
        let update = try writer.replaceText(block: DocumentEngineTestCase.firstID, range: 0..<5, with: "")
        XCTAssertEqual(YStateEncoder.encodeStateVector(author), before, "deletion advances no struct clocks")
        let store = store()
        _ = try store.create(for: scope, checkpoint: seed)
        _ = try store.append(update, for: scope, commandID: UUID(), baseRevision: 0, origin: .local)
        let restored = try XCTUnwrap(self.store().restore(for: scope))
        try reopened.applyUpdate(YUpdateDecoder.decode(restored.checkpoint), origin: .remote)
        for _ in 0..<2 {
            for bytes in restored.updates { try reopened.applyUpdate(YUpdateDecoder.decode(bytes), origin: .remote) }
        }
        XCTAssertEqual(
            YBlockProjection.project(reopened).blocks.map(BlockSnapshot.init),
            YBlockProjection.project(author).blocks.map(BlockSnapshot.init))
        let batch = try XCTUnwrap(store.outbox(for: scope))
        XCTAssertEqual(batch.updates, [update], "state-vector equality must not drop delete sets")
        try store.acknowledge(batch)
        XCTAssertNil(try self.store().outbox(for: scope))
    }

    func testPartialUncommittedFilesAreIgnoredAndNextAppendCanCommit() throws {
        let store = store()
        _ = try store.create(for: scope, checkpoint: baseline)
        let folder = directory.appendingPathComponent(try scope.directoryName())
        try Data([0xff]).write(to: folder.appendingPathComponent("interrupted.pending"))
        try Data([0xff]).write(to: folder.appendingPathComponent("\(UUID().uuidString).bin"))
        XCTAssertEqual(try self.store().restore(for: scope)?.manifest.revision, 0)
        _ = try store.append(Data([7]), for: scope, commandID: UUID(), baseRevision: 0, origin: .local)
        XCTAssertEqual(try self.store().restore(for: scope)?.updates, [Data([7])])
    }

    func testMissingSegmentCorruptCheckpointAndCorruptManifestAllBlockReopen() throws {
        for damage in ["missingSegment", "checkpoint", "manifest"] {
            let root = directory.appendingPathComponent(UUID().uuidString)
            let store = ReplicaStore(directory: root)
            _ = try store.create(for: scope, checkpoint: baseline)
            let manifest = try store.append(Data([7]), for: scope, commandID: UUID(), baseRevision: 0, origin: .local)
            let folder = root.appendingPathComponent(try scope.directoryName())
            if damage == "missingSegment" {
                try FileManager.default.removeItem(at: folder.appendingPathComponent(manifest.journal[0].file.name))
            } else {
                let name = damage == "checkpoint" ? manifest.checkpoint.name : "manifest.json"
                try Data([0xff]).write(to: folder.appendingPathComponent(name))
            }
            // The first read quarantines; every later read meets the sticky hold.
            for (expected, read) in [
                (ReplicaStoreError.corrupt, { _ = try store.restore(for: self.scope) }),
                (.quarantined, { _ = try store.outbox(for: self.scope) }),
                (.quarantined, { _ = try ReplicaStore(directory: root).restore(for: self.scope) }),
            ] as [(ReplicaStoreError, () throws -> Void)] {
                do {
                    try read()
                    XCTFail("damaged \(damage) must not reopen")
                } catch let error as ReplicaStoreError {
                    XCTAssertEqual(error, expected, damage)
                }
            }
            let recovery = folder.appendingPathComponent("Recovery")
            XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.appendingPathComponent("blocked").path))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: recovery.path).isEmpty)
        }
    }

    func testDraftDirectoryIsBackupIncluded() throws {
        _ = try store().create(for: scope, checkpoint: baseline)
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, false)
    }

    func testAccountServerOrgAndDocumentAreSeparateAndNoSignOutPurgeExists() throws {
        let store = store()
        _ = try store.create(for: scope, checkpoint: baseline)
        let alternatives = [
            ReplicaScope(
                serverOrigin: scope.serverOrigin, ownerUserID: UUID(), org: scope.org, documentID: scope.documentID),
            ReplicaScope(
                serverOrigin: "https://other.example", ownerUserID: scope.ownerUserID, org: scope.org,
                documentID: scope.documentID),
            ReplicaScope(
                serverOrigin: scope.serverOrigin, ownerUserID: scope.ownerUserID, org: "other",
                documentID: scope.documentID),
            ReplicaScope(
                serverOrigin: scope.serverOrigin, ownerUserID: scope.ownerUserID, org: scope.org, documentID: UUID()),
        ]
        for other in alternatives { XCTAssertNil(try store.restore(for: other)) }
        XCTAssertNotNil(try self.store().restore(for: scope))
    }

    func testCreateMarksOwnershipBeforeTheManifestIsVisible() throws {
        for boundary in ReplicaStore.Boundary.commitBoundaries {
            let root = directory.appendingPathComponent(UUID().uuidString)
            let ownership = ReplicaOwnershipStore(userDefaults: ownershipDefaults)
            let crashing = ReplicaStore(directory: root, ownershipStore: ownership) { op, point in
                if op == .create && point == boundary { throw Interrupted.crash }
            }
            XCTAssertThrowsError(try crashing.create(for: scope, checkpoint: baseline), "\(boundary)")
            // The marker is written before any payload, so a crash can never
            // leave a replica the classic writer could open.
            XCTAssertEqual(
                ownership.owner(documentID: scope.documentID, serverOrigin: scope.serverOrigin), .owned(scope),
                "\(boundary)")
            let restored = try ReplicaStore(directory: root).restore(for: scope)
            XCTAssertEqual(restored?.checkpoint, boundary.manifestIsVisible ? baseline : nil, "\(boundary)")
        }
    }

    func testCreateRefusesWhenOwnershipCannotBeWritten() throws {
        ownershipDefaults.set(Data([0xff]), forKey: "dev.llun.Schrift.replicaOwnership")
        let (store, ownership) = ownedStore()
        do {
            _ = try store.create(for: scope, checkpoint: baseline)
            XCTFail("a replica must not exist without a marker")
        } catch ReplicaStoreError.ownershipUnavailable {}
        XCTAssertNil(try store.restore(for: scope))
        XCTAssertTrue(ownership.holdsUnreadableData)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.path), "no replica directory exists without a marker")
    }

    func testLostMarkerDataWithReplicaFilesIsUnreadable() throws {
        let (store, ownership) = ownedStore()
        XCTAssertEqual(store.ownership(documentID: scope.documentID, serverOrigin: scope.serverOrigin), .none)
        _ = try store.create(for: scope, checkpoint: baseline)
        XCTAssertEqual(store.ownership(documentID: scope.documentID, serverOrigin: scope.serverOrigin), .owned(scope))
        // Marker data exists once any replica was created, even after every
        // marker is cleared, so its absence beside replica files means it was lost.
        try store.remove(for: scope)
        XCTAssertTrue(ownership.hasData)
        XCTAssertEqual(store.ownership(documentID: scope.documentID, serverOrigin: scope.serverOrigin), .none)
        _ = try store.create(for: scope, checkpoint: baseline)
        ownershipDefaults.removeObject(forKey: "dev.llun.Schrift.replicaOwnership")
        XCTAssertEqual(store.ownership(documentID: scope.documentID, serverOrigin: scope.serverOrigin), .unreadable)
        XCTAssertEqual(store.ownership(documentID: UUID(), serverOrigin: scope.serverOrigin), .unreadable)
    }

    func testRemoveClearsMarkerAndFilesAndIsIdempotent() throws {
        let (store, ownership) = ownedStore()
        _ = try store.create(for: scope, checkpoint: baseline)
        _ = try store.append(Data([1]), for: scope, commandID: UUID(), baseRevision: 0, origin: .local)
        XCTAssertEqual(ownership.owner(documentID: scope.documentID, serverOrigin: scope.serverOrigin), .owned(scope))
        try store.remove(for: scope)
        XCTAssertNil(try store.restore(for: scope))
        XCTAssertEqual(ownership.owner(documentID: scope.documentID, serverOrigin: scope.serverOrigin), .none)
        // A second discard is a no-op, not an error.
        try store.remove(for: scope)
        XCTAssertEqual(ownership.owner(documentID: scope.documentID, serverOrigin: scope.serverOrigin), .none)
    }

    func testRemoveWorksWhenQuarantined() throws {
        let (store, ownership) = ownedStore()
        _ = try store.create(for: scope, checkpoint: baseline)
        let manifest = try store.append(Data([7]), for: scope, commandID: UUID(), baseRevision: 0, origin: .local)
        let folder = directory.appendingPathComponent(try scope.directoryName())
        try Data([8]).write(to: folder.appendingPathComponent(manifest.journal[0].file.name))
        XCTAssertThrowsError(try store.restore(for: scope))
        // The user asked to discard this work; a sticky corruption hold must
        // not make it undeletable.
        try store.remove(for: scope)
        XCTAssertNil(try store.restore(for: scope))
        XCTAssertEqual(ownership.owner(documentID: scope.documentID, serverOrigin: scope.serverOrigin), .none)
    }

    func testRemoveCrashBoundariesKeepTheSafeDirection() throws {
        for boundary in [ReplicaStore.Boundary.replicaRenamed, .ownershipCleared] {
            let root = directory.appendingPathComponent(UUID().uuidString)
            let ownership = ReplicaOwnershipStore(userDefaults: ownershipDefaults)
            let healthy = ReplicaStore(directory: root, ownershipStore: ownership)
            _ = try healthy.create(for: scope, checkpoint: baseline)
            let crashing = ReplicaStore(directory: root, ownershipStore: ownership) { op, point in
                if op == .remove && point == boundary { throw Interrupted.crash }
            }
            XCTAssertThrowsError(try crashing.remove(for: scope), "\(boundary)")
            // The replica is unreachable at both boundaries, so it can never be
            // replayed as a half-deleted edit.
            XCTAssertNil(try healthy.restore(for: scope), "\(boundary)")
            let expected: ReplicaOwnership = boundary == .replicaRenamed ? .owned(scope) : .none
            XCTAssertEqual(
                ownership.owner(documentID: scope.documentID, serverOrigin: scope.serverOrigin), expected,
                "\(boundary)")
            // A retry finishes the discard and clears the marker.
            try healthy.remove(for: scope)
            XCTAssertEqual(ownership.owner(documentID: scope.documentID, serverOrigin: scope.serverOrigin), .none)
            XCTAssertNil(try healthy.restore(for: scope))
        }
    }

    func testRemoveWithoutOwnershipStoreStillRemovesFiles() throws {
        let store = store()
        _ = try store.create(for: scope, checkpoint: baseline)
        try store.remove(for: scope)
        XCTAssertNil(try store.restore(for: scope))
    }
}

extension ReplicaStore.Boundary {
    fileprivate static let manifestBoundaries: [Self] = [
        .manifestWritten, .manifestFlushed, .manifestSwitched, .manifestDirectoryFlushed,
    ]
    fileprivate static let commitBoundaries: [Self] =
        [
            .payloadWritten, .payloadFlushed, .payloadDirectoryFlushed,
        ] + manifestBoundaries
    fileprivate var manifestIsVisible: Bool {
        self == .manifestSwitched || self == .manifestDirectoryFlushed || self == .obsoleteFilesRemoved
    }
}
