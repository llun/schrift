import Foundation

enum BlockKind: Equatable, Sendable {
    case heading(level: Int)
    case paragraph
    case bulletItem
    case numberedItem
    case checklistItem(checked: Bool)
    case quote
    case codeBlock(language: String)
    case divider
    /// A standalone `![alt](url)` line with an absolute http(s) URL. `alt` and
    /// `url` are raw `String`s, never re-normalized through `URL`: the backend's
    /// `extract_attachments()` matches the embedded url byte-for-byte, so it must
    /// survive the round trip untouched. `text` stays empty.
    case image(alt: String, url: String)
    /// An uploaded file attachment (PDF, docx, …) the document links to.
    ///
    /// Like `.image`, `name` and `url` are raw `String`s and are never
    /// re-normalized through `URL`: the backend's `extract_attachments()`
    /// matches the embedded url byte-for-byte, and the encoder writes exactly
    /// what is held here. `text` stays empty; this is a leaf.
    ///
    /// A block only becomes one when `parseEditorBlocks` is given the server
    /// origin — see `parseAttachmentLink`. Parsed without one, the identical
    /// markdown stays a `.paragraph`, and both forms serialize to the same line.
    case attachment(name: String, url: String)
    /// Markdown the editor doesn't model (tables, nested lists, HTML, relative or
    /// ambiguous images…). The text is preserved verbatim — including newlines —
    /// so a full-overwrite save never destroys content authored elsewhere.
    case unknown
}

struct EditorBlock: Identifiable, Equatable, Sendable {
    let id: UUID
    var kind: BlockKind
    var text: String
    /// How many levels this list item is nested under the items above it.
    ///
    /// The editor's blocks stay a flat array; nesting is this number, read
    /// against the blocks before it. An item is a child of the nearest earlier
    /// list item one level shallower, which is exactly how markdown indentation
    /// and BlockNote's `blockGroup` children describe the same tree. Only list
    /// items carry a non-zero value, and never deeper than one level below the
    /// list item directly above — `normalizedListIndents` is the rule, and every
    /// edit funnels through it.
    var indent: Int

    init(id: UUID = UUID(), kind: BlockKind, text: String = "", indent: Int = 0) {
        self.id = id
        self.kind = kind
        self.text = text
        self.indent = indent
    }
}

/// Content equality ignoring block identities.
func blocksContentEqual(_ lhs: [EditorBlock], _ rhs: [EditorBlock]) -> Bool {
    lhs.count == rhs.count
        && zip(lhs, rhs).allSatisfy { $0.kind == $1.kind && $0.text == $1.text && $0.indent == $1.indent }
}

// MARK: - List nesting

/// The deepest a list item may be nested. Deep enough for any real outline,
/// and a bound on what a document from elsewhere can make the editor draw: a
/// markdown line nested deeper than this stays verbatim text.
let maxListIndent = 6

/// Whether a block is a bullet, numbered or checklist item — the kinds that
/// nest, and the kinds that form one list when adjacent.
func blockIsListItem(_ kind: BlockKind) -> Bool {
    switch kind {
    case .bulletItem, .numberedItem, .checklistItem:
        return true
    case .heading, .paragraph, .quote, .codeBlock, .divider, .image, .attachment, .unknown:
        return false
    }
}

/// Clamps every block's `indent` to what its position allows: zero for
/// anything that isn't a list item or that follows one that isn't, and at most
/// one level deeper than the list item directly above.
///
/// Edits are written freely (a conversion, a merge, a move, a deletion) and
/// this restores the invariant afterwards, so no single edit has to reason
/// about the items around it. An item whose parent disappears is adopted by
/// the item that now precedes it, never stranded at a depth nothing reaches.
func normalizedListIndents(_ blocks: [EditorBlock]) -> [EditorBlock] {
    var result = blocks
    for index in result.indices {
        let allowed: Int
        if !blockIsListItem(result[index].kind) {
            allowed = 0
        } else if index > 0, blockIsListItem(result[index - 1].kind) {
            allowed = min(result[index - 1].indent + 1, maxListIndent)
        } else {
            allowed = 0
        }
        result[index].indent = max(0, min(result[index].indent, allowed))
    }
    return result
}

