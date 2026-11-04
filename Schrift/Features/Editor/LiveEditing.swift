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

/// Replays a single buffered UIKit replacement after a pending remote frame was flushed.
/// Diff in Characters so a replacement never splits a surrogate pair or grapheme; caret
/// offsets remain UTF-16. Remove only original characters the user deleted, keeping peer
/// insertions/replacements, including edits elsewhere in the same block. At a shared
/// insertion boundary the peer's insertion precedes ours. Composition keeps its existing,
/// separate `rebasedCompositionText` policy.
func rebasedLiveInput(
    original: String, committed: String, caret: Int, onto peer: String
) -> (text: String, caret: Int) {
    let old = Array(original)
    let new = Array(committed)
    let target = Array(peer)
    let common = min(old.count, new.count)
    var prefix = 0
    while prefix < common, old[prefix] == new[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < common - prefix, old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }

    let peerDiff = target.difference(from: old)
    var removed = Set<Int>()
    var inserted = Set<Int>()
    for change in peerDiff {
        switch change {
        case .remove(let offset, _, _): removed.insert(offset)
        case .insert(let offset, _, _): inserted.insert(offset)
        }
    }
    // Survivors pair in order. Their identities let us delete the local replacement's
    // old span without deleting new peer characters interleaved within that span.
    let survivors = zip(old.indices.filter { !removed.contains($0) }, target.indices.filter { !inserted.contains($0) })
    var localDeletes = Set<Int>()
    var insertionIndex = target.count
    for (oldIndex, targetIndex) in survivors {
        if oldIndex >= prefix { insertionIndex = min(insertionIndex, targetIndex) }
        if oldIndex >= prefix, oldIndex < old.count - suffix { localDeletes.insert(targetIndex) }
    }
    let before = String(target[..<insertionIndex])
    let replacement = String(new[prefix..<(new.count - suffix)])
    let after = String(
        target[insertionIndex...].enumerated().compactMap { offset, character in
            localDeletes.contains(insertionIndex + offset) ? nil : character
        })
    let merged = before + replacement + after
    let localStart = String(new[..<prefix]).utf16.count
    let localEnd = localStart + replacement.utf16.count
    let userCaret = min(max(0, caret), committed.utf16.count)
    let mergedCaret =
        (localStart...localEnd).contains(userCaret)
        ? before.utf16.count + userCaret - localStart
        : transformedCaret(old: committed, new: merged, caret: userCaret)
    return (merged, mergedCaret)
}

// MARK: - Live-write engagement (C2c)

/// Whether the editor may currently drive live **writes** (C2c). Composes the C1
/// read-engage gate (`EditorViewModel.canEngageLiveEditing`: loaded, clean, no
/// dirty/pending-save/stored-draft/conflict, idle/saved) with the replica being
/// **fully modeled**. A `nil` projection already encodes "no replica / not
/// initial-synced / has pending structs / fail-safed" (the manager returns nil
/// from `projectedReplica` unless `canProjectReplica`), so those facts fold into the
/// single `projection != nil` check — but a reader's projection is not writable, so
/// the bridge also asks `canWriteReplica(for:)`; `isFullyModeled` is the extra write-only
/// requirement, so the tracked `old` baseline can never desync from a lossy/opaque
/// projection. A document with any non-modeled block stays read-live.
func canEngageLiveWrite(canEngageLiveEditing: Bool, projection: ProjectedDocument?) -> Bool {
    guard canEngageLiveEditing, let projection else { return false }
    return projection.isFullyModeled
}

/// The editor's outbound live-write seam, implemented by `LiveEditingBridge` (which
/// owns the `DocumentCollaborationManager` reference) and held **weakly** by
/// `EditorViewModel`. This is how the write path is threaded into `markDirty`
/// without the manager ever entering the view model.
@MainActor
protocol EditorLiveWriteCoordinating: AnyObject {
    /// Flush a pending remote frame BEFORE changing blocks, indices or selection.
    /// `forwardLocalEdit` runs after the mutation and is too late to do this safely.
    func prepareForLocalEdit()
    /// Forward one local edit to the shared replica if live-write mode is engaged.
    /// Returns `true` when the edit was handled live (the replica integrated + peers
    /// were notified and a snapshot scheduled), meaning the classic REST autosave
    /// must NOT also run. Returns `false` when not engaged (or a malformed replica
    /// fail-safed), in which case the caller proceeds down the classic path —
    /// this is the downgrade to classic.
    func forwardLocalEdit() -> Bool
    /// Whether a local edit made **right now** would be handled live rather than by the
    /// classic REST path — `forwardLocalEdit`'s own condition, evaluated without any of its
    /// side effects.
    ///
    /// It exists for one caller: queueing a photo offline. A queued photo enters the document
    /// as a `schrift-attachment://` placeholder, which the save coordinator's gates keep off
    /// the server — but the live write path never *becomes* a save. `markDirty` forwards here
    /// and returns without enqueuing, so an edit made while live editing is engaged is
    /// broadcast straight to peers, and `canEngageLiveWrite` cannot catch it because
    /// `YBlockProjection` models any string url, placeholder included. So the insert refuses
    /// to queue while this is true rather than relying on gates that never see the edit.
    var isHandlingLocalEditsLive: Bool { get }
    /// Fire any pending debounced live snapshot immediately (Done / background /
    /// disappear). A no-op when nothing is pending.
    func flushPendingLiveSnapshot()
}

extension EditorLiveWriteCoordinating {
    // Classic-only test delegates have no remote frame to flush.
    func prepareForLocalEdit() {}
}
