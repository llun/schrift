import CryptoKit
import Foundation

/// Unsynced replicas belong to an account, not just to a document UUID. The
/// directory name is a digest so neither document content nor account names
/// appear in paths. Callers must supply the authenticated account's full scope.
struct ReplicaScope: Codable, Equatable, Sendable {
    let serverOrigin: String
    let ownerUserID: UUID
    let org: String
    let documentID: UUID

    var isValid: Bool {
        guard let url = URLComponents(string: serverOrigin),
            url.scheme == "https" || url.scheme == "http", url.host?.isEmpty == false,
            url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
            url.path.isEmpty || url.path == "/", !org.isEmpty
        else { return false }
        return true
    }

    func directoryName() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return replicaDigest(try encoder.encode(self))
    }
}

struct ReplicaFile: Codable, Equatable, Sendable {
    let name: String
    let byteCount: Int
    let digest: String
}

struct ReplicaJournalEntry: Codable, Equatable, Sendable {
    enum Origin: String, Codable, Sendable { case local, remote }
    let sequence: UInt64
    let commandID: UUID
    let origin: Origin
    let file: ReplicaFile
}

/// Only this small, atomically switched value determines which immutable files
/// are committed. Outbox entries may precede the checkpoint after compaction:
/// they still have to be sent even though replay no longer needs them.
struct ReplicaManifest: Codable, Equatable, Sendable {
    static let currentFormat = 1
    let formatVersion: Int
    let scope: ReplicaScope
    let generation: UUID
    var revision: UInt64
    var checkpointSequence: UInt64
    var checkpoint: ReplicaFile
    var journal: [ReplicaJournalEntry]
    var outbox: [UInt64]
    var httpAcknowledgedThrough: UInt64
    let projectionCacheVersion: Int
}

struct ReplicaRestore: Sendable {
    let manifest: ReplicaManifest
    let checkpoint: Data
    /// Ordered updates after the checkpoint; applying Yjs updates twice is safe.
    let updates: [Data]
}

/// A captured, durable HTTP batch. Acknowledgment cannot accidentally include a
/// keystroke appended while the request was in flight. A socket send is never
/// sufficient evidence to call `acknowledge`.
struct ReplicaOutboxBatch: Equatable, Sendable {
    let scope: ReplicaScope
    let generation: UUID
    let sequences: [UInt64]
    let updates: [Data]

    fileprivate init(scope: ReplicaScope, generation: UUID, sequences: [UInt64], updates: [Data]) {
        self.scope = scope
        self.generation = generation
        self.sequences = sequences
        self.updates = updates
    }

    static func capture(manifest: ReplicaManifest, updates: [Data]) -> Self {
        Self(scope: manifest.scope, generation: manifest.generation, sequences: manifest.outbox, updates: updates)
    }
}

/// Optional-on-decode on PendingDraft. Markdown is a compatibility shadow; raw
/// generation/revision provenance is required in addition to canonical equality.
struct ReplicaDraftReference: Codable, Equatable, Sendable {
    let scope: ReplicaScope
    let formatVersion: Int
    let generation: UUID
    let revision: UInt64
    let projectionDigest: String

    init(manifest: ReplicaManifest, markdown: String) {
        scope = manifest.scope
        formatVersion = manifest.formatVersion
        generation = manifest.generation
        revision = manifest.revision
        projectionDigest = replicaDigest(Data(canonicalMarkdownStructure(markdown).utf8))
    }

    func matches(markdown: String) -> Bool {
        projectionDigest == replicaDigest(Data(canonicalMarkdownStructure(markdown).utf8))
    }
}

func replicaDigest(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}
