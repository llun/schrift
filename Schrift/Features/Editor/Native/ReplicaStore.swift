import Darwin
import Foundation

enum ReplicaStoreError: Error, Equatable {
    case invalidScope, alreadyExists, missingReplica, staleRevision, reusedCommand
    case unsupportedFormat, corrupt, quarantined, invalidAcknowledgment
    /// The durable owner marker could not be written, so creating a replica
    /// would leave it invisible to the read-only route.
    case ownershipUnavailable
}

/// Draft storage, never a re-downloadable cache. There is deliberately no
/// eviction or sign-out removal API; `remove(for:)` exists only for an explicit
/// user discard (keep-server-version, discard pending work, document deletion).
/// One main-actor writer serializes each read/modify/switch, including
/// independently constructed store instances. Raw files are immutable; an
/// incomplete unreferenced file is not an edit.
@MainActor
final class ReplicaStore {
    enum Operation: Equatable { case create, append, acknowledge, compact, remove }
    enum Boundary: Equatable {
        case payloadWritten, payloadFlushed, payloadDirectoryFlushed
        case manifestWritten, manifestFlushed, manifestSwitched, manifestDirectoryFlushed
        case obsoleteFilesRemoved
        case replicaRenamed, ownershipCleared
    }

    private struct Envelope: Codable {
        let manifest: Data
        let digest: String
    }

    private let directory: URL
    private let fileManager = FileManager.default
    /// The durable "native owns this document" marker. Optional so component
    /// tests can exercise raw storage without UserDefaults; production always
    /// injects one.
    let ownershipStore: ReplicaOwnershipStore?
    /// Throwing at a boundary models a process interruption. No catch rewinds
    /// an already switched manifest; the next operation reads disk afresh.
    private let interrupt: ((Operation, Boundary) throws -> Void)?

    init(
        directory: URL? = nil, ownershipStore: ReplicaOwnershipStore? = nil,
        interrupt: ((Operation, Boundary) throws -> Void)? = nil
    ) {
        self.directory =
            directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.llun.Schrift/ReplicaDrafts", isDirectory: true)
        self.ownershipStore = ownershipStore
        self.interrupt = interrupt
    }

    /// The durable owner marker's answer, failing closed when the marker data is
    /// gone but replica files exist: then ownership is unknown, not absent.
    func ownership(documentID: UUID, serverOrigin: String) -> ReplicaOwnership {
        guard let ownershipStore else { return .none }
        let owner = ownershipStore.owner(documentID: documentID, serverOrigin: serverOrigin)
        if owner == .none, !ownershipStore.hasData, fileManager.fileExists(atPath: directory.path) {
            return .unreadable
        }
        return owner
    }

    /// Marker data is missing or does not decode while replica files exist, so
    /// every document is read-only until the marker is rebuilt.
    var needsOwnershipRepair: Bool {
        guard let ownershipStore else { return false }
        if ownershipStore.holdsUnreadableData { return true }
        return !ownershipStore.hasData && fileManager.fileExists(atPath: directory.path)
    }

