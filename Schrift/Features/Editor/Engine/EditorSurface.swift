import Foundation

// MARK: - The surface boundary (B6a)

/// Model → UI. The one channel through which a surface learns that the
/// document changed: the engine never hands a surface the replica, and a
/// surface never reads one.
///
/// **Patches are authoritative and describe a transition, not a state.** A
/// patch is built from one transaction and is meant to be applied to a surface
/// that holds the document *as it was before that transaction*. The engine
/// emits a patch for a local intent exactly as it does for a remote update, so
/// a surface that already applied the keystroke itself (a UIKit text view
/// mutates its storage synchronously) must **reconcile** rather than apply the
/// change twice. The rule, per change kind:
///
/// - `.text`: each delta's `range` is in the surface's **pre-change** text.
///   Content inspection cannot tell "already applied" from "not applied" (a
///   displayed `"a"` plus a delete of `0..<1` is ambiguous), so the patch
///   carries an optional command stamp. Reconcile that exact command, never
///   suppress all `.localUser` patches. Native input intercepts UIKit before
///   its mutation and applies the engine echo after the journal is durable.
/// - `.replaceBlock`: assign the snapshot; idempotent.
/// - `.props`: assign the attribute set; idempotent.
/// - `.insert`: skip blocks whose id is already present; `.remove`: skip ids
///   already absent.
/// - `.reset`: replace the whole block list; idempotent.
///
/// A surface that never mutates on its own (a fresh renderer) applies every
/// patch unconditionally and converges. `HeadlessSurface` is that reference
/// implementation. There is no optimistic overlay (plan §2.3): the replica is
/// the truth and the patch is how the surface catches up.
///
/// During composition, `setCompositionDeferred(true)` means the composing
/// block's patches are discarded and replaced by an authoritative rebuild on
/// commit/cancel, then deferral clears. Structural invalidation may require
/// a whole-list reset. Selection is queried with `DocumentEngine.currentSelection`
/// after patches; its offsets resolve against the current replica, even while
/// the surface's composing block is intentionally frozen.
/// Input offsets always use replica coordinates, not the frozen display.
/// Selection endpoints and local intents targeting a deferred block throw
/// `.composingBlock`; joins also check the destination. These blocks stay locked
/// until `setCompositionDeferred(false)`, after the final rebuild is delivered.
/// If a structural change requires a whole-list reset, every block is locked
/// with `.composingBlock`. That global lock persists through pending reset
/// delivery and chained restarts until the deferral-complete signal.
/// An explicit-offset restart into a locked block is rejected too. A restart
/// from the existing relative selection (no `at:`) is safe and supported.
/// A composition restarted from `applyPatch` after commit/cancel keeps deferral
/// continuous; completion of the previous composition cannot clear the new one.
protocol EditorSurface: AnyObject {
    func applyPatch(_ patch: BlockPatch)
    func setCompositionDeferred(_ deferred: Bool)
}

extension EditorSurface {
    /// Surfaces without marked text need no deferral state.
    func setCompositionDeferred(_ deferred: Bool) {}
}

/// One transaction's worth of change, in document order: removals first, then
/// per-block changes, then insertions.
struct BlockPatch: Equatable, Sendable {
    var changes: [BlockChange]
    /// Present only for explicitly identified native commands. Untagged local
    /// patches and authoritative `.other` rebuilds must always be applied.
    var nativeCommand: NativePatchStamp?
    /// Who caused the transaction. Origin alone never identifies an already
    /// displayed command; `nativeCommand` identifies its individual emissions.
    /// Untagged patches always apply. Composition
    /// rebuilds are always `.other`, never `.localUser`, and must always be
    /// applied: they include discarded peer edits as well as committed text.
    var origin: BlockPatchOrigin

    init(_ changes: [BlockChange] = [], origin: BlockPatchOrigin = .other, nativeCommand: NativePatchStamp? = nil) {
        self.changes = changes
        self.origin = origin
        self.nativeCommand = nativeCommand
    }

    var isEmpty: Bool { changes.isEmpty }
}

/// A patch's cause/delivery policy; composition rebuilds use `.other` even when
/// the commit wrote through a `.localUser` transaction.
enum BlockPatchOrigin: Equatable, Sendable {
    case localUser
    case remote
    /// A transaction with no origin (B4 cleanup, a test), or an authoritative
    /// composition rebuild that every surface must apply.
    case other

    init(_ origin: YTransactionOrigin?) {
        switch origin {
        case .localUser: self = .localUser
        case .remote: self = .remote
        case .undoManager, nil: self = .other
        }
    }
}

/// One change to one block, or to the block list.
enum BlockChange: Equatable, Sendable {
    /// A text-only change to a block whose element children did not change.
    /// Ranges are block-relative UTF-16 offsets into the **pre-change** text,
    /// and the deltas are ordered and non-overlapping.
    case text(blockID: String, deltas: [TextDelta])
    /// Only the content element's attributes changed; the block's structure and
    /// text are untouched. `props` is the complete new attribute set.
    case props(blockID: String, props: [ProjectedProp])
    /// New blocks, in order, after `after` (`nil` = at the start), in the
    /// preorder list: a nested block follows its parent or previous sibling's
    /// last descendant, and carries its own `depth`/`parentID`.
    case insert(after: String?, blocks: [BlockSnapshot])
    /// Blocks that left the document.
    case remove(blockIDs: [String])
    /// The whole-block fallback: inline nodes, split/join, a type change, a
    /// mixed text-and-format delta, a container replacement (a clone-and-delete
    /// move to another depth or parent), or anything else the delta cannot
    /// express.
    case replaceBlock(blockID: String, block: BlockSnapshot)
    /// The whole block list, replacing whatever the surface holds. Emitted when
    /// the fragment root or the root group is added, removed or replaced — a
    /// change with no block-relative spelling.
    case reset([BlockSnapshot])
}

