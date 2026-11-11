import Foundation
import Observation

/// The view session (PR08b): one surface over a `DocumentReplicaSession`,
/// which solely owns the replica. This side holds no `YDoc` or engine: it
/// shows the attach snapshot, applies the session's deliveries in order and
/// posts input through the session's mailbox. A read-only reader made by
/// `inspect` has no replica session at all. One replica session may have
/// several of these surfaces, leased from `NativeSessionRegistry` (PR08c).
@MainActor @Observable
final class NativeEditorSession {
    @ObservationIgnored let replica: DocumentReplicaSession?
    /// The id the replica session knows this surface by.
    let surfaceID: UUID
    let textView: NativeTextView
    let surface: NativeTextSurface
    /// Outline, find and reading position over this surface (PR10b).
    @ObservationIgnored let navigation: NativeDocumentNavigation
    let hasUnsupportedRoot: Bool
    /// Only a fully modeled document with a total Markdown shadow may be
    /// authored: anything else would be written back lossily. Opaque/rich
    /// documents stay in PR01's read-only view until the total shadow exists.
    let canType: Bool
    private(set) var input: NativeInputCoordinator?
    private(set) var scope: ReplicaScope?
    private var hasRecoveryStore = false
    private var saveScheduler: NativeReplicaSaveScheduler?
    private(set) var isClosed = false
    /// The revision the display shows (the last delivery's).
    private(set) var revision: UInt64
    /// Mirrored from deliveries.
    private(set) var state: ReplicaState
    private var recoveries: [ProvisionalRecovery]
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var drains: [UUID: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var closing: Task<Void, Never>?
    /// The scope's collaborators (PR10), set when it goes live: the presence
    /// bar and the cursor overlay read it.
    private(set) var awareness: NativeAwarenessController?
    /// Set by `NativeSessionRegistry` for a leased surface: closing detaches
    /// it, and the registry closes the replica after its last surface.
    @ObservationIgnored var release: (() -> Task<Void, Never>)?

    private init(
        replica: DocumentReplicaSession?, surfaceID: UUID = UUID(), blocks: [BlockSnapshot], revision: UInt64,
        hasUnsupportedRoot: Bool,
        canType: Bool, recoveries: [ProvisionalRecovery], state: ReplicaState
    ) {
        self.replica = replica
        self.surfaceID = surfaceID
        let view = NativeTextView()
        let surface = NativeTextSurface(blocks: blocks, storage: view.textStorage, traits: view.traitCollection)
        // Folding is the surface's view state; the view lays out around it.
        view.blockControls.surface = surface
        surface.onFoldChange = { [weak view] in view?.blockControls.foldDidChange() }
        // Toggles open collapsed: lay out without their children from the start.
        if surface.hidden.contains(true) { view.blockControls.foldDidChange() }
        self.textView = view
        self.surface = surface
        let navigation = NativeDocumentNavigation(replica: replica, surface: surface, textView: view)
        self.navigation = navigation
        view.onLayout = { [weak navigation] in navigation?.layoutPassed() }
        self.hasUnsupportedRoot = hasUnsupportedRoot
        self.canType = canType
        self.revision = revision
        self.recoveries = recoveries
        self.state = state
        surface.surfaceID = surfaceID
    }

    /// The read-only route (PR01): a one-shot projection, no replica session.
    static func inspect(state: Data) async throws -> NativeEditorSession {
        let inspected = try await Task.detached { try DocumentReplicaSession.inspect(state: state) }.value
        return NativeEditorSession(
            replica: nil, blocks: inspected.blocks, revision: 0, hasUnsupportedRoot: inspected.hasUnsupportedRoot,
            canType: inspected.canType, recoveries: [], state: ReplicaState())
    }

    /// An in-memory replica session over `state` (the isolated host and
    /// component tests); `enableTyping` gives it a journal.
    /// `clientID` fixes the author (tests compare bytes); nil picks one.
    static func seed(
        state: Data, clientID: UInt? = nil, gc: Bool = true, hooks: DocumentReplicaSession.Hooks = .init()
    ) async throws -> NativeEditorSession {
        await attach(try await DocumentReplicaSession.seed(state: state, clientID: clientID, gc: gc, hooks: hooks))
    }

    /// Offline restoration never rebuilds rich state from a Markdown shadow:
    /// the session replays checkpoint and journal off the main actor. No live
    /// manager or socket is attached.
    static func restore(
        store: ReplicaStore, scope: ReplicaScope, editable: Bool = false,
        hooks: DocumentReplicaSession.Hooks = .init()
    ) async throws -> NativeEditorSession? {
        guard let replica = try await DocumentReplicaSession.restore(store: store, scope: scope, hooks: hooks) else {
            return nil
        }
        let session = await attach(replica, scope: scope)
        if editable { session.enableTyping(persist: DocumentReplicaSession.journal(store: store, scope: scope)) }
        return session
    }

    /// A new surface on `replica`; `scope` names its durable store.
    static func attach(_ replica: DocumentReplicaSession, scope: ReplicaScope? = nil) async -> NativeEditorSession {
        let surfaceID = UUID()
        let attachment = await replica.attach(surfaceID: surfaceID)
        let session = NativeEditorSession(
            replica: replica, surfaceID: surfaceID, blocks: attachment.blocks, revision: attachment.revision,
            hasUnsupportedRoot: attachment.hasUnsupportedRoot, canType: attachment.canType,
            recoveries: attachment.recoveries, state: attachment.state)
        session.scope = scope
        session.hasRecoveryStore = scope != nil
        session.consume(attachment.deliveries)
        return session
    }

    /// The delivery consumer: every delivery, in order, on the main actor.
    private func consume(_ deliveries: AsyncStream<ReplicaDelivery>) {
        consumer = Task { [weak self] in
            for await delivery in deliveries {
                guard let self else { return }
                self.apply(delivery)
            }
            self?.didFinishDeliveries()
        }
    }

    /// Paints `awareness`'s peers over this surface (PR10).
    func showAwareness(_ awareness: NativeAwarenessController) {
        self.awareness = awareness
        textView.cursorOverlay.surface = surface
        awareness.addView(textView)
    }

    /// Tests: sees every delivery before it is applied.
    @ObservationIgnored var onDelivery: ((ReplicaDelivery) -> Void)?

    private func apply(_ delivery: ReplicaDelivery) {
        onDelivery?(delivery)
        if delivery.resync == .requested {
            // The bound was reached: ask for the reset (PR08c).
            if let input { input.requestResync() } else { replica?.mailbox.post(.resync(surfaceID: surfaceID)) }
            return
        }
        let wasWritable = state.writable
        state = delivery.state
        if let input {
            input.apply(delivery)
            // The replica turned read-only (a reader answer): the view stops
            // taking input, so nothing typed looks accepted.
            if wasWritable, !state.writable { textView.isEditable = false }
        } else {
            for event in delivery.events {
                switch event {
                case .patch(let patch, let settled): surface.applyPatch(patch, settled: settled)
                case .compositionDeferred: break
                }
            }
        }
        revision = delivery.revision
        if delivery.events.contains(where: { if case .patch = $0 { true } else { false } }) {
            awareness?.documentChanged()
            navigation.documentChanged()
        }
        if let token = delivery.drained { drains.removeValue(forKey: token)?.resume() }
    }

    /// The session closed: everything posted before the close was journaled
    /// and delivered, so a save scheduled by a late append is handed over now.
    private func didFinishDeliveries() {
        for drain in drains.values { drain.resume() }
        drains = [:]
        input?.detach()
        input = nil
        saveScheduler?.flush()
        // A leased surface's scheduler is shared with the scope's other surfaces.
        if release == nil { saveScheduler?.cancel() }
        saveScheduler = nil
    }

    /// `persist` is the journal the session appends every local command to
    /// (nil when the registry installed it for the replica already);
    /// `scheduler` is retained so a debounced save outlives the keystroke that
    /// armed it, and is called only once a command is journaled. The
    /// production open route additionally requires `canType`; the isolated
    /// host and component tests type around preserved blocks, which input
    /// refuses.
    func enableTyping(
        persist: DocumentReplicaSession.Journal?, scheduler: NativeReplicaSaveScheduler? = nil
    ) {
        guard let replica, !isClosed, !hasUnsupportedRoot, input == nil else { return }
        saveScheduler = scheduler
        if let persist { replica.mailbox.post(.setWritable(persist)) }
        let input = NativeInputCoordinator(
            replica: replica, surfaceID: surfaceID, revision: revision, surface: surface, view: textView,
            recoveries: recoveries, hasRecoveryStore: hasRecoveryStore)
        input.onJournaled = { [weak scheduler] in scheduler?.schedule() }
        self.input = input
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

    /// Reconnect fetches merge into the same owner. The session journals the
    /// new server bytes before any resulting patch is delivered.
    func integrateServerState(_ state: Data) async throws {
        guard let replica, !isClosed else { throw ReplicaSaveError.invalidScope }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
            replica.mailbox.post(.integrate(state, reply: { done.resume(with: $0) }))
        }
        // Its delivery precedes nothing else this caller awaits on.
        await settle()
    }

    /// Returns once every message posted before it was handled and its
    /// delivery applied, including keys held behind a barrier. False when work
    /// was still in flight after `maxRounds` drains (tests fail on it).
    @discardableResult
    func settle(maxRounds: Int = 64) async -> Bool {
        for _ in 0..<maxRounds {
            await drainOnce()
            guard input?.hasInFlightWork == true else { return true }
        }
        return input?.hasInFlightWork != true
    }

    private func drainOnce() async {
        guard let replica, !isClosed else { return }
        let token = UUID()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            drains[token] = done
            if !replica.mailbox.post(.drain(surfaceID: surfaceID, token: token)) {
                drains.removeValue(forKey: token)?.resume()
            }
        }
    }

