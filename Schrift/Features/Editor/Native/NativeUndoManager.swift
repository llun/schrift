import UIKit

/// The main-actor side of the native history: UIKit's `NativeSystemUndoManager`
/// and its checkpoint notifications. The history itself (`ReplicaHistory`) is
/// the replica session's (PR08b): this side only mirrors `canUndo`/`canRedo`
/// from each delivery's state.
@MainActor
final class NativeUndoManager {
    static let maxDepth = 100

    /// What UIKit sees as the text view's undo manager.
    let system = NativeSystemUndoManager()
    private(set) var canUndo = false
    private(set) var canRedo = false

    /// A delivery's history state. UIKit refreshes the keyboard's undo/redo
    /// buttons on the checkpoint.
    func mirror(canUndo: Bool, canRedo: Bool) {
        guard canUndo != self.canUndo || canRedo != self.canRedo else { return }
        self.canUndo = canUndo
        self.canRedo = canRedo
        NotificationCenter.default.post(name: .NSUndoManagerCheckpoint, object: system)
    }

    func destroy() {
        system.input = nil
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