/// One replacement inside a block's text.
///
/// `range` is a block-relative UTF-16 range in the pre-change text; an empty
/// range is an insertion.
///
/// **`marks` contract.** `nil` means *inherit* the marks in force at the
/// insertion point (the character to the left, else the one to the right) —
/// the convenience form a surface uses when it builds a delta for a local
/// keystroke. The engine's `PatchBuilder` never emits `nil`: it always sends
/// the complete mark set, including `[]` for "no marks in force", so a surface
/// applying a patch never inherits by accident. A deletion carries no marks.
struct TextDelta: Equatable, Sendable {
    var range: Range<Int>
    var replacement: String
    var marks: [TextMark]?

    init(range: Range<Int>, replacement: String, marks: [TextMark]? = nil) {
        self.range = range
        self.replacement = replacement
        self.marks = marks
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

extension TextDelta {
    /// `range`, a block-relative UTF-16 range in `blockID`'s text before
    /// `changes`, mapped into the text after them (PR08b's rebase of a
    /// predicted command through a concurrent change). Both sides of the
    /// replica session call this, so they agree. Changes to other blocks leave
    /// it alone, and so do prop changes. Nil when it cannot be mapped: the
    /// block was replaced, removed or reset, or a delta overlaps the range's
    /// interior. An insertion exactly at an empty range moves it after the
    /// inserted text when `assoc >= 0`; a non-empty range keeps insertions at
    /// its boundaries outside.
    static func rebase(range: Range<Int>, assoc: Int, through changes: [BlockChange], blockID: String) -> Range<Int>? {
        var range = range
        for change in changes {
            switch change {
            case .text(let id, let deltas) where id == blockID:
                guard let mapped = rebase(range: range, assoc: assoc, through: deltas) else { return nil }
                range = mapped
            case .props, .text, .insert: continue
            case .replaceBlock(let id, _): if id == blockID { return nil }
            case .remove(let ids): if ids.contains(blockID) { return nil }
            case .reset: return nil
            }
        }
        return range
    }

    /// `range` through one patch's ordered, non-overlapping deltas.
    static func rebase(range: Range<Int>, assoc: Int, through deltas: [TextDelta]) -> Range<Int>? {
        var shift = 0
        for delta in deltas {
            let before: Bool
            if range.isEmpty {
                let point = range.lowerBound
                if delta.range.lowerBound < point, point < delta.range.upperBound { return nil }
                // An insertion exactly at the point is before it only with `assoc >= 0`.
                before =
                    delta.range.upperBound < point
                    || (delta.range.upperBound == point && (!delta.range.isEmpty || assoc >= 0))
            } else {
                if delta.range.upperBound <= range.lowerBound {
                    before = true
                } else if delta.range.lowerBound >= range.upperBound {
                    before = false
                } else {
                    return nil
                }
            }
            guard before else { break }
            shift += delta.replacement.utf16.count - delta.range.count
        }
        return (range.lowerBound + shift)..<(range.upperBound + shift)
    }

    /// `deltas` (a concurrent change to the same text) mapped through a
    /// replacement of `range` by `length` UTF-16 units: the other half of
    /// `rebase`. An insertion at either end of the range stays outside it, at
    /// its start before the replacement (as `rebase` with `assoc >= 0` moves
    /// an empty range after it). Nil when a delta overlaps the range's interior.
    static func rebase(_ deltas: [TextDelta], throughReplacing range: Range<Int>, length: Int) -> [TextDelta]? {
        let grown = length - range.count
        var out: [TextDelta] = []
        for var delta in deltas {
            if delta.range.upperBound <= range.lowerBound {
                out.append(delta)
            } else if delta.range.lowerBound >= range.upperBound {
                delta.range = (delta.range.lowerBound + grown)..<(delta.range.upperBound + grown)
                out.append(delta)
            } else {
                return nil
            }
        }
        return out
    }
}

/// One inline mark: a BlockNote attribute key and its raw JSON value
/// (`"{}"` for a boolean mark, `{"href":"…"}` for a link, `"null"` to remove).
struct TextMark: Equatable, Sendable {
    var key: String
    var valueJSON: String
}

/// A block as a surface renders it: identity, kind, attributes and inline runs,
/// and where it sits in the tree (PR06a): the native projection is a preorder
/// list, so `depth` and `parentID` are all a renderer needs to indent and to
/// number per sibling run. The surface never decides whether a block is
/// writable. `isOpaque` only distinguishes preserved placeholders from
/// genuinely empty text blocks.
struct BlockSnapshot: Equatable, Sendable {
    var id: String
    var node: String
    var props: [ProjectedProp]
    var runs: [InlineRun]
    var isOpaque: Bool
    var depth = 0
    var parentID: String?
    /// A non-prose block's bounded preview (PR06e). Display only.
    var preview: NativeBlockPreview?

    init(
        id: String, node: String, props: [ProjectedProp], runs: [InlineRun], isOpaque: Bool = false, depth: Int = 0,
        parentID: String? = nil, preview: NativeBlockPreview? = nil
    ) {
        self.id = id
        self.node = node
        self.props = props
        self.runs = runs
        self.isOpaque = isOpaque
        self.depth = depth
        self.parentID = parentID
        self.preview = preview
    }

    init(_ block: ProjectedBlock) {
        self.init(
            id: block.id, node: block.node, props: block.props, runs: block.runs, isOpaque: block.fidelity.isOpaque)
    }

    init(_ native: NativeBlockSnapshot) {
        self.init(native.block)
        depth = native.depth
        parentID = native.parentID
        preview = native.preview
    }
}
