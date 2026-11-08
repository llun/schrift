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
struct BlockPatch: Equatable {
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
enum BlockPatchOrigin: Equatable {
    case localUser
    case remote
    /// A transaction with no origin (B4 cleanup, a test), or an authoritative
    /// composition rebuild that every surface must apply.
    case other

    init(_ origin: YTransactionOrigin?) {
        switch origin {
        case .localUser: self = .localUser
        case .remote: self = .remote
        case nil: self = .other
        }
    }
}

/// One change to one block, or to the block list.
enum BlockChange: Equatable {
    /// A text-only change to a block whose element children did not change.
    /// Ranges are block-relative UTF-16 offsets into the **pre-change** text,
    /// and the deltas are ordered and non-overlapping.
    case text(blockID: String, deltas: [TextDelta])
    /// Only the content element's attributes changed; the block's structure and
    /// text are untouched. `props` is the complete new attribute set.
    case props(blockID: String, props: [ProjectedProp])
    /// New blocks, in order, after `after` (`nil` = at the start).
    case insert(after: String?, blocks: [BlockSnapshot])
    /// Blocks that left the document.
    case remove(blockIDs: [String])
    /// The whole-block fallback: inline nodes, split/join, a type change, a
    /// mixed text-and-format delta, a nested change, a container replacement,
    /// or anything else the delta cannot express.
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
struct TextDelta: Equatable {
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

/// One inline mark: a BlockNote attribute key and its raw JSON value
/// (`"{}"` for a boolean mark, `{"href":"…"}` for a link, `"null"` to remove).
struct TextMark: Equatable {
    var key: String
    var valueJSON: String
}

/// A block as a surface renders it: identity, kind, attributes and inline runs.
/// The surface never decides whether a block is writable. `isOpaque` only
/// distinguishes preserved placeholders from genuinely empty text blocks.
struct BlockSnapshot: Equatable {
    var id: String
    var node: String
    var props: [ProjectedProp]
    var runs: [InlineRun]
    var isOpaque: Bool

    init(id: String, node: String, props: [ProjectedProp], runs: [InlineRun], isOpaque: Bool = false) {
        self.id = id
        self.node = node
        self.props = props
        self.runs = runs
        self.isOpaque = isOpaque
    }

    init(_ block: ProjectedBlock) {
        self.init(
            id: block.id, node: block.node, props: block.props, runs: block.runs, isOpaque: block.fidelity.isOpaque)
    }
}
