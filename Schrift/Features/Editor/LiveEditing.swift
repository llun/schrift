import Foundation

/// One editor-block-level change from a live remote update, keyed by the stable
/// `EditorBlock.id` the bridge assigned to a BlockNote id. Applied in order, a
/// change set's `changes` transform the editor's current blocks into the
/// projected sequence (see `liveChangeSet`).
enum LiveBlockChange: Equatable, Sendable {
    /// In-place kind/text change for a surviving block.
    case update(id: UUID, kind: BlockKind, text: String)
    /// A new block. `afterID` is the id it follows in the working sequence, or
    /// `nil` to prepend it at the head.
    case insert(id: UUID, kind: BlockKind, text: String, afterID: UUID?)
    /// A block dropped from the document.
    case remove(id: UUID)
    /// Reorders a surviving block to immediately follow `afterID` (or the head
    /// when `nil`), without touching its kind/text.
    case move(id: UUID, afterID: UUID?)
}

/// An ordered set of block-level changes. Applying `changes` in order to the
/// editor's current blocks reproduces the projected sequence that produced it.
struct LiveChangeSet: Equatable, Sendable {
    var changes: [LiveBlockChange]
}

/// A projected block already rendered to editor vocabulary (see B5's
/// `editorBlock` projection), still keyed by its BlockNote id.
struct ProjectedEditorBlock: Equatable, Sendable {
    var blockNoteID: String
    var kind: BlockKind
    var text: String
}

/// Diffs the editor's current blocks against a freshly projected document,
/// keyed by BlockNote id via `map` (BlockNote id -> `EditorBlock.id`). Pure over
/// value inputs — no dependency on the replica, session, or UIKit.
///
/// `map` supplies the stable `EditorBlock.id` a BlockNote id was previously
/// assigned; a BlockNote id seen for the first time mints a fresh one via
/// `mintID`. The returned map contains exactly the ids in `projected` (a
/// BlockNote id absent from `projected` is dropped).
///
/// Diffing proceeds in two passes over the resolved (BlockNote id ->
/// `EditorBlock.id`) sequence:
///  1. Emit `.remove` for every current block whose id does not survive into
///     the projected sequence.
///  2. Walk the projected order left to right against a simulated working list
///     (the surviving current blocks, in their original relative order),
///     fixing each position in turn: a target id not yet in the working list is
///     an `.insert`; a target id present but out of place is a `.move`; either
///     way, a surviving block whose (kind, text) changed also gets an
///     `.update`. Because each step is checked against the simulated list
///     (not just reasoned about), the working list's prefix always matches the
///     projected prefix seen so far — the invariant that guarantees applying
///     `changes` in order reproduces the projected sequence exactly (id order,
///     kind, text, under the returned id mapping). This is not a minimal-move
///     diff, but the common case (only text changed) emits zero moves.
func liveChangeSet(
    current: [EditorBlock],
    projected: [ProjectedEditorBlock],
    map: [String: UUID],
    mintID: () -> UUID = { UUID() }
) -> (change: LiveChangeSet, map: [String: UUID]) {
    var newMap: [String: UUID] = [:]
    newMap.reserveCapacity(projected.count)
    var resolvedIDs: [UUID] = []
    resolvedIDs.reserveCapacity(projected.count)
    for block in projected {
        let id = map[block.blockNoteID] ?? mintID()
        newMap[block.blockNoteID] = id
        resolvedIDs.append(id)
    }

    // Dedup-tolerant so a (should-never-happen) duplicate block id can't crash the editor's live-apply path.
    let currentByID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let currentIDsInOrder = current.map(\.id)
    let projectedIDsSet = Set(resolvedIDs)
    let survivorSet = Set(currentIDsInOrder).intersection(projectedIDsSet)

    var changes: [LiveBlockChange] = []

    // Pass 1: removes — current blocks that did not survive into the projection.
    for id in currentIDsInOrder where !survivorSet.contains(id) {
        changes.append(.remove(id: id))
    }

    // Pass 2: walk the target order, fixing position then content at each step
    // against a simulated working list seeded with the surviving current blocks
    // (in their original relative order).
    var workingIDs = currentIDsInOrder.filter { survivorSet.contains($0) }
    var previousID: UUID?

    for (index, block) in projected.enumerated() {
        let targetID = resolvedIDs[index]

        if let currentPosition = workingIDs.firstIndex(of: targetID) {
            if currentPosition != index {
                changes.append(.move(id: targetID, afterID: previousID))
                workingIDs.remove(at: currentPosition)
                workingIDs.insert(targetID, at: index)
            }
            if let existing = currentByID[targetID], existing.kind != block.kind || existing.text != block.text {
                changes.append(.update(id: targetID, kind: block.kind, text: block.text))
            }
        } else {
            changes.append(.insert(id: targetID, kind: block.kind, text: block.text, afterID: previousID))
            workingIDs.insert(targetID, at: index)
        }

        previousID = targetID
    }

    return (LiveChangeSet(changes: changes), newMap)
}

/// Caret/selection transform for a single block whose text changed `old` ->
/// `new`, in UTF-16 code units (`NSRange`/`CursorRequest` space — a `String`'s
/// `Character` count is not the right unit for emoji/surrogate pairs).
///
/// Splits `old`/`new` into a common prefix (length `P`) and a common suffix
/// (length `S`, clamped so it never overlaps the prefix):
///  - a caret within the prefix (`caret <= P`) is unchanged;
///  - a caret within the suffix (`caret >= oldLen - S`) shifts by
///    `newLen - oldLen`;
///  - a caret inside the replaced middle clamps to the end of the common
///    prefix (`P`) — the start of the replacement's tail.
///
/// Total: never traps, and the result always lands in `[0, new.utf16.count]`.
func transformedCaret(old: String, new: String, caret: Int) -> Int {
    let oldUnits = Array(old.utf16)
    let newUnits = Array(new.utf16)
    let oldLength = oldUnits.count
    let newLength = newUnits.count
    let maxCommon = min(oldLength, newLength)

    var prefix = 0
    while prefix < maxCommon && oldUnits[prefix] == newUnits[prefix] {
        prefix += 1
    }

    var suffix = 0
    let suffixBudget = maxCommon - prefix
    while suffix < suffixBudget && oldUnits[oldLength - 1 - suffix] == newUnits[newLength - 1 - suffix] {
        suffix += 1
    }

    let result: Int
    if caret <= prefix {
        result = caret
    } else if caret >= oldLength - suffix {
        result = caret + (newLength - oldLength)
    } else {
        result = prefix
    }

    return min(max(result, 0), newLength)
}
