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
///   carries `origin`. A surface that applied a local intent optimistically
///   skips the `.localUser` patch for that edit; a surface that did not (or a
///   remote patch) applies it. Phase 2 may refine this with command ids.
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
/// Composition and selection hooks (`setCompositionDeferred`, `applySelection`)
/// belong to B6b; they are deliberately absent rather than stubbed.
protocol EditorSurface: AnyObject {
    func applyPatch(_ patch: BlockPatch)
}

/// One transaction's worth of change, in document order: removals first, then
/// per-block changes, then insertions.
struct BlockPatch: Equatable {
    var changes: [BlockChange]
    /// Who caused the transaction. A surface that applied a local intent
    /// optimistically skips `.localUser` patches for that edit; a surface with
    /// no optimism (or any `.remote` patch) applies everything.
    var origin: BlockPatchOrigin

    init(_ changes: [BlockChange] = [], origin: BlockPatchOrigin = .other) {
        self.changes = changes
        self.origin = origin
    }

    var isEmpty: Bool { changes.isEmpty }
}

/// The transaction origin a patch came from.
enum BlockPatchOrigin: Equatable {
    case localUser
    case remote
    /// A transaction with no origin — the B4 formatting cleanup, or a test.
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
/// The projection's fidelity is deliberately absent — a surface renders what it
/// is given and never decides whether a block is writable.
struct BlockSnapshot: Equatable {
    var id: String
    var node: String
    var props: [ProjectedProp]
    var runs: [InlineRun]

    init(id: String, node: String, props: [ProjectedProp], runs: [InlineRun]) {
        self.id = id
        self.node = node
        self.props = props
        self.runs = runs
    }

    init(_ block: ProjectedBlock) {
        self.init(id: block.id, node: block.node, props: block.props, runs: block.runs)
    }
}
