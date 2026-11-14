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
        /// `open` names the expanded toggles among the block and its parent:
        /// BlockNote's Enter reads that view state (PR06b), which never
        /// reaches Yjs. Toggles not named are closed, BlockNote's default.
        case split(offset: Int, newID: String, open: Set<String> = [])
        /// Backspace at `blockID`'s start: a paragraph joins the block above;
        /// a heading or list item resets to a paragraph, a toggle heading to
        /// a heading.
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
        /// Sinks `blockID` into its previous sibling (`sinkListItem`).
        case indent
        /// Lifts `blockID` out of its parent (`liftListItem`).
        case outdent
        /// BlockNote's `moveBlocksUp`/`moveBlocksDown` for `blockID` and its
        /// subtree (PR06d): past a sibling with children into its nearest
        /// child, past the group's end out beside the parent.
        case moveUp
        case moveDown
        /// A copy of `blockID`'s subtree after it, every container taking the
        /// next of `newIDs` in preorder.
        case duplicate(newIDs: [String])
        /// Deletes `blockID` with its subtree.
        case deleteBlock
        /// A new empty paragraph `newID` before or after `blockID`'s subtree.
        case insertBlock(newID: String, before: Bool)
        /// A lossless paste: `payload` (`BlockNoteSubtreePayload`, untrusted)
        /// as siblings after `blockID`'s subtree, replacing `blockID` when it
        /// is an empty paragraph without children. The engine decodes and
        /// bounds the payload and mints a fresh id per container (PR08a).
        case insertSubtrees(payload: Data)
        /// One step of the session's collaborative history (PR07b,
        /// `NativeUndoManager`). `blockID` is unused (empty).
        /// Shift-Return in a table cell paragraph: one BlockNote `hardBreak`
        /// at `offset` (PR11b).
        case lineBreak(offset: Int)
        /// A structure command on a table block (PR11b).
        case table(BlockNoteTableCommand)
        /// A column group's structure (PR12b), on the group's block id.
        /// `expecting`: the group's column ids the command's indices address;
        /// a group whose columns changed since refuses it (nil: no check).
        case columns(BlockNoteColumnCommand, expecting: [String]? = nil)
        /// The slash menu's Columns items (PR12b), on the "/query" paragraph:
        /// `count` columns; `ids` the group's (unless it replaces the
        /// paragraph), then each column's and its paragraph's.
        case insertColumns(count: Int, ids: [String], removing: Range<Int>)
        /// The slash menu's media items (PR13a), on the "/query" paragraph: an
        /// empty `node` block (BlockNote's `insertOrUpdateBlockForSlashMenu`)
        /// in place of the emptied paragraph or after it; `ids` are the new
        /// block's and the trailing paragraph's (either may go unused).
        case insertMedia(node: String, ids: [String], removing: Range<Int>)
        /// Inserts 1..N empty media blocks in one Yjs transaction relative to
        /// `command.blockID`'s enclosing depth-0 block (PR13b.2). `ids` has
        /// `nodes.count` block IDs (`ids[0]` goes unused when item 0 replaces an
        /// empty paragraph in place); `paragraphID` is the optional trailing
        /// root paragraph ID.
        case insertMediaBatch(
            nodes: [String], placement: MediaInsertPlacement, ids: [String], paragraphID: String?)
        /// The slash menu's mathBlock / diagram items (PR14), on the "/query"
        /// paragraph: removes `removing` and replaces the emptied paragraph
        /// (preserving its id) or inserts a new source block with `newID` after it.
        case insertSourceBlock(node: String, newID: String, removing: Range<Int>)
        /// Slash menu `/divider` or `---`/`***`/`___` + Return on a paragraph:
        /// removes `removing` and replaces the emptied paragraph or inserts a
        /// divider block plus an optional trailing paragraph (`ids` holds the
        /// divider's id and the trailing paragraph's id).
        case insertDivider(ids: [String], removing: Range<Int>)
        /// A media block's props (PR13a): BlockNote's `updateBlock`.
        /// `expecting` is the slot an upload started from: a block whose kind
        /// or url changed since refuses the commit.
        case mediaProps([ProjectedProp], expecting: MediaBlock.Slot? = nil)
        /// Inserts a typed inline object replacing `replacing` (block or cell
        /// UTF-16 range, collapsing to `replacing.lowerBound + 1`).
        case insertInlineObject(NativeInlineObject, replacing: Range<Int>)
        /// Inserts an inline `<math>` element replacing `replacing` (plus an
        /// optional trailing space for BlockNote's slash menu).
        case insertInlineMath(replacing: Range<Int>, source: String = "", trailingSpace: Bool = true)
        /// Pastes a decoded inline-slice payload (`BlockNoteInlinePayload`)
        /// over `range` (`replacement` / `newBlockIDs` in `range`).
        case pasteInline(payload: Data, range: NativeRangeCommand)
        case undo
        case redo
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
        case .split, .join, .marks, .props, .blockType, .indent, .outdent, .moveUp, .moveDown, .duplicate,
            .deleteBlock, .insertBlock, .insertSubtrees, .lineBreak, .table, .columns, .insertColumns, .insertMedia,
            .insertMediaBatch, .insertSourceBlock, .insertDivider, .mediaProps, .insertInlineObject,
            .insertInlineMath, .pasteInline, .undo, .redo:
            return ""
        }
    }
}

/// One authoritative patch emitted for a command. Cleanup may emit additional
/// patches; origin alone cannot identify an echo or a cleanup repair.
struct NativePatchStamp: Equatable, Sendable {
    let commandID: UUID
    let baseRevision: UInt64
    let emission: Int
    /// The surface whose command this is (PR08b), set by the replica session
    /// when it delivers; the engine knows no surfaces. A surface skips only its
    /// own predicted commands' echoes.
    var surfaceID: UUID?

    init(commandID: UUID, baseRevision: UInt64, emission: Int, surfaceID: UUID? = nil) {
        self.commandID = commandID
        self.baseRevision = baseRevision
        self.emission = emission
        self.surfaceID = surfaceID
    }
}
