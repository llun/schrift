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
///
/// **Fan-out (PR08c).** Every attached surface gets every change; a result
/// goes only to the surface whose command it answers. The one engine
/// selection belongs to the surface that set it last (a select or a command)
/// and only its deliveries carry it; the one engine composition belongs to the
/// surface whose begin was captured, and another surface's begin is not.
///
/// **Bounded delivery (PR08c).** A surface with `deliveryBound` deliveries
/// waiting gets a resync marker; until it asks (`.resync`), its deliveries are
/// held without their patches, and then they come followed by one `.reset`
/// from the canonical state, under a new epoch.
actor DocumentReplicaSession {
    typealias Journal = @Sendable (NativeEditCommand, Data) throws -> Void

    /// Test seams, called on the session.
    struct Hooks: Sendable {
        /// Before each message: a test holds the mailbox with a gate that
        /// suspends, so the hold never parks a cooperative-pool thread.
        var beforeMessage: (@Sendable () async -> Void)?
        /// Every unit of replica work (a message, an attach, a close): a test
        /// checks it never runs on the main thread.
        var onReplicaWork: (@Sendable () -> Void)?

        init(beforeMessage: (@Sendable () async -> Void)? = nil, onReplicaWork: (@Sendable () -> Void)? = nil) {
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
        /// A table surface's grid when it attached (PR11a); nil otherwise.
        var grid: TableGrid? = nil
        /// A column surface's group when it attached (PR12a); nil otherwise.
        var columnGroup: ColumnGroup? = nil
    }

    /// Unseen changes a surface keeps for rebasing (the "remote ring").
    static let ringCapacity = 256
    /// Deliveries a surface may have waiting before the rest is a resync.
    static let deliveryBound = 256

    nonisolated let mailbox = ReplicaCommandMailbox()
    /// Replaced only when a remote update fails to integrate: the graph is
    /// rebuilt from the journal (`recoverFromRemoteFault`).
    private var doc: YDoc
    private var engine: DocumentEngine
    private var sink: ReplicaPatchSink
    /// Remote entries journaled since the last compaction (PR09a).
    private var remoteAppends = 0
    private var history: ReplicaHistory?
    private let store: ReplicaStore?
    private let scope: ReplicaScope?
    private let interlinkingOrigin: String?
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
    /// The surface that set the engine's selection last: only its deliveries
    /// carry it (another surface's view follows its own shown deltas).
    private var selectionOwner: UUID?
    /// Awareness (PR10): hears the selection's relative positions when they change.
    private var cursorSink: (@Sendable (AwarenessCursor?) -> Void)?
    private var reportedCursor: AwarenessCursor?

    private struct Unseen {
        let revision: UInt64
        var changes: [BlockChange]
    }

    private struct SurfaceState {
        let deliveries: AsyncStream<ReplicaDelivery>.Continuation
        /// A table surface's table (PR11a): it sees that table's paragraphs
        /// and nothing else. Nil for a document surface, which never sees a
        /// table paragraph.
        var table: String?
        /// A column surface's column and its group (PR12a): it sees that
        /// column's blocks and the group's own changes, nothing else. Nil for
        /// a document surface, which never sees a column's blocks.
        var column: (group: String, id: String)?
        var epoch: UInt64 = 0
        var selectionSeq: UInt64 = 0
        var unseen: [Unseen] = []
        /// Unseen entries up to this revision were dropped from the ring: a
        /// command older than it cannot be rebased.
        var droppedThrough: UInt64 = 0
        /// The composition begun on this surface, as posted: its commit is
        /// rebased through the unseen ring like a predicted replace.
        var composing: (blockID: String, range: Range<Int>, base: UInt64)?
        /// Non-nil once the bound was reached: what the surface must still be
        /// told (results, drain markers, payloads), without patches, until it
        /// asks for its resync.
        var held: [ReplicaDelivery]?
    }

    /// `state` is a Yjs update; `updates` replay after it (a restored journal).
    /// `makeReplica` creates the graph (tests pass fixed client ids).
    private init(
        state: Data, updates: [Data], revision: UInt64, store: ReplicaStore?, scope: ReplicaScope?,
        freshClientID: Bool, interlinkingOrigin: String? = nil, makeReplica: @Sendable () -> YDoc, hooks: Hooks
    ) throws {
        let resolvedOrigin = interlinkingOrigin ?? scope?.serverOrigin
        let graph = try Self.build(
            state: state, updates: updates, revision: revision, durable: store != nil, freshClientID: freshClientID,
            interlinkingOrigin: resolvedOrigin, makeReplica: makeReplica)
        hasUnsupportedRoot = graph.hasUnsupportedRoot
        canType = graph.canType
        self.doc = graph.doc
        self.sink = graph.sink
        self.engine = graph.engine
        self.store = store
        self.scope = scope
        self.interlinkingOrigin = resolvedOrigin
        self.hooks = hooks
    }

    private struct Graph {
        let doc: YDoc
        let engine: DocumentEngine
        let sink: ReplicaPatchSink
        let hasUnsupportedRoot: Bool
        let canType: Bool
    }

    private static func build(
        state: Data, updates: [Data], revision: UInt64, durable: Bool, freshClientID: Bool,
        interlinkingOrigin: String? = nil, makeReplica: () -> YDoc
    ) throws -> Graph {
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
        let sink = ReplicaPatchSink()
        let engine = DocumentEngine(doc: doc, surface: sink, revision: revision)
        sink.engine = engine
        if durable {
            // Every revision must be a journal entry: an unjournaled
            // transaction freezes the engine (it has no rollback); the next
            // delivery's state says so and the surface stops authoring.
            engine.onUnjournaledTransaction = {}
        }
        // Marks never make the native projection lossy (raw Yjs write-back
        // keeps them all); the Markdown shadow is the one `ReplicaSaveAdapter`
        // captures, which drops what Markdown cannot spell.
        return Graph(
            doc: doc, engine: engine, sink: sink,
            hasUnsupportedRoot: projected.blocks.isEmpty && !projected.isFullyRenderable,
            canType: projected.isFullyModeled
                && NativeBlockProjection.markdownShadow(doc, interlinkingOrigin: interlinkingOrigin) != nil)
    }

    /// An in-memory replica of `state` (no journal until `setWritable`).
    /// `clientID` fixes the author (tests compare bytes); nil picks one.
    static func seed(
        state: Data, revision: UInt64 = 0, clientID: UInt? = nil, gc: Bool = true,
        interlinkingOrigin: String? = nil, hooks: Hooks = Hooks()
    ) async throws -> DocumentReplicaSession {
        try DocumentReplicaSession(
            state: state, updates: [], revision: revision, store: nil, scope: nil, freshClientID: false,
            interlinkingOrigin: interlinkingOrigin,
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
    static func inspect(state: Data, interlinkingOrigin: String? = nil) throws -> (
        blocks: [BlockSnapshot], hasUnsupportedRoot: Bool, canType: Bool, tables: [String: TableGrid],
        columns: [String: (group: ColumnGroup, blocks: [[BlockSnapshot]])]
    ) {
        let doc = YDoc(clientID: 1, gc: true)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(state), origin: .remote)
        let projected = NativeBlockProjection.project(doc)
        return (
            projected.blocks.map(BlockSnapshot.init), projected.blocks.isEmpty && !projected.isFullyRenderable,
            projected.isFullyModeled
                && NativeBlockProjection.markdownShadow(doc, interlinkingOrigin: interlinkingOrigin) != nil,
            TableGrid.tables(in: doc),
            ColumnGroup.groups(in: doc)
        )
    }

    /// The projection now and every delivery after it, in one turn.
    func attach(surfaceID: UUID) -> Attachment {
        attach(surfaceID: surfaceID, table: nil)!
    }

    /// A table surface (PR11a): table `blockID`'s paragraphs, opened as text
    /// targets, and only their deliveries after this. Nil (nothing attached)
    /// when it is not a familiar table of this replica.
    func attach(surfaceID: UUID, table blockID: String?) -> Attachment? {
        hooks.onReplicaWork?()
        if loop == nil { loop = Task { await self.run() } }
        var grid: TableGrid?
        if let blockID {
            guard !isClosed, openTables[blockID] != nil || engine.openTable(blockID) else { return nil }
            openTables[blockID, default: 0] += 1
            grid = engine.tableGrid(blockID)
        }
        // One slot past the bound is for the resync marker.
        let (stream, continuation) = AsyncStream<ReplicaDelivery>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.deliveryBound + 1))
        if isClosed {
            continuation.finish()
        } else {
            surfaces[surfaceID] = SurfaceState(deliveries: continuation, table: blockID)
            if selectionOwner == nil { selectionOwner = surfaceID }
        }
        let recoveries = store.flatMap { store in scope.map { store.provisionalRecoveries(for: $0) } } ?? []
        return Attachment(
            blocks: projection(for: blockID), revision: engine.revision, hasUnsupportedRoot: hasUnsupportedRoot,
            canType: canType, recoveries: recoveries, state: state, deliveries: stream, grid: grid)
    }

    /// A surface's whole projection: the document, a table's paragraphs or a column's blocks.
    private func projection(for table: String?, column: String? = nil) -> [BlockSnapshot] {
        if let column { return engine.columnBlocks(column) ?? [] }
        guard let table else { return NativeBlockProjection.project(doc).blocks.map(BlockSnapshot.init) }
        return engine.tableParagraphs(table) ?? []
    }

    /// Open tables by block id, with how many table surfaces show each.
    private var openTables: [String: Int] = [:]
    /// Open column groups by block id, with how many column surfaces show each.
    private var openGroups: [String: Int] = [:]

    /// A column surface (PR12a): column `columnID` of group `groupID`, its
    /// blocks opened as text targets, and only their deliveries after this.
    /// Nil (nothing attached) when it is not a column of a familiar group of
    /// this replica.
    func attach(surfaceID: UUID, group groupID: String, column columnID: String) -> Attachment? {
        hooks.onReplicaWork?()
        if loop == nil { loop = Task { await self.run() } }
        guard !isClosed, openGroups[groupID] != nil || engine.openColumns(groupID),
            let group = engine.columnGroup(groupID), group.columns.contains(where: { $0.id == columnID })
        else {
            if openGroups[groupID] == nil { engine.closeColumns(groupID) }
            return nil
        }
        openGroups[groupID, default: 0] += 1
        let (stream, continuation) = AsyncStream<ReplicaDelivery>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.deliveryBound + 1))
        var surface = SurfaceState(deliveries: continuation, table: nil)
        surface.column = (groupID, columnID)
        surfaces[surfaceID] = surface
        if selectionOwner == nil { selectionOwner = surfaceID }
        return Attachment(
            blocks: projection(for: nil, column: columnID), revision: engine.revision,
            hasUnsupportedRoot: hasUnsupportedRoot, canType: canType, recoveries: [], state: state,
            deliveries: stream, columnGroup: group)
    }

    /// Returns once the session closed (`.close` was handled).
    func waitUntilClosed() async {
        guard !isClosed else { return }
        // A replica closed before any attach (an open dropped during its
        // restore) has no loop yet to handle the `.close`.
        if loop == nil { loop = Task { await self.run() } }
        await withCheckedContinuation { closeWaiters.append($0) }
    }

    // MARK: - The loop

    private func run() async {
        for await message in mailbox.stream {
            mailbox.took()
            guard !isClosed else {
                message.cancel()
                continue
            }
            await hooks.beforeMessage?()
            hooks.onReplicaWork?()
            handle(message)
            reportCursor()
        }
    }

    /// Our selection as awareness: none for a reader (no journal).
    private var cursor: AwarenessCursor? { journal == nil ? nil : engine.awarenessCursor() }

    private func reportCursor() {
        guard let cursorSink, !isClosed else { return }
        let cursor = self.cursor
        guard cursor != reportedCursor else { return }
        reportedCursor = cursor
        cursorSink(cursor)
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
            selectionOwner = surfaceID
            let rebased = selection.flatMap { rebase($0, surfaceID: surfaceID, base: base) }
            if (try? engine.setSelection(rebased)) == nil { try? engine.setSelection(nil) }
        case .compositionBegin(let surfaceID, let epoch, let base, let blockID, let range):
            // A begin that cannot be captured (a race with an unseen change)
            // leaves no composition: its commit comes back `.orphaned`.
            // Mapped like a predicted replace (an insertion at the same point lands first).
            // One engine composition: another surface's begin is not captured.
            guard surfaces[surfaceID]?.epoch == epoch, !engine.isComposing,
                let rebased = rebase(range, assoc: 1, blockID: blockID, surfaceID: surfaceID, base: base)
            else { return }
            if (try? engine.compositionBegan(blockID: blockID, replacing: rebased)) != nil {
                surfaces[surfaceID]?.composing = (blockID, range, base)
            }
            deliver(to: surfaceID)
        case .compositionCommit(let surfaceID, let epoch, let commandID, let text):
            commitComposition(surfaceID: surfaceID, epoch: epoch, commandID: commandID, text: text)
        case .compositionCancel(let surfaceID):
            if surfaces[surfaceID]?.composing != nil, engine.isComposing { try? engine.compositionCancelled() }
            surfaces[surfaceID]?.composing = nil
            deliver(to: surfaceID, result: .composition(commandID: nil, .cancelled), selection: true)
        case .writeProvisional(let entries):
            // A convenience copy, never committed content: a failed write
            // must not block typing.
            if let store, let scope { try? store.writeProvisionalRecoveries(entries, for: scope) }
        case .integrate(let update, let reply):
            // Evaluated first: an optional call skips its arguments when nil.
            let result = Result { try integrate(update) }
            reply?(result)
        case .liveSync(let peerVector, let reply):
            reply(YStateEncoder.encodeStateVector(doc), peerVector.flatMap(missingUpdate(since:)))
        case .watchCursor(let sink):
            cursorSink = sink
            reportedCursor = cursor
            sink(reportedCursor)
        case .resolveCursors(let cursors, let reply):
            // Untrusted peer positions: never a write, never a fail-safe.
            reply(
                cursors.mapValues {
                    PeerCursorPlaces(anchor: engine.peerPlace($0.anchor), head: engine.peerPlace($0.head))
                })
        case .navigation(let reply):
            reply(engine.navigationEntries())
        case .locate(let handle, let group, let reply):
            reply(group.map { engine.locateColumn(handle, group: $0) } ?? engine.locate(handle))
        case .tableGrid(let blockID, let full, let reply):
            reply(engine.tableGrid(blockID, full: full))
        case .tableCopy(let blockID, let from, let to, let serverOrigin, let reply):
            reply(engine.tableCopy(blockID, from: from, to: to, interlinkingOrigin: serverOrigin ?? interlinkingOrigin))
        case .columnGroup(let blockID, let reply):
            reply(engine.columnGroup(blockID))
        case .mediaLocation(let blockID, let reply):
            reply(.some(engine.mediaLocation(blockID)))
        case .requestAvailability(let surfaceID, let blockID, let candidates):
            let actions = candidates.filter { candidate in
                guard let kind = candidate.kind else { return engine.hasLosslessCopy(blockID) }
                return engine.canApplyStructural(
                    NativeEditCommand(id: UUID(), baseRevision: engine.revision, blockID: blockID, kind: kind))
            }.map(\.action)
            var delivery = ReplicaDelivery(revision: engine.revision, state: state)
            delivery.availability = (blockID, engine.revision, actions)
            send(delivery, to: surfaceID)
        case .copyPayload(let surfaceID, let requestID, let blockIDs):
            var delivery = ReplicaDelivery(revision: engine.revision, state: state)
            delivery.clipboard = (requestID, engine.subtreePayload(blockIDs))
            send(delivery, to: surfaceID)
        case .copyInlinePayload(let surfaceID, let requestID, let slices):
            var delivery = ReplicaDelivery(revision: engine.revision, state: state)
            delivery.inlineClipboard = (requestID, engine.inlinePayload(slices))
            send(delivery, to: surfaceID)
        case .setWritable(let journal):
            self.journal = journal
            if journal != nil, history == nil { history = ReplicaHistory(doc: doc, engine: engine) }
            deliver(to: nil)
        case .drain(let surfaceID, let token):
            var delivery = ReplicaDelivery(revision: engine.revision, state: state)
            delivery.drained = token
            send(delivery, to: surfaceID)
        case .resync(let surfaceID):
            resync(surfaceID)
        case .detach(let surfaceID):
            guard let surface = surfaces.removeValue(forKey: surfaceID) else { return }
            surface.deliveries.finish()
            if selectionOwner == surfaceID {
                selectionOwner = nil
                try? engine.setSelection(nil)
            }
            // A composition nobody can commit any more ends here.
            if surface.composing != nil, engine.isComposing {
                try? engine.compositionCancelled()
                deliver(to: nil)
            }
            if let table = surface.table { closeTable(table) }
            if let column = surface.column { closeColumns(column.group) }
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
            // Read-only (`setWritable(nil)`): a predicted key rolls back into a recovery entry.
            if message.predicted {
                invalidate(message.surfaceID, commandID: id)
            } else {
                deliver(to: message.surfaceID, result: .refused(commandID: id, nil))
            }
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
        selectionOwner = message.surfaceID
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

    /// A commit is a predicted command: the surface shows its text already.
    /// Its rebuild is the surface's own echo, kept out of its unseen ring
    /// unless discarded peer changes were folded in. A commit whose target
    /// is gone ends the surface's epoch like an unrebaseable key.
    private func commitComposition(surfaceID: UUID, epoch: UInt64, commandID: UUID, text: String) {
        // Only this surface's own composition is ended here.
        let begun = surfaces[surfaceID]?.composing
        surfaces[surfaceID]?.composing = nil
        guard surfaces[surfaceID]?.epoch == epoch else {
            // The surface rolls this epoch back already.
            if begun != nil, engine.isComposing { try? engine.compositionCancelled() }
            deliver(to: surfaceID, result: .composition(commandID: commandID, .orphaned))
            return
        }
        guard engine.isComposing, let begun else {
            // The begin never captured its target: nothing is written.
            invalidate(surfaceID, commandID: commandID)
            return
        }
        guard journal != nil else {
            // Read-only (`setWritable(nil)`): like a predicted key, the commit
            // is never written without a journal and rolls back into a
            // recovery entry.
            try? engine.compositionCancelled()
            invalidate(surfaceID, commandID: commandID)
            return
        }
        // A composition commit is one undo step.
        history?.stopCapturing()
        defer { history?.stopCapturing() }
        let journal = self.journal
        do {
            switch try engine.compositionCommitted(
                text: text, commandID: commandID, persist: { try journal?($0, $1) })
            {
            case .committed(_, let folds):
                // Its echo is out of the ring, so the ring moves through it, as
                // through a predicted replace.
                if !folds, var surface = surfaces[surfaceID] {
                    surface.unseen.removeAll { $0.revision <= begun.base }
                    _ = rebase(begun.range, text: text, blockID: begun.blockID, unseen: &surface.unseen)
                    surfaces[surfaceID] = surface
                    predicting = (surfaceID, commandID)
                }
                defer { predicting = nil }
                selectionOwner = surfaceID
                deliver(to: surfaceID, result: .composition(commandID: commandID, .committed), selection: true)
            case .orphaned:
                invalidate(surfaceID, commandID: commandID)
            }
        } catch {
            // A boundary refusal leaves the engine composing; end it. A failed
            // append keeps the entry on disk.
            if engine.isComposing { try? engine.compositionCancelled() }
            deliver(to: surfaceID, result: .composition(commandID: commandID, .failed), selection: true)
        }
    }

    /// What a peer at `vector` lacks. Only journaled state is published: a
    /// reader (no journal) or a frozen replica, whose graph may hold an
    /// unjournaled mutation, answers nothing.
    private func missingUpdate(since vector: Data) -> Data? {
        guard journal != nil, !engine.nativeWriteFailed,
            let entries = try? YUpdateDecoder.decodeStateVector(vector)
        else { return nil }
        // `uniquingKeysWith`: the vector is wire data and may repeat a client.
        let since = Dictionary(entries.map { ($0.client, $0.clock) }, uniquingKeysWith: { _, latest in latest })
        return try? YStateEncoder.encodeStateAsUpdate(doc, since: since)
    }

    private func integrate(_ state: Data) throws {
        let update = state.isEmpty ? Data([0, 0]) : state
        let decoded = try YUpdateDecoder.decode(update)
        // An update that builds on structs this replica lacks (a live frame
        // that overtook its dependency) is refused untouched: integrating it
        // would leave pending structs, which the durable path treats as corrupt
        // and freezes on. The live binding asks for state again instead.
        guard !decoded.missesDependencies(in: doc.store) else { throw NativeLiveError.missingDependencies }
        // A duplicate or empty frame changes nothing: it is not journaled.
        guard !decoded.addsNothing(to: doc.store) else { return }
        let doc = self.doc
        defer { deliver(to: nil) }
        var applied = false
        var appendFailed = false
        do {
            try engine.durablyIntegrateRemote(
                update: update,
                apply: {
                    applied = true
                    try doc.applyUpdate(decoded, origin: .remote)
                    guard doc.store.pendingStructs == nil, doc.store.pendingDs == nil else {
                        throw ReplicaStoreError.corrupt
                    }
                },
                persist: { [store, scope] revision in
                    guard let store, let scope else { return }
                    do {
                        try store.append(update, for: scope, commandID: UUID(), baseRevision: revision, origin: .remote)
                    } catch {
                        appendFailed = true
                        throw error
                    }
                })
        } catch {
            // A failed append is ours: authoring stays frozen. An update that
            // failed to integrate is the peer's: it may have half-mutated the
            // graph, which is rebuilt from the journal, and only the caller
            // (the live binding) stops.
            if applied, !appendFailed { recoverFromRemoteFault() }
            throw error
        }
        remoteAppends += 1
        compactIfNeeded()
    }

    /// Remote entries are covered as soon as they are journaled, so a live
    /// document that is only read still compacts (the HTTP ack compacts too).
    private func compactIfNeeded() {
        guard let store, let scope, remoteAppends >= ReplicaSaveAdapter.compactionJournalThreshold,
            !engine.nativeWriteFailed, let checkpoint = try? YStateEncoder.encodeStateAsUpdate(doc)
        else { return }
        remoteAppends = 0
        // Best effort: a failure leaves the journal as it was.
        try? store.compact(for: scope, checkpoint: checkpoint, baseRevision: engine.revision)
    }

    /// The graph a failed remote update left is replaced by a replay of the
    /// durable journal, which never held that update, and every surface gets
    /// a `.reset` under a new epoch (keys in flight become recovery entries).
    /// Undo history and the selection start over. An in-memory replica has no
    /// journal to replay and stays frozen.
    private func recoverFromRemoteFault() {
        guard let store, let scope, let restored = try? store.restore(for: scope),
            let graph = try? Self.build(
                state: restored.checkpoint, updates: restored.updates, revision: restored.manifest.revision,
                durable: true, freshClientID: true, interlinkingOrigin: scope.serverOrigin,
                makeReplica: { YDoc(clientID: UInt.random(in: 1...UInt(UInt32.max))) })
        else { return }
        _ = sink.take()
        history?.destroy()
        doc.destroy()
        doc = graph.doc
        engine = graph.engine
        sink = graph.sink
        history = journal == nil ? nil : ReplicaHistory(doc: doc, engine: engine)
        // The new engine's index opens the groups and tables surfaces show again.
        for group in openGroups.keys { engine.openColumns(group) }
        for table in openTables.keys { engine.openTable(table) }
        for id in surfaces.keys {
            surfaces[id]?.composing = nil
            resync(id)
        }
    }

    /// The last table surface of `table` left: its paragraphs stop being
    /// text targets, and the document surfaces, which saw no cell text while
    /// it was open, get the table's preview once.
    private func closeTable(_ table: String) {
        openTables[table, default: 1] -= 1
        guard openTables[table] == 0 else { return }
        openTables[table] = nil
        engine.closeTable(table)
        if let snapshot = engine.nativeSnapshot(for: table) {
            var patch = BlockPatch([.replaceBlock(blockID: table, block: snapshot)], origin: .other)
            // A column's table (PR12a): the preview is that column's.
            if let column = engine.column(of: table) { patch.columns[table] = column }
            sink.applyPatch(patch)
            deliver(to: nil)
        }
    }

    /// The last column surface of group `group` left: its blocks stop being
    /// text targets, and the document surfaces, which saw no column's text
    /// while it was open, get the group's preview once.
    private func closeColumns(_ group: String) {
        openGroups[group, default: 1] -= 1
        guard openGroups[group] == 0 else { return }
        openGroups[group] = nil
        engine.closeColumns(group)
        if let snapshot = engine.nativeSnapshot(for: group) {
            sink.applyPatch(BlockPatch([.replaceBlock(blockID: group, block: snapshot)], origin: .other))
            deliver(to: nil)
        }
    }

    /// `events` as surface `surfaceID` sees them (PR11a): a document surface
    /// never sees a table paragraph; a table surface sees only its table's
    /// paragraphs and the table's own changes (which it ignores, and its
    /// editor reads as a structure signal), and a reset as its table's.
    /// PR12a: a document surface never sees a column's blocks (the patch names
    /// them, `BlockPatch.columns`); a column surface sees only its column's
    /// blocks and its group's own changes (a structure signal, which its
    /// surface ignores), and a reset as its column's.
    private func events(_ events: [ReplicaDelivery.Event], for surface: SurfaceState) -> [ReplicaDelivery.Event] {
        if let column = surface.column { return columnEvents(events, column: column) }
        // The spelling is sound here: a canonical index refuses a block id
        // holding U+0001, and a non-canonical one only ever delivers `.reset`.
        func shown(_ id: String) -> Bool {
            guard let table = surface.table else { return !TableGrid.isParagraphID(id) }
            return id == table || TableGrid.tableID(ofParagraph: id) == table && TableGrid.isParagraphID(id)
        }
        guard
            surface.table != nil
                || events.contains(where: { event in
                    guard case .patch(let patch, _) = event else { return false }
                    if !patch.columns.isEmpty || !patch.removedColumns.isEmpty { return true }
                    return patch.changes.contains { change in
                        switch change {
                        case .text(let id, _), .props(let id, _), .replaceBlock(let id, _): TableGrid.isParagraphID(id)
                        case .remove(let ids): ids.contains(where: TableGrid.isParagraphID)
                        case .insert(_, let blocks): blocks.contains { TableGrid.isParagraphID($0.id) }
                        case .reset: false
                        }
                    }
                })
        else { return events }
        return events.compactMap { event in
            guard case .patch(var patch, let settled) = event else { return event }
            // A table surface's table may be a column's block: its own changes still reach it.
            let columns = surface.table == nil ? patch.columns : [:]
            let removedColumns = surface.table == nil ? patch.removedColumns : [:]
            patch.columns = [:]
            patch.removedColumns = [:]
            patch.changes = patch.changes.compactMap { change in
                switch change {
                case .text(let id, _), .props(let id, _), .replaceBlock(let id, _):
                    return shown(id) && columns[id] == nil ? change : nil
                case .remove(let ids):
                    let kept = ids.filter { shown($0) && removedColumns[$0] == nil }
                    return kept.isEmpty ? nil : .remove(blockIDs: kept)
                case .insert(let after, let blocks):
                    let kept = blocks.filter { shown($0.id) && columns[$0.id] == nil }
                    return kept.isEmpty ? nil : .insert(after: after, blocks: kept)
                case .reset:
                    guard let table = surface.table else { return change }
                    return .reset(engine.tableParagraphs(table) ?? [])
                }
            }
            return patch.isEmpty ? nil : .patch(patch, settled: settled)
        }
    }

    /// A column surface's events (PR12a): its column's blocks, by the patch's
    /// own tags, and its group's changes.
    private func columnEvents(_ events: [ReplicaDelivery.Event], column: (group: String, id: String))
        -> [ReplicaDelivery.Event]
    {
        events.compactMap { event in
            guard case .patch(var patch, let settled) = event else { return event }
            let columns = patch.columns
            let removedColumns = patch.removedColumns
            patch.columns = [:]
            patch.removedColumns = [:]
            patch.changes = patch.changes.compactMap { change in
                switch change {
                case .text(let id, _), .props(let id, _), .replaceBlock(let id, _):
                    return columns[id] == column.id || id == column.group ? change : nil
                case .remove(let ids):
                    // The group's own removal (it dissolved or went) too: a structure signal (PR12b).
                    let kept = ids.filter { removedColumns[$0] == column.id || $0 == column.group }
                    return kept.isEmpty ? nil : .remove(blockIDs: kept)
                case .insert(let after, let blocks):
                    let kept = blocks.filter { columns[$0.id] == column.id }
                    return kept.isEmpty ? nil : .insert(after: after, blocks: kept)
                case .reset:
                    return .reset(engine.columnBlocks(column.id) ?? [])
                }
            }
            return patch.isEmpty ? nil : .patch(patch, settled: settled)
        }
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
    /// surface, the result only to `surfaceID`. Changes that
    /// are not a surface's own predicted echo join its unseen ring.
    private func deliver(
        to surfaceID: UUID?, result: ReplicaResult? = nil, selection: Bool = false, timings: ReplicaTimings? = nil
    ) {
        var events = sink.take()
        for index in events.indices {
            guard case .patch(var patch, let settled) = events[index], var stamp = patch.nativeCommand else { continue }
            stamp.surfaceID = predicting?.commandID == stamp.commandID ? predicting?.surfaceID : surfaceID
            patch.nativeCommand = stamp
            events[index] = .patch(patch, settled: settled)
        }
        let all = events
        for id in surfaces.keys {
            let own = id == surfaceID
            var surface = surfaces[id]!
            let events = self.events(all, for: surface)
            let changed = events.contains { if case .patch = $0 { true } else { false } }
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
            if id == selectionOwner, own ? (selection || changed) : changed {
                // `try?` flattens: nil when there is no selection (or detached).
                let endpoints = try? engine.currentSelectionEndpoints()
                delivery.selection = ReplicaSelection(
                    seq: surface.selectionSeq, anchor: endpoints?.anchor, head: endpoints?.head,
                    tracked: endpoints != nil)
            }
            send(delivery, to: id)
        }
    }

    /// Every delivery leaves through here. At the bound the surface gets the
    /// marker in the slot kept for it, and from then on only what answers
    /// something is kept, without patches (the reset will show them).
    private func send(_ delivery: ReplicaDelivery, to surfaceID: UUID) {
        guard var surface = surfaces[surfaceID] else { return }
        defer { surfaces[surfaceID] = surface }
        if surface.held != nil {
            if let answers = delivery.withoutPatches() { surface.held?.append(answers) }
            return
        }
        if case .enqueued(let remaining) = surface.deliveries.yield(delivery), remaining > 1 { return }
        surface.held = []
        var marker = ReplicaDelivery(revision: delivery.revision, state: delivery.state)
        marker.resync = .requested
        surface.deliveries.yield(marker)
    }

    /// The surface asked to catch up (it read the marker, or marked text held
    /// too many deliveries): what was held, then the canonical state as one
    /// `.reset` under a new epoch. Commands of the old epoch posted after the
    /// ask are dropped like an invalidated epoch's; the surface held its keys.
    private func resync(_ surfaceID: UUID) {
        guard var surface = surfaces[surfaceID] else { return }
        let held = surface.held ?? []
        surface.held = nil
        surface.epoch += 1
        surface.unseen = []
        surface.droppedThrough = engine.revision
        surfaces[surfaceID] = surface
        for delivery in held { send(delivery, to: surfaceID) }
        let blocks = projection(for: surface.table, column: surface.column?.id)
        var reset = ReplicaDelivery(
            revision: engine.revision, events: [.patch(BlockPatch([.reset(blocks)], origin: .other), settled: [:])],
            state: state)
        reset.resync = .reset(epoch: surface.epoch)
        if surfaceID == selectionOwner {
            let endpoints = try? engine.currentSelectionEndpoints()
            reset.selection = ReplicaSelection(
                seq: surface.selectionSeq, anchor: endpoints?.anchor, head: endpoints?.head, tracked: endpoints != nil)
        }
        send(reset, to: surfaceID)
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
