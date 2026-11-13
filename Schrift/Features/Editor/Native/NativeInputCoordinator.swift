import Observation
import UIKit
import UniformTypeIdentifiers

/// Ordinary input is intercepted before UIKit changes storage; returning false
/// prevents UIKit from applying the same edit a second time.
///
/// **Option A (PR08b).** The replica lives in `DocumentReplicaSession`, off the
/// main actor. Same-block typing is predicted: shown at once
/// (`NativeTextSurface.predict`) and posted, then journaled a few milliseconds
/// later in order; its echo confirms it. Every other command is a barrier,
/// shown when its result arrives; keys typed meanwhile are held as intents
/// and replayed. A barrier that meets a change this surface had not seen is
/// retried once. A failed append, or an invalidated epoch, rolls the display
/// back to canonical and turns the dropped text into a recovery entry.
///
/// Marked text (IME) is different: UIKit owns the provisional range in storage
/// for the whole composition, so `NativeCompositionSession` freezes the surface
/// and commits once. Offset-based commands are refused while it is active,
/// because document-wide UIKit offsets are stale until reconciliation.
@MainActor @Observable
final class NativeInputCoordinator: NSObject, UITextViewDelegate {
    /// How many predicted keystrokes may wait for their journal append; more
    /// keys are held as intents.
    static let maxPendingTyping = 32
    /// How many held keys a surface keeps; more show `native_editor_input_busy`.
    static let maxIntents = 64

    private let replica: DocumentReplicaSession
    let surfaceID: UUID
    private let surface: NativeTextSurface
    private weak var view: NativeTextView?
    let composition: NativeCompositionSession
    /// The revision the canonical display shows (the last delivery's).
    private(set) var canonicalRevision: UInt64
    /// Mirrored from deliveries: authoring stopped (a failed append, an
    /// unjournaled transaction or a full mailbox) or the session closed.
    private(set) var isFrozen = false
    private(set) var isDetached = false
    /// The surface's epoch in the session: commands of an older one are dropped.
    private var epoch: UInt64 = 0
    /// Called once a command's bytes are journaled (the save scheduler).
    @ObservationIgnored var onJournaled: () -> Void = {}
    /// Called when authoring stops for a storage reason.
    @ObservationIgnored var onFrozen: () -> Void = {}

    /// The barrier in flight: displayed on its result.
    private struct Barrier {
        enum Placement {
            /// The engine's caret.
            case caret
            /// This selection, unchanged.
            case keeping(NSRange)
            /// The same offsets in a block that moved.
            case remapping(blockID: String, offset: Int, length: Int)
            /// A caret at this document offset (a barrier replacement).
            case at(Int)
            /// The selection the history step restored.
            case history
        }
        let id: UUID
        let refusal: L10nKey?
        let placement: Placement
        /// Re-derives the action from the current display once, for `.stale`.
        let retry: (() -> Bool)?
        /// The selection the action was taken from, for an action whose retry
        /// reads the selection: the retry runs against it (moved through what
        /// was shown since), not one made meanwhile. Nil for an action on its
        /// own target (a history step, a block's props, a mapped range).
        let origin: BlockRange?
    }
    @ObservationIgnored private var barrier: Barrier?
    /// What the deliveries since the barrier was posted showed: a retry and a
    /// selection the user made meanwhile are mapped through it.
    @ObservationIgnored private var barrierShown: [Shown] = []
    /// Deliveries that arrived while a composition owned the view, in order.
    @ObservationIgnored private var queued: [ReplicaDelivery] = []
    /// Stale answers wait for the end of their drain, so a retry runs on the
    /// display (and base revision) every queued delivery has reached.
    @ObservationIgnored private var staleAfterDrain: [UUID] = []
    /// A storage failure while a composition owned the view, applied after it.
    @ObservationIgnored private var failsAfterComposition = false
    /// Resyncs asked for whose reset has not arrived (PR08c). Until it does,
    /// arriving deliveries lose their patches (the reset shows them), nothing
    /// is applied, and keys are held.
    @ObservationIgnored private var resyncsAsked = 0
    /// A reset is on its way or queued: keys wait for it.
    private var awaitsReset: Bool { resyncsAsked > 0 || queued.contains { $0.resync != nil } }
    /// Marked text owns the view: storage and its offsets are UIKit's.
    private var compositionOwnsView: Bool { composition.isActive || view?.markedTextRange != nil }
    /// A selection the user made while the barrier was in flight, and how many
    /// of `barrierShown`'s deliveries it had already seen: it wins over wherever
    /// the barrier would put the selection.
    @ObservationIgnored private var userSelection: (anchors: BlockRange, seen: Int)?
    /// What one delivery showed: text deltas per block, and the blocks it
    /// rebuilt or removed (offsets there cannot be mapped), or a reset.
    private struct Shown {
        var deltas: [(blockID: String, deltas: [TextDelta])]
        var replaced: Set<String>
        /// The rebuilt blocks whose text changed.
        var retexted: Set<String> = []
        var reset: Bool
    }
    private typealias BlockRange = (start: (String, Int), end: (String, Int))
    private enum Intent {
        case insert(String)
        case deleteBackward
    }
    @ObservationIgnored private var intents: [Intent] = []
    /// Blocks whose predictions the session refused: typing there is a barrier.
    @ObservationIgnored private var barrierOnly: Set<String> = []
    /// Block-menu availability by (block, structural revision), from the session.
    private var availability: [String: (revision: UInt64, actions: [NativeBlockAction])] = [:]
    @ObservationIgnored private var requestedAvailability: Set<String> = []
    /// Bumped by every delivery with a non-text change: block-menu answers are
    /// keyed by it, since typing never changes what the menu offers.
    @ObservationIgnored private var structureRevision: UInt64 = 0
    /// Copies waiting for their lossless payload.
    @ObservationIgnored private var pendingCopies: [UUID: PendingCopy] = [:]
    /// The last command posted (a cut's delete).
    @ObservationIgnored private var lastCommandID: UUID?
    /// Tests: false once any command posted since `resetOutcome` was refused,
    /// went stale twice, was invalidated or failed.
    @ObservationIgnored private(set) var lastOutcome: Bool?
    /// Directed relative selection: published on every UIKit change and
    /// restored after each peer patch or rebuild.
    @ObservationIgnored let selection: NativeSelectionCoordinator
    /// The general pasteboard; tests use a uniquely named one.
    @ObservationIgnored var pasteboard: UIPasteboard = .general
    private(set) var noticeKey: L10nKey?
    /// What the formatting bar shows: the marks every selected character
    /// carries, or at a caret the marks typing there would carry.
    private(set) var activeMarks: [TextMark] = []
    /// The slash command at the caret (the text after "/" in a paragraph that
    /// is only that command), which `NativeEditorView` shows the menu for.
    private(set) var slashMenuQuery: String?
    /// The "/query" token the menu's choice removes: from the paragraph's
    /// start to the caret. Text after the caret is the user's and stays.
    @ObservationIgnored private var slashToken: Range<Int>?
    /// A toggle at a caret (ProseMirror's stored marks): the marks the next
    /// typed text carries. Nothing is written until text is typed, and a
    /// selection change drops it.
    @ObservationIgnored private var pendingTypingMarks: [TextMark]?
    /// The active keyboard's language; a seam so tests can stand in for a
    /// composing keyboard the simulator may not have.
    @ObservationIgnored var inputLanguage: () -> String? = { nil }
    /// A single character a composing keyboard was allowed to write itself.
    /// It either starts marked text, arrives through `insertText`, or is
    /// written straight to storage (space, digits, punctuation), which
    /// `textViewDidChange` turns into an ordinary command.
    @ObservationIgnored private var directInsertion: (range: NSRange, text: String)?
    /// The last caret UIKit reported, so a caret moving into folded content
    /// keeps its direction past it.
    @ObservationIgnored private var lastCaret: Int?
    /// The session's collaborative undo history (PR07b), destroyed with it.
    @ObservationIgnored let history: NativeUndoManager
    /// Where the last typing command left the caret. Typing anywhere else (a
    /// tap, an arrow key) starts a new undo step.
    @ObservationIgnored private var typingCaret: NSRange?

    init(
        replica: DocumentReplicaSession, surfaceID: UUID, revision: UInt64, surface: NativeTextSurface,
        view: NativeTextView, recoveries: [ProvisionalRecovery] = [], hasRecoveryStore: Bool = false
    ) {
        self.replica = replica
        self.surfaceID = surfaceID
        self.canonicalRevision = revision
        self.surface = surface
        self.view = view
        let mailbox = replica.mailbox
        var stop: () -> Void = {}
        var base: () -> UInt64 = { revision }
        var canAuthor: () -> Bool = { true }
        var currentEpoch: () -> UInt64 = { 0 }
        self.composition = NativeCompositionSession(
            surface: surface, view: view,
            port: NativeCompositionSession.Port(
                begin: { blockID, range in
                    let posted = mailbox.post(
                        .compositionBegin(
                            surfaceID: surfaceID, epoch: currentEpoch(), baseRevision: base(), blockID: blockID,
                            range: range))
                    if !posted { stop() }
                    return posted
                },
                cancel: { if !mailbox.post(.compositionCancel(surfaceID: surfaceID)) { stop() } },
                writeRecoveries: { mailbox.post(.writeProvisional($0)) }),
            recoveries: recoveries, hasRecoveryStore: hasRecoveryStore, canAuthor: { canAuthor() })
        var postSelection: (UInt64, EditorSelection?) -> Void = { _, _ in }
        self.selection = NativeSelectionCoordinator(surface: surface, view: view) { postSelection($0, $1) }
        self.history = NativeUndoManager()
        super.init()
        stop = { [weak self] in self?.stopAfterStorageFailure() }
        currentEpoch = { [weak self] in self?.epoch ?? 0 }
        base = { [weak self] in self?.canonicalRevision ?? revision }
        canAuthor = { [weak self] in self.map { !$0.isFrozen && !$0.isDetached } ?? false }
        postSelection = { [weak self] seq, selection in
            guard let self else { return }
            _ = self.post(
                .select(surfaceID: surfaceID, seq: seq, baseRevision: self.canonicalRevision, selection))
        }
        history.system.input = self
        surface.surfaceID = surfaceID
        surface.onPatchApplied = { [weak self] patch in
            // The editor's own commands place their caret themselves.
            if patch.nativeCommand?.surfaceID != surfaceID { self?.needsRestore = true }
        }
        // A fold sends no selection change; the caret must not stay in what it hid.
        let relayout = surface.onFoldChange
        surface.onFoldChange = { [weak self] in
            relayout?()
            // A peer patch may have edited storage just before this fold callback.
            self?.asOneKeyboardChange { self?.keepSelectionVisible() }
        }
        inputLanguage = { [weak view] in view?.textInputMode?.primaryLanguage }
        view.delegate = self
        view.inputCoordinator = self
        view.isEditable = true
        view.allowsEditingTextAttributes = false
        refreshSelectionMarks()
    }

    // MARK: - Table cells (PR11a)

    /// Where a table key moves the active cell (BlockNote 0.56 `TableExtension`).
    enum TableMove {
        /// Tab: the next cell in row order.
        case next
        /// Shift-Tab: the previous cell.
        case previous
        /// Return: the cell below.
        case below
        /// Escape: back to the document (a CellSelection is cleared first).
        case exit
        /// ⌘Return (PR11c): back to the document, as Done.
        case done
    }

