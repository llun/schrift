/// Invalidates composing-block deltas rather than storing them for replay.
/// Independent block changes still flow. Once a structural change involving
/// this block makes list coordinates unsafe, everything waits for a full reset.
///
/// The queue holds a same-block replacement range, not just an insertion
/// point: UIKit's marked text may replace a selection, and both endpoints must
/// be captured before the provisional text exists.
struct CompositionQueue {
    let range: RelativeEditorRange
    private(set) var requiresReset = false
    /// A change other than the commit's own write was discarded: the final
    /// rebuild carries more than the composed text.
    private(set) var foldsOtherChanges = false

    var blockID: String { range.blockID }

    mutating func filter(_ patch: BlockPatch) -> BlockPatch {
        let filtered = filtering(patch)
        if patch.nativeCommand == nil, filtered.changes.count != patch.changes.count { foldsOtherChanges = true }
        return filtered
    }

    private mutating func filtering(_ patch: BlockPatch) -> BlockPatch {
        guard !requiresReset else { return BlockPatch(origin: patch.origin) }
        let id = blockID
        if patch.changes.contains(where: { change in
            switch change {
            case .reset: return true
            case .remove(let ids): return ids.contains(id)
            case .insert(_, let blocks): return blocks.contains { $0.id == id }
            default: return false
            }
        }) {
            requiresReset = true
            return BlockPatch(origin: patch.origin)
        }
        return BlockPatch(
            patch.changes.filter { change in
                switch change {
                case .text(let blockID, _), .props(let blockID, _), .replaceBlock(let blockID, _):
                    return blockID != id
                default: return true
                }
            }, origin: patch.origin)
    }
}