    /// Rebuild the owner marker from the scoped manifests on disk and the scopes
    /// native drafts reference (`draftScopes`; a draft's work is native even when
    /// its folder is gone). Only the explicit Profile recovery action calls this;
    /// routine writes never overwrite unreadable marker data. Returns whether
    /// the marker is now readable.
    ///
    /// A folder without a manifest or quarantine never committed an edit (a
    /// crash inside `create`), so it claims nothing. A folder that is
    /// quarantined, damaged or in a newer format cannot name its document, so
    /// nothing is written: a rebuilt marker would call that document classic.
    /// Two scopes for one document resolve to the drafted one, else the only one
    /// with unsent edits; anything still ambiguous also writes nothing. Both
    /// refusals keep every document read-only, the fail-closed direction.
    @discardableResult
    func repairOwnership(draftScopes: [ReplicaScope] = []) -> Bool {
        guard let ownershipStore else { return false }
        var candidates = draftScopes.map { (scope: $0, hasOutbox: false) }
        for entry in replicaFolders() {
            switch read(folder: entry) {
            case .uncommitted: continue
            case .unreadable: return false
            case .manifest(let manifest): candidates.append((manifest.scope, !manifest.outbox.isEmpty))
            }
        }
        var scopes: [ReplicaScope] = []
        let byDocument = Dictionary(grouping: candidates) { "\($0.scope.serverOrigin)|\($0.scope.documentID)" }
        for group in byDocument.values {
            var distinct: [ReplicaScope] = []
            for candidate in group where !distinct.contains(candidate.scope) { distinct.append(candidate.scope) }
            let unsent = group.filter(\.hasOutbox).map(\.scope)
            if distinct.count == 1 {
                scopes.append(distinct[0])
            } else if let drafted = distinct.first(where: { draftScopes.contains($0) }) {
                scopes.append(drafted)  // one document has at most one draft
            } else if unsent.count == 1 {
                scopes.append(unsent[0])
            } else {
                return false
            }
        }
        return ownershipStore.repair(from: scopes)
    }

    /// Folders that block `repairOwnership`: quarantined, damaged or in a newer format.
    var hasUnreadableFolders: Bool {
        replicaFolders().contains { if case .unreadable = read(folder: $0) { true } else { false } }
    }

    /// The Profile recovery's way out of a folder no repair can read. Each one is
    /// moved, bytes intact, into `ReplicaDraftsSetAside` beside this store, which
    /// nothing reads as a replica; its document then follows its draft (read-only)
    /// or, with none, the server. Returns false if any move failed.
    @discardableResult
    func setAsideUnreadableFolders() -> Bool {
        let unreadable = replicaFolders().filter { if case .unreadable = read(folder: $0) { true } else { false } }
        guard !unreadable.isEmpty else { return true }
        let setAside = directory.deletingLastPathComponent()
            .appendingPathComponent("ReplicaDraftsSetAside", isDirectory: true)
        do {
            try ensureDirectory(setAside)
            for folder in unreadable {
                try renameFile(
                    folder, to: setAside.appendingPathComponent("\(folder.lastPathComponent).\(UUID().uuidString)"))
            }
            try syncDirectory(setAside)
            try syncDirectory(directory)
            return true
        } catch {
            return false
        }
    }

    private enum FolderRead {
        /// No manifest and no quarantine: a crash inside `create`, which claims nothing.
        case uncommitted
        case unreadable
        case manifest(ReplicaManifest)
    }

