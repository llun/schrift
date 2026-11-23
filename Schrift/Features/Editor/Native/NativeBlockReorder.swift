import Foundation

/// Where a block (with its nested subtree) lands during a drag-to-reorder move.
///
/// Any visual "drop after block `X` at depth `d`" maps unambiguously to one of
/// these three cases:
/// - `d == X.depth + 1` → `.firstChild(of: X.id)` (inside `X`'s nested group,
///   creating it when absent).
/// - `d <= X.depth` → `.after(A.id)` where `A` is the unique ancestor of `X`
///   at depth `d` (`A == X` when `d == X.depth`), placing the moved block right
///   after `A`'s entire subtree (including any hidden descendants of a folded
///   toggle).
/// - Before the first block of the document or column (`d == 0`) →
///   `.before(firstBlockID)`.
enum NativeMoveDestination: Equatable, Sendable {
    /// Immediately before `blockID` in its group (at `blockID`'s depth).
    case before(String)
    /// Immediately after `blockID` and its entire subtree in its group (at
    /// `blockID`'s depth).
    case after(String)
    /// As the first child inside `blockID`'s nested `blockGroup` (at
    /// `blockID`'s depth + 1), creating the nested group if absent.
    case firstChild(of: String)

    /// The reference block named by this destination.
    var referenceBlockID: String {
        switch self {
        case .before(let id), .after(let id), .firstChild(of: let id): id
        }
    }
}

/// A validated, clamped drop placement returned by `NativeBlockReorder.dropTarget`.
struct NativeBlockDropTarget: Equatable, Sendable {
    /// The tree placement to pass to `NativeInputCoordinator.moveBlock(_:to:)`.
    let destination: NativeMoveDestination
    /// The clamped landing nesting depth (`0...BlockNoteWriter.maxNestingDepth`),
    /// used by the drag UI to indent the drop indicator line and tick haptics.
    let depth: Int
}

/// Pure, UIKit-free drop-target resolution for single-block drag-to-reorder.
///
/// The drag UI calls `dropTarget(...)` on every gesture frame against the
/// projected block list and fold state; every non-nil result satisfies the same
/// structural invariants that `DocumentEngine` enforces on commit.
enum NativeBlockReorder {
    private static let rootOnlyNodes: Set<String> = MediaBlock.nodes.union(["table", MediaBlock.uploadLoader])

    /// Whether `blockID` can be picked up and dragged with its nested subtree.
    static func canDrag(
        _ blockID: String,
        in blocks: [BlockSnapshot],
        expanded: Set<String> = [],
        hidden: [Bool]? = nil
    ) -> Bool {
        guard hasCanonicalIDs(blocks) else { return false }
        let hiddenFlags = effectiveHiddenFlags(in: blocks, expanded: expanded, hidden: hidden)
        guard let sourceIndex = blocks.firstIndex(where: { $0.id == blockID }),
            !hiddenFlags[sourceIndex]
        else { return false }
        let subtree = subtreeRange(startingAt: sourceIndex, in: blocks)
        return sourceInfo(at: sourceIndex, subtree: subtree, in: blocks) != nil
    }

