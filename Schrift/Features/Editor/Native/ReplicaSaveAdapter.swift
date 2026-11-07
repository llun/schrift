import Foundation

enum ReplicaSaveError: Error, Equatable {
    case incompatibleDraft, staleReference, invalidScope
    /// The raw revision has no total Markdown shadow yet (opaque/rich blocks).
    case unprojectableShadow
}

/// An immutable captured save, constructed only after the raw journal is
/// verified. Keeping the adapter here also preserves the injected store's
/// identity across the coordinator's queued/in-flight slots.
struct ReplicaSaveRequest: Equatable, Sendable {
    let adapter: ReplicaSaveAdapter
    let reference: ReplicaDraftReference
    let batch: ReplicaOutboxBatch?

    fileprivate init(adapter: ReplicaSaveAdapter, reference: ReplicaDraftReference, batch: ReplicaOutboxBatch?) {
        self.adapter = adapter
        self.reference = reference
        self.batch = batch
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.reference == rhs.reference && lhs.batch == rhs.batch
    }
}

/// Docs 6 only. Saves use the coordinator's existing single-writer slots and
/// half-land handling, never the legacy live-snapshot fallback or Markdown diff.
@MainActor
final class ReplicaSaveAdapter {
    let scope: ReplicaScope
    private let store: ReplicaStore

    init(store: ReplicaStore, scope: ReplicaScope) {
        self.store = store
        self.scope = scope
    }

    /// The only per-keystroke work: append the incremental bytes durably.
    /// Projection/shadow generation and HTTP scheduling happen separately.
    func record(_ command: NativeEditCommand, update: Data) throws {
        try store.append(update, for: scope, commandID: command.id, baseRevision: command.baseRevision, origin: .local)
    }

    /// Re-captures a stored draft: `markdown` is that draft's shadow and must
    /// match `expected`. A reference older than the journal (keystrokes appended
    /// after its draft was written) is re-stamped from the current raw revision,
    /// never from its stale Markdown. A different scope, format or generation, a
    /// revision ahead of the journal, or a mismatched shadow is refused.
    func prepare(
        markdown: String, expected: ReplicaDraftReference
    ) throws -> (request: ReplicaSaveRequest, markdown: String) {
        let restored = try restoreVerified()
        let manifest = restored.manifest
        guard expected.scope == scope, expected.formatVersion == manifest.formatVersion,
            expected.generation == manifest.generation, expected.revision <= manifest.revision,
            expected.matches(markdown: markdown)
        else { throw ReplicaSaveError.staleReference }
        return try capture(
            restored, markdown: expected.revision < manifest.revision ? Self.projectedMarkdown(restored) : markdown)
    }

    /// First capture, with no stored draft: the shadow always comes from raw,
    /// so no caller-supplied Markdown is ever stamped as current.
    func prepare() throws -> (request: ReplicaSaveRequest, markdown: String) {
        let restored = try restoreVerified()
        return try capture(restored, markdown: Self.projectedMarkdown(restored))
    }

    private func restoreVerified() throws -> ReplicaRestore {
        guard scope.isValid, let restored = try store.restore(for: scope) else { throw ReplicaSaveError.invalidScope }
        return restored
    }

    private func capture(
        _ restored: ReplicaRestore, markdown: String
    ) throws -> (request: ReplicaSaveRequest, markdown: String) {
        let reference = ReplicaDraftReference(manifest: restored.manifest, markdown: markdown)
        return (ReplicaSaveRequest(adapter: self, reference: reference, batch: try store.outbox(for: scope)), markdown)
    }

    /// The compatibility shadow of a verified raw revision. Read-only: this
    /// throwaway replica never authors, and the shadow is never a writer.
    private static func projectedMarkdown(_ restored: ReplicaRestore) throws -> String {
        let doc = YDoc(clientID: 0)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(restored.checkpoint), origin: .remote)
        for update in restored.updates { try doc.applyUpdate(YUpdateDecoder.decode(update), origin: .remote) }
        guard doc.store.pendingStructs == nil, doc.store.pendingDs == nil else { throw ReplicaStoreError.corrupt }
        guard let markdown = YBlockProjection.projectedMarkdown(YBlockProjection.project(doc)) else {
            throw ReplicaSaveError.unprojectableShadow
        }
        return markdown
    }

    func isCurrent(_ request: ReplicaSaveRequest) -> Bool {
        guard let restored = try? store.restore(for: scope) else { return false }
        return restored.manifest.generation == request.reference.generation
            && restored.manifest.revision == request.reference.revision && restored.manifest.outbox.isEmpty
    }

    /// Confirmation of every body PATCH precedes the durable acknowledgment,
    /// then the caller attempts title. A partial batch is retained in full and
    /// retried idempotently. Delete-only bytes are never inferred from a vector.
    func saveBody(_ request: ReplicaSaveRequest, client: DocsAPIClient) async throws {
        guard client.serverOrigin == scope.serverOrigin, request.reference.scope == scope,
            let restored = try store.restore(for: scope),
            restored.manifest.generation == request.reference.generation,
            restored.manifest.revision >= request.reference.revision
        else { throw ReplicaSaveError.staleReference }
        let config = try await client.serverConfig()
        guard config.usesCollaborationYDocServer, config.collaborationOrg == scope.org else {
            throw ReplicaSaveError.invalidScope
        }
        guard try await client.currentUser().id == scope.ownerUserID else { throw DocsAPIError.forbidden }
        if let batch = request.batch {
            for update in batch.updates {
                try await client.applyCollaborationYDocUpdate(
                    documentID: scope.documentID, org: scope.org, update: update)
            }
            try store.acknowledge(batch)
        }
    }
}
