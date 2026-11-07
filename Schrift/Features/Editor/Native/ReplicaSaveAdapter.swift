import Foundation

enum ReplicaSaveError: Error, Equatable {
    case incompatibleDraft, staleReference, invalidScope
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

    func prepare(markdown: String, expected: ReplicaDraftReference? = nil) throws -> ReplicaSaveRequest {
        guard scope.isValid, let restored = try store.restore(for: scope) else { throw ReplicaSaveError.invalidScope }
        let reference = ReplicaDraftReference(manifest: restored.manifest, markdown: markdown)
        if let expected, expected != reference { throw ReplicaSaveError.staleReference }
        return ReplicaSaveRequest(adapter: self, reference: reference, batch: try store.outbox(for: scope))
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