    /// What the table editor reads before the text view does (PR11c): a
    /// hardware arrow (with Shift, `extend`), Backspace/Delete, typing, and
    /// the clipboard. Returns whether the editor handled it (a CellSelection,
    /// a move across a cell edge, cells to paste); false lets the text view go on.
    enum TableKey: Equatable {
        enum Direction: Equatable {
            case left, right, up, down
        }
        case arrow(Direction, extend: Bool)
        case delete
        case typing
        case copy, cut, paste
    }

    @ObservationIgnored var tableKey: ((TableKey) -> Bool)?

    /// Where `showCell` leaves the caret.
    enum CellCaret {
        /// The cell's text selected (`goToNextCell`); a caret at the end of a
        /// multi-paragraph cell.
        case selectAll
        case start
        case end
    }

    /// Set on a table surface's coordinator: Tab, Shift-Tab, Return and Escape
    /// move between cells instead of nesting or splitting blocks, and
    /// Backspace at a paragraph's start does nothing (BlockNote keeps the
    /// cell). Returns whether the key was handled.
    @ObservationIgnored var tableMove: ((TableMove) -> Bool)?
    /// A column surface (PR12a): Escape returns to the document.
    @ObservationIgnored var onExit: (() -> Void)?

    /// Shows the cell made of `blockIDs` (a table surface) and selects its
    /// text, as prosemirror-tables' `goToNextCell` does; a cell of several
    /// paragraphs gets a caret at its end. View state only.
    func showCell(_ blockIDs: [String], caret: CellCaret = .selectAll) {
        guard let view, let first = blockIDs.first, let last = blockIDs.last,
            let start = surface.rangeIndex.position(for: first), let end = surface.rangeIndex.position(for: last)
        else { return }
        asOneKeyboardChange {
            surface.setFocus(Set(blockIDs))
            let lower = surface.rangeIndex.entries[start].textRange.location
            let upper = NSMaxRange(surface.rangeIndex.entries[end].textRange)
            let range: NSRange =
                switch caret {
                case .start: NSRange(location: lower, length: 0)
                case .end: NSRange(location: upper, length: 0)
                case .selectAll:
                    start == end
                        ? NSRange(location: lower, length: upper - lower) : NSRange(location: upper, length: 0)
                }
            lastCaret = range.location
            if view.selectedRange != range { selection.place(range) }
        }
        refreshSelectionMarks()
    }

    /// The table editor refused something before posting it (PR11c): its notice.
    func refuse(_ notice: L10nKey) { noticeKey = notice }

    /// A table structure command from the table editor (PR11b): one barrier
    /// on the table block, journaled before it is shown; the caret keeps its
    /// offsets in its paragraph (remapped), and the editor re-reads the grid
    /// when the result shows.
    @discardableResult
    func applyTable(_ tableID: String, _ command: BlockNoteTableCommand) -> Bool {
        guard let view, view.isEditable, !isFrozen, !isDetached, !compositionOwnsView else { return false }
        let selection = view.selectedRange
        let remapping = surface.rangeIndex.entry(atUTF16: selection.location).map {
            (blockID: $0.blockID, offset: max(0, selection.location - $0.textRange.location), length: selection.length)
        }
        return applyStructural(
            tableID, .table(command), refusal: .native_editor_input_unavailable, remapping: remapping)
    }

    /// Shift-Return in a table cell (PR11b): one hard break at the caret
    /// (BlockNote's `setHardBreak`), a barrier like Return in prose.
    @discardableResult
    func insertLineBreak() -> Bool {
        guard tableMove != nil, let view, view.isEditable, !isFrozen, !isDetached, !compositionOwnsView else {
            return false
        }
        let selection = view.selectedRange
        guard selection.length == 0, let entry = surface.rangeIndex.entry(atUTF16: selection.location),
            selection.location <= NSMaxRange(entry.textRange)
        else {
            noticeKey = .native_editor_input_unavailable
            return false
        }
        return applyStructural(
            entry.blockID, .lineBreak(offset: selection.location - entry.textRange.location),
            refusal: .native_editor_input_unavailable,
            retry: again { [weak self] in self?.insertLineBreak() ?? false }, readsSelection: true)
    }

    /// Back from a table (PR11a): the caret at the start of the block after
    /// it (the table itself is one atomic character), and the keyboard up.
    func focus(after blockID: String) {
        guard let view, let position = surface.rangeIndex.position(for: blockID) else { return }
        if surface.rangeIndex.entries.indices.contains(position + 1) {
            let caret = NSRange(location: surface.rangeIndex.entries[position + 1].textRange.location, length: 0)
            asOneKeyboardChange { selection.place(caret) }
        }
        view.becomeFirstResponder()
    }

    /// A delivered patch that was not this surface's own command: the selection
    /// is restored from the session's endpoints after the delivery.
    @ObservationIgnored private var needsRestore = false

    // MARK: - Deliveries (PR08b)

    /// The one composition rule (PR08b): while marked text owns the view,
    /// whole deliveries wait unapplied, results included; its commit or cancel
    /// applies them in order.
    ///
    /// **Bounded delivery (PR08c).** A surface with
    /// `DocumentReplicaSession.deliveryBound` deliveries waiting (in the
    /// session's stream, or here behind marked text) asks for a resync: what
    /// arrives until its reset keeps only its answers, and the reset shows the
    /// canonical state under a new epoch. Keys typed meanwhile are held.
    func apply(_ delivery: ReplicaDelivery) {
        if case .reset? = delivery.resync {
            resyncsAsked = max(0, resyncsAsked - 1)
            // Everything queued before it is shown by it.
            queued = queued.compactMap { $0.withoutPatches() }
            queued.append(delivery)
        } else if resyncsAsked > 0 {
            if let answers = delivery.withoutPatches() { queued.append(answers) }
        } else {
            queued.append(delivery)
        }
        guard !compositionOwnsView else {
            let sinceReset = queued.count - (queued.lastIndex { $0.resync != nil }.map { $0 + 1 } ?? 0)
            if resyncsAsked == 0, sinceReset >= DocumentReplicaSession.deliveryBound { requestResync() }
            return
        }
        drain()
    }

    /// The session's resync marker (or marked text holding the bound): ask
    /// for the reset. A post that fails froze authoring instead.
    func requestResync() {
        if post(.resync(surfaceID: surfaceID)) { resyncsAsked += 1 }
    }

    /// Every queued patch and result first; then what acts on the display
    /// they reached: a failure that waited, stale retries, held keys. Nothing
    /// is applied while a reset asked for is still on its way.
    private func drain() {
        guard resyncsAsked == 0 else { return }
        let deliveries = queued
        queued = []
        for delivery in deliveries { applyNow(delivery) }
        if failsAfterComposition {
            failsAfterComposition = false
            stopAfterStorageFailure()
        }
        let stale = staleAfterDrain
        staleAfterDrain = []
        asOneKeyboardChange(if: !stale.isEmpty) {
            for id in stale { handle(.stale(commandID: id), selection: nil) }
        }
        refreshSelectionMarks()
        replayIntents()
    }

    /// Marked text ended: storage is the model's again, and what waited applies.
    private func releaseComposition() {
        surface.holdForComposition(false)
        drain()
        keepSelectionVisible()
    }

    /// Applies one delivery: its patches in order, then its result, as one
    /// keyboard change.
    private func applyNow(_ delivery: ReplicaDelivery) {
        // Only what can move storage or the caret is a keyboard text change:
        // this surface's own keystroke echoes and drain markers are not.
        let changes =
            delivery.events.contains { event in
                guard case .patch(let patch, _) = event else { return true }
                guard let stamp = patch.nativeCommand, stamp.surfaceID == surfaceID else { return true }
                return !surface.predictions.contains { $0.commandID == stamp.commandID }
            }
            || delivery.result.map { result in
                if case .applied(let id, _, _) = result { return barrier?.id == id }
                return true
            } ?? false
        asOneKeyboardChange(if: changes) {
            needsRestore = false
            surface.resetShownDeltas()
            let shownSelection = blockSelection()
            for event in delivery.events {
                switch event {
                case .patch(let patch, let settled):
                    if patch.changes.contains(where: { if case .text = $0 { false } else { true } })
                        || patch.nativeCommand?.surfaceID != surfaceID
                    {
                        structureRevision &+= 1
                    }
                    surface.applyPatch(patch, settled: settled)
                case .compositionDeferred:
                    // The engine's own deferral: the queue already held this delivery.
                    break
                }
            }
            if barrier != nil {
                barrierShown.append(
                    Shown(
                        deltas: surface.shownDeltas, replaced: surface.shownReplaced,
                        retexted: surface.shownRetexted, reset: surface.shownReset))
            }
            canonicalRevision = delivery.revision
            history.mirror(canUndo: delivery.state.canUndo, canRedo: delivery.state.canRedo)
            if case .reset(let epoch)? = delivery.resync {
                self.epoch = epoch
                // Every key posted before the ask was answered before the
                // reset and later ones were held, so normally nothing is
                // pending; anything that is becomes a recovery entry.
                let dropped = surface.rollback()
                for prediction in dropped { composition.finish(prediction.commandID) }
                if let first = dropped.first {
                    composition.recover(dropped.map(\.text).joined(), blockID: first.blockID)
                }
            }
            if case .stale(let id)? = delivery.result {
                staleAfterDrain.append(id)
            } else if let result = delivery.result {
                let shownBefore = (surface.shownDeltas.count, surface.shownReplaced, surface.shownRetexted)
                handle(result, selection: delivery.selection)
                // A rollback or a reconciliation the result caused is shown
                // too: a barrier still in flight maps through it.
                if barrier != nil, surface.shownDeltas.count > shownBefore.0 || surface.shownReplaced != shownBefore.1 {
                    barrierShown.append(
                        Shown(
                            deltas: Array(surface.shownDeltas[shownBefore.0...]),
                            replaced: surface.shownReplaced.subtracting(shownBefore.1),
                            retexted: surface.shownRetexted.subtracting(shownBefore.2), reset: false))
                }
            } else if needsRestore {
                if delivery.selection?.seq == selection.seq {
                    selection.restore(from: delivery.selection)
                } else if let shownSelection {
                    // A newer capture is still in flight: the session's endpoints
                    // are for an older one. Map the view's own range instead.
                    follow(shownSelection)
                }
                // A restore may land in content this patch folded away.
                keepSelectionVisible()
            }
            needsRestore = false
            if delivery.state.detached { isDetached = true }
            if delivery.state.frozen, !isFrozen { stopAfterStorageFailure() }
        }
        if let answer = delivery.availability {
            availability[answer.blockID] = (structureRevision, answer.actions)
            requestedAvailability.remove(answer.blockID)
        }
        if let clipboard = delivery.clipboard, pendingCopies[clipboard.requestID] != nil {
            pendingCopies[clipboard.requestID]?.payload = .some(clipboard.payload)
            flushCopies()
        }
        refreshSelectionMarks()
    }

    /// A block-relative point as a document offset, clamped to its block's text.
    private func resolve(_ point: (String, Int)) -> Int? {
        guard let entry = surface.rangeIndex.entry(for: point.0) else { return nil }
        return entry.textRange.location + min(max(0, point.1), entry.textRange.length)
    }

