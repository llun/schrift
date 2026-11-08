import Foundation
import Observation

/// PR01's sole replica owner. It is deliberately separate from the live
/// collaboration manager: the classic bridge never attaches to this replica.
@MainActor @Observable
final class NativeEditorSession {
    private var doc: YDoc?
    let engine: DocumentEngine
    let textView: NativeTextView
    let surface: NativeTextSurface
    let hasUnsupportedRoot: Bool
    private(set) var input: NativeInputCoordinator?
    private var replicaScope: ReplicaScope?
    private var replicaStore: ReplicaStore?
    var isClosed: Bool { doc == nil }

    init(
        state: Data,
        revision: UInt64 = 0,
        makeReplica: () throws -> YDoc = { YDoc(clientID: UInt.random(in: 1...UInt(UInt32.max)), gc: true) }
    ) throws {
        let doc = try makeReplica()
        do {
            try doc.applyUpdate(YUpdateDecoder.decode(state), origin: .remote)
        } catch {
            doc.destroy()
            throw error
        }
        let projected = YBlockProjection.project(doc)
        let view = NativeTextView()
        let resolver = NativeBlockResolver()
        let surface = NativeTextSurface(
            blocks: projected.blocks.map(BlockSnapshot.init), storage: view.textStorage, traits: view.traitCollection,
            reprojectBlock: { resolver.engine?.nativeSnapshot(for: $0) })
        self.doc = doc
        self.textView = view
        self.surface = surface
        self.hasUnsupportedRoot = projected.blocks.isEmpty && !projected.isFullyRenderable
        // The initial projection is installed before hooks accept transactions.
        self.engine = DocumentEngine(doc: doc, surface: surface, revision: revision)
        resolver.engine = engine
    }

    func close() {
        guard let doc else { return }
        textView.isEditable = false
        textView.delegate = nil
        textView.inputCoordinator = nil
        input = nil
        self.doc = nil
        doc.destroy()
    }

    /// Only enable after a raw checkpoint is durable. Production route wiring
    /// waits for the coordinator-backed save/reopen ownership path.
    func enableTyping(persist: @escaping (NativeEditCommand, Data) throws -> Void) {
        guard !isClosed, !hasUnsupportedRoot, input == nil else { return }
        input = NativeInputCoordinator(engine: engine, surface: surface, view: textView, persist: persist)
    }

    /// Offline restoration never rebuilds rich state from a Markdown shadow.
    /// Retained structs keep their original client IDs; new authoring uses an
    /// ID absent from the restored store. No live manager/socket is attached.
    static func restore(store: ReplicaStore, scope: ReplicaScope, editable: Bool = false) throws -> NativeEditorSession?
    {
        guard let restored = try store.restore(for: scope) else { return nil }
        let session = try NativeEditorSession(state: Data([0, 0]), revision: restored.manifest.revision) {
            let doc = YDoc(clientID: UInt.random(in: 1...UInt(UInt32.max)))
            do {
                try doc.applyUpdate(YUpdateDecoder.decode(restored.checkpoint), origin: .remote)
                for update in restored.updates { try doc.applyUpdate(YUpdateDecoder.decode(update), origin: .remote) }
                guard doc.store.pendingStructs == nil, doc.store.pendingDs == nil else {
                    throw ReplicaStoreError.corrupt
                }
                var fresh = UInt.random(in: 1...UInt(UInt32.max))
                while doc.store.clients[fresh] != nil { fresh = UInt.random(in: 1...UInt(UInt32.max)) }
                doc.clientID = fresh
                return doc
            } catch {
                doc.destroy()
                throw error
            }
        }
        session.replicaScope = scope
        session.replicaStore = store
        session.engine.onUnjournaledTransaction = { [weak session] in session?.input?.stopAfterStorageFailure() }
        if editable {
            let adapter = ReplicaSaveAdapter(store: store, scope: scope)
            session.enableTyping { try adapter.record($0, update: $1) }
        }
        return session
    }

