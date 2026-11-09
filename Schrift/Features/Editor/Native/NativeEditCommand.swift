import Foundation

/// One prevalidated command in replica UTF-16 coordinates. Ordinary typing
/// replaces a block-relative range; Return and boundary Backspace are
/// structural and carry no replacement text; a mark command changes only the
/// attributes of a range.
struct NativeEditCommand: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Ordinary typing. `marks` is the complete mark set the inserted text
        /// carries; `nil` inherits Yjs's marks, those of the character before
        /// the range.
        case replace(range: Range<Int>, replacement: String, marks: [TextMark]? = nil)
        /// Return at `offset`: a split whose new block takes `newID`, or an
        /// empty list item's reset to a paragraph (no block, `newID` unused).
        case split(offset: Int, newID: String)
        /// Backspace at `blockID`'s start: a paragraph joins the block above;
        /// a heading or list item resets to a paragraph.
        case join
        /// One replacement over a range that may span blocks (typing, deleting,
        /// pasting or dictating over a selection) or text with newlines, which
        /// split blocks. `blockID` is the range's first block.
        case range(NativeRangeCommand)
        /// One mark change over a range that may span blocks. `blockID` is the
        /// range's first block; the text is untouched.
        case marks(NativeMarkCommand)
        /// A prop edit on the block's own content element, never a type change:
        /// a checkbox's `checked`, a numbered item's `start`, a code block's
        /// `language`, a callout's `emoji` or a heading's `level`.
        case props([ProjectedProp])
        /// A slash-menu type change (BlockNote's `updateBlock`): `removing` is
        /// the "/query" range deleted in the same transaction, `props` the new
        /// type's overrides (a heading's level).
        case blockType(node: String, props: [ProjectedProp], removing: Range<Int>)
    }

    let id: UUID
    let baseRevision: UInt64
    let blockID: String
    let kind: Kind

    init(id: UUID, baseRevision: UInt64, blockID: String, kind: Kind) {
        self.id = id
        self.baseRevision = baseRevision
        self.blockID = blockID
        self.kind = kind
    }

    /// The ordinary-typing spelling.
    init(
        id: UUID, baseRevision: UInt64, blockID: String, range: Range<Int>, replacement: String,
        marks: [TextMark]? = nil
    ) {
        self.init(
            id: id, baseRevision: baseRevision, blockID: blockID,
            kind: .replace(range: range, replacement: replacement, marks: marks))
    }

    /// The inserted text for an ordinary or range command; empty for a
    /// structural or mark command.
    var replacement: String {
        switch kind {
        case .replace(_, let replacement, _): return replacement
        case .range(let range): return range.replacement
        case .split, .join, .marks, .props, .blockType: return ""
        }
    }
}

/// One authoritative patch emitted for a command. Cleanup may emit additional
/// patches; origin alone cannot identify an echo or a cleanup repair.
struct NativePatchStamp: Equatable, Sendable {
    let commandID: UUID
    let baseRevision: UInt64
    let emission: Int
}