    /// The view's selection as block-relative endpoints.
    private func blockSelection() -> BlockRange? {
        guard let view, view.markedTextRange == nil else { return nil }
        return blockRange(view.selectedRange)
    }

    /// A document range as block-relative endpoints.
    private func blockRange(_ range: NSRange) -> BlockRange? {
        let index = surface.rangeIndex
        guard let start = index.textPosition(atUTF16: range.location),
            let end = index.textPosition(atUTF16: NSMaxRange(range), isUpperBound: range.length > 0)
        else { return nil }
        return (
            (index.entries[start.position].blockID, start.offset), (index.entries[end.position].blockID, end.offset)
        )
    }

    /// Moves the view's selection through the text this delivery showed.
    private func follow(_ shown: BlockRange) {
        let delivery = Shown(deltas: surface.shownDeltas, replaced: [], reset: false)
        guard let view, let range = map(shown, through: [delivery][...]) else { return }
        if range != view.selectedRange {
            selection.place(range)
        } else if surface.shownReplaced.contains(shown.start.0) || surface.shownReplaced.contains(shown.end.0) {
            // The session's capture did not survive the rebuild of its block.
            selection.publish(range)
        }
    }

    /// Block-relative endpoints moved through what deliveries showed, as a
    /// document range; nil when an endpoint's block was rebuilt, removed or
    /// reset, or a change overlapped the inside of a range in one block. A
    /// non-empty range keeps a concurrent insertion at either end outside it
    /// (as `NativeSelectionCoordinator.publish` captures it); a caret stays
    /// before one.
    private func map(_ range: BlockRange, through shown: ArraySlice<Shown>) -> NSRange? {
        var start = range.start
        var end = range.end
        let empty = start == end
        for delivery in shown {
            // A block rebuilt with the same text keeps its offsets.
            let rewritten = delivery.replaced.intersection(delivery.retexted)
            guard !delivery.reset, !rewritten.contains(start.0), !rewritten.contains(end.0) else { return nil }
            for applied in delivery.deltas {
                if !empty, start.0 == end.0, applied.blockID == start.0 {
                    guard let moved = TextDelta.rebase(range: start.1..<end.1, assoc: -1, through: applied.deltas)
                    else { return nil }
                    start.1 = moved.lowerBound
                    end.1 = moved.upperBound
                    continue
                }
                if applied.blockID == start.0 {
                    guard
                        let moved = TextDelta.rebase(
                            range: start.1..<start.1, assoc: empty ? -1 : 1, through: applied.deltas)
                    else { return nil }
                    start.1 = moved.lowerBound
                }
                if empty {
                    end = start
                } else if applied.blockID == end.0 {
                    guard let moved = TextDelta.rebase(range: end.1..<end.1, assoc: -1, through: applied.deltas)
                    else { return nil }
                    end.1 = moved.lowerBound
                }
            }
        }
        guard let lower = resolve(start), let upper = resolve(end), upper >= lower else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }

    /// The one rule at every barrier end: a selection the user made while it
    /// was in flight, moved through what was shown since, wins over wherever
    /// the barrier would put the selection, and held keys replay there. A
    /// block the barrier's own echo rebuilt keeps the user's offsets only when
    /// its text is unchanged. Clears the user's selection; true when placed.
    @discardableResult
    private func endBarrierSelection(ownEcho: Bool) -> Bool {
        defer { userSelection = nil }
        guard let user = userSelection else { return false }
        var since = barrierShown[min(user.seen, barrierShown.count)...]
        if ownEcho, let last = since.indices.last {
            since[last].replaced = since[last].replaced.intersection(since[last].retexted)
        }
        guard let range = map(user.anchors, through: since) else { return false }
        show(range)
        return true
    }

    /// Shows a selection and captures it again even when the view's range did
    /// not move: the session's capture may not have survived what was shown.
    private func show(_ range: NSRange) {
        if range != view?.selectedRange { selection.place(range) } else { selection.publish(range) }
    }

    /// `range`, posted with the barrier in flight, in the current display.
    private func mapThroughBarrier(_ range: BlockRange, from seen: Int = 0) -> NSRange? {
        map(range, through: barrierShown[min(seen, barrierShown.count)...])
    }

    private func handle(_ result: ReplicaResult, selection resolved: ReplicaSelection?) {
        switch result {
        case .applied(let id, let caret, let journaled):
            if journaled { onJournaled() }
            surface.confirm(id)
            settleCopies(after: id, applied: true)
            guard let barrier, barrier.id == id else { return }
            self.barrier = nil
            endUndoStep()
            noticeKey = nil
            if endBarrierSelection(ownEcho: true) { return }
            switch barrier.placement {
            case .caret:
                if let caret, let entry = surface.rangeIndex.entry(for: caret.blockID) {
                    selection.place(
                        NSRange(
                            location: entry.textRange.location + min(caret.offset, entry.textRange.length), length: 0))
                }
            case .keeping(let range):
                selection.place(range)
            case .remapping(let blockID, let offset, let length):
                if let entry = surface.rangeIndex.entry(for: blockID) {
                    let text = entry.textRange
                    let location = text.location + min(max(0, offset), text.length)
                    selection.place(NSRange(location: location, length: min(length, NSMaxRange(text) - location)))
                }
            case .at(let location):
                typingCaret = NSRange(location: location, length: 0)
                selection.place(NSRange(location: min(location, surface.storage.length), length: 0))
            case .history:
                guard journaled else {
                    lastOutcome = false
                    return
                }
                // A step whose patch changed nothing on screen still moves the caret.
                selection.restore(from: resolved)
                keepSelectionVisible()
                pendingTypingMarks = nil
            }
            noticeKey = nil
        case .refused(let id, let error):
            settleCopies(after: id, applied: false)
            guard let barrier, barrier.id == id else { return }
            self.barrier = nil
            endBarrierSelection(ownEcho: false)
            endUndoStep()
            lastOutcome = false
            if error == .payloadTooLarge {
                noticeKey = .native_editor_paste_too_large
            } else if error != .unsupportedNativeInput {
                noticeKey = .native_editor_input_unavailable
            } else if let refusal = barrier.refusal {
                noticeKey = refusal
            }
        case .stale(let id):
            guard let barrier, barrier.id == id else {
                settleCopies(after: id, applied: false)
                return
            }
            self.barrier = nil
            // A selection the user made meanwhile carries over to the retry.
            let carried = userSelection.flatMap { mapThroughBarrier($0.anchors, from: $0.seen) }
            userSelection = nil
            // Once, against the display that now includes what it missed, and
            // from the selection the action was taken at. When that selection
            // cannot be found any more, nothing is retried.
            let origin = barrier.origin.map { mapThroughBarrier($0) }
            var retried = false
            if origin != .some(nil) {
                if let origin = origin ?? nil, origin != view?.selectedRange { selection.place(origin) }
                retried = barrier.retry?() == true
            }
            if let carried {
                // The view shows the user's selection; the retry keeps it as theirs.
                if self.barrier != nil { userSelection = blockRange(carried).map { ($0, 0) } }
                show(carried)
            }
            if retried, let next = lastCommandID, next != id {
                // A cut's copy follows its retried delete.
                for (copy, pending) in pendingCopies where pending.after == id { pendingCopies[copy]?.after = next }
            } else {
                settleCopies(after: id, applied: false)
                lastOutcome = false
                if self.barrier == nil, noticeKey == nil { noticeKey = .native_editor_input_unavailable }
            }
        case .invalidated(let epoch, let id):
            settleCopies(after: id, applied: false)
            if let predicted = surface.predictions.first(where: { $0.commandID == id }) {
                barrierOnly.insert(predicted.blockID)
            }
            self.epoch = epoch
            lastOutcome = false
            rollBack()
        case .failed:
            barrier = nil
            userSelection = nil
            lastOutcome = false
            stopAfterStorageFailure()
        case .composition(let id, let result):
            if let id { composition.finish(id) }
            switch result {
            case .committed:
                onJournaled()
                if let id { surface.confirm(id) }
            case .failed:
                lastOutcome = false
                stopAfterStorageFailure()
            case .orphaned, .cancelled:
                // An orphaned commit's epoch already ended: its rollback keeps the text.
                break
            }
            endUndoStep()
        }
    }

    /// Every pending prediction and held key is dropped from the display and
    /// kept as one recovery entry the user can insert again.
    private func rollBack() {
        let dropped = surface.rollback()
        // A dropped commit's text becomes the recovery entry below.
        for prediction in dropped { composition.finish(prediction.commandID) }
        var text = dropped.map(\.text).joined()
        for case .insert(let typed) in intents { text += typed }
        intents = []
        typingCaret = nil
        // Held keys with no prediction behind them are kept too, at the caret's block.
        if let block = dropped.first?.blockID ?? blockSelection()?.start.0 ?? surface.blocks.first?.id {
            composition.recover(text, blockID: block)
        }
        if let view {
            selection.place(NSRange(location: min(view.selectedRange.location, surface.storage.length), length: 0))
        }
    }

    /// Something is in flight that the next key must wait for (a resolved
    /// composition's own delivery included: held keys go after its text).
    private var isBusy: Bool {
        barrier != nil || surface.expectsInvalidation
            || surface.predictions.count >= Self.maxPendingTyping || awaitsReset
    }

    /// True while a command, a held key, a composition result or a reset is in flight.
    var hasInFlightWork: Bool {
        barrier != nil || hasUnansweredPrediction || !intents.isEmpty || !pendingCopies.isEmpty || awaitsReset
    }

    /// A prediction whose answer has not arrived (one queued behind a
    /// composition has: it waits for the user, not the session).
    private var hasUnansweredPrediction: Bool {
        // An invalidation or a failure answers every prediction of its epoch.
        guard
            !queued.contains(where: {
                switch $0.result {
                case .invalidated?, .failed?: true
                default: false
                }
            })
        else { return false }
        let answered = Set(
            queued.compactMap { delivery -> UUID? in
                switch delivery.result {
                case .applied(let id, _, _)?, .refused(let id, _)?, .stale(let id)?, .invalidated(_, let id)?,
                    .failed(let id)?, .composition(let id?, _)?:
                    id
                case .composition(nil, _)?, nil: nil
                }
            })
        return surface.predictions.contains { !answered.contains($0.commandID) }
    }

    private func replayIntents() {
        // Held keys wait for marked text too: they replay after it resolves.
        while !isBusy, !compositionOwnsView, !intents.isEmpty {
            switch intents.removeFirst() {
            case .insert(let text): typeKey(text)
            case .deleteBackward: deleteKey()
            }
        }
    }

    private func hold(_ intent: Intent) {
        guard intents.count < Self.maxIntents else {
            noticeKey = .native_editor_input_busy
            return
        }
        intents.append(intent)
    }

    /// Tests: forget earlier outcomes before an action.
    func resetOutcome() { lastOutcome = nil }

    /// Every message goes through the bounded mailbox; a full one stops
    /// authoring rather than lose input silently.
    private func post(_ message: ReplicaMessage) -> Bool {
        guard !isDetached else { return false }
        guard replica.mailbox.post(message) else {
            stopAfterStorageFailure()
            return false
        }
        return true
    }

    // MARK: - Key input hooks (NativeTextView)

