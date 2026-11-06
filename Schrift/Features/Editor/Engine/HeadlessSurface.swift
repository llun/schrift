import Foundation

/// An in-memory `EditorSurface`: a block list that only ever changes through
/// `applyPatch`. It exists so the engine can be proven headlessly — after every
/// step its `blocks` must equal the replica's projection.
///
/// It never mutates optimistically, which is what makes it the reference
/// implementation of the patch contract: a patch is applied to the state the
/// previous patch left behind, so the surface converges to the replica without
/// the reconciliation a real text view needs (see `EditorSurface`).
final class HeadlessSurface: EditorSurface {
    private(set) var blocks: [BlockSnapshot]
    /// Every patch received, in order — the engine's output, for assertions.
    private(set) var appliedPatches: [BlockPatch] = []
    private(set) var isCompositionDeferred = false
    private(set) var compositionDeferrals: [Bool] = []

    init(blocks: [BlockSnapshot] = []) {
        self.blocks = blocks
    }

    func applyPatch(_ patch: BlockPatch) {
        appliedPatches.append(patch)
        for change in patch.changes { apply(change) }
    }

    func setCompositionDeferred(_ deferred: Bool) {
        isCompositionDeferred = deferred
        compositionDeferrals.append(deferred)
    }

    private func apply(_ change: BlockChange) {
        switch change {
        case .text(let blockID, let deltas):
            guard let index = blocks.firstIndex(where: { $0.id == blockID }) else { return }
            blocks[index].runs = TextDelta.apply(deltas, to: blocks[index].runs)
        case .props(let blockID, let props):
            guard let index = blocks.firstIndex(where: { $0.id == blockID }) else { return }
            blocks[index].props = props
        case .insert(let after, let inserted):
            let position: Int
            if let after, let index = blocks.firstIndex(where: { $0.id == after }) {
                position = index + 1
            } else {
                position = 0
            }
            blocks.insert(contentsOf: inserted, at: position)
        case .remove(let blockIDs):
            let removed = Set(blockIDs)
            blocks.removeAll { removed.contains($0.id) }
        case .replaceBlock(let blockID, let block):
            guard let index = blocks.firstIndex(where: { $0.id == blockID }) else { return }
            blocks[index] = block
        case .reset(let reset):
            blocks = reset
        }
    }
}
