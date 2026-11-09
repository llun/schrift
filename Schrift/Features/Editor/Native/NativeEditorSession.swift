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
    /// Only a fully modeled document with a total Markdown shadow may be
    /// authored: anything else would be written back lossily. Opaque/rich
    /// documents stay in PR01's read-only view until the total shadow exists.
    let canType: Bool
    private(set) var input: NativeInputCoordinator?
    private var replicaScope: ReplicaScope?
    private var replicaStore: ReplicaStore?
    private var saveScheduler: NativeReplicaSaveScheduler?
    var scope: ReplicaScope? { replicaScope }
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
        self.canType = projected.isFullyModeled && YBlockProjection.projectedMarkdown(projected) != nil
        // The initial projection is installed before hooks accept transactions.
        self.engine = DocumentEngine(doc: doc, surface: surface, revision: revision)
        resolver.engine = engine
    }

    func close() {
        guard let doc else { return }
        // A close is a safe boundary: hand any debounced save to the
        // coordinator before the replica goes away. The scheduler reads the
        // durable store, not this graph, so the order is not load-bearing.
        saveScheduler?.flush()
        saveScheduler?.cancel()
        saveScheduler = nil
        textView.isEditable = false
        textView.delegate = nil
        textView.inputCoordinator = nil
        input = nil
        self.doc = nil
        doc.destroy()
    }

    /// Only enable after a raw checkpoint is durable. `scheduler` is retained
    /// so a debounced save outlives the keystroke that armed it. The production
    /// open route additionally requires `canType`; the isolated host and
    /// component tests type around preserved blocks, which input refuses.
    func enableTyping(
        persist: @escaping (NativeEditCommand, Data) throws -> Void,
        scheduler: NativeReplicaSaveScheduler? = nil
    ) {
        guard !isClosed, !hasUnsupportedRoot, input == nil else { return }
        saveScheduler = scheduler
        // A restored replica keeps IME provisional text beside its journal.
        let recoveryStore = replicaStore.flatMap { store in replicaScope.map { (store: store, scope: $0) } }
        input = NativeInputCoordinator(
            engine: engine, surface: surface, view: textView, persist: persist, recoveryStore: recoveryStore)
    }

    /// Journal bytes not yet handed to the coordinator. They are durable on
    /// this device, so the view reports them as saved here, never as synced.
    var hasPendingSave: Bool { saveScheduler?.hasPendingSave ?? false }

    /// Flush a debounced save now (background, close, a tap on the status).
    func flushPendingSave() {
        saveScheduler?.flush()
    }

    /// A capture that cannot be prepared leaves durable journal bytes nothing
    /// can send. Stop authoring rather than growing an unsendable journal.
    func freezeAuthoring() {
        input?.stopAfterStorageFailure()
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
/// from its replica regardless of the switch or connectivity, and it never
/// falls back to the classic editor. Missing or corrupt marker data is
/// read-only too, because ownership is unknown rather than absent.
///
/// With the switch on, a signed-in Docs 6 user with `abilities.update` types
/// into a durable replica: an owned one is restored offline-first and the
/// fetched server state is integrated into it; an unowned, fully projectable
/// document with no local classic work is seeded into a new replica (which
/// writes the marker). Anything else keeps PR01's read-only view.
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
    /// Bumped by every open and close (including the close a sign-in change
    /// forces), so an awaited fetch, restore or save result is dropped once
    /// the open that asked for it is gone.
    private var generation = 0
    private enum OpenResult: Sendable {
        case classic
        case state(Data, org: String)
    }
    private var pendingOpen: AsyncStream<OpenResult>.Continuation?
    /// The reopen and reconnect work `EditorView` starts outside its `.task`;
    /// close cancels both.
    private var reopenTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
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

    /// `canUpdate` is the document's `abilities.update`; missing metadata
    /// fails closed to the read-only view.
    func open(viewModel: EditorViewModel, isOffline: Bool, canUpdate: Bool = false) async {
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
        // The account this open acts for, rechecked after every await with the
        // generation: a sign-out or account switch while a fetch is pending must
        // never seed, show or integrate into another account's replica.
        let account = viewModel.signedInUser.userID
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
            guard scope.ownerUserID == account else {
                route = .preservedUnavailable
                return
            }
            let restored: NativeEditorSession?
            do {
                restored = try NativeEditorSession.restore(store: coordinator.replicaStore, scope: scope)
            } catch {
                route = .preservedUnavailable
                return
            }
            if let session = restored {
                // The "turn the switch on" explanation is only true while it is off.
                isPreservedReadOnly = !enabled
                if enabled, canUpdate, session.canType, mayType(viewModel) {
                    installTyping(session, scope: scope, viewModel: viewModel)
                }
                route = .native(session)
                // Offline-first: the replica is on screen before any request.
                await integrateServerState(
                    into: session, scope: scope, viewModel: viewModel, request: request, isOffline: isOffline)
                return
            }
            // A marker with no replica: a crash between marking and the first
            // manifest. With the switch on, clear it when nothing unsynced exists
            // anywhere and take the unowned route, which re-seeds from the server
            // when typing is possible. Otherwise it stays read-only.
            guard enabled, coordinator.clearNativeOwnership(scope: scope) else {
                route = .preservedUnavailable
                return
            }
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
                    self?.canContinue(request: request, viewModel: viewModel, isOffline: isOffline, account: account)
                        == true,
                    config.usesCollaborationYDocServer
                else {
                    continuation.yield(.classic)
                    return
                }
                let state = try await viewModel.client.collaborationYDocState(
                    documentID: viewModel.documentID, org: config.collaborationOrg)
                guard !Task.isCancelled else { return }
                guard
                    self?.canContinue(request: request, viewModel: viewModel, isOffline: isOffline, account: account)
                        == true,
                    try await viewModel.refreshOfflineCacheForNativeReader(isCurrent: {
                        self?.canContinue(
                            request: request, viewModel: viewModel, isOffline: isOffline, account: account)
                            == true
                    })
                else {
                    continuation.yield(.classic)
                    return
                }
                continuation.yield(.state(state, org: config.collaborationOrg))
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
        guard canContinue(request: request, viewModel: viewModel, isOffline: isOffline, account: account),
            case .state(let state, let org) = result
        else {
            route = .classic
            return
        }
        let session: NativeEditorSession
        do { session = try NativeEditorSession(state: state) } catch {
            route = .classic
            return
        }
        // A document that is not fully projectable, or a reader, stays in PR01's
        // in-memory read-only view and never gains a replica or marker.
        guard enabled, canUpdate, session.canType, let account, mayType(viewModel) else {
            route = .native(session)
            return
        }
        session.close()
        let scope = ReplicaScope(
            serverOrigin: viewModel.client.serverOrigin, ownerUserID: account, org: org,
            documentID: viewModel.documentID)
        route = seedReplica(state: state, scope: scope, viewModel: viewModel)
    }

    /// Reconnect: merge the fetched raw state into the open durable owner.
    func refresh(viewModel: EditorViewModel, isOffline: Bool) async {
        guard isOpen, case .native(let session) = route, let scope = session.scope else { return }
        await integrateServerState(
            into: session, scope: scope, viewModel: viewModel, request: generation, isOffline: isOffline)
    }

    /// A sign-in change: close, then open again in a task the next close cancels.
    func reopen(viewModel: EditorViewModel, isOffline: Bool, canUpdate: Bool) {
        close()
        reopenTask = Task { [weak self] in
            await self?.open(viewModel: viewModel, isOffline: isOffline, canUpdate: canUpdate)
        }
    }

    /// Reconnect, in a task close cancels; a newer reconnect replaces it.
    func refreshInBackground(viewModel: EditorViewModel, isOffline: Bool) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.refresh(viewModel: viewModel, isOffline: isOffline) }
    }

    /// Background or an explicit tap: hand any debounced save over now.
    func flushPendingSave() {
        guard case .native(let session) = route else { return }
        session.flushPendingSave()
    }

    /// The status tap. Never the classic `saveNow`: its fallback is a Markdown
    /// enqueue the owner marker refuses.
    func saveNow(viewModel: EditorViewModel) {
        guard case .native(let session) = route else { return }
        session.flushPendingSave()
        let coordinator = viewModel.saveCoordinator
        let documentID = viewModel.documentID
        guard coordinator.pendingSave(documentID: documentID) == nil,
            coordinator.storedDraft(documentID: documentID)?.replica != nil
        else { return }
        switch coordinator.state(for: documentID) {
        case .failed, .pendingSync: coordinator.retryReplicaDraft(documentID: documentID)
        case .idle, .saving, .saved: break
        }
    }

    /// Creates the replica (marker first, so a crash leaves a marker without a
    /// replica that the next open re-seeds), then restores and types into it.
    private func seedReplica(state: Data, scope: ReplicaScope, viewModel: EditorViewModel) -> Route {
        let coordinator = viewModel.saveCoordinator
        do {
            _ = try coordinator.replicaStore.create(for: scope, checkpoint: state)
            guard let session = try NativeEditorSession.restore(store: coordinator.replicaStore, scope: scope) else {
                return .preservedUnavailable
            }
            installTyping(session, scope: scope, viewModel: viewModel)
            return .native(session)
        } catch ReplicaStoreError.alreadyExists, ReplicaStoreError.corrupt, ReplicaStoreError.quarantined,
            ReplicaStoreError.unsupportedFormat
        {
            // A replica is already on disk for this scope, whatever the marker
            // says: never open the classic writer over it.
            return .preservedUnavailable
        } catch {
            // Without a marker the classic editor is still the safe owner.
            return coordinator.nativeOwnership(documentID: scope.documentID) == .none
                ? .classic : .preservedUnavailable
        }
    }

    /// Every persisted command schedules a debounced save through the
    /// coordinator's replica path, at the classic autosave cadence.
    private func installTyping(_ session: NativeEditorSession, scope: ReplicaScope, viewModel: EditorViewModel) {
        let coordinator = viewModel.saveCoordinator
        let adapter = ReplicaSaveAdapter(store: coordinator.replicaStore, scope: scope)
        let documentID = scope.documentID
        let contentCache = viewModel.contentCache
        let signedInUser = viewModel.signedInUser
        let listTitle = viewModel.title
        let scheduler = NativeReplicaSaveScheduler(
            interval: viewModel.autosaveInterval,
            enqueue: {
                // The native view never edits the title. Send the server copy on
                // disk (refreshed at each online open) as title and baseline, so
                // replay keeps a web rename and checks the body like classic.
                // A stored draft keeps its own baseline. `enqueueReplica`
                // refuses another account's scope. An unknown account (a login
                // handing over its cookies) is not a refusal: the journal is
                // durable and the reopen under the known owner hands it over.
                guard signedInUser.userID != nil else { return false }
                let cached = contentCache.content(for: documentID)
                try coordinator.enqueueReplica(
                    adapter: adapter, title: cached?.title ?? listTitle,
                    baseline: coordinator.storedDraft(documentID: documentID)?.baseline
                        ?? cached.map {
                            DraftBaseline(serverUpdatedAt: $0.serverUpdatedAt, markdown: $0.markdown, title: $0.title)
                        })
                return true
            },
            onFailure: { [weak session] error in
                session?.freezeAuthoring()
                coordinator.noteReplicaCaptureFailure(documentID: documentID, error: error)
            })
        session.enableTyping(
            persist: { command, update in
                try adapter.record(command, update: update)
                scheduler.schedule()
            }, scheduler: scheduler)
        // Edits an earlier process journaled but never handed over (it ended
        // inside the debounce) have no draft, so no replay pass knows them.
        if coordinator.pendingSave(documentID: documentID) == nil,
            (try? coordinator.replicaStore.manifest(for: scope))?.outbox.isEmpty == false
        {
            scheduler.schedule()
        }
    }

    /// Reconnect and open both merge the server's raw state into the same
    /// durable owner; a converted response is never installed over it.
    private func integrateServerState(
        into session: NativeEditorSession, scope: ReplicaScope, viewModel: EditorViewModel, request: Int,
        isOffline: Bool
    ) async {
        guard enabled, !isOffline, !viewModel.availability.showsOfflineStatus else { return }
        let isCurrent = { [weak self] in
            !Task.isCancelled && self?.generation == request && !session.isClosed
                && viewModel.signedInUser.userID == scope.ownerUserID
        }
        do {
            let config = try await viewModel.client.serverConfig()
            guard isCurrent(), config.usesCollaborationYDocServer, config.collaborationOrg == scope.org else { return }
            let state = try await viewModel.client.collaborationYDocState(
                documentID: scope.documentID, org: scope.org)
            guard isCurrent() else { return }
            try session.integrateServerState(state)
            // Refreshes the server title native saves send.
            guard isCurrent() else { return }
            _ = try await viewModel.refreshOfflineCacheForNativeReader(isCurrent: isCurrent)
        } catch {
            // Offline-first: the restored replica stays on screen. A disk
            // failure inside the integration has already frozen authoring.
        }
    }

    /// Typing also needs no live owner (a native session never takes the live
    /// write path), no pending create or delete and no classic draft.
    private func mayType(_ viewModel: EditorViewModel) -> Bool {
        let coordinator = viewModel.saveCoordinator
        let documentID = viewModel.documentID
        return !viewModel.isLocalDocument && !viewModel.isDocumentPendingDelete
            && !coordinator.isLiveHeld(documentID: documentID)
            && (coordinator.storedDraft(documentID: documentID).map { $0.replica != nil } ?? true)
    }

    private func canContinue(request: Int, viewModel: EditorViewModel, isOffline: Bool, account: UUID?) -> Bool {
        generation == request && viewModel.signedInUser.userID == account && canOpen(viewModel, isOffline: isOffline)
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

    /// Closing flushes a debounced save before the replica goes away.
    func close() {
        isOpen = false
        generation += 1
        reopenTask?.cancel()
        reopenTask = nil
        refreshTask?.cancel()
        refreshTask = nil
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
