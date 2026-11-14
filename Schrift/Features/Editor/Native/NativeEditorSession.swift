import Foundation
import Observation
import UIKit

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
    /// A table surface's table (PR11a): its blocks are that table's
    /// paragraphs, one cell shown at a time. Nil for the document.
    private(set) var table: String?
    /// The table's grid, as attached and refreshed after a structure change.
    var grid: TableGrid?
    /// After each delivery is applied (the table editor relays out its grid).
    @ObservationIgnored var onApplied: ((ReplicaDelivery) -> Void)?
    /// A column surface's column and group (PR12a): its blocks are that
    /// column's. Nil for the document.
    private(set) var column: (group: String, id: String)?
    /// A scoped source surface's kind (PR14): `mathBlock`, `diagram`, or inline `math`.
    private(set) var source: NativeSourceKind?
    /// Revision bumped whenever displayed blocks, fold state, or checklist
    /// presentation changes so SwiftUI shells refresh Reading chrome.
    private(set) var presentationRevision: Int = 0
    /// Server origin for interlink clipboard plain-text serialization and
    /// same-origin URL paste-interlink.
    @ObservationIgnored private var interlinkingOrigin: String = ""

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
        surface.onFoldChange = { [weak view, weak self] in
            view?.blockControls.foldDidChange()
            self?.presentationRevision &+= 1
        }
    }

    /// The read-only route (PR01): a one-shot projection, no replica session.
    static func inspect(state: Data, interlinkingOrigin: String? = nil) async throws -> NativeEditorSession {
        let inspected = try await Task.detached {
            try DocumentReplicaSession.inspect(state: state, interlinkingOrigin: interlinkingOrigin)
        }.value
        let session = NativeEditorSession(
            replica: nil, blocks: inspected.blocks, revision: 0, hasUnsupportedRoot: inspected.hasUnsupportedRoot,
            canType: inspected.canType, recoveries: [], state: ReplicaState())
        session.inspectedTables = inspected.tables
        session.inspectedColumns = inspected.columns
        return session
    }

    /// The reader's tables, read once with its projection (PR11a).
    @ObservationIgnored private var inspectedTables: [String: TableGrid] = [:]

    /// Table `blockID`'s grid now: asked of the replica session, or the
    /// reader's own copy.
    func tableGrid(_ blockID: String, full: Bool = false) async -> TableGrid? {
        guard let replica else { return inspectedTables[blockID] }
        return await withCheckedContinuation { done in
            // A refused post answers nil itself (`ReplicaMessage.cancel`).
            replica.mailbox.post(.tableGrid(blockID: blockID, full: full, reply: { done.resume(returning: $0) }))
        }
    }

    /// The clipboard of table `blockID`'s CellSelection (PR11c), read in
    /// mailbox order (after every edit posted before it).
    func tableCopy(
        _ blockID: String, from: TableSlot, to: TableSlot, serverOrigin: String? = nil
    ) async -> TableCopy? {
        guard let replica else { return nil }
        return await withCheckedContinuation { done in
            replica.mailbox.post(
                .tableCopy(
                    blockID: blockID, from: from, to: to, serverOrigin: serverOrigin,
                    reply: { done.resume(returning: $0) }))
        }
    }

    /// An in-memory replica session over `state` (the isolated host and
    /// component tests); `enableTyping` gives it a journal.
    /// `clientID` fixes the author (tests compare bytes); nil picks one.
    static func seed(
        state: Data, clientID: UInt? = nil, gc: Bool = true, interlinkingOrigin: String? = nil,
        hooks: DocumentReplicaSession.Hooks = .init()
    ) async throws -> NativeEditorSession {
        let session = await attach(
            try await DocumentReplicaSession.seed(
                state: state, clientID: clientID, gc: gc, interlinkingOrigin: interlinkingOrigin, hooks: hooks))
        session.interlinkingOrigin = interlinkingOrigin ?? ""
        return session
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
        session.interlinkingOrigin = scope?.serverOrigin ?? ""
        session.hasRecoveryStore = scope != nil
        session.consume(attachment.deliveries)
        return session
    }

    /// A table surface over this document's replica (PR11a): table
    /// `blockID`'s paragraphs, typed through the same journal and save
    /// scheduler while this document types. Nil when the table is not a
    /// familiar one (the editor then shows it read-only). Closing it only
    /// detaches it; the document keeps the replica.
    func openTable(_ blockID: String) async -> NativeEditorSession? {
        guard let replica, !isClosed, table == nil else { return nil }
        let surfaceID = UUID()
        guard let attachment = await replica.attach(surfaceID: surfaceID, table: blockID), !isClosed else {
            return nil
        }
        // No recovery entries: those are the document's (`provisional.json` is
        // written by one surface's list).
        let session = NativeEditorSession(
            replica: replica, surfaceID: surfaceID, blocks: attachment.blocks, revision: attachment.revision,
            hasUnsupportedRoot: false, canType: attachment.canType, recoveries: [], state: attachment.state)
        session.table = blockID
        session.grid = attachment.grid
        children.add(session)
        session.scope = scope
        session.interlinkingOrigin = input?.serverOrigin ?? interlinkingOrigin
        session.release = { Task {} }
        session.surface.setFocus([])
        session.textView.isScrollEnabled = false
        session.textView.alwaysBounceVertical = false
        session.textView.textContainerInset = UIEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
        session.textView.accessibilityIdentifier = "nativeEditor.table.cell"
        session.consume(attachment.deliveries)
        // The table types while the document does (the replica's one journal).
        if input != nil, textView.isEditable { session.enableTyping(persist: nil, scheduler: saveScheduler) }
        // One clipboard for the document and its cells (tests use a private one).
        if let pasteboard = input?.pasteboard { session.input?.pasteboard = pasteboard }
        // A cell composition's recovery entries are the document's (PR11c):
        // written with its list, shown by it, restored with it.
        if let document = input?.composition, let cell = session.input?.composition {
            let source = UUID()
            cell.forward = { [weak document] in document?.adopt($0, from: source) }
        }
        return session
    }

    /// Column group `blockID` now: asked of the replica session, or the
    /// reader's own copy (PR12a).
    func columnGroup(_ blockID: String) async -> ColumnGroup? {
        guard let replica else { return inspectedColumns[blockID]?.group }
        return await withCheckedContinuation { done in
            replica.mailbox.post(.columnGroup(blockID: blockID, reply: { done.resume(returning: $0) }))
        }
    }

    /// The reader's column groups with each column's blocks, read once with
    /// its projection (PR12a).
    @ObservationIgnored private var inspectedColumns: [String: (group: ColumnGroup, blocks: [[BlockSnapshot]])] = [:]

    /// A column surface over this document's replica (PR12a): column
    /// `columnID` of group `groupID`, typed through the same journal and save
    /// scheduler while this document types. Nil when it is not a column of a
    /// familiar group. A reader gets a read-only surface over its own copy.
    /// Closing it only detaches it; the document keeps the replica.
    func openColumn(group groupID: String, column columnID: String) async -> NativeEditorSession? {
        guard !isClosed, table == nil, column == nil else { return nil }
        guard let replica else {
            guard let inspected = inspectedColumns[groupID],
                let index = inspected.group.columns.firstIndex(where: { $0.id == columnID })
            else { return nil }
            let session = NativeEditorSession(
                replica: nil, blocks: inspected.blocks[index], revision: 0, hasUnsupportedRoot: false, canType: false,
                recoveries: [], state: ReplicaState())
            session.column = (groupID, columnID)
            return session
        }
        let surfaceID = UUID()
        guard let attachment = await replica.attach(surfaceID: surfaceID, group: groupID, column: columnID), !isClosed
        else { return nil }
        // No recovery entries: those are the document's.
        let session = NativeEditorSession(
            replica: replica, surfaceID: surfaceID, blocks: attachment.blocks, revision: attachment.revision,
            hasUnsupportedRoot: false, canType: attachment.canType, recoveries: [], state: attachment.state)
        session.column = (groupID, columnID)
        session.scope = scope
        session.interlinkingOrigin = input?.serverOrigin ?? interlinkingOrigin
        session.release = { Task {} }
        children.add(session)
        session.textView.accessibilityIdentifier = "nativeEditor.column"
        session.consume(attachment.deliveries)
        // The column types while the document does (the replica's one journal).
        if input != nil, textView.isEditable { session.enableTyping(persist: nil, scheduler: saveScheduler) }
        if let pasteboard = input?.pasteboard { session.input?.pasteboard = pasteboard }
        // A column composition's recovery entries are the document's, as a cell's are (PR11c).
        if let document = input?.composition, let cell = session.input?.composition {
            let source = UUID()
            cell.forward = { [weak document] in document?.adopt($0, from: source) }
        }
        return session
    }

    /// A focused source surface over a `mathBlock`, `diagram`, or inline `<math>`
    /// chip (PR14). Settles any pending mailbox command on this surface before
    /// attaching so newly inserted slash items resolve immediately.
    func openSource(_ request: NativeSourceRequest) async -> NativeEditorSession? {
        guard !isClosed, source == nil else { return nil }
        guard let replica else {
            return openInspectedSource(request)
        }
        // A slash command posted just before opening runs asynchronously in the
        // replica mailbox; draining first ensures the new target exists in Yjs.
        await settle()
        guard !isClosed else { return nil }
        let surfaceID = UUID()
        let attachment: DocumentReplicaSession.Attachment?
        switch request {
        case .block(let blockID):
            attachment = await replica.attach(surfaceID: surfaceID, source: .block(id: blockID))
        case .inlineMath(let blockID, let utf16Offset):
            attachment = await replica.attach(surfaceID: surfaceID, inlineMathIn: blockID, utf16Offset: utf16Offset)
        }
        guard let attachment, let sourceKind = attachment.sourceKind, !isClosed else { return nil }
        let session = NativeEditorSession(
            replica: replica, surfaceID: surfaceID, blocks: attachment.blocks, revision: attachment.revision,
            hasUnsupportedRoot: false, canType: attachment.canType, recoveries: [], state: attachment.state)
        session.source = sourceKind
        session.scope = scope
        session.interlinkingOrigin = input?.serverOrigin ?? interlinkingOrigin
        session.release = { Task {} }
        children.add(session)
        Self.configureSourceTextView(session.textView)
        session.consume(attachment.deliveries)
        if input != nil, textView.isEditable { session.enableTyping(persist: nil, scheduler: saveScheduler) }
        if let pasteboard = input?.pasteboard { session.input?.pasteboard = pasteboard }
        session.input?.sourceKind = sourceKind
        if let parent = input?.composition, let child = session.input?.composition {
            let forwardID = UUID()
            child.forward = { [weak parent] in parent?.adopt($0, from: forwardID) }
        }
        return session
    }

    private func openInspectedSource(_ request: NativeSourceRequest) -> NativeEditorSession? {
        let columnBlocks = inspectedColumns.values.flatMap(\.blocks).flatMap { $0 }
        let tableBlocks = inspectedTables.flatMap { tableID, grid in
            grid.rows.flatMap { row in
                row.flatMap { cell in
                    cell.paragraphs.map { para in
                        BlockSnapshot(
                            id: TableGrid.paragraphID(table: tableID, item: para.itemID),
                            node: "paragraph", props: [], runs: para.runs, isOpaque: false)
                    }
                }
            }
        }
        let allBlocks = surface.blocks + columnBlocks + tableBlocks
        switch request {
        case .block(let blockID):
            guard let block = allBlocks.first(where: { $0.id == blockID }),
                !block.isOpaque,
                case .source(let node, _, _) = block.preview
            else { return nil }
            let kind: NativeSourceKind = node == SourceBlock.mathBlock ? .mathBlock : .diagram
            let text = block.runs.map(\.text).joined()
            guard SourceBlock.isEditableSource(text, node: node) else { return nil }
            let snapshot = BlockSnapshot(
                id: blockID, node: "codeBlock", props: [],
                runs: text.isEmpty ? [] : [InlineRun(text)], isOpaque: false)
            let session = NativeEditorSession(
                replica: nil, blocks: [snapshot], revision: 0, hasUnsupportedRoot: false, canType: false,
                recoveries: [], state: ReplicaState())
            session.source = kind
            Self.configureSourceTextView(session.textView)
            return session
        case .inlineMath(let blockID, let utf16Offset):
            guard let block = allBlocks.first(where: { $0.id == blockID }) else { return nil }
            var cursor = 0
            for run in block.runs {
                if cursor == utf16Offset, case .math(let src)? = run.inlineObject {
                    guard SourceBlock.isEditableSource(src, node: NativeInlineObject.mathNodeName) else {
                        return nil
                    }
                    let snapshot = BlockSnapshot(
                        id: blockID, node: "paragraph", props: [],
                        runs: src.isEmpty ? [] : [InlineRun(src)], isOpaque: false)
                    let session = NativeEditorSession(
                        replica: nil, blocks: [snapshot], revision: 0, hasUnsupportedRoot: false, canType: false,
                        recoveries: [], state: ReplicaState())
                    session.source = .inlineMath
                    Self.configureSourceTextView(session.textView)
                    return session
                }
                cursor += run.text.utf16.count
            }
            return nil
        }
    }

    private static func configureSourceTextView(_ textView: NativeTextView) {
        textView.accessibilityIdentifier = "nativeEditor.source.text"
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
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

    /// Where block `blockID` is, read in mailbox order anywhere in the
    /// document (PR13b): `.some(nil)` when no block has that id, nil when
    /// nothing answered (no replica, closed, a full mailbox).
    func mediaLocation(_ blockID: String) async -> MediaLocation?? {
        guard let replica, !isClosed else { return nil }
        return await withCheckedContinuation { done in
            replica.mailbox.post(.mediaLocation(blockID: blockID, reply: { done.resume(returning: $0) }))
        }
    }

    /// A headless surface's command (PR13b, no input coordinator): posted as a
    /// barrier at the revision shown, answered by its result; nil when it could
    /// not be posted or the session ended first.
    func post(_ kind: NativeEditCommand.Kind, blockID: String) async -> ReplicaResult? {
        guard let replica, !isClosed, input == nil else { return nil }
        let command = NativeEditCommand(id: UUID(), baseRevision: revision, blockID: blockID, kind: kind)
        return await withCheckedContinuation { done in
            results[command.id] = done
            let posted = replica.mailbox.post(
                .command(
                    ReplicaCommand(
                        surfaceID: surfaceID, epoch: headlessEpoch, predicted: false, command: command,
                        undoBefore: true, undoAfter: true)))
            if !posted { results.removeValue(forKey: command.id)?.resume(returning: nil) }
        }
    }

    @ObservationIgnored private var results: [UUID: CheckedContinuation<ReplicaResult?, Never>] = [:]
    /// A surface without input's epoch (review X8): a resync's reset moves it.
    @ObservationIgnored private var headlessEpoch: UInt64 = 0

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
            if case .reset(let epoch) = delivery.resync { headlessEpoch = epoch }
            if case .invalidated(let epoch, _)? = delivery.result { headlessEpoch = epoch }
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
            presentationRevision &+= 1
        }
        if let token = delivery.drained { drains.removeValue(forKey: token)?.resume() }
        if let result = delivery.result, let id = result.commandID {
            results.removeValue(forKey: id)?.resume(returning: result)
        }
        onApplied?(delivery)
    }

    /// The session closed: everything posted before the close was journaled
    /// and delivered, so a save scheduled by a late append is handed over now.
    private func didFinishDeliveries() {
        for drain in drains.values { drain.resume() }
        drains = [:]
        for result in results.values { result.resume(returning: nil) }
        results = [:]
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
        input.session = self
        let resolvedOrigin =
            interlinkingOrigin.isEmpty
            ? (scope?.serverOrigin ?? textView.blockControls.serverOrigin) : interlinkingOrigin
        input.serverOrigin = resolvedOrigin
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

    /// Schedule the debounced native replica save (for example after a title edit).
    func scheduleSave() {
        saveScheduler?.schedule()
    }

    /// Switches this surface between Reading and Editing mode without tearing
    /// down its `NativeInputCoordinator`.
    func setEditing(_ editing: Bool) {
        if editing {
            guard let input, !input.isFrozen, !input.isDetached, state.writable else {
                textView.isEditable = false
                return
            }
            textView.isEditable = true
            input.refreshSelectionMarks()
        } else {
            if textView.markedTextRange != nil {
                textView.unmarkText()
            }
            flushPendingSave()
            if textView.isFirstResponder {
                textView.resignFirstResponder()
            }
            textView.isEditable = false
            input?.endEditingMode()
        }
    }

    /// Updates local Reading-mode checklist hiding without writing Yjs state.
    @discardableResult
    func setChecklistPresentation(hidesCompleted: Bool, settlingIDs: Set<String>) -> Bool {
        let changed = surface.setChecklistPresentation(hidesCompleted: hidesCompleted, settlingIDs: settlingIDs)
        presentationRevision &+= 1
        return changed
    }

    /// A capture that cannot be prepared leaves durable journal bytes nothing
    /// can send. Stop authoring rather than growing an unsendable journal.
    func freezeAuthoring() {
        input?.stopAfterStorageFailure()
        // The table and column surfaces this document opened share its journal (PR12a).
        for child in children.allObjects { child.freezeAuthoring() }
    }

    /// The table and column surfaces this document opened, while they live.
    @ObservationIgnored private let children = NSHashTable<NativeEditorSession>.weakObjects()

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
    /// Whether `abilities.mention` is granted for this open document session.
    private(set) var canMention = false
    private var rowCanMention = false
    /// Bumped by every open and close (including the close a sign-in change
    /// forces), so an awaited fetch, restore or save result is dropped once
    /// the open that asked for it is gone.
    private var generation = 0
    private struct ServerAbilityAnswer: Sendable {
        let writer: Bool?
        let mention: Bool?
    }
    private enum OpenResult: Sendable {
        case classic
        /// `ability`: the server's `abilities.update` and `abilities.mention` (nil: not asked, or no answer).
        case state(Data, config: ServerConfig, ability: ServerAbilityAnswer?)
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
    func open(
        viewModel: EditorViewModel, isOffline: Bool, canUpdate: Bool = false, canMention: Bool = false
    ) async {
        // A repeated call while visible must not swap a focused editor. Close
        // establishes the next safe open or reopen boundary.
        guard !isOpen else { return }
        isOpen = true
        enabled = preference()
        self.canUpdate = false
        self.canMention = false
        self.rowCanMention = canMention
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
            viewModel.seedNativeMetadataIfNeeded(includeLocalDrafts: false)
            route = .preservedUnavailable
            return
        case .owned(let scope):
            // Another account's unsynced replica is never shown to this one.
            guard scope.ownerUserID == account else {
                viewModel.seedNativeMetadataIfNeeded(includeLocalDrafts: false)
                route = .preservedUnavailable
                return
            }
            viewModel.seedNativeMetadataIfNeeded()
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
                    self.canMention = canMention && !viewModel.isLocalDocument
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
                async let ability = Self.serverAbility(viewModel, asking: canUpdate)
                let state = try await viewModel.client.collaborationYDocState(
                    documentID: viewModel.documentID, org: config.collaborationOrg)
                let answer = await ability
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
                continuation.yield(.state(state, config: config, ability: answer))
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
            case .state(let state, let config, let ability) = result
        else {
            route = .classic
            return
        }
        await activateFetchedState(
            state: state, config: config, ability: ability, viewModel: viewModel, request: request,
            account: account, canUpdate: canUpdate, fallbackToClassicOnInspectError: true)
    }

    private func activateFetchedState(
        state: Data, config: ServerConfig, ability: ServerAbilityAnswer?,
        viewModel: EditorViewModel, request: Int, account: UUID?, canUpdate: Bool,
        fallbackToClassicOnInspectError: Bool
    ) async {
        let session: NativeEditorSession
        do {
            session = try await NativeEditorSession.inspect(
                state: state, interlinkingOrigin: viewModel.client.serverOrigin)
        } catch {
            guard generation == request else { return }
            if fallbackToClassicOnInspectError {
                route = .classic
            } else {
                viewModel.seedNativeMetadataIfNeeded()
                route = .preservedUnavailable
            }
            return
        }
        guard !Task.isCancelled, generation == request, viewModel.signedInUser.userID == account else { return }
        // A document that is not fully projectable, or a reader, stays in PR01's
        // in-memory read-only view and never gains a replica or marker.
        let scope = account.map {
            ReplicaScope(
                serverOrigin: viewModel.client.serverOrigin, ownerUserID: $0, org: config.collaborationOrg,
                documentID: viewModel.documentID)
        }
        // A writer answer lifts a remembered denial on every route (review R2), the unowned one
        // included: the next headless commit and the live gate may trust the server again.
        if ability?.writer == true, let scope { viewModel.saveCoordinator.clearNativeReader(scope) }
        // A denial a headless media commit learned (review Z2d) is a reader answer here too.
        let denied = scope.map { viewModel.saveCoordinator.isNativeReader($0) } ?? false
        let verified = canUpdate && ability?.writer != false && !denied
        self.canUpdate = verified
        guard enabled, verified, session.canType, let account, let scope, mayType(viewModel) else {
            self.canMention = false
            viewModel.seedNativeMetadataIfNeeded()
            route = .native(session)
            return
        }
        session.close()
        let seeded = await seedReplica(
            state: state, scope: scope, viewModel: viewModel, request: request, account: account)
        guard let seeded else { return }
        viewModel.seedNativeMetadataIfNeeded()
        route = seeded
        if case .native(let session) = seeded {
            self.canMention = (ability?.mention ?? rowCanMention) && !viewModel.isLocalDocument
            startLive(session, scope: scope, config: config, viewModel: viewModel)
        }
    }

    /// Reconnect: merge the fetched raw state into the open durable owner.
    func refresh(viewModel: EditorViewModel, isOffline: Bool) async {
        guard isOpen, case .native(let session) = route, let scope = session.scope else { return }
        await integrateServerState(
            into: session, scope: scope, viewModel: viewModel, request: generation, isOffline: isOffline)
    }

    /// A sign-in change: close, then open again in a task the next close cancels.
    func reopen(viewModel: EditorViewModel, isOffline: Bool, canUpdate: Bool, canMention: Bool = false) {
        close()
        reopenTask = Task { [weak self] in
            await self?.open(viewModel: viewModel, isOffline: isOffline, canUpdate: canUpdate, canMention: canMention)
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

    /// Schedule the debounced native replica save if the active native surface is writable.
    func scheduleSave() {
        guard case .native(let session) = route, session.input != nil else { return }
        session.scheduleSave()
    }

    /// Updates the document title in native mode and schedules the debounced replica save.
    func updateTitle(_ text: String, viewModel: EditorViewModel) {
        guard case .native(let session) = route, session.input != nil else { return }
        viewModel.updateNativeTitle(text) { [weak self] in
            self?.scheduleSave()
        }
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

    /// Native "Keep my version" conflict resolution: flushes any debounced title/body edit into
    /// the held replica draft, then releases the conflict hold and pushes via
    /// `DocumentSaveCoordinator.resolveConflictKeepingLocal`.
    func resolveConflictKeepingMine(viewModel: EditorViewModel) {
        let coordinator = viewModel.saveCoordinator
        let documentID = viewModel.documentID
        guard let conflict = coordinator.conflict(for: documentID) else { return }
        if case .native(let session) = route, session.input != nil {
            if viewModel.hasPendingNativeTitleEdit { session.scheduleSave() }
            session.flushPendingSave()
        }
        guard
            coordinator.pendingSave(documentID: documentID) != nil
                || coordinator.storedDraft(documentID: documentID) != nil
        else {
            coordinator.clearResolvedConflict(documentID: documentID)
            return
        }
        viewModel.advanceNativeBaselineAfterConflict(serverUpdatedAt: conflict.serverUpdatedAt)
        coordinator.resolveConflictKeepingLocal(documentID: documentID)
    }

    /// Native "Keep the server version" conflict resolution: fetches the authoritative server state
    /// first (so offline/4xx/5xx failures leave local replica, draft, and conflict untouched),
    /// then closes the open replica session, discards local replica/draft/conflict, updates
    /// title/cache metadata, and reopens cleanly on the server Yjs state (or falls back to classic).
    func resolveConflictKeepingServer(
        viewModel: EditorViewModel, isOffline: Bool, canUpdate: Bool, canMention: Bool = false
    ) async {
        let coordinator = viewModel.saveCoordinator
        let documentID = viewModel.documentID
        guard coordinator.conflict(for: documentID) != nil else { return }
        if case .native(let session) = route, session.input != nil {
            if viewModel.hasPendingNativeTitleEdit { session.scheduleSave() }
            session.flushPendingSave()
        }
        viewModel.clearError()
        guard !viewModel.isLocalDocument else { return }
        let diagnosticsMarker = viewModel.diagnostics?.marker()
        let saveMarker = coordinator.saveMarker(documentID: documentID)
        let titleAtChoice = viewModel.title
        let discardedDraft = coordinator.storedDraft(documentID: documentID)
        let discardedSave = coordinator.pendingSave(documentID: documentID)
        let scope = coordinator.nativeOwnership(documentID: documentID).scope ?? discardedDraft?.replica?.scope
        let revisionAtChoice = try? scope.flatMap { try coordinator.replicaStore.manifest(for: $0)?.revision }
        let requestGeneration = generation
        do {
            let config = try await viewModel.client.serverConfig()
            let fetched = try await viewModel.client.formattedContent(documentID: documentID)
            let (formatted, leafNesting) = await viewModel.recoveringLeafNestingForNative(fetched)
            let resolvedState: (state: Data, ability: ServerAbilityAnswer?)?
            if enabled, config.usesCollaborationYDocServer {
                async let ability = Self.serverAbility(viewModel, asking: canUpdate)
                let state = try await viewModel.client.collaborationYDocState(
                    documentID: documentID, org: config.collaborationOrg)
                resolvedState = (state, await ability)
            } else {
                resolvedState = nil
            }
            guard !Task.isCancelled, generation == requestGeneration else { return }
            guard !coordinator.mayPredateSave(saveMarker) else {
                viewModel.recordNativeRefreshError(after: diagnosticsMarker)
                return
            }
            let currentHasPendingSave: Bool =
                if case .native(let session) = route { session.hasPendingSave } else { false }
            let currentRevision = try? scope.flatMap { try coordinator.replicaStore.manifest(for: $0)?.revision }
            guard !viewModel.hasPendingNativeTitleEdit,
                viewModel.title == titleAtChoice,
                !currentHasPendingSave,
                coordinator.pendingSave(documentID: documentID) == discardedSave,
                coordinator.storedDraft(documentID: documentID) == discardedDraft,
                currentRevision == revisionAtChoice
            else { return }
            close()
            if let closing {
                await closing.value
                guard !Task.isCancelled else { return }
            }
            coordinator.resolveConflictKeepingServer(documentID: documentID)
            if let resolvedState, let account = viewModel.signedInUser.userID {
                viewModel.applyResolvedServerMetadataForNative(
                    formatted: formatted, leafNesting: leafNesting, installClassicFallback: false)
                isOpen = true
                generation += 1
                self.rowCanMention = canMention
                await activateFetchedState(
                    state: resolvedState.state, config: config, ability: resolvedState.ability,
                    viewModel: viewModel, request: generation, account: account, canUpdate: canUpdate,
                    fallbackToClassicOnInspectError: false)
                await viewModel.loadChildren()
            } else {
                viewModel.applyResolvedServerMetadataForNative(
                    formatted: formatted, leafNesting: leafNesting, installClassicFallback: true)
                isOpen = true
                route = .classic
                await viewModel.loadChildren()
            }
        } catch let error as DocsAPIError where error == .notFound || error == .forbidden {
            guard generation == requestGeneration else { return }
            viewModel.recordNativeUnavailableError(after: diagnosticsMarker)
        } catch {
            guard generation == requestGeneration else { return }
            viewModel.recordNativeRefreshError(after: diagnosticsMarker)
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
        let scheduler = registry.scheduler(for: scope) { [weak viewModel] in
            NativeReplicaSaveScheduler(
                interval: viewModel?.autosaveInterval ?? .seconds(10),
                enqueue: { [weak viewModel] in
                    guard signedInUser.userID != nil else { return false }
                    let cached = contentCache.content(for: documentID)
                    let draft = coordinator.storedDraft(documentID: documentID)
                    let inputs =
                        viewModel?.nativeEnqueueInputs(
                            cached: cached, draft: draft, fallbackTitle: listTitle)
                        ?? (
                            title: draft?.title
                                ?? coordinator.knownServerTitle(documentID: documentID)
                                ?? cached?.title
                                ?? listTitle,
                            baseline: draft?.baseline
                                ?? cached.map {
                                    DraftBaseline(
                                        serverUpdatedAt: $0.serverUpdatedAt, markdown: $0.markdown, title: $0.title)
                                }
                        )
                    try coordinator.enqueueReplica(adapter: adapter, title: inputs.title, baseline: inputs.baseline)
                    viewModel?.markNativeTitleEnqueued(title: inputs.title)
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
        registry.installJournal(adapter, for: scope)
        session.enableTyping(persist: nil, scheduler: scheduler)
        // Edits an earlier process journaled but never handed over (it ended
        // inside the debounce) have no draft, so no replay pass knows them.
        if coordinator.pendingSave(documentID: documentID) == nil,
            (try? coordinator.replicaStore.manifest(for: scope))?.outbox.isEmpty == false
        {
            scheduler.schedule()
        }
        // A native upload held back while nothing could write the document may land now.
        coordinator.replayNativeAttachments(scope: scope)
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
            let ability = canUpdate ? await Self.serverAbility(viewModel) : nil
            guard isCurrent() else { return }
            if ability?.writer == false {
                // The row was stale: every surface of the scope stops writing
                // (a key typed meanwhile becomes a recovery entry) and no socket opens.
                becomeReader(scope, coordinator: viewModel.saveCoordinator)
            } else if ability?.writer == true {
                // The server says writer: an earlier remembered denial no longer holds.
                viewModel.saveCoordinator.clearNativeReader(scope)
                if let serverMention = ability?.mention {
                    self.canMention = serverMention && !viewModel.isLocalDocument
                }
            } else if viewModel.saveCoordinator.isNativeReader(scope) {
                // No answer and a headless media commit's denial stands (review Z2d): this open
                // is a reader too, so nothing dials a socket for it. It recovers on reopen.
                becomeReader(scope, coordinator: viewModel.saveCoordinator)
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
    /// explicit reader answer counts: a failed request (offline, a 5xx, a
    /// timeout, a captive portal) keeps the row, and the server still
    /// refuses a real reader's save. A row that says reader is never asked.
    private static func serverSaysReader(_ viewModel: EditorViewModel, asking: Bool) async -> Bool {
        await serverAbility(viewModel, asking: asking)?.writer == false
    }

    /// `serverAbility`, asked only when the row says writer: nil when it was not asked.
    private static func serverAbility(_ viewModel: EditorViewModel, asking: Bool) async -> ServerAbilityAnswer? {
        guard asking else { return nil }
        return await serverAbility(viewModel)
    }

    /// The server's `abilities.update` and `abilities.mention` for the document:
    /// nil when it did not answer (offline, a 5xx, a timeout, a missing route,
    /// an unreadable body, an expired session). A 403, an API 404, any other
    /// answer about the document and an answer naming another document are a
    /// reader answer (review Z2c, R1, as the headless gate reads them).
    private static func serverAbility(_ viewModel: EditorViewModel) async -> ServerAbilityAnswer {
        do {
            let document = try await viewModel.client.document(documentID: viewModel.documentID)
            let writer = DocumentAbilityAnswer.classify(document, asked: viewModel.documentID).writer == true
            return ServerAbilityAnswer(
                writer: writer,
                mention: writer ? document.abilities.mention : false)
        } catch {
            let reader = DocumentAbilityAnswer.classify(error) == .reader
            return ServerAbilityAnswer(
                writer: reader ? false : nil,
                mention: reader ? false : nil)
        }
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
            // A denial a headless media commit learned (review Z2c) keeps a reader off the socket,
            // and a surface that is not writable (its journal removed by that denial, review Z2d)
            // never dials one, even after the denial is lifted: it recovers on reopen.
            !viewModel.saveCoordinator.isNativeReader(scope),
            registry.isWritable(scope),
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
            becameReader: { [weak self, weak coordinator = viewModel.saveCoordinator] in
                guard let coordinator else { return }
                self?.becomeReader(scope, coordinator: coordinator)
            },
            localState: { [weak collaboration] in collaboration?.localAwarenessState })
        session.showAwareness(binding.awareness)
    }

    /// The server says this account may only read now: every surface of the
    /// scope stops writing (a key typed meanwhile becomes a recovery entry,
    /// what is journaled stays for HTTP) and no socket stays open.
    private func becomeReader(_ scope: ReplicaScope, coordinator: DocumentSaveCoordinator) {
        canUpdate = false
        canMention = false
        // No headless media commit trusts a cached `update: true` for this scope again (review Y1).
        coordinator.noteNativeReader(scope)
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
        canUpdate = false
        canMention = false
        rowCanMention = false
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
