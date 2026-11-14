import Foundation
import Observation

/// Per-open-document in-memory loader for `@` mention candidates over
/// `GET /api/v1.0/documents/{id}/accesses/`.
///
/// Scoped to `(serverOrigin, ownerUserID, documentID, signInGeneration)`. Never
/// persisted to disk and never stored inside `DocsAPIClient`.
@MainActor @Observable
final class NativeMentionAccessLoader {
    struct Scope: Equatable, Sendable {
        let serverOrigin: String
        let ownerUserID: UUID?
        let documentID: UUID
        let signInGeneration: Int
    }

    private(set) var scope: Scope
    private(set) var canMention: Bool
    private(set) var isLocalDocument: Bool
    private(set) var isOffline: Bool
    private(set) var state: NativeInlinePickerSource.MentionAccessState = .idle

    @ObservationIgnored private let fetchAccesses: @MainActor (UUID) async throws -> [DocumentAccess]
    @ObservationIgnored private var inFlightTask: Task<Void, Never>?
    @ObservationIgnored private var requestGeneration = 0

    var effectiveCanMention: Bool {
        canMention && !isLocalDocument && scope.ownerUserID != nil
    }

    init(
        scope: Scope,
        canMention: Bool = false,
        isLocalDocument: Bool = false,
        isOffline: Bool = false,
        fetchAccesses: @escaping @MainActor (UUID) async throws -> [DocumentAccess]
    ) {
        self.scope = scope
        self.canMention = canMention
        self.isLocalDocument = isLocalDocument
        self.isOffline = isOffline
        self.fetchAccesses = fetchAccesses
    }

    convenience init(
        client: DocsAPIClient,
        scope: Scope,
        canMention: Bool = false,
        isLocalDocument: Bool = false,
        isOffline: Bool = false
    ) {
        self.init(
            scope: scope,
            canMention: canMention,
            isLocalDocument: isLocalDocument,
            isOffline: isOffline,
            fetchAccesses: { documentID in
                try await client.listAccesses(documentID: documentID)
            })
    }

    func update(scope: Scope, canMention: Bool, isLocalDocument: Bool, isOffline: Bool) {
        let scopeChanged = self.scope != scope
        self.scope = scope
        self.canMention = canMention
        self.isLocalDocument = isLocalDocument
        self.isOffline = isOffline
        if scopeChanged || !effectiveCanMention {
            reset()
        }
    }

    func requestMentions(for key: InlineTriggerKey) {
        guard effectiveCanMention, !isOffline else { return }
        switch state {
        case .loading, .loaded:
            return
        case .failed(let failedKey) where failedKey == key:
            return
        case .idle, .failed:
            break
        }

        requestGeneration += 1
        let generation = requestGeneration
        let expectedScope = scope
        inFlightTask?.cancel()
        state = .loading
        inFlightTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.requestGeneration == generation {
                    self.inFlightTask = nil
                }
            }
            do {
                let accesses = try await self.fetchAccesses(expectedScope.documentID)
                guard !Task.isCancelled,
                    self.requestGeneration == generation,
                    self.scope == expectedScope,
                    self.effectiveCanMention
                else { return }
                self.state = .loaded(mentionCandidates(from: accesses))
            } catch {
                guard !Task.isCancelled,
                    self.requestGeneration == generation,
                    self.scope == expectedScope,
                    self.effectiveCanMention
                else { return }
                self.state = .failed(key)
            }
        }
    }

    func clearFailure() {
        if case .failed = state {
            state = .idle
        }
    }

    func reset() {
        requestGeneration += 1
        inFlightTask?.cancel()
        inFlightTask = nil
        state = .idle
    }
}