    /// Resolves the valid clamped destination for dragging `draggedBlockID` to
    /// `slotIndex` (`0...blocks.count`, the boundary before `blocks[slotIndex]`
    /// or after the last block when `slotIndex == blocks.count`) at
    /// `requestedDepth`.
    ///
    /// Returns `nil` when `draggedBlockID` is not draggable, when `slotIndex`
    /// lies strictly inside hidden folded content or inside the dragged block's
    /// own visible subtree, when no valid depth exists at the slot (for example
    /// dropping a table or column group between nested children), or when the
    /// resolved placement is a no-op.
    static func dropTarget(
        moving draggedBlockID: String,
        in blocks: [BlockSnapshot],
        expanded: Set<String> = [],
        hidden: [Bool]? = nil,
        slotIndex: Int,
        requestedDepth: Int
    ) -> NativeBlockDropTarget? {
        guard !blocks.isEmpty, (0...blocks.count).contains(slotIndex), hasCanonicalIDs(blocks) else { return nil }
        let hiddenFlags = effectiveHiddenFlags(in: blocks, expanded: expanded, hidden: hidden)
        guard let sourceIndex = blocks.firstIndex(where: { $0.id == draggedBlockID }),
            !hiddenFlags[sourceIndex]
        else { return nil }

        let subtree = subtreeRange(startingAt: sourceIndex, in: blocks)
        guard let info = sourceInfo(at: sourceIndex, subtree: subtree, in: blocks) else { return nil }

        // A slot strictly between two hidden blocks lies inside folded content
        // that cannot be targeted visually.
        if slotIndex > 0, slotIndex < blocks.count, hiddenFlags[slotIndex - 1], hiddenFlags[slotIndex] {
            return nil
        }

        // Normalize or reject slots falling inside the dragged block's subtree:
        // only the bottom edge of a folded dragged block (whose descendants are
        // all hidden) maps past its subtree; any visible interior slot is invalid.
        var effectiveSlot = slotIndex
        if slotIndex > sourceIndex, slotIndex < subtree.upperBound {
            guard slotIndex == sourceIndex + 1, hiddenFlags[slotIndex] else { return nil }
            effectiveSlot = subtree.upperBound
        }

        let prevIndex = previousVisibleIndex(before: effectiveSlot, excluding: subtree, hidden: hiddenFlags)
        let nextIndex = nextVisibleIndex(from: effectiveSlot, excluding: subtree, hidden: hiddenFlags)
        guard prevIndex != nil || nextIndex != nil else { return nil }

        let dragMaxDepth = info.mustBeRoot ? 0 : max(0, BlockNoteWriter.maxNestingDepth - info.subtreeHeight)
        let resolved: NativeBlockDropTarget

        if let prevIndex {
            let prev = blocks[prevIndex]
            let minDepth = nextIndex.map { blocks[$0].depth } ?? 0
            let prevAllowsChild = canAcceptChildren(prev, expanded: expanded)
            let structuralMax = prevAllowsChild ? prev.depth + 1 : prev.depth
            let maxDepth = min(structuralMax, dragMaxDepth)
            guard minDepth <= maxDepth else { return nil }

            let clampedDepth = min(max(requestedDepth, minDepth), maxDepth)
            guard
                let candidate = resolveAfter(
                    prevIndex: prevIndex, depth: clampedDepth, minDepth: minDepth, in: blocks, expanded: expanded)
            else { return nil }
            resolved = candidate
        } else if let nextIndex {
            let next = blocks[nextIndex]
            guard next.depth <= dragMaxDepth else { return nil }
            resolved = NativeBlockDropTarget(destination: .before(next.id), depth: next.depth)
        } else {
            return nil
        }

        if isNoOp(sourceIndex: sourceIndex, subtree: subtree, destination: resolved.destination, in: blocks) {
            return nil
        }
        return resolved
    }

    // MARK: - Private helpers

    private static func hasCanonicalIDs(_ blocks: [BlockSnapshot]) -> Bool {
        var seen: Set<String> = []
        seen.reserveCapacity(blocks.count)
        for block in blocks {
            guard !block.id.isEmpty, seen.insert(block.id).inserted else { return false }
        }
        return true
    }

    private struct SourceInfo {
        let mustBeRoot: Bool
        let subtreeHeight: Int
    }

    private static func sourceInfo(
        at sourceIndex: Int, subtree: Range<Int>, in blocks: [BlockSnapshot]
    ) -> SourceInfo? {
        let source = blocks[sourceIndex]
        if source.node == "columnList" {
            guard source.depth == 0, !source.isOpaque, !source.isLocked, subtree.count == 1 else { return nil }
            return SourceInfo(mustBeRoot: true, subtreeHeight: 0)
        }
        var maxDepth = source.depth
        var containsRootOnly = false
        for index in subtree {
            let block = blocks[index]
            guard !block.isOpaque, !block.isLocked, block.node != "columnList" else { return nil }
            maxDepth = max(maxDepth, block.depth)
            if rootOnlyNodes.contains(block.node) { containsRootOnly = true }
        }
        return SourceInfo(mustBeRoot: containsRootOnly, subtreeHeight: maxDepth - source.depth)
    }

    private static func subtreeRange(startingAt index: Int, in blocks: [BlockSnapshot]) -> Range<Int> {
        let baseDepth = blocks[index].depth
        var end = index + 1
        while end < blocks.count, blocks[end].depth > baseDepth { end += 1 }
        return index..<end
    }

