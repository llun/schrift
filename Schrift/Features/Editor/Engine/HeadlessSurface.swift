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

    init(blocks: [BlockSnapshot] = []) {
        self.blocks = blocks
    }

    func applyPatch(_ patch: BlockPatch) {
        appliedPatches.append(patch)
        for change in patch.changes { apply(change) }
    }

    private func apply(_ change: BlockChange) {
        switch change {
        case .text(let blockID, let deltas):
            guard let index = blocks.firstIndex(where: { $0.id == blockID }) else { return }
            blocks[index].runs = Self.apply(deltas, to: blocks[index].runs)
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

    /// Applies deltas to a run list. Deltas are in pre-change coordinates, so
    /// they are applied from the last one backwards and earlier offsets stay
    /// valid. Reversing the *array* (not sorting by range) keeps several
    /// insertions at the same offset in their original order.
    /// A `nil` mark set inherits the marks in force at the insertion point.
    static func apply(_ deltas: [TextDelta], to runs: [InlineRun]) -> [InlineRun] {
        var units: [(unit: UInt16, marks: [TextMark])] = []
        for run in runs {
            let marks = run.marks.map { TextMark(key: $0.key, valueJSON: $0.valueJSON) }
            for unit in run.text.utf16 { units.append((unit, marks)) }
        }
        for delta in deltas.reversed() {
            let lower = min(max(0, delta.range.lowerBound), units.count)
            let upper = min(max(lower, delta.range.upperBound), units.count)
            // Inherit the marks in force *before* the insertion point — the
            // character to its left, not the one to its right, which a later
            // delta in this same patch may have just inserted.
            let marks =
                delta.marks
                ?? (lower > 0 ? units[lower - 1].marks : (lower < units.count ? units[lower].marks : []))
            let replacement = delta.replacement.utf16.map { (unit: $0, marks: marks) }
            units.replaceSubrange(lower..<upper, with: replacement)
        }
        var out: [InlineRun] = []
        var buffer: [UInt16] = []
        var current: [TextMark] = []
        func flush() {
            guard !buffer.isEmpty else { return }
            out.append(
                InlineRun(
                    String(decoding: buffer, as: UTF16.self),
                    marks: current.map { ($0.key, $0.valueJSON) }))
            buffer = []
        }
        for entry in units {
            if entry.marks != current {
                flush()
                current = entry.marks
            }
            buffer.append(entry.unit)
        }
        flush()
        return out
    }
}
