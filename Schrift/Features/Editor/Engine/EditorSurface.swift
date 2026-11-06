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
/// mutates its storage synchronously) must **reconcile** — the range already
/// holds the replacement, so it is a no-op — rather than insert a second copy.
/// `HeadlessSurface` never mutates on its own, so it applies every patch and
/// its block list equals the replica's projection after each step. There is no
/// optimistic overlay (plan §2.3): the replica is the truth and the patch is
/// how the surface catches up.
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

    init(_ changes: [BlockChange] = []) {
        self.changes = changes
    }

    var isEmpty: Bool { changes.isEmpty }
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
    /// mixed text-and-format delta, or anything else the delta cannot express.
    case replaceBlock(blockID: String, block: BlockSnapshot)
}

/// One replacement inside a block's text.
///
/// `range` is a block-relative UTF-16 range in the pre-change text; an empty
/// range is an insertion. `marks` is the complete mark set the replacement
/// carries, or `nil` to inherit the marks in force at the insertion point.
struct TextDelta: Equatable {
    var range: Range<Int>
    var replacement: String
    var marks: [TextMark]?

    init(range: Range<Int>, replacement: String, marks: [TextMark]? = nil) {
        self.range = range
        self.replacement = replacement
        self.marks = marks
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