    /// Ends the session: any debounced save is handed to the coordinator (the
    /// scheduler reads the durable store, not the graph), the view stops
    /// editing, and the replica session closes after every message already
    /// posted (a leased surface detaches; the registry closes the replica
    /// after its last surface). The returned task completes once it has.
    @discardableResult
    func close() -> Task<Void, Never> {
        if let closing { return closing }
        isClosed = true
        // What is journaled already is handed over now; appends still queued
        // schedule their save as their results arrive, flushed when the
        // deliveries end (`didFinishDeliveries`).
        saveScheduler?.flush()
        textView.isEditable = false
        textView.delegate = nil
        textView.inputCoordinator = nil
        guard let replica else {
            input?.detach()
            input = nil
            closing = Task {}
            return closing!
        }
        let closed: Task<Void, Never>
        if let release {
            replica.mailbox.post(.detach(surfaceID: surfaceID))
            closed = release()
        } else {
            replica.mailbox.post(.close)
            closed = Task { await replica.waitUntilClosed() }
        }
        let task = Task { [consumer] in
            await closed.value
            await consumer?.value
        }
        closing = task
        return task
    }

    isolated deinit {
        guard !isClosed, let replica else { return }
        if release != nil {
            replica.mailbox.post(.detach(surfaceID: surfaceID))
        } else {
            replica.mailbox.post(.close)
        }
    }
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
    /// The Live collaboration preference, one input of the native live gate (PR09a).
    private let livePreference: @MainActor () -> Bool
    /// The open's `abilities.update`, another input of that gate.
    private var canUpdate = false
    /// Bumped by every open and close (including the close a sign-in change
    /// forces), so an awaited fetch, restore or save result is dropped once
    /// the open that asked for it is gone.
    private var generation = 0
    private enum OpenResult: Sendable {
        case classic
        /// `isReader`: the server answered `abilities.update` false.
        case state(Data, config: ServerConfig, isReader: Bool)
    }
    private var pendingOpen: AsyncStream<OpenResult>.Continuation?
    /// The reopen and reconnect work `EditorView` starts outside its `.task`;
    /// close cancels both.
    private var reopenTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    /// The last native session's close: the next open waits for it (the
    /// registry also serializes each scope's replica lifecycle, PR08c).
    private var closing: Task<Void, Never>?
    private let waitForTimeout: @MainActor () async throws -> Void
    /// Tests: the replica sessions this route restores run these hooks.
    private let replicaHooks: DocumentReplicaSession.Hooks
    /// Where replicas are opened (PR08c): `EditorView` hands in the app's
    /// shared one before opening; tests keep this private one.
    @ObservationIgnored var registry = NativeSessionRegistry()
    /// Dials the native live socket (PR09a); `EditorView` hands in the app's
    /// manager. Without one (tests, previews) no socket is opened.
    @ObservationIgnored var collaboration: DocumentCollaborationManager?