    /// A typed key: held while a barrier is in flight, else ordinary input.
    func typeKey(_ text: String) {
        // Return during a composition commits it, whatever is in flight.
        if composition.isActive, text == "\n" || text == "\r" {
            insertNewline()
            return
        }
        if isBusy {
            hold(.insert(text))
            return
        }
        guard let view else { return }
        if text == "\n" || text == "\r" {
            insertNewline()
        } else if text == "\t" {
            insertTab()
        } else {
            replace(range: view.selectedRange, with: text)
        }
    }

    /// The delete key: held while a barrier is in flight.
    func deleteKey() {
        if isBusy {
            hold(.deleteBackward)
            return
        }
        guard let view else { return }
        var range = view.selectedRange
        if range.length == 0 {
            // A block start is structural (PR04a): a join or a reset to a
            // paragraph, else a quiet no-op. Every other caret takes the command
            // path, which refuses the document-end boundary's separator with a notice.
            if isBlockStart(range.location) {
                deleteBackwardAtBlockStart()
                return
            }
            guard range.location > 0 else { return }
            range = (surface.storage.string as NSString).rangeOfComposedCharacterSequence(at: range.location - 1)
        }
        replace(range: range, with: "")
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        // Key input reaches `NativeTextView.insertText`, which never asks the
        // delegate; this covers UIKit paths that do, so Return routes once.
        if Self.isNewline(text), view?.isApplyingMarkedText != true {
            // Return over a selection replaces it with a block break.
            if range.length == 0 || composition.isActive {
                typeKey("\n")
            } else {
                _ = replace(range: range, with: "\n")
            }
            return false
        }
        if allowsUIKitChange(range, text) { return true }
        _ = replace(range: range, with: text)
        return false
    }