    /// Reconnect fetches merge into the same owner. The new server bytes are
    /// journaled before any resulting surface patch is published.
    func integrateServerState(_ state: Data) throws {
        guard let doc, let scope = replicaScope, let store = replicaStore else { throw ReplicaSaveError.invalidScope }
        let update = state.isEmpty ? Data([0, 0]) : state
        let decoded = try YUpdateDecoder.decode(update)
        do {
            try engine.durablyIntegrateRemote(
                update: update,
                apply: {
                    try doc.applyUpdate(decoded, origin: .remote)
                    guard doc.store.pendingStructs == nil, doc.store.pendingDs == nil else {
                        throw ReplicaStoreError.corrupt
                    }
                },
                persist: { revision in
                    try store.append(update, for: scope, commandID: UUID(), baseRevision: revision, origin: .remote)
                })
        } catch {
            if engine.nativeWriteFailed { input?.stopAfterStorageFailure() }
            throw error
        }
    }

    isolated deinit { doc?.destroy() }

}

@MainActor
private final class NativeBlockResolver {
    weak var engine: DocumentEngine?
}

/// Reads the flag at each open. Failed/legacy/offline opens go to the classic
/// editor; a selected route never changes in response to a preference write.
///
/// A document named by the durable owner marker is different: it is restored
/// read-only from its replica regardless of the switch or connectivity, and it
/// never falls back to the classic editor. Missing or corrupt marker data is
/// read-only too, because ownership is unknown rather than absent.
@MainActor @Observable
final class NativeEditorOpen {
    enum Route {
        case loading, classic
        case native(NativeEditorSession)
        /// The marker says native owns this document, but its replica is
        /// missing or unreadable. Show the preserved read-only explanation;
        /// never open the classic writer over it.
        case preservedUnavailable
    }
    private(set) var enabled = false
    private(set) var route: Route
    /// True when the native route was selected because the document is
    /// native-owned, not because the experimental switch is on. The view uses
    /// it to explain why editing is unavailable.
    private(set) var isPreservedReadOnly = false
    private var isOpen = false
    private let preference: @MainActor () -> Bool
    private var generation = 0
    private enum OpenResult: Sendable {
        case classic
        case state(Data)
    }
    private var pendingOpen: AsyncStream<OpenResult>.Continuation?
    private let waitForTimeout: @MainActor () async throws -> Void