    init(
        preference: @escaping @MainActor () -> Bool = { NativeEditorPreference.isEnabled() },
        livePreference: @escaping @MainActor () -> Bool = { LiveCollaborationPreference.isEnabled() },
        waitForTimeout: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(3)) },
        replicaHooks: DocumentReplicaSession.Hooks = .init()
    ) {
        self.preference = preference
        self.livePreference = livePreference
        self.replicaHooks = replicaHooks
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
        self.canUpdate = false
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
        if let closing {
            await closing.value
            guard generation == request, !Task.isCancelled else { return }
        }
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
                restored = try await registry.open(store: coordinator.replicaStore, scope: scope, hooks: replicaHooks)
            } catch {
                guard generation == request else { return }
                route = .preservedUnavailable
                return
            }
            // The restore ran off the main actor: drop it if this open is gone
            // or the account changed meanwhile.
            guard !Task.isCancelled, generation == request, viewModel.signedInUser.userID == account else {
                restored?.close()
                return
            }
            if let session = restored {
                // The "turn the switch on" explanation is only true while it is off.
                isPreservedReadOnly = !enabled
                if enabled, canUpdate, session.canType, mayType(viewModel) {
                    // Typing starts from the row at once; an online open's
                    // integration asks the server and downgrades a reader.
                    self.canUpdate = true
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
                // Asked beside the state, inside the same deadline.
                async let isReader = Self.serverSaysReader(viewModel, asking: canUpdate)
                let state = try await viewModel.client.collaborationYDocState(
                    documentID: viewModel.documentID, org: config.collaborationOrg)
                let reader = await isReader
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
                continuation.yield(.state(state, config: config, isReader: reader))
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
            case .state(let state, let config, let isReader) = result
        else {
            route = .classic
            return
        }
        let session: NativeEditorSession
        do { session = try await NativeEditorSession.inspect(state: state) } catch {
            guard generation == request else { return }
            route = .classic
            return
        }
        guard !Task.isCancelled, generation == request,
            canContinue(request: request, viewModel: viewModel, isOffline: isOffline, account: account)
        else { return }
        // A document that is not fully projectable, or a reader, stays in PR01's
        // in-memory read-only view and never gains a replica or marker.
        let verified = canUpdate && !isReader
        self.canUpdate = verified
        guard enabled, verified, session.canType, let account, mayType(viewModel) else {
            route = .native(session)
            return
        }
        session.close()
        let scope = ReplicaScope(
            serverOrigin: viewModel.client.serverOrigin, ownerUserID: account, org: config.collaborationOrg,
            documentID: viewModel.documentID)
        let seeded = await seedReplica(
            state: state, scope: scope, viewModel: viewModel, request: request, account: account)
        guard let seeded else { return }
        route = seeded
        if case .native(let session) = seeded { startLive(session, scope: scope, config: config, viewModel: viewModel) }
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
    /// Nil when the open went away during the restore.
    private func seedReplica(
        state: Data, scope: ReplicaScope, viewModel: EditorViewModel, request: Int, account: UUID
    ) async -> Route? {
        let coordinator = viewModel.saveCoordinator
        do {
            _ = try coordinator.replicaStore.create(for: scope, checkpoint: state)
            let restored = try await registry.open(store: coordinator.replicaStore, scope: scope, hooks: replicaHooks)
            guard !Task.isCancelled, generation == request, viewModel.signedInUser.userID == account else {
                restored?.close()
                return nil
            }
            guard let session = restored else { return .preservedUnavailable }
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
    /// coordinator's replica path, at the classic autosave cadence. The
    /// scope's journal and scheduler are shared by its surfaces (PR08c).
    private func installTyping(_ session: NativeEditorSession, scope: ReplicaScope, viewModel: EditorViewModel) {
        let coordinator = viewModel.saveCoordinator
        let adapter = ReplicaSaveAdapter(store: coordinator.replicaStore, scope: scope)
        let documentID = scope.documentID
        let contentCache = viewModel.contentCache
        let signedInUser = viewModel.signedInUser
        let listTitle = viewModel.title
        let registry = self.registry
        let scheduler = registry.scheduler(for: scope) {
            NativeReplicaSaveScheduler(
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
                                DraftBaseline(
                                    serverUpdatedAt: $0.serverUpdatedAt, markdown: $0.markdown, title: $0.title)
                            })
                    return true
                },
                onFailure: { [weak registry] error in
                    for surface in registry?.surfaces(of: scope) ?? [] { surface.freezeAuthoring() }
                    coordinator.noteReplicaCaptureFailure(documentID: documentID, error: error)
                })
        }
        // The append runs on the replica session; the save is scheduled only on
        // the journaled result, and the live socket gets the bytes only after
        // the append succeeded (journal before publication).
        let outbox = registry.liveBinding(for: scope)?.outbox
        registry.setWritable(
            { command, update in
                try adapter.record(command, update: update)
                outbox?.publish(update)
            }, for: scope)
        session.enableTyping(persist: nil, scheduler: scheduler)
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
            try await session.integrateServerState(state)
            guard isCurrent() else { return }
            if canUpdate, await Self.serverSaysReader(viewModel, asking: true) {
                guard isCurrent() else { return }
                // The row was stale: every surface of the scope stops writing
                // (a key typed meanwhile becomes a recovery entry) and no socket opens.
                becomeReader(scope)
            }
            startLive(session, scope: scope, config: config, viewModel: viewModel)
            // Refreshes the server title native saves send.
            _ = try await viewModel.refreshOfflineCacheForNativeReader(isCurrent: isCurrent)
        } catch {
            // Offline-first: the restored replica stays on screen. A disk
            // failure inside the integration has already frozen authoring.
        }
    }

    /// Whether the server says this account may only read the document. The
    /// navigation row can be stale (an account switch reuses the screen; a
    /// cached row predates a permission change), so online opens ask. Only an
    /// explicit `update: false` answer counts: a failed request (offline, a
    /// 5xx, a timeout, a captive portal) keeps the row, and the server still
    /// refuses a real reader's save. A row that says reader is never asked.
    private static func serverSaysReader(_ viewModel: EditorViewModel, asking: Bool) async -> Bool {
        guard asking, let document = try? await viewModel.client.document(documentID: viewModel.documentID)
        else { return false }
        return !document.abilities.update
    }

    /// Joins the scope's live room when the native live gate holds, unless its
    /// socket is up already. Only a typing session goes live: a reader never
    /// opens a socket. A socket that ended is dialed again on the next
    /// reconnect refresh; backoff and background handling are PR09b.
    private func startLive(
        _ session: NativeEditorSession, scope: ReplicaScope, config: ServerConfig, viewModel: EditorViewModel
    ) {
        guard session.input != nil, !session.isClosed,
            nativeLiveCollaborationEligible(
                nativeEnabled: enabled, liveEnabled: livePreference(),
                serverSupports: config.supportsNativeLiveCollaboration && config.collaborationOrg == scope.org,
                canUpdate: canUpdate),
            let binding = registry.liveBinding(for: scope), let collaboration
        else { return }
        let signedInUser = viewModel.signedInUser
        // Background, foreground and the path's return reach the socket too.
        collaboration.addLifecycleObserver(binding)
        binding.connect(
            dial: { [weak collaboration] in collaboration?.nativeTransport(for: scope.documentID, config: config) },
            wireProtocol: CollaborationWireProtocol(config: config),
            documentName: scope.documentID.uuidString.lowercased(),
            // A cookie handover forgets the signed-in user before /users/me
            // confirms the next one: nothing is dialed or sent for the scope then.
            isCurrent: { [weak session] in
                session.map { !$0.isClosed } == true && signedInUser.userID == scope.ownerUserID
            },
            // A 1000 close is the server's permission reset: ask again.
            isReader: { [weak viewModel] in
                guard let viewModel else { return false }
                return await Self.serverSaysReader(viewModel, asking: true)
            },
            becameReader: { [weak self] in self?.becomeReader(scope) },
            localState: { [weak collaboration] in collaboration?.localAwarenessState })
        session.showAwareness(binding.awareness)
    }

    /// The server says this account may only read now: every surface of the
    /// scope stops writing (a key typed meanwhile becomes a recovery entry,
    /// what is journaled stays for HTTP) and no socket stays open.
    private func becomeReader(_ scope: ReplicaScope) {
        canUpdate = false
        registry.setWritable(nil, for: scope)
        registry.liveBinding(for: scope, create: false)?.disconnect()
    }

    /// The Live collaboration preference changed while open (PR09b): off
    /// closes the socket and leaves HTTP saving; on joins again through the
    /// reconnect refresh, which rechecks the whole gate.
    func liveSettingChanged(viewModel: EditorViewModel, isOffline: Bool) {
        guard isOpen, case .native(let session) = route, let scope = session.scope else { return }
        if livePreference() {
            refreshInBackground(viewModel: viewModel, isOffline: isOffline)
        } else {
            registry.liveBinding(for: scope, create: false)?.disconnect()
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
            closing = session.close()
            route = .loading
        case .preservedUnavailable:
            route = .loading
        case .loading, .classic:
            break
        }
    }
}
