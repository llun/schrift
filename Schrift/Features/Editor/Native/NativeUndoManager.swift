import UIKit

/// The native editing session's collaborative undo history (PR07b): one
/// `YUndoManager` over the document's root (the `document-store` fragment),
/// created with the input coordinator and destroyed with it at close. History
/// is session-local and bounded (`maxDepth`); the replica store persists the
/// document, never the history.
///
/// Only the engine's local user origin is tracked, so a peer's update, a remote
/// fetch and the derived format cleanup (nil origin) are never undoable; the
/// manager's own steps are tracked by `YUndoManager` itself to fill the
/// opposite stack. A step is applied by the input coordinator through
/// `DocumentEngine.applyHistoryStep`, so it is journaled before publication and
/// saved like any other command; this type only runs the Yjs side.
///
/// Each captured step stores the selection from before its first change (the
/// engine's `selectionBeforeCommand`) as relative positions, as y-prosemirror
/// stores `beforeTransactionSelection`; popping a step restores the selection
/// it stored. A position on content a peer deleted resolves like any relative
/// selection: the selection coordinator falls back to the surviving endpoint or
/// a neighbouring block.
///
/// No actor annotation (PR08a): like the engine and the replica, it is confined
/// to the domain that creates it. The UIKit side is `NativeUndoManager`.
final class ReplicaHistory {
    /// How many undo steps a session keeps; the oldest beyond it are dropped
    /// (their `keep` marks released). Redo steps come from undos, so they are
    /// bounded by the same number.
    static let maxDepth = 100
    private static let selectionKey = "selection"

    let history: YUndoManager
    private weak var engine: DocumentEngine?
    /// Called after every stack change (added, popped, cleared).
    var onChange: (() -> Void)?

    init(doc: YDoc, engine: DocumentEngine) {
        self.engine = engine
        history = YUndoManager(
            doc: doc, scope: [doc.get(BlockNoteYjs.fragmentField)], trackedOrigins: [.localUser])
        history.onStackItemAdded = { [weak self] event in
            guard let self else { return }
            if let selection = self.engine?.selectionBeforeCommand {
                event.stackItem.meta[Self.selectionKey] = selection
            }
            // shortcut: a failed trim keeps the extra item (its `keep` marks too); the next add retries.
            if event.type == .undo { try? self.history.trimUndoStack(to: Self.maxDepth) }
            self.onChange?()
        }
        history.onStackItemPopped = { [weak self] _ in self?.onChange?() }
        history.onStackCleared = { [weak self] _, _ in self?.onChange?() }
    }

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    /// The next local change starts a new step: structural commands, a
    /// composition commit, a caret moved other than by typing, undo and redo.
    func stopCapturing() { history.stopCapturing() }

    /// Runs one undo (or redo) on the replica and restores the selection the
    /// popped step stored. Call only from `DocumentEngine.applyHistoryStep`.
    func step(undo: Bool) throws -> Bool {
        guard let item = undo ? try history.undo() : try history.redo() else { return false }
        if let selection = item.meta[Self.selectionKey] as? RelativeEditorSelection {
            engine?.restoreSelection(selection)
        }
        return true
    }

    /// Stops capturing. The replica is destroyed right after at close, so the
    /// stacks' `keep` marks need no release.
    func destroy() {
        history.destroy()
    }
}

/// The main-actor side of the native history: UIKit's `NativeSystemUndoManager`
/// and its checkpoint notifications over one `ReplicaHistory`.
@MainActor
final class NativeUndoManager {
    static let maxDepth = ReplicaHistory.maxDepth

    let replica: ReplicaHistory
    var history: YUndoManager { replica.history }
    /// What UIKit sees as the text view's undo manager.
    let system = NativeSystemUndoManager()

    init(doc: YDoc, engine: DocumentEngine) {
        replica = ReplicaHistory(doc: doc, engine: engine)
        replica.onChange = { [weak self] in self?.didChange() }
    }

    var canUndo: Bool { replica.canUndo }
    var canRedo: Bool { replica.canRedo }
    func stopCapturing() { replica.stopCapturing() }
    func step(undo: Bool) throws -> Bool { try replica.step(undo: undo) }

    func destroy() {
        replica.destroy()
        system.input = nil
    }

    /// UIKit refreshes the keyboard's undo/redo buttons on the checkpoint.
    private func didChange() {
        NotificationCenter.default.post(name: .NSUndoManagerCheckpoint, object: system)
    }
}

/// The text view's `undoManager`: Edit ▸ Undo/Redo, the shake gesture, ⌘Z and
/// ⇧⌘Z and the keyboard's undo all read `canUndo`/`canRedo` and call
/// `undo()`/`redo()` here, which route to the native history. UIKit's own text
/// history is never used: an action UIKit registers (marked text writes storage
/// through `super`) is never run, because undo and redo are overridden, and
/// `levelsOfUndo` keeps at most one of them.
final class NativeSystemUndoManager: UndoManager {
    weak var input: NativeInputCoordinator?

    override init() {
        super.init()
        levelsOfUndo = 1
    }

    override var canUndo: Bool { MainActor.assumeIsolated { input?.canUndo ?? false } }
    override var canRedo: Bool { MainActor.assumeIsolated { input?.canRedo ?? false } }
    override func undo() { MainActor.assumeIsolated { _ = input?.undo() } }
    override func redo() { MainActor.assumeIsolated { _ = input?.redo() } }
    /// UIKit's selector-based registrations are dropped outright. Anything it registers
    /// with a closure stays in `super` (at most one, `levelsOfUndo` 1) and never runs:
    /// `undo()`/`redo()` above never call `super`.
    override func registerUndo(withTarget target: Any, selector: Selector, object anObject: Any?) {}
}