    init(
        preference: @escaping @MainActor () -> Bool = { NativeEditorPreference.isEnabled() },
        waitForTimeout: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(3)) }
    ) {
        self.preference = preference
        // Preserve the immediate default-off classic renderer. This initial
        // value only chooses the initial view; every safe open rereads the key.
        let initialPreference = preference()
        self.enabled = initialPreference
        self.route = initialPreference ? .loading : .classic
        self.waitForTimeout = waitForTimeout
    }

    func open(viewModel: EditorViewModel, isOffline: Bool) async {
        // A repeated call while visible must not swap a focused editor. Close
        // establishes the next safe open or reopen boundary.
        guard !isOpen else { return }
        isOpen = true
        enabled = preference()
        isPreservedReadOnly = false
        // A reappearing classic editor keeps its SwiftUI identity and local
        // view state while the optional native eligibility read is in flight.
        switch route {
        case .loading, .native, .preservedUnavailable: route = .loading
        case .classic: break
        }
        pendingOpen?.finish()
        generation += 1
        let request = generation
        // Ownership is checked before any network and regardless of the switch.
        // A native-owned document is restored from its durable replica, or
        // shown read-only when that replica cannot be read. The coordinator's
        // store is the one its classic/live refusal reads.
        let coordinator = viewModel.saveCoordinator
        switch coordinator.nativeOwnership(documentID: viewModel.documentID) {
        case .unreadable:
            route = .preservedUnavailable
            return
        case .owned(let scope):
            // Another account's unsynced replica is never shown to this one.
            guard scope.ownerUserID == viewModel.signedInUser.userID else {
                route = .preservedUnavailable
                return
            }
            // Slice A never types in production, so the "turn the switch on"
            // explanation is only true while the switch is off.
            isPreservedReadOnly = !enabled
            route = restoreOwned(scope: scope, store: coordinator.replicaStore)
            return
        case .none:
            break
        }
        guard canOpen(viewModel, isOffline: isOffline) else {
            route = .classic
            return
        }
        // A task-group race waits for cancelled children before returning. A
        // shared config read may not cooperate, so use a one-result stream and
        // cancel both owned tasks without holding the classic cache behind it.
        let (results, continuation) = AsyncStream<OpenResult>.makeStream(bufferingPolicy: .bufferingOldest(1))
        pendingOpen = continuation
        let fetch = Task { @MainActor [weak self] in
            defer { continuation.finish() }
            do {
                guard !Task.isCancelled else { return }
                let config = try await viewModel.client.serverConfig()
                guard !Task.isCancelled,
                    self?.canContinue(request: request, viewModel: viewModel, isOffline: isOffline) == true,
                    config.usesCollaborationYDocServer
                else {
                    continuation.yield(.classic)
                    return
                }
                let state = try await viewModel.client.collaborationYDocState(
                    documentID: viewModel.documentID, org: config.collaborationOrg)
                guard !Task.isCancelled else { return }
                guard self?.canContinue(request: request, viewModel: viewModel, isOffline: isOffline) == true,
                    try await viewModel.refreshOfflineCacheForNativeReader()
                else {
                    continuation.yield(.classic)
                    return
                }
                continuation.yield(.state(state))
            } catch {
                continuation.yield(.classic)
            }
        }
        let waitForTimeout = self.waitForTimeout
        let timeout = Task { @MainActor in
            do {
                guard !Task.isCancelled else { return }
                try await waitForTimeout()
                guard !Task.isCancelled else { return }
                continuation.yield(.classic)
                continuation.finish()
            } catch {
                // Cancellation after fetch/close is not another result.
            }
        }
        defer {
            fetch.cancel()
            timeout.cancel()
            continuation.finish()
            if generation == request { pendingOpen = nil }
        }
        var iterator = results.makeAsyncIterator()
        guard let result = await iterator.next(), !Task.isCancelled, generation == request else { return }
        guard canOpen(viewModel, isOffline: isOffline), case .state(let state) = result else {
            route = .classic
            return
        }
        do { route = .native(try NativeEditorSession(state: state)) } catch { route = .classic }
    }

    private func restoreOwned(scope: ReplicaScope, store: ReplicaStore) -> Route {
        do {
            guard
                let session = try NativeEditorSession.restore(
                    store: store, scope: scope, editable: false)
            else { return .preservedUnavailable }
            return .native(session)
        } catch {
            return .preservedUnavailable
        }
    }

    private func canContinue(request: Int, viewModel: EditorViewModel, isOffline: Bool) -> Bool {
        generation == request && canOpen(viewModel, isOffline: isOffline)
    }

    private func canOpen(_ viewModel: EditorViewModel, isOffline: Bool) -> Bool {
        // Transport evidence only skips this optional prefetch. The classic
        // route keeps its existing cache/retry controls so it can recover.
        enabled && !isOffline && !viewModel.availability.showsOfflineStatus && !viewModel.isLocalDocument
            && !viewModel.isDocumentPendingDelete
            && !viewModel.hasPendingNewDocumentEntry
            && !viewModel.isEditing && !viewModel.hasUnsavedLocalContent
            && viewModel.saveCoordinator.storedDraft(documentID: viewModel.documentID) == nil
            && viewModel.saveCoordinator.pendingSave(documentID: viewModel.documentID) == nil
    }

    func close() {
        isOpen = false
        generation += 1
        pendingOpen?.finish()
        pendingOpen = nil
        isPreservedReadOnly = false
        switch route {
        case .native(let session):
            session.close()
            route = .loading
        case .preservedUnavailable:
            route = .loading
        case .loading, .classic:
            break
        }
    }
}