    /// UIKit's own marked-text edits must reach storage: the composition owns
    /// that range and commits it once. A composing keyboard also asks here
    /// before its first keystroke; refusing would turn romaji or pinyin into
    /// committed Latin text, so it proceeds to `setMarkedText` or `insertText`,
    /// both overridden. Every other change takes the command path.
    private func allowsUIKitChange(_ range: NSRange, _ text: String) -> Bool {
        guard let view else { return false }
        if view.isApplyingMarkedText || (composition.isActive && view.markedTextRange != nil) { return true }
        // A key typed while the composition still owns the view is held, never written by UIKit.
        guard !compositionOwnsView, let language = inputLanguage(),
            ["ja", "zh", "yue", "ko"].contains(where: { language.hasPrefix($0) }),
            range == view.selectedRange, text.utf16.count == 1,
            !text.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) || $0.value == 0xfffc }),
            // The same single-block shape the command path accepts: UIKit must
            // never write across a separator or into a placeholder.
            let entry = surface.rangeIndex.entry(atUTF16: range.location),
            let position = surface.rangeIndex.position(for: entry.blockID),
            range.location >= entry.textRange.location, NSMaxRange(range) <= NSMaxRange(entry.textRange),
            !AttributedDocumentProjection.isPlaceholder(surface.blocks[position]),
            // UIKit must never write into folded content either (PR06b).
            !surface.isHidden(position: position)
        else { return false }
        directInsertion = (range, text)
        return true
    }

    /// Our overrides never let UIKit write storage outside marked text, except
    /// a composing keyboard's direct character: undo UIKit's write and submit
    /// it as an ordinary durable command. Anything else bypassed the journal:
    /// restore the projection rather than let storage drift from the replica.
    func textViewDidChange(_ textView: UITextView) {
        guard let view, !view.isApplyingMarkedText, !compositionOwnsView else { return }
        let direct = directInsertion
        // Kept until UIKit's own write is undone: the selection changes that
        // causes are not the user's.
        defer { directInsertion = nil }
        if let direct, let blockID = surface.rangeIndex.entry(atUTF16: direct.range.location)?.blockID,
            surface.storage.length == surface.rangeIndex.length + direct.text.utf16.count - direct.range.length,
            (surface.storage.string as NSString).substring(
                with: NSRange(location: direct.range.location, length: direct.text.utf16.count)) == direct.text
        {
            surface.restoreStorage(blockID: blockID)
            if isBusy {
                // Behind a barrier, the keyboard's own character waits like any key.
                selection.place(direct.range)
                hold(.insert(direct.text))
                return
            }
            // A refused command must still leave storage equal to the model.
            if !replace(range: direct.range, with: direct.text), !surface.storageMatchesModel {
                surface.restoreStorage()
            }
            return
        }
        // A late notification for marked text this view already cleared and
        // reconciled has nothing to undo.
        guard !surface.storageMatchesModel else { return }
        surface.restoreStorage()
        noticeKey = .native_editor_input_unavailable
    }

    /// iOS 26 can supply disjoint ranges. Its fallback passes their union to
    /// the older delegate, which would incorrectly delete intervening text.
    func textView(_ textView: UITextView, shouldChangeTextInRanges ranges: [NSValue], replacementText text: String)
        -> Bool
    {
        if Self.isNewline(text), view?.isApplyingMarkedText != true {
            guard ranges.count == 1, let range = ranges.first?.rangeValue else {
                noticeKey = .native_editor_input_unavailable
                return false
            }
            if range.length == 0 || composition.isActive {
                typeKey("\n")
            } else {
                _ = replace(range: range, with: "\n")
            }
            return false
        }
        if ranges.count == 1, let range = ranges.first?.rangeValue, allowsUIKitChange(range, text) { return true }
        guard ranges.count == 1, let range = ranges.first?.rangeValue else {
            noticeKey = .native_editor_input_unavailable
            return false
        }
        _ = replace(range: range, with: text)
        return false
    }

    /// Focus loss normally reaches `unmarkText` first, which commits like
    /// UIKit. A composition still active here was never confirmed: end it
    /// without writing and keep its text as an explicit recovery entry.
    func textViewDidEndEditing(_ textView: UITextView) {
        // An allowance for a keystroke that never arrived ends with editing.
        directInsertion = nil
        guard composition.isActive else { return }
        view?.dropMarkedText()
        composition.interrupt()
        releaseComposition()
    }

    /// UIKit's selection, including hardware Shift-arrows, is published as
    /// directed relative endpoints so it survives peer edits and rebuilds.
    /// Marked text owns storage and its offsets are stale until the
    /// composition reconciles, so publication waits for that.
    func textViewDidChangeSelection(_ textView: UITextView) {
        guard let view, !view.isApplyingMarkedText, !compositionOwnsView else { return }
        if !surface.isApplyingPatch {
            pendingTypingMarks = nil
            revealCaret(in: view)
            // The user moved while a barrier is in flight: that selection, not
            // the barrier's caret, is where held keys go. (Not UIKit moving the
            // caret past a composing keyboard's direct character, nor the
            // editor's own placement.)
            if barrier != nil, directInsertion == nil, !selection.isRestoring {
                userSelection = blockSelection().map { ($0, barrierShown.count) }
            }
        }
        lastCaret = view.selectedRange.location
        selection.selectionDidChange()
        refreshSelectionMarks()
    }

    /// A caret UIKit placed never rests in folded content: it moves past the
    /// folded run when it moved forward, else (or with no previous caret) back
    /// to the end of the visible block before it, the toggle's title.
    private func revealCaret(in view: NativeTextView) {
        let range = view.selectedRange
        guard range.length == 0, surface.isHidden(atUTF16: range.location) else { return }
        let forward = lastCaret.map { range.location > $0 } ?? false
        view.selectedRange = NSRange(location: visibleLocation(range.location, forward: forward), length: 0)
    }

    /// After a fold or a restored selection: a start inside folded content
    /// moves forward to the end of its hidden run, an end moves back to the
    /// run's start, and a caret (or a selection within one run) collapses to
    /// the end of the toggle's title. The engine's selection follows.
    ///
    /// A selection is trimmed to visible content, never grown over the fold:
    /// a start in a folded run moves forward to its end, an end backward to
    /// its start, and both in one run (or a caret) collapse to the title's
    /// end. A selection with no endpoint in folded content is left alone, so
    /// this never fights a drag over visible text.
    private func keepSelectionVisible() {
        guard let view, !compositionOwnsView else { return }
        let range = view.selectedRange
        let start = hiddenRun(at: range.location)
        let end = range.length > 0 ? hiddenRun(at: NSMaxRange(range)) : start
        guard start != nil || end != nil else { return }
        let visible: NSRange
        if let run = start ?? end, range.length == 0 || start == end {
            visible = NSRange(location: max(0, run.location - 1), length: 0)
        } else {
            let lower = start.map(NSMaxRange) ?? range.location
            let upper = end?.location ?? NSMaxRange(range)
            visible = NSRange(location: lower, length: max(0, upper - lower))
        }
        guard visible != range else { return }
        lastCaret = visible.location
        selection.place(visible)
    }

    /// The folded run holding `location`, if it is hidden.
    private func hiddenRun(at location: Int) -> NSRange? {
        guard surface.isHidden(atUTF16: location) else { return nil }
        return surface.hiddenRanges.first { NSLocationInRange(location, $0) }
    }

    /// `location` itself when it is shown; otherwise the start of the first
    /// visible block after its folded run (`forward`, when there is one) or the
    /// text end of the visible block before it.
    private func visibleLocation(_ location: Int, forward: Bool) -> Int {
        guard surface.isHidden(atUTF16: location),
            let run = surface.hiddenRanges.first(where: { NSLocationInRange(location, $0) })
        else { return location }
        if forward, NSMaxRange(run) < surface.storage.length { return NSMaxRange(run) }
        return max(0, run.location - 1)
    }

    /// `marks`, when given, is the complete mark set the text carries (a link
    /// edit); otherwise typing takes the marks at the caret.
    @discardableResult
    func replace(range: NSRange, with text: String, marks: [TextMark]? = nil) -> Bool {
        directInsertion = nil
        guard let view, view.isEditable, !isFrozen, !isDetached else { return false }
        guard range.length != 0 || !text.isEmpty else { return false }
        // The composition owns input until it reconciles: UIKit's offsets are
        // stale and a second command would race the commit.
        guard view.markedTextRange == nil, !composition.isActive else { return false }
        // The software keyboard also types through the delegate and UITextInput
        // `replace`, not only `insertText`: behind a barrier, typing at the caret
        // and deleting the character before it are held like keys.
        // Typing over a selection is held the same way and replays over the
        // selection then current.
        if isBusy {
            if range == view.selectedRange, !text.isEmpty {
                hold(.insert(text))
                return true
            }
            let caret = view.selectedRange
            if text.isEmpty, range.length > 0,
                range == caret
                    || (caret.length == 0 && NSMaxRange(range) == caret.location
                        && range
                            == (surface.storage.string as NSString).rangeOfComposedCharacterSequence(
                                at: range.location))
            {
                hold(.deleteBackward)
                return true
            }
        }
        // Anything else would read offsets a commit still in flight owns.
        guard !compositionOwnsView else { return false }
        // The software keyboard deletes the separator before a block start
        // through the delegate or UITextInput `replace`, not `deleteBackward`:
        // it is the same boundary Backspace.
        if text.isEmpty, range.length == 1, view.selectedRange == NSRange(location: NSMaxRange(range), length: 0),
            isBlockStart(NSMaxRange(range))
        {
            return deleteBackwardAtBlockStart()
        }
        // Subtraction, rather than NSMaxRange, also rejects overflowing ranges.
        guard range.location >= 0, range.length >= 0, range.location <= surface.storage.length,
            range.length <= surface.storage.length - range.location,
            !text.unicodeScalars.contains(where: { $0.value == 0xfffc })
        else {
            noticeKey = .native_editor_input_unavailable
            return false
        }
        let text = NativeClipboard.normalizingLineBreaks(text)
        // Within one block's text and without a line break: ordinary typing.
        // A code block keeps its line breaks as source. Anything else (a
        // selection across blocks, pasted or dictated lines) is one range command.
        guard let entry = surface.rangeIndex.entry(atUTF16: range.location),
            range.location <= NSMaxRange(entry.textRange),
            range.length <= NSMaxRange(entry.textRange) - range.location,
            !text.contains("\n") || isCode(entry.blockID)
        else { return replaceRange(range, with: text) }
        guard let position = surface.rangeIndex.position(for: entry.blockID),
            !AttributedDocumentProjection.isPlaceholder(surface.blocks[position]), !surface.isHidden(position: position)
        else {
            noticeKey = .native_editor_input_unavailable
            return false
        }
        let offset = range.location - entry.textRange.location
        let blockRange = offset..<(offset + range.length)
        let runs = surface.blocks[position].runs
        let typed = text.isEmpty ? nil : typingMarks(marks, runs: runs, blockRange)
        let caret = NSRange(location: range.location + text.utf16.count, length: 0)
        // Typing continues one undo step only from where typing left the caret.
        let undoBefore = view.selectedRange != typingCaret
        guard barrier == nil, !awaitsReset else { return false }
        guard canPredict(surface.blocks[position], blockRange, text, typed) else {
            // The engine's own validation decides: shown on its result.
            return postBarrier(
                entry.blockID, .replace(range: blockRange, replacement: text, marks: typed),
                refusal: .native_editor_input_unavailable, placement: .at(caret.location), undoBefore: undoBefore,
                undoAfter: false,
                retry: again(at: range) { [weak self] in self?.replace(range: $0, with: text, marks: marks) ?? false })
        }
        let command = NativeEditCommand(
            id: UUID(), baseRevision: canonicalRevision, blockID: entry.blockID, range: blockRange,
            replacement: text, marks: typed)
        guard
            post(
                .command(
                    ReplicaCommand(
                        surfaceID: surfaceID, epoch: epoch, predicted: true, command: command,
                        undoBefore: undoBefore, undoAfter: false)))
        else { return false }
        lastCommandID = command.id
        asOneKeyboardChange {
            surface.predict(
                NativeTextSurface.Prediction(
                    commandID: command.id, blockID: entry.blockID, range: blockRange, text: text,
                    marks: typed ?? NativeMarkSelection.inherited(runs, at: blockRange.lowerBound)))
            pendingTypingMarks = nil
            typingCaret = caret
            selection.place(caret)
        }
        noticeKey = nil
        return true
    }

    /// Option A's prediction guard: the checks `DocumentEngine.replaceText`
    /// makes that the display can make (a writable, projectable text without a
    /// placeholder, no line break outside code, no object character, no split
    /// surrogate). The session refuses anything else, and a block it refused
    /// once is typed through barriers from then on.
    private func canPredict(_ block: BlockSnapshot, _ range: Range<Int>, _ text: String, _ marks: [TextMark]?) -> Bool {
        guard !surface.expectsInvalidation, !barrierOnly.contains(block.id), !block.isOpaque,
            !AttributedDocumentProjection.isPlaceholder(block), BlockNoteWriter.nativePropSchemas[block.node] != nil,
            // A table cell's hard break (PR11a): shown, not typed into.
            block.node == "codeBlock" || !block.runs.contains(where: { $0.text.contains("\n") }),
            surface.predictions.count < Self.maxPendingTyping,
            !text.unicodeScalars.contains(where: {
                $0.value == 0xfffc || (CharacterSet.newlines.contains($0) && !(block.node == "codeBlock" && $0 == "\n"))
            }),
            marks?.allSatisfy({ $0.valueJSON != "null" }) != false
        else { return false }
        let units = Array(block.runs.map(\.text).joined().utf16)
        func boundary(_ offset: Int) -> Bool {
            guard offset >= 0, offset <= units.count else { return false }
            return offset == 0 || offset == units.count
                || !(0xd800...0xdbff).contains(units[offset - 1]) || !(0xdc00...0xdfff).contains(units[offset])
        }
        return boundary(range.lowerBound) && boundary(range.upperBound)
    }

    /// One range command replacing a document range that may span blocks.
    /// The end-of-document boundary ends a range (the last block's text end)
    /// but is never a caret. Every block it touches must be typeable: anything
    /// else is refused with a notice before any write.
    private func replaceRange(_ range: NSRange, with text: String) -> Bool {
        let index = surface.rangeIndex
        guard let start = index.textPosition(atUTF16: range.location),
            let end = index.textPosition(atUTF16: NSMaxRange(range), isUpperBound: range.length > 0),
            start != end || !text.isEmpty
        else {
            noticeKey = .native_editor_input_unavailable
            return false
        }
        guard !touchesFoldedContent(start.position, end.position) else {
            noticeKey = .native_editor_range_unavailable
            return false
        }
        let lines = NativeRangeCommand.lines(of: text)
        let command = NativeRangeCommand(
            startOffset: start.offset, endBlockID: index.entries[end.position].blockID, endOffset: end.offset,
            replacement: text, newBlockIDs: (1..<lines.count).map { _ in UUID().uuidString })
        return applyStructural(
            index.entries[start.position].blockID, .range(command), refusal: .native_editor_range_unavailable,
            retry: again(at: range) { [weak self] in self?.replaceRange($0, with: text) ?? false })
    }

    /// Return: one durable structural command at the caret, or a range
    /// replacement over a selection. While text is marked, Return commits the
    /// composition (PR03) and never splits it.
    @discardableResult
    func insertNewline() -> Bool {
        directInsertion = nil
        guard let view, view.isEditable, !isFrozen, !isDetached else { return false }
        if composition.isActive {
            view.dropMarkedText()
            return commitComposition()
        }
        // In a table, Return moves to the cell below (no-op on the last row).
        if let tableMove, !compositionOwnsView { return tableMove(.below) || true }
        // A commit still in flight owns the view: Return waits like any key.
        if compositionOwnsView {
            hold(.insert("\n"))
            return true
        }
        let selection = view.selectedRange
        if selection.length > 0, view.markedTextRange == nil { return replace(range: selection, with: "\n") }
        guard view.markedTextRange == nil, selection.length == 0,
            let entry = surface.rangeIndex.entry(atUTF16: selection.location),
            let position = surface.rangeIndex.position(for: entry.blockID),
            selection.location <= NSMaxRange(entry.textRange),
            !AttributedDocumentProjection.isPlaceholder(surface.blocks[position])
        else {
            noticeKey = .native_editor_input_unavailable
            return false
        }
        // BlockNote's Enter in a code block inserts a line break in the block.
        if isCode(entry.blockID) { return replace(range: selection, with: "\n") }
        let offset = selection.location - entry.textRange.location
        // BlockNote's Enter reads whether the toggle (or a toggle parent) is open.
        let open = Set([entry.blockID, surface.blocks[position].parentID].compactMap { $0 }.filter(surface.isExpanded))
        return applyStructural(
            entry.blockID, .split(offset: offset, newID: UUID().uuidString, open: open),
            refusal: .native_editor_input_unavailable, retry: again { [weak self] in self?.insertNewline() ?? false },
            readsSelection: true)
    }

    /// The folded-content rule (PR06b): a range or mark command that touches
    /// any block inside a collapsed toggle is refused before it is armed, so
    /// hidden content is never edited by a visible selection.
    private func touchesFoldedContent(_ first: Int, _ last: Int) -> Bool {
        first <= last && (first...last).contains { surface.isHidden(position: $0) }
    }

    private func isCode(_ blockID: String) -> Bool {
        surface.rangeIndex.position(for: blockID).map { surface.blocks[$0].node == "codeBlock" } == true
    }

    /// Backspace at a block's start: the engine joins a paragraph into the
    /// block above, or resets a heading or list item to a paragraph. The first
    /// paragraph and a block above that is opaque, a placeholder or not
    /// writable text stay a quiet no-op.
    @discardableResult
    func deleteBackwardAtBlockStart() -> Bool {
        directInsertion = nil
        // BlockNote keeps a cell's paragraphs: Backspace at a start does nothing.
        if tableMove != nil { return true }
        guard let view, view.isEditable, !isFrozen, !isDetached,
            !compositionOwnsView, view.selectedRange.length == 0,
            isBlockStart(view.selectedRange.location),
            let entry = surface.rangeIndex.entry(atUTF16: view.selectedRange.location),
            let position = surface.rangeIndex.position(for: entry.blockID)
        else { return false }
        // A paragraph merges into the block above it in preorder; when that is
        // a folded toggle's hidden last descendant, the toggle unfolds first,
        // so the merge never edits hidden content.
        if surface.blocks[position].node == "paragraph", position > 0, surface.isHidden(position: position - 1) {
            surface.reveal(surface.blocks[position - 1].id)
        }
        return applyStructural(
            entry.blockID, .join, refusal: nil,
            retry: again { [weak self] in self?.deleteBackwardAtBlockStart() ?? false }, readsSelection: true)
    }

    /// Tab and Shift-Tab, and the bar's Indent/Outdent (BlockNote's
    /// `nestBlock`/`unnestBlock`): one durable tree move of the caret's block,
    /// with its children. A move changes no text, so the selection stays where
    /// it was. Where BlockNote does nothing (a list's first block, a root block,
    /// the depth bound, a selection across blocks) it is a quiet no-op.
    @discardableResult
    func indent() -> Bool { moveBlock(.indent) }

    @discardableResult
    func outdent() -> Bool {
        if let tableMove { return compositionOwnsView ? false : tableMove(.previous) || true }
        return moveBlock(.outdent)
    }

    /// Hardware Tab: two spaces in a code block (BlockNote's
    /// `indentLineWithTab`), the next cell in a table, else `indent()`.
    @discardableResult
    func insertTab() -> Bool {
        if let tableMove { return compositionOwnsView ? false : tableMove(.next) || true }
        guard let view, let entry = surface.rangeIndex.entry(atUTF16: view.selectedRange.location) else { return false }
        return isCode(entry.blockID) ? replace(range: view.selectedRange, with: "  ") : indent()
    }

    private func moveBlock(_ kind: NativeEditCommand.Kind) -> Bool {
        directInsertion = nil
        guard let view, view.isEditable, !isFrozen, !isDetached, !compositionOwnsView else { return false }
        let selection = view.selectedRange
        guard let entry = surface.rangeIndex.entry(atUTF16: selection.location),
            selection.location <= NSMaxRange(entry.textRange),
            NSMaxRange(selection) <= NSMaxRange(entry.textRange)
        else { return false }
        return applyStructural(
            entry.blockID, kind, refusal: nil, keeping: selection,
            retry: again { [weak self] in self?.moveBlock(kind) ?? false }, readsSelection: true)
    }

    /// The keyboard (`inputDelegate`) holds an autocorrection or inline
    /// prediction for the text it last saw, and UIKit accepts it, at that
    /// now stale range, when the caret moves outside a text change
    /// (`prepareForSelectionChange`). So a command's storage edit and caret,
    /// or a patch's restored selection, reach it as one text change; nested
    /// calls (a patch inside a command) report once.
    private var keyboardChangeDepth = 0

    private func asOneKeyboardChange<T>(if reported: Bool = true, _ body: () throws -> T) rethrows -> T {
        guard reported else { return try body() }
        keyboardChangeDepth += 1
        if keyboardChangeDepth == 1 { view?.inputDelegate?.textWillChange(view) }
        defer {
            keyboardChangeDepth -= 1
            if keyboardChangeDepth == 0 { view?.inputDelegate?.textDidChange(view) }
        }
        return try body()
    }

    /// `refusal` is the notice for an unsupported shape; nil keeps it quiet.
    /// `keeping` is a selection to restore instead of the command's caret;
    /// `remapping` one to restore at the same offsets in a block that moved.
    /// A barrier: shown when the session's result arrives.
    private func applyStructural(
        _ blockID: String, _ kind: NativeEditCommand.Kind, refusal: L10nKey?, keeping: NSRange? = nil,
        remapping: (blockID: String, offset: Int, length: Int)? = nil, retry: (() -> Bool)? = nil,
        readsSelection: Bool = false
    ) -> Bool {
        // Folded content is never the target of a command.
        guard !surface.isHidden(blockID: blockID) else {
            if let refusal { noticeKey = refusal }
            return false
        }
        let placement: Barrier.Placement =
            if let keeping { .keeping(keeping) } else if let remapping {
                .remapping(blockID: remapping.blockID, offset: remapping.offset, length: remapping.length)
            } else { .caret }
        // A structural command is its own undo step.
        return postBarrier(
            blockID, kind, refusal: refusal, placement: placement, undoBefore: true, undoAfter: true, retry: retry,
            readsSelection: readsSelection)
    }

    private func postBarrier(
        _ blockID: String, _ kind: NativeEditCommand.Kind, refusal: L10nKey?, placement: Barrier.Placement,
        undoBefore: Bool, undoAfter: Bool, retry: (() -> Bool)?, readsSelection: Bool = false
    ) -> Bool {
        guard barrier == nil else { return false }
        let command = NativeEditCommand(id: UUID(), baseRevision: canonicalRevision, blockID: blockID, kind: kind)
        guard
            post(
                .command(
                    ReplicaCommand(
                        surfaceID: surfaceID, epoch: epoch, predicted: false, command: command, undoBefore: undoBefore,
                        undoAfter: undoAfter)))
        else { return false }
        barrier = Barrier(
            id: command.id, refusal: refusal, placement: placement, retry: retry,
            origin: readsSelection ? blockSelection() : nil)
        barrierShown = []
        userSelection = nil
        lastCommandID = command.id
        if undoAfter { typingCaret = nil }
        return true
    }

    // MARK: - Marks

    /// Typing's marks: an explicit set, a pending toggle, or ProseMirror's
    /// marks at the caret (or across the replaced range). Nil when that is
    /// what Yjs inherits anyway, so plain typing writes what it always did.
    private func typingMarks(_ explicit: [TextMark]?, runs: [InlineRun], _ range: Range<Int>) -> [TextMark]? {
        let marks =
            explicit ?? pendingTypingMarks
            ?? (range.isEmpty
                ? NativeMarkSelection.typing(runs, at: range.lowerBound)
                : NativeMarkSelection.typing(runs, replacing: range))
        return NativeMarkSelection.same(marks, NativeMarkSelection.inherited(runs, at: range.lowerBound)) ? nil : marks
    }

    private var canFormat: Bool {
        guard let view else { return false }
        return view.isEditable && !isFrozen && !isDetached && !compositionOwnsView
    }

    /// Republishes `activeMarks` and the caret's typing attributes (what UIKit
    /// shows marked text with), after a selection change or a patch.
    func refreshSelectionMarks() {
        guard let view, !compositionOwnsView else { return }
        // The edit menu and VoiceOver ask synchronously: have the answer ready.
        if let id = blockActionTarget(), availability[id]?.revision != structureRevision { requestAvailability(id) }
        let range = view.selectedRange
        let index = surface.rangeIndex
        var marks: [TextMark] = []
        var block: BlockSnapshot?
        var caretOffset = 0
        if range.length > 0 {
            marks = NativeMarkSelection.common(in: surface.blocks, index: index, range: range) ?? []
        } else if let caret = index.textPosition(atUTF16: range.location),
            !AttributedDocumentProjection.isPlaceholder(surface.blocks[caret.position])
        {
            block = surface.blocks[caret.position]
            caretOffset = caret.offset
            marks =
                pendingTypingMarks ?? NativeMarkSelection.typing(surface.blocks[caret.position].runs, at: caret.offset)
        }
        if marks != activeMarks { activeMarks = marks }
        slashToken = block.flatMap { Self.slashToken(in: $0, caret: caretOffset) }
        let query = block.flatMap { block in
            slashToken.map { String(decoding: Array(text(of: block).utf16)[1..<$0.upperBound], as: UTF16.self) }
        }
        if query != slashMenuQuery { slashMenuQuery = query }
        guard range.length == 0, let block else { return }
        var typing = view.typingAttributes
        for key in [NSAttributedString.Key.underlineStyle, .strikethroughStyle, .backgroundColor] { typing[key] = nil }
        typing.merge(AttributedDocumentProjection.markAttributes(block: block, marks: marks, traits: surface.traits)) {
            $1
        }
        typing[.link] = nil
        view.typingAttributes = typing
    }

    /// Bold, italic, underline, strike or code. Over a selection, one durable
    /// command: off when every character has it, otherwise on everywhere (a
    /// mixed run turns all on). At a caret it only changes what typing carries.
    @discardableResult
    func toggleMark(_ key: String) -> Bool {
        let isOn = activeMarks.contains { $0.key == key }
        return setMark(key, value: isOn ? nil : "{}")
    }

    /// A text or background colour by BlockNote name; nil removes it.
    @discardableResult
    func setColor(_ key: String, name: String?) -> Bool {
        setMark(key, value: name.map(NativeMark.colorValue))
    }

    private func setMark(_ key: String, value: String?) -> Bool {
        guard let view, canFormat else { return false }
        let range = view.selectedRange
        guard range.length > 0 else {
            var marks = activeMarks.filter { $0.key != key }
            if let value { marks.append(TextMark(key: key, valueJSON: value)) }
            pendingTypingMarks = marks
            refreshSelectionMarks()
            return true
        }
        return applyMarks([TextMark(key: key, valueJSON: value ?? "null")], over: range)
    }

    private func applyMarks(_ attributes: [TextMark], over range: NSRange) -> Bool {
        let index = surface.rangeIndex
        guard let start = index.textPosition(atUTF16: range.location),
            let end = index.textPosition(atUTF16: NSMaxRange(range), isUpperBound: true)
        else {
            noticeKey = .native_editor_range_unavailable
            return false
        }
        guard !touchesFoldedContent(start.position, end.position) else {
            noticeKey = .native_editor_range_unavailable
            return false
        }
        let command = NativeMarkCommand(
            startOffset: start.offset, endBlockID: index.entries[end.position].blockID, endOffset: end.offset,
            attributes: attributes)
        return applyStructural(
            index.entries[start.position].blockID, .marks(command), refusal: .native_editor_range_unavailable,
            keeping: range, retry: again(at: range) { [weak self] in self?.applyMarks(attributes, over: $0) ?? false })
    }

    /// What the link sheet edits: the selection (its link when the whole
    /// selection is one), or the link around a caret, or a new link at it.
    func linkTarget() -> NativeLinkTarget? {
        guard let view, canFormat else { return nil }
        let range = view.selectedRange
        if range.length > 0 {
            let href = (NativeMarkSelection.common(in: surface.blocks, index: surface.rangeIndex, range: range) ?? [])
                .first { $0.key == NativeMark.link }.flatMap { YBlockProjection.linkHref(from: $0.valueJSON) }
            let label = NativeClipboard.plainText(for: range, surface: surface) ?? ""
            return NativeLinkTarget(range: range, label: label, href: href)
        }
        guard let entry = surface.rangeIndex.entry(atUTF16: range.location),
            let position = surface.rangeIndex.position(for: entry.blockID),
            !AttributedDocumentProjection.isPlaceholder(surface.blocks[position])
        else { return nil }
        let offset = range.location - entry.textRange.location
        guard let link = NativeMarkSelection.linkRange(surface.blocks[position].runs, at: offset) else {
            return NativeLinkTarget(range: range, label: "", href: nil)
        }
        let linkRange = NSRange(location: entry.textRange.location + link.range.lowerBound, length: link.range.count)
        let label = NativeClipboard.plainText(for: linkRange, surface: surface) ?? ""
        return NativeLinkTarget(range: linkRange, label: label, href: link.href)
    }

    /// Saves the sheet with the classic editor's URL rules; false keeps it
    /// open. An unchanged label is one mark command; a new or edited label
    /// is typed with the link (one block only).
    @discardableResult
    func applyLink(label: String, url: String, to target: NativeLinkTarget) -> Bool {
        guard canFormat, let href = sanitizedLinkURL(url) else { return false }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.isEmpty ? href : trimmed
        let mark = TextMark(key: NativeMark.link, valueJSON: NativeMark.linkValue(href))
        if target.range.length > 0, text == target.label.trimmingCharacters(in: .whitespacesAndNewlines) {
            _ = applyMarks([mark], over: target.range)
            return true
        }
        guard let entry = surface.rangeIndex.entry(atUTF16: target.range.location),
            let position = surface.rangeIndex.position(for: entry.blockID),
            NSMaxRange(target.range) <= NSMaxRange(entry.textRange)
        else {
            noticeKey = .native_editor_range_unavailable
            return true
        }
        let offset = target.range.location - entry.textRange.location
        let runs = surface.blocks[position].runs
        let around =
            target.range.length == 0
            ? NativeMarkSelection.typing(runs, at: offset)
            : NativeMarkSelection.typing(runs, replacing: offset..<(offset + target.range.length))
        _ = replace(range: target.range, with: text, marks: around.filter { $0.key != NativeMark.link } + [mark])
        return true
    }

    @discardableResult
    func removeLink(_ target: NativeLinkTarget) -> Bool {
        guard canFormat, target.range.length > 0 else { return false }
        return applyMarks([TextMark(key: NativeMark.link, valueJSON: "null")], over: target.range)
    }

    // MARK: - Block props and types

    /// Ticks or unticks a checklist item: one durable `checked` prop command
    /// (BlockNote's `updateBlock`), never a type change. The selection stays.
    @discardableResult
    func toggleCheckbox(blockID: String) -> Bool {
        guard let block = block(blockID), block.node == "checkListItem" else { return false }
        let checked = block.props.contains(ProjectedProp(key: "checked", value: .bool(true)))
        return setProps(blockID, [ProjectedProp(key: "checked", value: .bool(!checked))])
    }

    /// A code block's language, as one prop command.
    @discardableResult
    func setCodeLanguage(blockID: String, language: String) -> Bool {
        guard block(blockID)?.node == "codeBlock" else { return false }
        return setProps(blockID, [ProjectedProp(key: "language", value: .string(language))])
    }

    /// The number a numbered list starts at (its first item's `start`); nil
    /// unsets it, so the list counts from 1.
    @discardableResult
    func setNumberStart(blockID: String, start: Int?) -> Bool {
        guard block(blockID)?.node == "numberedListItem" else { return false }
        return setProps(blockID, [ProjectedProp(key: "start", value: start.map { .int($0) } ?? .undefined)])
    }

    /// A callout's emoji, as one prop command.
    @discardableResult
    func setCalloutEmoji(blockID: String, emoji: String) -> Bool {
        guard block(blockID)?.node == "callout" else { return false }
        return setProps(blockID, [ProjectedProp(key: "emoji", value: .string(emoji))])
    }

    /// The slash menu's choice: the "/query" paragraph becomes that block
    /// type, the query removed, as one durable command. Items the native
    /// editor cannot author yet (divider, photo, file) are not offered.
    @discardableResult
    func applySlashItem(_ item: SlashMenuItem) -> Bool {
        guard let view, canFormat, view.selectedRange.length == 0, let token = slashToken,
            let type = Self.slashType(item.action),
            let entry = surface.rangeIndex.entry(atUTF16: view.selectedRange.location)
        else { return false }
        return applyStructural(
            entry.blockID, .blockType(node: type.node, props: type.props, removing: token),
            refusal: .native_editor_input_unavailable,
            retry: again { [weak self] in self?.applySlashItem(item) ?? false }, readsSelection: true)
    }

    /// A paragraph starting with "/" and the caret after it, with no
    /// whitespace between: that "/query" is the command. Unlike the classic
    /// editor (which clears the whole block), only the token is consumed, as
    /// BlockNote's suggestion menu does, so "/h1Notes" keeps "Notes".
    private static func slashToken(in block: BlockSnapshot, caret: Int) -> Range<Int>? {
        let units = Array(block.runs.map(\.text).joined().utf16)
        guard block.node == "paragraph", caret >= 1, caret <= units.count, units.first == 0x2F,
            !String(decoding: units[1..<caret], as: UTF16.self).contains(where: \.isWhitespace)
        else { return nil }
        return 0..<caret
    }

    /// The slash items this editor can apply, in the classic menu's order,
    /// with the native-only toggles after Heading 3 and the checklist.
    static let slashItems = allSlashMenuItems.filter { slashType($0.action) != nil }.flatMap { item in
        switch item.id {
        case "heading3": [item, toggleHeadingSlashItem]
        case "checklist": [item, toggleListSlashItem]
        default: [item]
        }
    }

    private static func slashType(_ action: SlashMenuAction) -> (node: String, props: [ProjectedProp])? {
        if case .toggle(let heading) = action {
            // BlockNote's "Toggle List" and "Toggle Heading" (level 1) items.
            return heading
                ? (
                    "heading",
                    [
                        ProjectedProp(key: "level", value: .int(1)),
                        ProjectedProp(key: "isToggleable", value: .bool(true)),
                    ]
                )
                : ("toggleListItem", [])
        }
        guard case .convert(let kind) = action else { return nil }
        switch kind {
        case .paragraph: return ("paragraph", [])
        case .heading(let level): return ("heading", [ProjectedProp(key: "level", value: .int(level))])
        case .bulletItem: return ("bulletListItem", [])
        case .numberedItem: return ("numberedListItem", [])
        case .checklistItem: return ("checkListItem", [])
        case .quote: return ("quote", [])
        case .codeBlock: return ("codeBlock", [])
        default: return nil
        }
    }

    /// Unchanged values write nothing; anything else is one validated command.
    private func setProps(_ blockID: String, _ props: [ProjectedProp]) -> Bool {
        guard let view, canFormat, let block = block(blockID) else { return false }
        let defaults = BlockNoteWriter.nativePropSchemas[block.node] ?? []
        func current(_ key: String) -> YAnyValue? {
            block.props.last { $0.key == key }?.value ?? defaults.first { $0.key == key }?.value
        }
        guard props.contains(where: { current($0.key) != $0.value }) else { return true }
        return applyStructural(
            blockID, .props(props), refusal: .native_editor_input_unavailable, keeping: view.selectedRange,
            retry: again { [weak self] in self?.setProps(blockID, props) ?? false })
    }

    private func block(_ blockID: String) -> BlockSnapshot? {
        surface.rangeIndex.position(for: blockID).map { surface.blocks[$0] }.flatMap {
            AttributedDocumentProjection.isPlaceholder($0) ? nil : $0
        }
    }

    private func text(of block: BlockSnapshot) -> String { block.runs.map(\.text).joined() }

    // MARK: - Clipboard

    /// Copy puts the selection's plain text on the pasteboard, one line per
    /// block, and, when the selection is whole sibling subtrees
    /// (`NativeClipboard.wholeBlocks`), their lossless payload beside it.
    func copySelection() {
        guard let view, !compositionOwnsView,
            let text = NativeClipboard.plainText(for: view.selectedRange, surface: surface)
        else {
            return
        }
        copy(text: text, blocks: NativeClipboard.wholeBlocks(for: view.selectedRange, surface: surface))
        flushCopies()
    }

    /// Cut is copy plus one range delete; a refused delete leaves the
    /// pasteboard as it was.
    @discardableResult
    func cutSelection() -> Bool {
        // A delete held behind a barrier would leave its copy unwritten.
        guard !isBusy else {
            noticeKey = .native_editor_input_busy
            return false
        }
        guard let view, !compositionOwnsView,
            let text = NativeClipboard.plainText(for: view.selectedRange, surface: surface)
        else {
            return false
        }
        // Asked for before the delete removes the blocks (the mailbox is
        // ordered), written once the delete is applied.
        let copy = copy(text: text, blocks: NativeClipboard.wholeBlocks(for: view.selectedRange, surface: surface))
        let before = lastCommandID
        guard replace(range: view.selectedRange, with: ""), lastCommandID != before, let delete = lastCommandID else {
            pendingCopies[copy] = nil
            return false
        }
        pendingCopies[copy]?.after = delete
        return true
    }

    /// Paste at a caret prefers Schrift's lossless payload (one command
    /// inserting the subtrees with fresh ids); otherwise, and over a
    /// selection, the pasteboard's plain text replaces the selection as one
    /// command, newlines splitting blocks.
    @discardableResult
    func pasteFromPasteboard() -> Bool {
        guard let view, view.isEditable else { return false }
        if view.selectedRange.length == 0,
            let payload = pasteboard.data(forPasteboardType: BlockNoteSubtreePayload.pasteboardType)
        {
            return pasteBlocks(payload)
        }
        guard let text = pasteboard.string, !text.isEmpty else { return false }
        guard !NativeClipboard.isTooLarge(NativeClipboard.normalizingLineBreaks(text)) else {
            noticeKey = .native_editor_paste_too_large
            return false
        }
        return replace(range: view.selectedRange, with: text)
    }

    /// The payload is untrusted: the engine decodes, bounds and validates it
    /// and mints its ids; a too-large refusal (`.payloadTooLarge`) gets its own
    /// notice.
    private func pasteBlocks(_ payload: Data) -> Bool {
        directInsertion = nil
        guard let view, !compositionOwnsView, !isFrozen, !isDetached else { return false }
        let index = surface.rangeIndex
        guard let entry = index.entry(atUTF16: view.selectedRange.location) ?? index.entries.last else { return false }
        return applyStructural(
            entry.blockID, .insertSubtrees(payload: payload), refusal: .native_editor_paste_unavailable,
            retry: again { [weak self] in self?.pasteBlocks(payload) ?? false }, readsSelection: true)
    }

    /// Writes `text` (and, for whole blocks, their lossless payload, which the
    /// session encodes) once the payload arrives and, for a cut, once its delete
    /// was applied. `requiresPayload` (Copy block) writes nothing without one.
    @discardableResult
    private func copy(text: String?, blocks: [String]?, requiresPayload: Bool = false) -> UUID {
        let id = UUID()
        pendingCopies[id] = PendingCopy(
            text: text, requiresPayload: requiresPayload, payload: blocks == nil ? .some(nil) : nil, after: nil)
        if let blocks, !post(.copyPayload(surfaceID: surfaceID, requestID: id, blockIDs: blocks)) {
            pendingCopies[id] = nil
        }
        return id
    }

    private struct PendingCopy {
        let text: String?
        let requiresPayload: Bool
        /// Nil until the session answered.
        var payload: Data??
        /// A cut's delete: written only once it was applied.
        var after: UUID?
    }

    private func flushCopies() {
        for (id, copy) in pendingCopies where copy.after == nil {
            guard let payload = copy.payload else { continue }
            pendingCopies[id] = nil
            if copy.requiresPayload, payload == nil {
                // Copy block without a lossless payload copies nothing.
                lastOutcome = false
                continue
            }
            writePasteboard(text: copy.text, payload: payload)
        }
    }

    /// A command's result releases (or, refused, drops) the copies waiting for it.
    private func settleCopies(after command: UUID, applied: Bool) {
        for (id, copy) in pendingCopies where copy.after == command {
            if applied { pendingCopies[id]?.after = nil } else { pendingCopies[id] = nil }
        }
        flushCopies()
    }

    /// One pasteboard item: plain text and, when there is one, the lossless
    /// payload. Replaces whatever was there, as `string` did.
    private func writePasteboard(text: String?, payload: Data?) {
        var item: [String: Any] = [:]
        if let text { item[UTType.utf8PlainText.identifier] = text }
        if let payload { item[BlockNoteSubtreePayload.pasteboardType] = payload }
        guard !item.isEmpty else { return }
        pasteboard.setItems([item])
    }

    // MARK: - Block actions (PR06d)

    /// The block the menu acts on: the caret's, or the one a selection lies
    /// in. Nil across blocks, while composing, in folded content or when
    /// editing stopped.
    func blockActionTarget() -> String? {
        guard let view, view.isEditable, !compositionOwnsView, !isFrozen, !isDetached else { return nil }
        let range = view.selectedRange
        let index = surface.rangeIndex
        guard
            let entry = index.entry(atUTF16: range.location)
                ?? (range.location == index.length ? index.entries.last : nil),
            NSMaxRange(range) <= NSMaxRange(entry.range), !surface.isHidden(blockID: entry.blockID)
        else { return nil }
        return entry.blockID
    }

    /// What `performBlockAction` would apply now (the engine's own
    /// validation, nothing written); the menu disables the rest.
    /// The session answers asynchronously (PR08b): until its answer for this
    /// block and structure is in, nothing is offered, and the answer refreshes
    /// the menu (`availability` is observed).
    func availableBlockActions() -> [NativeBlockAction] {
        guard let id = blockActionTarget() else { return [] }
        if let cached = availability[id], cached.revision == structureRevision { return cached.actions }
        requestAvailability(id)
        return []
    }

    private func requestAvailability(_ id: String) {
        guard !requestedAvailability.contains(id) else { return }
        requestedAvailability.insert(id)
        let candidates = NativeBlockAction.allCases.map {
            ReplicaAvailabilityCandidate(action: $0, kind: blockKind($0, id))
        }
        _ = post(.requestAvailability(surfaceID: surfaceID, blockID: id, candidates: candidates))
    }

    /// One durable command on the target block and its subtree (Copy writes
    /// only the pasteboard). A move or duplicate keeps the selection at the
    /// same offsets in its block wherever that lands; delete and insert place
    /// the engine's caret. Unavailable actions are quiet no-ops.
    @discardableResult
    func performBlockAction(_ action: NativeBlockAction) -> Bool {
        directInsertion = nil
        guard let view, let id = blockActionTarget(), let entry = surface.rangeIndex.entry(for: id) else {
            return false
        }
        if action == .copy { return copyBlock(id) }
        guard let kind = blockKind(action, id) else { return false }
        let range = view.selectedRange
        // The menu's target, never Tab's caret rules: whatever the menu offered
        // (a caret at the document end, a selection with its separator) applies.
        // Indent and outdent leave every block where it was in storage.
        let retry = again { [weak self] in self?.performBlockAction(action) ?? false }
        if action == .indent || action == .outdent {
            return applyStructural(id, kind, refusal: nil, keeping: range, retry: retry, readsSelection: true)
        }
        let keeps = [.moveUp, .moveDown, .duplicate].contains(action)
        return applyStructural(
            id, kind, refusal: nil,
            remapping: keeps ? (id, range.location - entry.textRange.location, range.length) : nil, retry: retry,
            readsSelection: true)
    }

    private func blockKind(_ action: NativeBlockAction, _ id: String) -> NativeEditCommand.Kind? {
        switch action {
        case .moveUp: .moveUp
        case .moveDown: .moveDown
        case .indent: .indent
        case .outdent: .outdent
        case .insertAbove: .insertBlock(newID: UUID().uuidString, before: true)
        case .insertBelow: .insertBlock(newID: UUID().uuidString, before: false)
        case .duplicate: .duplicate(newIDs: subtree(id).map { _ in UUID().uuidString })
        case .delete: .deleteBlock
        case .copy: nil
        }
    }

    /// The block's preorder positions with its descendants, folded ones included.
    private func subtree(_ id: String) -> Range<Int> {
        guard let start = surface.rangeIndex.position(for: id) else { return 0..<0 }
        var end = start + 1
        while end < surface.blocks.count, surface.blocks[end].depth > surface.blocks[start].depth { end += 1 }
        return start..<end
    }

    /// Copy block: the subtree's lossless payload and its visible plain text,
    /// written when the session has encoded it (nothing without one).
    private func copyBlock(_ id: String) -> Bool {
        let span = subtree(id)
        guard let first = surface.rangeIndex.entry(for: id),
            let last = surface.rangeIndex.entries.indices.contains(span.upperBound - 1)
                ? surface.rangeIndex.entries[span.upperBound - 1] : nil
        else { return false }
        let range = NSRange(location: first.range.location, length: NSMaxRange(last.textRange) - first.range.location)
        copy(text: NativeClipboard.plainText(for: range, surface: surface), blocks: [id], requiresPayload: true)
        return true
    }

    /// The edit menu's Block submenu, unavailable actions disabled.
    func blockMenuActions() -> [UIAction] {
        let labels = view?.blockControls.labels ?? NativeEditorLabels()
        let available = Set(availableBlockActions())
        guard !available.isEmpty else { return [] }
        return NativeBlockAction.allCases.map { action in
            UIAction(
                title: labels.blockActions[action] ?? action.rawValue,
                attributes: !available.contains(action) ? .disabled : action == .delete ? .destructive : []
            ) { [weak self] _ in self?.performBlockAction(action) }
        }
    }

    /// VoiceOver's custom actions on the text view: the available block actions.
    func blockAccessibilityActions() -> [UIAccessibilityCustomAction] {
        let labels = view?.blockControls.labels ?? NativeEditorLabels()
        return availableBlockActions().map { action in
            UIAccessibilityCustomAction(name: labels.blockActions[action] ?? action.rawValue) { [weak self] _ in
                self?.performBlockAction(action) ?? false
            }
        }
    }

    /// The long-press edit menu gains a Block submenu for the target block.
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement])
        -> UIMenu?
    {
        let actions = blockMenuActions()
        guard !actions.isEmpty else { return nil }
        let title = view?.blockControls.labels.blockMenu ?? NativeEditorLabels().blockMenu
        return UIMenu(children: suggestedActions + [UIMenu(title: title, children: actions)])
    }

    private static func isNewline(_ text: String) -> Bool {
        text == "\n" || text == "\r"
    }

    /// The end-of-document boundary has no owner, so it is never a block start.
    func isBlockStart(_ location: Int) -> Bool {
        surface.rangeIndex.entry(atUTF16: location)?.range.location == location
    }

    // MARK: - Marked text

    /// Called by `setMarkedText` before UIKit applies the marked range.
    func beginComposition(markedText: String) -> Bool {
        guard let view, view.isEditable, !isFrozen, !isDetached else { return false }
        directInsertion = nil
        let began = composition.begin(markedText: markedText)
        if began { noticeKey = nil }
        return began
    }

    /// `text` is UIKit's committed string; nil commits the last marked string.
    /// An orphaned commit becomes a pending recovery entry, shown by the view.
    /// A barrier: the result reconciles the display (one undo step, grouped
    /// by the session).
    @discardableResult
    func commitComposition(text: String? = nil) -> Bool {
        guard composition.isActive else { return false }
        typingCaret = nil
        guard let commit = composition.commit(text: text) else {
            releaseComposition()
            return true
        }
        surface.holdForComposition(false)
        guard !isBusy, intents.isEmpty else {
            // Behind held input the commit is held like a key, in order (the
            // session's composition is cancelled); a full queue keeps it as recovery.
            composition.finish(commit.id)
            _ = post(.compositionCancel(surfaceID: surfaceID))
            if intents.count < Self.maxIntents {
                hold(.insert(commit.text))
            } else {
                composition.recover(commit.text, blockID: commit.blockID)
            }
            releaseComposition()
            return true
        }
        // Shown at once and journaled in order, like a typed key; what waited
        // for the composition then rebases through it.
        if let entry = surface.rangeIndex.entry(for: commit.blockID),
            let position = surface.rangeIndex.position(for: commit.blockID)
        {
            let runs = surface.blocks[position].runs
            let caret = NSRange(
                location: entry.textRange.location + commit.range.lowerBound + commit.text.utf16.count, length: 0)
            asOneKeyboardChange {
                surface.predict(
                    NativeTextSurface.Prediction(
                        commandID: commit.id, blockID: commit.blockID, range: commit.range, text: commit.text,
                        marks: NativeMarkSelection.inherited(runs, at: commit.range.lowerBound)))
                selection.place(caret)
            }
            // While a barrier is in flight its retry maps through the commit,
            // and the commit's caret is the user's latest selection.
            if barrier != nil {
                barrierShown.append(
                    Shown(
                        deltas: [(commit.blockID, [TextDelta(range: commit.range, replacement: commit.text)])],
                        replaced: [], reset: false))
                userSelection = blockSelection().map { ($0, barrierShown.count) }
            }
        }
        lastCommandID = commit.id
        // A post that fails stops authoring; the rollback keeps the text.
        _ = post(.compositionCommit(surfaceID: surfaceID, epoch: epoch, commandID: commit.id, text: commit.text))
        releaseComposition()
        return true
    }

    @discardableResult
    func cancelComposition() -> Bool {
        guard composition.isActive else { return false }
        let cancelled = composition.cancel()
        // A cancel that could not be posted froze authoring: its notice stays.
        if cancelled, !isFrozen { noticeKey = nil }
        releaseComposition()
        return cancelled
    }

    // MARK: - Undo (PR07b)

    /// Whether Undo applies now: there is a step, and editing is possible (not
    /// read-only, frozen or composing).
    /// The stacks are the session's, mirrored from each delivery; a typed key
    /// still waiting for its append is undoable already (the step follows it).
    var canUndo: Bool { canFormat && (history.canUndo || !surface.predictions.isEmpty) }
    var canRedo: Bool { canFormat && history.canRedo && surface.predictions.isEmpty }

    @discardableResult
    func undo() -> Bool { applyHistory(.undo) }

    @discardableResult
    func redo() -> Bool { applyHistory(.redo) }

    /// One durable history step through the engine: journaled before the
    /// surface sees it, saved and placed like any command, then the selection
    /// the step stored is shown. Undo and redo are boundaries on both sides.
    private func applyHistory(_ kind: NativeEditCommand.Kind) -> Bool {
        directInsertion = nil
        guard canFormat else { return false }
        return postBarrier(
            "", kind, refusal: nil, placement: .history, undoBefore: true, undoAfter: true,
            retry: again { [weak self] in self?.applyHistory(kind) ?? false })
    }

    /// The next typing starts a new undo step (the session already stopped
    /// capturing around the command).
    private func endUndoStep() {
        typingCaret = nil
    }

    /// A retry for a stale barrier: none while retrying, so it happens once.
    private var isRetrying = false

    /// A retry of an action on a document range captured when it was posted:
    /// the range is first moved through what the display showed since, so a
    /// peer edit before it does not shift the retry onto other text.
    private func again(at range: NSRange, _ action: @escaping (NSRange) -> Bool) -> (() -> Bool)? {
        guard !isRetrying, let anchors = blockRange(range) else { return nil }
        return again { [weak self] in
            guard let self, let mapped = self.mapThroughBarrier(anchors) else { return false }
            return action(mapped)
        }
    }

    private func again(_ action: @escaping () -> Bool) -> (() -> Bool)? {
        guard !isRetrying else { return nil }
        return { [weak self] in
            guard let self else { return false }
            self.isRetrying = true
            defer { self.isRetrying = false }
            return action()
        }
    }

    // MARK: - Recovery

    /// Inserts recovered text at the caret through the ordinary durable
    /// command path. A caret the command path refuses keeps the entry.
    @discardableResult
    func insertRecovery(_ recovery: ProvisionalRecovery) -> Bool {
        guard let view, !compositionOwnsView, replace(range: view.selectedRange, with: recovery.text) else {
            return false
        }
        composition.resolveRecovery(recovery)
        return true
    }

    func copyRecovery(_ recovery: ProvisionalRecovery) {
        pasteboard.string = recovery.text
        composition.resolveRecovery(recovery)
    }

    func discardRecovery(_ recovery: ProvisionalRecovery) {
        composition.resolveRecovery(recovery)
    }

    /// Authoring stops: predictions roll back into a recovery entry, held keys
    /// with them, and the view is read-only.
    func stopAfterStorageFailure() {
        // Under a composition the rollback's offsets are not storage's: it waits.
        guard !compositionOwnsView else {
            failsAfterComposition = true
            return
        }
        directInsertion = nil
        let first = !isFrozen
        isFrozen = true
        barrier = nil
        if !surface.predictions.isEmpty || !intents.isEmpty { rollBack() }
        // No delete will be applied and no payload may come: nothing is copied.
        pendingCopies = [:]
        view?.isEditable = false
        view?.resignFirstResponder()
        noticeKey = .native_editor_storage_failed
        if first { onFrozen() }
    }

    /// The session closed: nothing more is posted.
    func detach() {
        isDetached = true
        barrier = nil
        intents = []
        history.destroy()
    }

    /// A composition this editor cannot support (a multi-block selection, an
    /// opaque target): keep the preserved read-only refusal and never let
    /// provisional text become committed content.
    func refuseComposition() {
        directInsertion = nil
        // Folding is view state and never locks the editor: a composition that
        // would start in folded content is cancelled (nothing was marked or
        // written), the keyboard is told, and the caret moves out of the fold.
        if let view, surface.isHidden(atUTF16: view.selectedRange.location) {
            view.unmarkText()
            keepSelectionVisible()
            noticeKey = .native_editor_range_unavailable
            return
        }
        // A storage failure (a begin that could not be posted) keeps its notice.
        if !isFrozen { noticeKey = .native_editor_marked_unavailable }
        view?.isEditable = false
        view?.resignFirstResponder()
    }
}
