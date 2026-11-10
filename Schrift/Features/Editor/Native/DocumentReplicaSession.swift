import Foundation

/// The sole owner of one native replica (PR08b): its `YDoc`, the
/// `DocumentEngine` over it, the shared `ReplicaHistory` and the journal
/// writes for its `ReplicaScope`. Nothing else touches the graph; surfaces
/// talk to it through `mailbox` (main → session, ordered and bounded) and
/// read `ReplicaDelivery` values from the stream `attach` returns. Only
/// `Sendable` values cross.
///
/// **One message, one synchronous turn.** The loop takes a message and
/// handles it to completion: the engine call, the journal append and the
/// delivery yield, with no await between them, so nothing can interleave
/// with a command half done.
///
/// **Journal before publication (redefined in PR08b).** Publication is the
/// canonical advance, save scheduling or a network send. A command's patch
/// reaches every surface only after its bytes are journaled, and the surface
/// schedules the save only on the `.applied` result. A predicted keystroke is
/// on screen before that, as provisional UI (like marked text); a failed or
/// refused append rolls it back.
///
/// **Rebase.** Each surface keeps the changes it had not seen when it sent a
/// command (`unseen`: every patch but its own predicted echoes, at most
/// `ringCapacity`). A predicted command is rebased through them with
/// `TextDelta.rebase`, and they through it, exactly as the surface rebases its
/// pending predictions, so both arrive at the same text. A command that cannot
/// be rebased invalidates the surface's epoch; a barrier is `.stale`.
actor DocumentReplicaSession {
    typealias Journal = @Sendable (NativeEditCommand, Data) throws -> Void

    /// Test seams, called on the session.
    struct Hooks: Sendable {
        /// Before each message: a test holds the mailbox with a latch.
        var beforeMessage: (@Sendable () -> Void)?
        /// Every unit of replica work (a message, an attach, a close): a test
        /// checks it never runs on the main thread.
        var onReplicaWork: (@Sendable () -> Void)?

        init(beforeMessage: (@Sendable () -> Void)? = nil, onReplicaWork: (@Sendable () -> Void)? = nil) {
            self.beforeMessage = beforeMessage
            self.onReplicaWork = onReplicaWork
        }
    }

    /// What a surface needs to start: the projection at `revision` and the
    /// stream of everything after it, made in one session turn.
    struct Attachment: Sendable {
        let blocks: [BlockSnapshot]
        let revision: UInt64
        let hasUnsupportedRoot: Bool
        let canType: Bool
        let recoveries: [ProvisionalRecovery]
        let state: ReplicaState
        let deliveries: AsyncStream<ReplicaDelivery>
    }

    /// Unseen changes a surface keeps for rebasing (the "remote ring").
    static let ringCapacity = 256

    nonisolated let mailbox = ReplicaCommandMailbox()
    private let doc: YDoc
    private let engine: DocumentEngine
    private let sink: ReplicaPatchSink
    private var history: ReplicaHistory?
    private let store: ReplicaStore?
    private let scope: ReplicaScope?
    private var journal: Journal?
    private let hooks: Hooks
    private let hasUnsupportedRoot: Bool
    private let canType: Bool
    private var surfaces: [UUID: SurfaceState] = [:]
    private var loop: Task<Void, Never>?
    private var isClosed = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    /// The surface whose predicted command is being applied: its echo is not
    /// an unseen change for it.
    private var predicting: (surfaceID: UUID, commandID: UUID)?

    private struct Unseen {
        let revision: UInt64
        var changes: [BlockChange]
    }

    private struct SurfaceState {
        let deliveries: AsyncStream<ReplicaDelivery>.Continuation
        var epoch: UInt64 = 0
        var selectionSeq: UInt64 = 0
        var unseen: [Unseen] = []
        /// Unseen entries up to this revision were dropped from the ring: a
        /// command older than it cannot be rebased.
        var droppedThrough: UInt64 = 0
    }

    /// `state` is a Yjs update; `updates` replay after it (a restored journal).
    /// `makeReplica` creates the graph (tests pass fixed client ids).
    private init(
        state: Data, updates: [Data], revision: UInt64, store: ReplicaStore?, scope: ReplicaScope?,
        freshClientID: Bool, makeReplica: @Sendable () -> YDoc, hooks: Hooks
    ) throws {
        let doc = makeReplica()
        do {
            try doc.applyUpdate(YUpdateDecoder.decode(state), origin: .remote)
            for update in updates { try doc.applyUpdate(YUpdateDecoder.decode(update), origin: .remote) }
            if !updates.isEmpty || freshClientID {
                guard doc.store.pendingStructs == nil, doc.store.pendingDs == nil else {
                    throw ReplicaStoreError.corrupt
                }
            }
            if freshClientID {
                // Retained structs keep their client ids; new authoring uses one
                // absent from the restored store.
                var fresh = UInt.random(in: 1...UInt(UInt32.max))
                while doc.store.clients[fresh] != nil { fresh = UInt.random(in: 1...UInt(UInt32.max)) }
                doc.clientID = fresh
            }
        } catch {
            doc.destroy()
            throw error
        }
        let projected = NativeBlockProjection.project(doc)
        hasUnsupportedRoot = projected.blocks.isEmpty && !projected.isFullyRenderable
        // Marks never make the native projection lossy (raw Yjs write-back
        // keeps them all); the Markdown shadow is the one `ReplicaSaveAdapter`
        // captures, which drops what Markdown cannot spell.
        canType = projected.isFullyModeled && NativeBlockProjection.markdownShadow(doc) != nil
        let sink = ReplicaPatchSink()
        let engine = DocumentEngine(doc: doc, surface: sink, revision: revision)
        sink.engine = engine
        if store != nil {
            // Every revision must be a journal entry: an unjournaled
            // transaction freezes the engine (it has no rollback); the next
            // delivery's state says so and the surface stops authoring.
            engine.onUnjournaledTransaction = {}
        }
        self.doc = doc
        self.sink = sink
        self.engine = engine
        self.store = store
        self.scope = scope
        self.hooks = hooks
    }

    /// An in-memory replica of `state` (no journal until `setWritable`).
    /// `clientID` fixes the author (tests compare bytes); nil picks one.
    static func seed(
        state: Data, revision: UInt64 = 0, clientID: UInt? = nil, gc: Bool = true, hooks: Hooks = Hooks()
    ) async throws -> DocumentReplicaSession {
        try DocumentReplicaSession(
            state: state, updates: [], revision: revision, store: nil, scope: nil, freshClientID: false,
            makeReplica: { YDoc(clientID: clientID ?? UInt.random(in: 1...UInt(UInt32.max)), gc: gc) }, hooks: hooks)
    }

    /// The durable replica of `scope`: checkpoint and journal replayed into a
    /// fresh, non-colliding author, off the main actor. Nil when there is no
    /// replica. With `editable`, typing journals through `ReplicaSaveAdapter`.
    static func restore(
        store: ReplicaStore, scope: ReplicaScope, editable: Bool = false, hooks: Hooks = Hooks()
    ) async throws -> DocumentReplicaSession? {
        guard let restored = try store.restore(for: scope) else { return nil }
        let session = try DocumentReplicaSession(
            state: restored.checkpoint, updates: restored.updates, revision: restored.manifest.revision,
            store: store, scope: scope, freshClientID: true,
            makeReplica: { YDoc(clientID: UInt.random(in: 1...UInt(UInt32.max))) }, hooks: hooks)
        if editable { session.mailbox.post(.setWritable(journal(store: store, scope: scope))) }
        return session
    }

    /// `ReplicaSaveAdapter.record`'s append: local incremental bytes only.
    static func journal(store: ReplicaStore, scope: ReplicaScope) -> Journal {
        { command, update in
            try store.append(
                update, for: scope, commandID: command.id, baseRevision: command.baseRevision, origin: .local)
        }
    }

    /// The read-only route's one-shot projection: no session outlives it.
    static func inspect(state: Data) throws -> (blocks: [BlockSnapshot], hasUnsupportedRoot: Bool, canType: Bool) {
        let doc = YDoc(clientID: 1, gc: true)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(state), origin: .remote)
        let projected = NativeBlockProjection.project(doc)
        return (
            projected.blocks.map(BlockSnapshot.init), projected.blocks.isEmpty && !projected.isFullyRenderable,
            projected.isFullyModeled && NativeBlockProjection.markdownShadow(doc) != nil
        )
    }

    /// The projection now and every delivery after it, in one turn.
    func attach(surfaceID: UUID) -> Attachment {
        hooks.onReplicaWork?()
        if loop == nil { loop = Task { await self.run() } }
        let (stream, continuation) = AsyncStream<ReplicaDelivery>.makeStream()
        // shortcut: deliveries are unbounded per surface; PR08c bounds them at 256 with a .reset resync.
        if isClosed {
            continuation.finish()
        } else {
            surfaces[surfaceID] = SurfaceState(deliveries: continuation)
        }
        let blocks = NativeBlockProjection.project(doc).blocks.map(BlockSnapshot.init)
        let recoveries = store.flatMap { store in scope.map { store.provisionalRecoveries(for: $0) } } ?? []
        return Attachment(
            blocks: blocks, revision: engine.revision, hasUnsupportedRoot: hasUnsupportedRoot, canType: canType,
            recoveries: recoveries, state: state, deliveries: stream)
    }

    /// Returns once the session closed (`.close` was handled).
    func waitUntilClosed() async {
        guard !isClosed else { return }
        await withCheckedContinuation { closeWaiters.append($0) }
    }

    // MARK: - The loop

    private func run() async {
        for await message in mailbox.stream {
            guard !isClosed else {
                message.cancel()
                continue
            }
            hooks.beforeMessage?()
            hooks.onReplicaWork?()
            handle(message)
        }
    }

    private var state: ReplicaState {
        ReplicaState(
            canUndo: history?.canUndo ?? false, canRedo: history?.canRedo ?? false, writable: journal != nil,
            frozen: engine.nativeWriteFailed, detached: engine.isDetached)
    }

    private func handle(_ message: ReplicaMessage) {
        switch message {
        case .command(let command):
            handle(command)
        case .select(let surfaceID, let seq, let base, let selection):
            guard surfaces[surfaceID] != nil else { return }
            surfaces[surfaceID]?.selectionSeq = seq
            let rebased = selection.flatMap { rebase($0, surfaceID: surfaceID, base: base) }
            if (try? engine.setSelection(rebased)) == nil { try? engine.setSelection(nil) }
        case .compositionBegin(let surfaceID, let base, let blockID, let range):
            // A begin that cannot be captured (a race with an unseen change)
            // leaves no composition: its commit comes back `.orphaned`.
            guard surfaces[surfaceID] != nil,
                let range = rebase(range, assoc: -1, blockID: blockID, surfaceID: surfaceID, base: base)
            else { return }
            try? engine.compositionBegan(blockID: blockID, replacing: range)
            deliver(to: surfaceID)
        case .compositionCommit(let surfaceID, let commandID, let text):
            commitComposition(surfaceID: surfaceID, commandID: commandID, text: text)
        case .compositionCancel(let surfaceID):
            if engine.isComposing { try? engine.compositionCancelled() }
            deliver(to: surfaceID, result: .composition(commandID: nil, .cancelled), selection: true)
        case .writeProvisional(let entries):
            // A convenience copy, never committed content: a failed write
            // must not block typing.
            if let store, let scope { try? store.writeProvisionalRecoveries(entries, for: scope) }
        case .integrate(let update, let reply):
            // Evaluated first: an optional call skips its arguments when nil.
            let result = Result { try integrate(update) }
            reply?(result)
        case .requestAvailability(let surfaceID, let blockID, let candidates):
            let actions = candidates.filter { candidate in
                guard let kind = candidate.kind else { return engine.hasLosslessCopy(blockID) }
                return engine.canApplyStructural(
                    NativeEditCommand(id: UUID(), baseRevision: engine.revision, blockID: blockID, kind: kind))
            }.map(\.action)
            var delivery = ReplicaDelivery(revision: engine.revision, state: state)
            delivery.availability = (blockID, engine.revision, actions)
            surfaces[surfaceID]?.deliveries.yield(delivery)
        case .copyPayload(let surfaceID, let requestID, let blockIDs):
            var delivery = ReplicaDelivery(revision: engine.revision, state: state)
            delivery.clipboard = (requestID, engine.subtreePayload(blockIDs))
            surfaces[surfaceID]?.deliveries.yield(delivery)
        case .setWritable(let journal):
            self.journal = journal
            if journal != nil, history == nil { history = ReplicaHistory(doc: doc, engine: engine) }
            deliver(to: nil)
        case .drain(let surfaceID, let token):
            var delivery = ReplicaDelivery(revision: engine.revision, state: state)
            delivery.drained = token
            surfaces[surfaceID]?.deliveries.yield(delivery)
        case .detach(let surfaceID):
            surfaces.removeValue(forKey: surfaceID)?.deliveries.finish()
        case .close:
            close()
        case .inspect(let body):
            body(engine, doc, history)
        }
    }

    private func handle(_ message: ReplicaCommand) {
        let id = message.command.id
        guard var surface = surfaces[message.surfaceID] else { return }
        guard message.epoch == surface.epoch else {
            // The surface already dropped its predictions of the old epoch; a
            // barrier gets an answer so it can retry.
            if !message.predicted { deliver(to: message.surfaceID, result: .stale(commandID: id)) }
            return
        }
        guard journal != nil else {
            deliver(to: message.surfaceID, result: .refused(commandID: id, nil))
            return
        }
        surface.unseen.removeAll { $0.revision <= message.command.baseRevision }
        var command = message.command
        let unseen = surface.droppedThrough > command.baseRevision || !surface.unseen.isEmpty
        if unseen {
            guard message.predicted, surface.droppedThrough <= command.baseRevision,
                case .replace(let range, let text, let marks) = command.kind,
                let rebased = rebase(range, text: text, blockID: command.blockID, unseen: &surface.unseen)
            else {
                surfaces[message.surfaceID] = surface
                if message.predicted {
                    invalidate(message.surfaceID, commandID: id)
                } else {
                    deliver(to: message.surfaceID, result: .stale(commandID: id))
                }
                return
            }
            command = NativeEditCommand(
                id: id, baseRevision: command.baseRevision, blockID: command.blockID,
                kind: .replace(range: rebased, replacement: text, marks: marks))
        }
        surfaces[message.surfaceID] = surface
        // Stamped with the engine's own revision: only this surface's commands
        // (already in its display) or rebased changes came between.
        command = NativeEditCommand(id: id, baseRevision: engine.revision, blockID: command.blockID, kind: command.kind)
        if message.undoBefore { history?.stopCapturing() }
        defer { if message.undoAfter { history?.stopCapturing() } }
        let started = ContinuousClock.now
        var journalTime = Duration.zero
        let journal = self.journal
        let persist: (Data) throws -> Void = { update in
            let start = ContinuousClock.now
            defer { journalTime = ContinuousClock.now - start }
            try journal?(command, update)
        }
        if message.predicted { predicting = (message.surfaceID, id) }
        defer { predicting = nil }
        let result: ReplicaResult
        do {
            switch command.kind {
            case .replace:
                try engine.replaceText(command, persist: persist)
                result = .applied(commandID: id, caret: nil, journaled: true)
            case .undo, .redo:
                let undo = command.kind == .undo
                let history = self.history
                let changed = try engine.applyHistoryStep(
                    command, step: { try history?.step(undo: undo) ?? false }, persist: persist)
                result = .applied(commandID: id, caret: nil, journaled: changed)
            default:
                let caret = try engine.applyStructural(command, persist: persist)
                result = .applied(commandID: id, caret: caret, journaled: true)
            }
        } catch {
            if engine.nativeWriteFailed {
                deliver(to: message.surfaceID, result: .failed(commandID: id), selection: true)
            } else if message.predicted {
                invalidate(message.surfaceID, commandID: id)
            } else {
                deliver(to: message.surfaceID, result: .refused(commandID: id, error as? DocumentEngineError))
            }
            return
        }
        let history = command.kind == .undo || command.kind == .redo
        deliver(
            to: message.surfaceID, result: result, selection: history,
            timings: ReplicaTimings(engine: ContinuousClock.now - started, journal: journalTime))
    }

    private func commitComposition(surfaceID: UUID, commandID: UUID, text: String) {
        guard engine.isComposing else {
            // The begin never captured its target: nothing is written.
            deliver(to: surfaceID, result: .composition(commandID: commandID, .orphaned), selection: true)
            return
        }
        // A composition commit is one undo step.
        history?.stopCapturing()
        defer { history?.stopCapturing() }
        let journal = self.journal
        let outcome: ReplicaResult.CompositionResult
        do {
            switch try engine.compositionCommitted(
                text: text, commandID: commandID, persist: { try journal?($0, $1) })
            {
            case .committed: outcome = .committed
            case .orphaned: outcome = .orphaned
            }
        } catch {
            // A boundary refusal leaves the engine composing; end it so the
            // surface unfreezes. A failed append keeps the entry on disk.
            if engine.isComposing { try? engine.compositionCancelled() }
            outcome = .failed
        }
        deliver(to: surfaceID, result: .composition(commandID: commandID, outcome), selection: true)
    }

    private func integrate(_ state: Data) throws {
        let update = state.isEmpty ? Data([0, 0]) : state
        let decoded = try YUpdateDecoder.decode(update)
        let doc = self.doc
        defer { deliver(to: nil) }
        try engine.durablyIntegrateRemote(
            update: update,
            apply: {
                try doc.applyUpdate(decoded, origin: .remote)
                guard doc.store.pendingStructs == nil, doc.store.pendingDs == nil else {
                    throw ReplicaStoreError.corrupt
                }
            },
            persist: { [store, scope] revision in
                guard let store, let scope else { return }
                try store.append(update, for: scope, commandID: UUID(), baseRevision: revision, origin: .remote)
            })
    }

    private func invalidate(_ surfaceID: UUID, commandID: UUID) {
        guard var surface = surfaces[surfaceID] else { return }
        surface.epoch += 1
        surface.unseen = []
        surface.droppedThrough = engine.revision
        surfaces[surfaceID] = surface
        deliver(to: surfaceID, result: .invalidated(epoch: surface.epoch, commandID: commandID), selection: true)
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        hooks.onReplicaWork?()
        _ = sink.take()
        // Undo history is session-local: it goes with the session.
        history?.destroy()
        history = nil
        doc.destroy()
        for surface in surfaces.values { surface.deliveries.finish() }
        surfaces = [:]
        mailbox.finish()
        for waiter in closeWaiters { waiter.resume() }
        closeWaiters = []
    }

    // MARK: - Delivery

    /// Everything the engine delivered since the last call goes to every
    /// surface (in this PR, one), the result only to `surfaceID`. Changes that
    /// are not a surface's own predicted echo join its unseen ring.
    private func deliver(
        to surfaceID: UUID?, result: ReplicaResult? = nil, selection: Bool = false, timings: ReplicaTimings? = nil
    ) {
        var events = sink.take()
        let changed = events.contains { if case .patch = $0 { true } else { false } }
        for index in events.indices {
            guard case .patch(var patch, let settled) = events[index], var stamp = patch.nativeCommand else { continue }
            stamp.surfaceID = predicting?.commandID == stamp.commandID ? predicting?.surfaceID : surfaceID
            patch.nativeCommand = stamp
            events[index] = .patch(patch, settled: settled)
        }
        for id in surfaces.keys {
            let own = id == surfaceID
            var surface = surfaces[id]!
            for event in events {
                guard case .patch(let patch, _) = event, !patch.isEmpty else { continue }
                if let stamp = patch.nativeCommand, stamp.surfaceID == id, predicting?.commandID == stamp.commandID {
                    continue
                }
                surface.unseen.append(Unseen(revision: engine.revision, changes: patch.changes))
            }
            if surface.unseen.count > Self.ringCapacity {
                let overflow = surface.unseen.count - Self.ringCapacity
                surface.droppedThrough = max(surface.droppedThrough, surface.unseen[overflow - 1].revision)
                surface.unseen.removeFirst(overflow)
            }
            surfaces[id] = surface
            var delivery = ReplicaDelivery(revision: engine.revision, events: events, state: state)
            if own {
                delivery.result = result
                delivery.timings = timings
            }
            if own ? (selection || changed) : changed {
                // `try?` flattens: nil when there is no selection (or detached).
                let endpoints = try? engine.currentSelectionEndpoints()
                delivery.selection = ReplicaSelection(
                    seq: surface.selectionSeq, anchor: endpoints?.anchor, head: endpoints?.head,
                    tracked: endpoints != nil)
            }
            surface.deliveries.yield(delivery)
        }
    }

    // MARK: - Rebase

    /// A predicted replacement of `range` by `text` in `blockID`, rebased
    /// through every unseen change (each rebased through it in turn, for the
    /// next command). Nil when any step cannot be mapped.
    private func rebase(_ range: Range<Int>, text: String, blockID: String, unseen: inout [Unseen]) -> Range<Int>? {
        var range = range
        for index in unseen.indices {
            // Own after concurrent: an insertion at the same point lands first.
            guard
                let mapped = TextDelta.rebase(range: range, assoc: 1, through: unseen[index].changes, blockID: blockID)
            else { return nil }
            var changes = unseen[index].changes
            for (position, change) in changes.enumerated() {
                guard case .text(let id, let deltas) = change, id == blockID else { continue }
                guard let next = TextDelta.rebase(deltas, throughReplacing: range, length: text.utf16.count) else {
                    return nil
                }
                changes[position] = .text(blockID: id, deltas: next)
            }
            unseen[index].changes = changes
            range = mapped
        }
        return range
    }

    /// A position range (a composition anchor) through the surface's unseen
    /// changes after `base`, without changing them.
    private func rebase(
        _ range: Range<Int>, assoc: Int, blockID: String, surfaceID: UUID, base: UInt64
    ) -> Range<Int>? {
        guard let surface = surfaces[surfaceID], surface.droppedThrough <= base else { return nil }
        var range = range
        for entry in surface.unseen where entry.revision > base {
            guard let mapped = TextDelta.rebase(range: range, assoc: assoc, through: entry.changes, blockID: blockID)
            else { return nil }
            range = mapped
        }
        return range
    }

    private func rebase(_ selection: EditorSelection, surfaceID: UUID, base: UInt64) -> EditorSelection? {
        func map(_ position: EditorPosition) -> EditorPosition? {
            rebase(
                position.offset..<position.offset, assoc: position.assoc, blockID: position.blockID,
                surfaceID: surfaceID, base: base
            ).map { EditorPosition(blockID: position.blockID, offset: $0.lowerBound, assoc: position.assoc) }
        }
        guard let anchor = map(selection.anchor), let head = map(selection.head) else { return nil }
        return EditorSelection(anchor: anchor, head: head)
    }

    isolated deinit {
        if !isClosed {
            history?.destroy()
            doc.destroy()
        }
    }
}

/// The engine's surface inside the session: it only collects what the engine
/// delivers, with each `.text`/`.props` block's settled projection taken at
/// delivery time (what a main-actor surface used to ask the engine for).
private final class ReplicaPatchSink: EditorSurface {
    weak var engine: DocumentEngine?
    private var events: [ReplicaDelivery.Event] = []

    func applyPatch(_ patch: BlockPatch) {
        var settled: [String: BlockSnapshot] = [:]
        for change in patch.changes {
            switch change {
            case .text(let id, _), .props(let id, _):
                if let snapshot = engine?.nativeSnapshot(for: id) { settled[id] = snapshot }
            default: break
            }
        }
        events.append(.patch(patch, settled: settled))
    }

    func setCompositionDeferred(_ deferred: Bool) {
        events.append(.compositionDeferred(deferred))
    }

    func take() -> [ReplicaDelivery.Event] {
        defer { events = [] }
        return events
    }
}
