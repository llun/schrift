import Foundation

// MARK: - Aligning freshly parsed blocks with a server replica's blocks

/// Gives freshly parsed BlockNote blocks (the editor's markdown, `MarkdownYjs.blockNoteBlocks`,
/// whose ids are minted per parse) the ids of the server replica's blocks they correspond to,
/// so `BlockNoteWrite.applyEdit(old:new:to:)` can turn "the document should now read like
/// this markdown" into an **incremental** CRDT update instead of a full rewrite.
///
/// This is what the Docs 6 save needs: the collaboration server applies a PATCHed update
/// incrementally, so a from-scratch document would be *appended* to the existing one. Diffing
/// against the server's own replica means blocks this alignment anchors are not rewritten at
/// all. It is **not** a merge of co-author edits: the editor's whole document is diffed
/// against the server's state *at save time*, so a co-author's edit to a block after this
/// user loaded the document is reverted unless the draft/conflict rules (`draftSyncDecision`,
/// keyed on `updated_at`) catch it first — and those need the Docs 6 collaboration server to
/// be configured with `YHUB_JWT_PRIVATE_KEY`, without which `updated_at` stops following
/// editor edits. Only anchored blocks survive untouched (unchanged non-opaque blocks, plus
/// `unknownNode:*` and document-link blocks); an untouched opaque block (a table, parsed as
/// `.unknown`) or nested list is still rewritten from markdown, as in the classic save.
///
/// The result's *content* is exactly `new` — the same overwrite semantics as the classic
/// full-overwrite save. Only the ids change, and only in two ways:
///
/// 1. **Anchors** — the longest common subsequence of old and new blocks with the same visible
///    content (`sameVisibleContent`). The new block takes the old id, and because it is equal
///    `applyEdit` leaves it untouched — which also preserves a *lossy* block's props and marks
///    the editor does not model, something the classic save destroys on every save.
/// 2. **Positional pairs** — inside each gap between two anchors, the k-th old block and the
///    k-th new block are paired when the old one is `.modeled` (so `applyEdit` can reconcile
///    its kind, props and text in place) and the new one has no children (the differ never
///    reconciles a nested subtree).
///
/// Everything else keeps its fresh id: an unmatched new block is inserted, an unmatched old
/// block is removed. Pairing is order-preserving by construction, so `applyEdit` never has to
/// move a survivor.
///
/// Pure value code; see `AGENTS.md`, "The Yjs CRDT core".
enum BlockNoteAlignment {
    /// Above this many cells the LCS table is skipped and the whole middle is treated as one
    /// gap. The common prefix and suffix are trimmed first, so only a document rewritten
    /// almost everywhere reaches it; the content is still exactly `new`, it just reuses fewer
    /// blocks.
    static let maxTableCells = 4_000_000

    /// `new`, with each block's id replaced by the id of the `old` block it corresponds to.
    /// See the type overview for the two matching rules.
    static func align(old: [ProjectedBlock], new: [BlockNoteBlock]) -> [BlockNoteBlock] {
        var result = new
        for (oldIndex, newIndex) in matches(old: old, new: new) {
            result[newIndex].id = old[oldIndex].id
        }
        return result
    }

    /// The `(oldIndex, newIndex)` pairs, ascending in both coordinates.
    static func matches(old: [ProjectedBlock], new: [BlockNoteBlock]) -> [(old: Int, new: Int)] {
        let anchors = anchorPairs(old: old, new: new)
        var result: [(old: Int, new: Int)] = []
        var oldStart = 0
        var newStart = 0
        // A sentinel anchor past both ends closes the final gap.
        for anchor in anchors + [(old: old.count, new: new.count)] {
            let gapLength = min(anchor.old - oldStart, anchor.new - newStart)
            for k in 0..<max(gapLength, 0) where canPair(old: old[oldStart + k], new: new[newStart + k]) {
                result.append((old: oldStart + k, new: newStart + k))
            }
            if anchor.old < old.count {
                result.append(anchor)
            }
            oldStart = anchor.old + 1
            newStart = anchor.new + 1
        }
        return result
    }

    // MARK: - Matching predicates