/// The end (exclusive) of the list item at `index` together with every item
/// nested under it: its children move with it when it is indented or outdented.
func listSubtreeEnd(of index: Int, in blocks: [EditorBlock]) -> Int {
    let depth = blocks[index].indent
    var end = index + 1
    while end < blocks.count, blockIsListItem(blocks[end].kind), blocks[end].indent > depth {
        end += 1
    }
    return end
}

/// Whether the block at `index` can move one level deeper: it is a list item
/// and the list item above it is at its level or deeper (so there is a parent
/// to nest under).
func canIndentListItem(at index: Int, in blocks: [EditorBlock]) -> Bool {
    guard blocks.indices.contains(index), index > 0, blockIsListItem(blocks[index].kind),
        blockIsListItem(blocks[index - 1].kind)
    else { return false }
    return blocks[index].indent <= blocks[index - 1].indent && blocks[index].indent < maxListIndent
}

/// Whether the block at `index` is a nested list item that can move one level out.
func canOutdentListItem(at index: Int, in blocks: [EditorBlock]) -> Bool {
    guard blocks.indices.contains(index), blockIsListItem(blocks[index].kind) else { return false }
    return blocks[index].indent > 0
}

/// The blocks with the item at `index` and its subtree moved one level in
/// (`by: 1`) or out (`by: -1`), or nil when that move isn't allowed.
///
/// Children travel with their item, so an outline keeps its shape. Outdenting
/// leaves the item's later siblings where they are, so they become its
/// children — the same thing BlockNote does on Shift-Tab.
func shiftingListItem(at index: Int, by delta: Int, in blocks: [EditorBlock]) -> [EditorBlock]? {
    let allowed: Bool
    switch delta {
    case 1:
        allowed = canIndentListItem(at: index, in: blocks)
    case -1:
        allowed = canOutdentListItem(at: index, in: blocks)
    default:
        allowed = false
    }
    guard allowed else { return nil }
    var result = blocks
    for position in index..<listSubtreeEnd(of: index, in: blocks) {
        result[position].indent = min(max(0, result[position].indent + delta), maxListIndent)
    }
    return normalizedListIndents(result)
}

/// Whether a block's text is read as inline markdown — styled while editing,
/// with its syntax hidden — or kept verbatim.
///
/// This must agree with `InlineMarkdown`, which declines to parse a code
/// block's or an `.unknown` block's text: styling those would show formatting
/// the full-overwrite save would never write. `.divider`, `.image` and
/// `.attachment` are leaves with no text at all.
func rendersInlineMarkdown(_ kind: BlockKind) -> Bool {
    switch kind {
    case .codeBlock, .unknown, .divider, .image, .attachment:
        return false
    case .paragraph, .heading, .bulletItem, .numberedItem, .checklistItem, .quote:
        return true
    }
}

/// 1-based position of the block within its contiguous run of numbered items
/// at the same nesting level.
///
/// Items nested deeper are skipped (a numbered list keeps counting across a
/// sub-list), and the count stops at anything shallower or at a sibling of
/// another list kind — so each level of an outline numbers from 1.
func numberedIndex(of index: Int, in blocks: [EditorBlock]) -> Int {
    let depth = blocks[index].indent
    var position = 1
    var cursor = index - 1
    while cursor >= 0, blockIsListItem(blocks[cursor].kind) {
        let level = blocks[cursor].indent
        if level > depth {
            cursor -= 1
            continue
        }
        guard level == depth, case .numberedItem = blocks[cursor].kind else { break }
        position += 1
        cursor -= 1
    }
    return position
}