    private static func effectiveHiddenFlags(
        in blocks: [BlockSnapshot], expanded: Set<String>, hidden: [Bool]?
    ) -> [Bool] {
        if let hidden, hidden.count == blocks.count { return hidden }
        var result: [Bool] = []
        result.reserveCapacity(blocks.count)
        var foldedDepth: Int?
        for block in blocks {
            if let depth = foldedDepth, block.depth <= depth { foldedDepth = nil }
            result.append(foldedDepth != nil)
            if foldedDepth == nil, isToggle(block), !expanded.contains(block.id) {
                foldedDepth = block.depth
            }
        }
        return result
    }

    private static func isToggle(_ block: BlockSnapshot) -> Bool {
        !block.isOpaque && BlockNoteWriter.isToggle(node: block.node, props: block.props.map { ($0.key, $0.value) })
    }

    private static func canAcceptChildren(_ block: BlockSnapshot, expanded: Set<String>) -> Bool {
        guard !block.isOpaque, !block.isLocked, block.node != "columnList", !rootOnlyNodes.contains(block.node) else {
            return false
        }
        if isToggle(block), !expanded.contains(block.id) { return false }
        return true
    }

    private static func previousVisibleIndex(
        before slotIndex: Int, excluding subtree: Range<Int>, hidden: [Bool]
    ) -> Int? {
        var cursor = slotIndex - 1
        while cursor >= 0 {
            if !subtree.contains(cursor), !hidden[cursor] { return cursor }
            cursor -= 1
        }
        return nil
    }

    private static func nextVisibleIndex(
        from slotIndex: Int, excluding subtree: Range<Int>, hidden: [Bool]
    ) -> Int? {
        var cursor = slotIndex
        while cursor < hidden.count {
            if !subtree.contains(cursor), !hidden[cursor] { return cursor }
            cursor += 1
        }
        return nil
    }

    private static func resolveAfter(
        prevIndex: Int, depth: Int, minDepth: Int, in blocks: [BlockSnapshot], expanded: Set<String>
    ) -> NativeBlockDropTarget? {
        let prev = blocks[prevIndex]
        if depth == prev.depth + 1 {
            return NativeBlockDropTarget(destination: .firstChild(of: prev.id), depth: depth)
        }
        var candidateDepth = depth
        while candidateDepth >= minDepth {
            guard let anchorIndex = ancestorIndex(of: prevIndex, atDepth: candidateDepth, in: blocks) else {
                return nil
            }
            if candidateDepth == 0 {
                return NativeBlockDropTarget(destination: .after(blocks[anchorIndex].id), depth: 0)
            }
            if let parentIndex = ancestorIndex(of: anchorIndex, atDepth: candidateDepth - 1, in: blocks) {
                let parent = blocks[parentIndex]
                if !rootOnlyNodes.contains(parent.node), parent.node != "columnList",
                    !(isToggle(parent) && !expanded.contains(parent.id))
                {
                    return NativeBlockDropTarget(destination: .after(blocks[anchorIndex].id), depth: candidateDepth)
                }
            }
            candidateDepth -= 1
        }
        return nil
    }

    private static func ancestorIndex(of index: Int, atDepth targetDepth: Int, in blocks: [BlockSnapshot]) -> Int? {
        var cursor = index
        while cursor >= 0 {
            if blocks[cursor].depth == targetDepth { return cursor }
            if blocks[cursor].depth < targetDepth { return nil }
            cursor -= 1
        }
        return nil
    }

    private static func isNoOp(
        sourceIndex: Int, subtree: Range<Int>, destination: NativeMoveDestination, in blocks: [BlockSnapshot]
    ) -> Bool {
        let source = blocks[sourceIndex]
        switch destination {
        case .before(let targetID):
            return subtree.upperBound < blocks.count
                && blocks[subtree.upperBound].depth == source.depth
                && blocks[subtree.upperBound].id == targetID
        case .after(let targetID):
            var cursor = sourceIndex - 1
            while cursor >= 0, blocks[cursor].depth > source.depth { cursor -= 1 }
            return cursor >= 0 && blocks[cursor].depth == source.depth && blocks[cursor].id == targetID
        case .firstChild(of: let targetID):
            return sourceIndex > 0
                && blocks[sourceIndex - 1].depth == source.depth - 1
                && blocks[sourceIndex - 1].id == targetID
        }
    }
}