    /// Whether a new block shows exactly what the old one shows, so keeping the old block
    /// untouched is the same as writing the new one: same node, same runs, every prop the new
    /// block carries present on the old with the same value, and no children (the projection
    /// never reports children, so a new block with some cannot be the same).
    ///
    /// The old block must have legible content. `.modeled` and `.lossy` blocks do; an
    /// `.opaque` one generally does not (its props/runs may be empty because they could not
    /// be read). The exception is an **unknown node** (`unknownNode:…` — e.g. the web's
    /// `file` attachment block, which this projection does not classify): its props and runs
    /// were read in full and only the node name was unrecognized, so equality is real
    /// equality.
    static func sameVisibleContent(old: ProjectedBlock, new: BlockNoteBlock) -> Bool {
        guard !old.id.isEmpty, hasLegibleContent(old), new.children.isEmpty, old.node == new.node, old.runs == new.runs
        else {
            return false
        }
        return new.props.allSatisfy { prop in
            old.props.first(where: { $0.key == prop.key })?.value == prop.value
        }
    }

    /// Whether a gap's old and new block may be reconciled in place by `applyEdit`. Only a
    /// `.modeled` old block qualifies: its runs are the replica's exact text, so the differ's
    /// text-span indices line up with the live items. A lossy block's runs are scrubbed of
    /// marks and an opaque block's are unreliable, so reconciling either could corrupt it.
    static func canPair(old: ProjectedBlock, new: BlockNoteBlock) -> Bool {
        old.fidelity == .modeled && new.children.isEmpty && !old.id.isEmpty
    }

    private static func hasLegibleContent(_ block: ProjectedBlock) -> Bool {
        switch block.fidelity {
        case .modeled, .lossy:
            return true
        case .opaque(let reason):
            return reason.hasPrefix("unknownNode:")
        }
    }

    // MARK: - Longest common subsequence

    /// The anchors: a longest common subsequence under `sameVisibleContent`, after trimming
    /// the common prefix and suffix (a typical save changes a few blocks in the middle).
    private static func anchorPairs(old: [ProjectedBlock], new: [BlockNoteBlock]) -> [(old: Int, new: Int)] {
        var prefix = 0
        while prefix < old.count, prefix < new.count, sameVisibleContent(old: old[prefix], new: new[prefix]) {
            prefix += 1
        }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
            sameVisibleContent(old: old[old.count - 1 - suffix], new: new[new.count - 1 - suffix])
        {
            suffix += 1
        }

        var pairs: [(old: Int, new: Int)] = (0..<prefix).map { (old: $0, new: $0) }

        let oldMiddle = prefix..<(old.count - suffix)
        let newMiddle = prefix..<(new.count - suffix)
        let rows = oldMiddle.count
        let columns = newMiddle.count
        if rows > 0, columns > 0, (rows + 1) * (columns + 1) <= maxTableCells {
            // lengths[i][j] = LCS length of old[oldMiddle][i...] and new[newMiddle][j...].
            let width = columns + 1
            var lengths = [Int](repeating: 0, count: (rows + 1) * width)
            for i in stride(from: rows - 1, through: 0, by: -1) {
                for j in stride(from: columns - 1, through: 0, by: -1) {
                    if sameVisibleContent(old: old[oldMiddle.lowerBound + i], new: new[newMiddle.lowerBound + j]) {
                        lengths[i * width + j] = lengths[(i + 1) * width + j + 1] + 1
                    } else {
                        lengths[i * width + j] = max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
                    }
                }
            }
            var i = 0
            var j = 0
            while i < rows, j < columns {
                if sameVisibleContent(old: old[oldMiddle.lowerBound + i], new: new[newMiddle.lowerBound + j]) {
                    pairs.append((old: oldMiddle.lowerBound + i, new: newMiddle.lowerBound + j))
                    i += 1
                    j += 1
                } else if lengths[(i + 1) * width + j] >= lengths[i * width + j + 1] {
                    i += 1
                } else {
                    j += 1
                }
            }
        }

        for k in 0..<suffix {
            pairs.append((old: old.count - suffix + k, new: new.count - suffix + k))
        }
        return pairs
    }
}