    private func replicaFolders() -> [URL] {
        let entries = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.pathExtension != "removed" }
    }

    /// Reads without quarantining: repair and set-aside must not change a folder.
    private func read(folder entry: URL) -> FolderRead {
        let file = entry.appendingPathComponent("manifest.json")
        let blocked = entry.appendingPathComponent("Recovery/blocked")
        guard fileManager.fileExists(atPath: file.path) || fileManager.fileExists(atPath: blocked.path) else {
            return .uncommitted
        }
        guard !fileManager.fileExists(atPath: blocked.path),
            let bytes = try? Data(contentsOf: file),
            let envelope = try? JSONDecoder().decode(Envelope.self, from: bytes),
            replicaDigest(envelope.manifest) == envelope.digest,
            let manifest = try? JSONDecoder().decode(ReplicaManifest.self, from: envelope.manifest),
            manifest.formatVersion == ReplicaManifest.currentFormat, isValid(manifest),
            // A folder claims only the scope its name was derived from.
            (try? folder(for: manifest.scope).lastPathComponent) == entry.lastPathComponent
        else { return .unreadable }
        return .manifest(manifest)
    }

    /// Clear this scope's marker when it has no replica: a crash between
    /// marking and the first manifest. Refuses while a manifest or a
    /// quarantine hold exists; the coordinator also requires no draft.
    @discardableResult
    func clearOwnership(for scope: ReplicaScope) -> Bool {
        do {
            guard try readManifest(for: scope) == nil else { return false }
        } catch {
            return false
        }
        return ownershipStore?.clear(scope) ?? true
    }

    func create(for scope: ReplicaScope, checkpoint: Data) throws -> ReplicaManifest {
        guard try readManifest(for: scope) == nil else { throw ReplicaStoreError.alreadyExists }
        let folder = try folder(for: scope)
        // Mark ownership before any replica file or directory exists. A crash can
        // then leave a marker without a replica (read-only, safe), never a replica
        // without a marker (which the classic writer could overwrite), and an
        // existing root without marker data always means the marker was lost.
        guard ownershipStore?.mark(scope) ?? true else { throw ReplicaStoreError.ownershipUnavailable }
        try ensureDirectory(folder)
        var root = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try root.setResourceValues(values)
        let file = try writePayload(checkpoint, in: folder, journal: false, operation: .create)
        let manifest = ReplicaManifest(
            formatVersion: ReplicaManifest.currentFormat, scope: scope, generation: UUID(), revision: 0,
            checkpointSequence: 0, checkpoint: file, journal: [], outbox: [], httpAcknowledgedThrough: 0,
            projectionCacheVersion: 1)
        try switchManifest(manifest, in: folder, operation: .create)
        return manifest
    }

    /// A successful return is the durability boundary. The caller must not
    /// publish or send an edit before this returns, and must stop writing after
    /// any failure (the in-memory Yjs transaction itself has no rollback).
    @discardableResult
    func append(
        _ update: Data, for scope: ReplicaScope, commandID: UUID, baseRevision: UInt64,
        origin: ReplicaJournalEntry.Origin
    ) throws -> ReplicaManifest {
        var manifest = try requireManifest(for: scope)
        if let prior = manifest.journal.first(where: { $0.commandID == commandID }) {
            guard prior.sequence > 0, prior.sequence - 1 == baseRevision, prior.origin == origin,
                try readPayload(prior.file, for: scope) == update
            else { throw ReplicaStoreError.reusedCommand }
            return manifest
        }
        guard manifest.revision == baseRevision, baseRevision < UInt64.max else {
            throw ReplicaStoreError.staleRevision
        }
        let folder = try folder(for: scope)
        let file = try writePayload(update, in: folder, journal: true, operation: .append)
        manifest.revision += 1
        manifest.journal.append(
            ReplicaJournalEntry(sequence: manifest.revision, commandID: commandID, origin: origin, file: file))
        if origin == .local { manifest.outbox.append(manifest.revision) }
        try switchManifest(manifest, in: folder, operation: .append)
        return manifest
    }

    /// Verify every referenced file, including old outbox segments covered by
    /// the checkpoint. Corrupt data never becomes a partial successful restore.
    func restore(for scope: ReplicaScope) throws -> ReplicaRestore? {
        guard let manifest = try readManifest(for: scope) else { return nil }
        let checkpoint = try readPayload(manifest.checkpoint, for: scope)
        var updates: [Data] = []
        for entry in manifest.journal {
            let bytes = try readPayload(entry.file, for: scope)
            if entry.sequence > manifest.checkpointSequence { updates.append(bytes) }
        }
        return ReplicaRestore(manifest: manifest, checkpoint: checkpoint, updates: updates)
    }

    /// The committed manifest alone, without reading or verifying payloads.
    func manifest(for scope: ReplicaScope) throws -> ReplicaManifest? { try readManifest(for: scope) }

    func outbox(for scope: ReplicaScope) throws -> ReplicaOutboxBatch? {
        _ = try restore(for: scope)
        let manifest = try requireManifest(for: scope)
        guard !manifest.outbox.isEmpty else { return nil }
        let sequences = Set(manifest.outbox)
        let updates = try manifest.journal.filter { sequences.contains($0.sequence) }.map {
            try readPayload($0.file, for: scope)
        }
        return .capture(manifest: manifest, updates: updates)
    }

    /// Call only after the corresponding HTTP body PATCH confirms. Body/title
    /// half-land must acknowledge the body independently of title retry state.
    /// Deletions are acknowledged by sequence, never by state-vector equality.
    func acknowledge(_ batch: ReplicaOutboxBatch) throws {
        var manifest = try requireManifest(for: batch.scope)
        guard batch.generation == manifest.generation, !batch.sequences.isEmpty,
            batch.sequences.count == batch.updates.count,
            batch.sequences == batch.sequences.sorted(), Set(batch.sequences).count == batch.sequences.count,
            batch.sequences.allSatisfy({ $0 > 0 && $0 <= manifest.revision })
        else { throw ReplicaStoreError.invalidAcknowledgment }
        let remaining = batch.sequences.filter { $0 > manifest.httpAcknowledgedThrough }
        guard Array(manifest.outbox.prefix(remaining.count)) == remaining else {
            throw ReplicaStoreError.invalidAcknowledgment
        }
        guard !remaining.isEmpty else { return }
        let entries = Dictionary(uniqueKeysWithValues: manifest.journal.map { ($0.sequence, $0) })
        for (sequence, update) in zip(batch.sequences, batch.updates) where remaining.contains(sequence) {
            guard let entry = entries[sequence], try readPayload(entry.file, for: batch.scope) == update else {
                throw ReplicaStoreError.invalidAcknowledgment
            }
        }
        manifest.outbox.removeFirst(remaining.count)
        manifest.httpAcknowledgedThrough = remaining.last!
        try switchManifest(manifest, in: folder(for: batch.scope), operation: .acknowledge)
    }

    /// Snapshot bytes must represent exactly `baseRevision`. This is an
    /// explicit checkpoint operation, never an encoding done per keystroke.
    /// Switch first, then remove only files the new manifest no longer needs.
    func compact(for scope: ReplicaScope, checkpoint: Data, baseRevision: UInt64) throws {
        var manifest = try requireManifest(for: scope)
        guard manifest.revision == baseRevision else { throw ReplicaStoreError.staleRevision }
        // Do not replace corrupt recovery data with a new apparently healthy
        // snapshot. This also verifies every outbox segment before pruning.
        _ = try restore(for: scope)
        let folder = try folder(for: scope)
        let previous = [manifest.checkpoint] + manifest.journal.map(\.file)
        let file = try writePayload(checkpoint, in: folder, journal: false, operation: .compact)
        manifest.checkpoint = file
        manifest.checkpointSequence = manifest.revision
        let outbox = Set(manifest.outbox)
        manifest.journal.removeAll { !outbox.contains($0.sequence) }
        try switchManifest(manifest, in: folder, operation: .compact)
        let retained = Set([file.name] + manifest.journal.map { $0.file.name })
        for obsolete in previous where !retained.contains(obsolete.name) {
            try fileManager.removeItem(at: payloadURL(obsolete, in: folder))
        }
        try syncDirectory(folder)
        if fileManager.fileExists(atPath: folder.appendingPathComponent("Journal").path) {
            try syncDirectory(folder.appendingPathComponent("Journal"))
        }
        try interrupt?(.compact, .obsoleteFilesRemoved)
    }

    /// Explicitly discard a replica. The whole folder is renamed to a tombstone
    /// before anything is deleted, so an interruption leaves either the intact
    /// replica or an unreachable tombstone — never a half-deleted replica that
    /// could be mistaken for a valid one. The owner marker is cleared only
    /// after the replica is unreachable; a crash before that leaves the
    /// document read-only rather than classic-editable.
    ///
    /// Quarantined replicas are removed too: the user asked to discard this
    /// work, and a sticky corruption hold must not make it undeletable. The
    /// recovery copies go with the folder.
    func remove(for scope: ReplicaScope) throws {
        let folder = try folder(for: scope)
        removeTombstones()
        guard fileManager.fileExists(atPath: folder.path) else {
            _ = ownershipStore?.clear(scope)
            return
        }
        let tombstone = directory.appendingPathComponent("\(UUID().uuidString).removed", isDirectory: true)
        try renameFile(folder, to: tombstone)
        try syncDirectory(directory)
        try interrupt?(.remove, .replicaRenamed)
        _ = ownershipStore?.clear(scope)
        try interrupt?(.remove, .ownershipCleared)
        try? fileManager.removeItem(at: tombstone)
        try? syncDirectory(directory)
    }

    private func removeTombstones() {
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        for entry in entries where entry.pathExtension == "removed" {
            try? fileManager.removeItem(at: entry)
        }
    }

    private func folder(for scope: ReplicaScope) throws -> URL {
        guard scope.isValid else { throw ReplicaStoreError.invalidScope }
        return directory.appendingPathComponent(try scope.directoryName(), isDirectory: true)
    }

    private func requireManifest(for scope: ReplicaScope) throws -> ReplicaManifest {
        guard let manifest = try readManifest(for: scope) else { throw ReplicaStoreError.missingReplica }
        return manifest
    }

    private func readManifest(for scope: ReplicaScope) throws -> ReplicaManifest? {
        let folder = try folder(for: scope)
        guard !fileManager.fileExists(atPath: folder.appendingPathComponent("Recovery/blocked").path) else {
            throw ReplicaStoreError.quarantined
        }
        let file = folder.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: file.path) else { return nil }
        let bytes = try Data(contentsOf: file)
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
            guard replicaDigest(envelope.manifest) == envelope.digest else { throw ReplicaStoreError.corrupt }
            let manifest = try JSONDecoder().decode(ReplicaManifest.self, from: envelope.manifest)
            guard manifest.formatVersion == ReplicaManifest.currentFormat else {
                throw ReplicaStoreError.unsupportedFormat
            }
            guard manifest.scope == scope, isValid(manifest) else { throw ReplicaStoreError.corrupt }
            return manifest
        } catch ReplicaStoreError.unsupportedFormat {
            // An older app cannot repair a newer format. Preserve it in place.
            throw ReplicaStoreError.unsupportedFormat
        } catch {
            try quarantine(in: folder, damaged: file)
            throw ReplicaStoreError.corrupt
        }
    }

    private func isValid(_ manifest: ReplicaManifest) -> Bool {
        guard manifest.checkpointSequence <= manifest.revision,
            manifest.httpAcknowledgedThrough <= manifest.revision,
            manifest.journal.map(\.sequence) == manifest.journal.map(\.sequence).sorted(),
            Set(manifest.journal.map(\.sequence)).count == manifest.journal.count,
            Set(manifest.journal.map(\.commandID)).count == manifest.journal.count,
            Set(manifest.journal.map { $0.file.name }).count == manifest.journal.count,
            !manifest.journal.contains(where: { $0.file.name == manifest.checkpoint.name }),
            manifest.journal.allSatisfy({ $0.sequence > 0 && $0.sequence <= manifest.revision }),
            manifest.outbox
                == manifest.journal.filter({
                    $0.origin == .local && $0.sequence > manifest.httpAcknowledgedThrough
                }).map(\.sequence)
        else { return false }
        let replay = manifest.journal.filter { $0.sequence > manifest.checkpointSequence }
        guard UInt64(replay.count) == manifest.revision - manifest.checkpointSequence else { return false }
        return replay.enumerated().allSatisfy { offset, entry in
            entry.sequence == manifest.checkpointSequence + UInt64(offset) + 1
        }
    }

    private func payloadURL(_ file: ReplicaFile, in folder: URL) throws -> URL {
        let pieces = file.name.split(separator: "/", omittingEmptySubsequences: false)
        let leaf: Substring
        if pieces.count == 2, pieces[0] == "Journal" {
            leaf = pieces[1]
        } else if pieces.count == 1 {
            leaf = pieces[0]
        } else {
            throw ReplicaStoreError.corrupt
        }
        guard leaf.hasSuffix(".bin"), UUID(uuidString: String(leaf.dropLast(4))) != nil,
            file.byteCount >= 0
        else { throw ReplicaStoreError.corrupt }
        return folder.appendingPathComponent(file.name)
    }

    private func readPayload(_ file: ReplicaFile, for scope: ReplicaScope) throws -> Data {
        let folder = try folder(for: scope)
        let url: URL
        do { url = try payloadURL(file, in: folder) } catch {
            try quarantine(in: folder, damaged: nil)
            throw ReplicaStoreError.corrupt
        }
        // Permission/I/O errors also stop replay. The originals stay in place
        // if they cannot be copied, so an unavailable disk never means empty.
        do {
            let bytes = try Data(contentsOf: url)
            guard bytes.count == file.byteCount, replicaDigest(bytes) == file.digest else {
                throw ReplicaStoreError.corrupt
            }
            return bytes
        } catch {
            try quarantine(in: folder, damaged: url)
            throw ReplicaStoreError.corrupt
        }
    }

    private func writePayload(_ bytes: Data, in folder: URL, journal: Bool, operation: Operation) throws -> ReplicaFile
    {
        let subfolder = journal ? folder.appendingPathComponent("Journal", isDirectory: true) : folder
        try ensureDirectory(subfolder)
        let name = "\(UUID().uuidString.lowercased()).bin"
        try writeFlushed(
            bytes, to: subfolder.appendingPathComponent(name),
            afterWrite: { try self.interrupt?(operation, .payloadWritten) },
            afterFlush: { try self.interrupt?(operation, .payloadFlushed) })
        try syncDirectory(subfolder)
        try interrupt?(operation, .payloadDirectoryFlushed)
        return ReplicaFile(
            name: journal ? "Journal/\(name)" : name, byteCount: bytes.count, digest: replicaDigest(bytes))
    }

    private func switchManifest(_ manifest: ReplicaManifest, in folder: URL, operation: Operation) throws {
        let bytes = try JSONEncoder().encode(manifest)
        let envelope = try JSONEncoder().encode(Envelope(manifest: bytes, digest: replicaDigest(bytes)))
        let temporary = folder.appendingPathComponent("\(UUID().uuidString).pending")
        try writeFlushed(
            envelope, to: temporary,
            afterWrite: { try self.interrupt?(operation, .manifestWritten) },
            afterFlush: { try self.interrupt?(operation, .manifestFlushed) })
        try renameFile(temporary, to: folder.appendingPathComponent("manifest.json"))
        try interrupt?(operation, .manifestSwitched)
        try syncDirectory(folder)
        try interrupt?(operation, .manifestDirectoryFlushed)
    }

    /// Copy rather than move: interruption during quarantine cannot remove the
    /// only remaining manifest or segment. The durable marker makes the hold
    /// sticky. Recovery is explicit future work; never automatically clear it.
    private func quarantine(in folder: URL, damaged: URL?) throws {
        let recovery = folder.appendingPathComponent("Recovery", isDirectory: true)
        try ensureDirectory(recovery)
        for source in [folder.appendingPathComponent("manifest.json"), damaged].compactMap({ $0 }) {
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = recovery.appendingPathComponent("\(UUID().uuidString).quarantine")
            try writeFlushed(Data(contentsOf: source), to: destination)
        }
        try syncDirectory(recovery)
        let marker = recovery.appendingPathComponent("blocked")
        if !fileManager.fileExists(atPath: marker.path) { try writeFlushed(Data([1]), to: marker) }
        try syncDirectory(recovery)
    }

    private func ensureDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw CocoaError(.fileWriteFileExists) }
            return
        }
        let parent = url.deletingLastPathComponent()
        try ensureDirectory(parent)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        try syncDirectory(parent)
    }

    private func writeFlushed(
        _ bytes: Data, to url: URL, afterWrite: () throws -> Void = {}, afterFlush: () throws -> Void = {}
    ) throws {
        guard fileManager.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: bytes)
        try afterWrite()
        try handle.synchronize()
        try afterFlush()
    }

    private func renameFile(_ source: URL, to destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else { throw posixError() }
    }

    private func syncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
    }

    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
