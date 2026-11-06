/// Invalidates composing-block deltas rather than storing them for replay.
/// Independent block changes still flow. Once a structural change involving
/// this block makes list coordinates unsafe, everything waits for a full reset.
struct CompositionQueue {
    let anchor: RelativeEditorPosition
    private(set) var requiresReset = false

    mutating func filter(_ patch: BlockPatch) -> BlockPatch {
        guard !requiresReset else { return BlockPatch(origin: patch.origin) }
        let id = anchor.blockID
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
