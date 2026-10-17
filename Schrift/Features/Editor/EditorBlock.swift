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
    /// How many levels this block is nested under the list items above it.
    ///
    /// The editor's blocks stay a flat array; nesting is this number, read
    /// against the blocks before it. A block is a child of the nearest earlier
    /// list item one level shallower, which is exactly how markdown indentation
    /// and BlockNote's `blockGroup` children describe the same tree. Only list
    /// items and the media leaves that nest under them (`blockNestsAsLeaf`)
    /// carry a non-zero value, never deeper than `nestingBase` of the block
    /// directly above — `normalizedListIndents` is the rule, and every edit
    /// funnels through it.
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
        && zip(lhs, rhs).allSatisfy { blockContentEqual($0, $1) }
}

/// Whether two blocks show exactly the same thing: same kind, text and nesting level.
func blockContentEqual(_ lhs: EditorBlock, _ rhs: EditorBlock) -> Bool {
    lhs.kind == rhs.kind && lhs.text == rhs.text && lhs.indent == rhs.indent
}

// MARK: - Identity across a content swap

/// Above this many cells the id-reuse LCS table is skipped and the changed middle keeps its
/// fresh ids. The cap bounds main-actor work during install, because each cell can be a string
/// comparison. The common prefix and suffix are trimmed first, so only a document rewritten
/// almost everywhere reaches it — and then the result is what `install` always did.
let maxBlockIDReuseTableCells = 250_000

/// `new`, with every block whose content is unchanged carrying the id it has in `old`.
///
/// `EditorViewModel.install(...)` re-parses a whole markdown body, and a parse mints a fresh
/// `EditorBlock.id` for every block. The reading surface's `ForEach`, the editing canvas's
/// rows, the checklist presentation and `EditorScrollAnchorStore` all key on those ids, so a
/// revalidation that changed one paragraph used to re-identify the entire document: every row
/// was torn down and rebuilt (a visible flash) and any scroll anchor naming a block went stale.
///
/// Matching is **content equality only** (`blockContentEqual`: kind, text and indent) — the
/// longest common subsequence of `old` and `new` under that predicate, after trimming the
/// common prefix and suffix. A matched block takes the old id; **every unmatched block keeps
/// its fresh id**. There is deliberately no positional pairing of changed blocks, even of the
/// same kind: an id is also the editing canvas's native text-view identity (`inputRowID`), and
/// handing a surviving `UITextView` a block whose text changed under it is exactly the
/// reconciliation the marked-text rules refuse to do. A block whose content changed is a
/// different block as far as identity goes, which is what `install` always said; only the
/// blocks nothing touched are now spared.
///
/// Ids stay unique: the LCS is one-to-one, an old id already handed out is never handed out
/// twice (a defensive guard — `old` comes from the screen, whose ids are unique), and an
/// unmatched block whose id collides with one that was reused is minted a new one.
///
/// When `new` has the same content as `old`, the result is equal to `old` — ids included —
/// so the caller can skip the assignment entirely.
func reusingBlockIDs(from old: [EditorBlock], into new: [EditorBlock]) -> [EditorBlock] {
    guard !old.isEmpty, !new.isEmpty else { return new }
    var result = new
    var reused = Set<UUID>()
    var matchedNewIndices = Set<Int>()
    for (oldIndex, newIndex) in blockIDReuseMatches(old: old, new: new) {
        let id = old[oldIndex].id
        guard reused.insert(id).inserted else { continue }
        result[newIndex] = EditorBlock(
            id: id, kind: new[newIndex].kind, text: new[newIndex].text, indent: new[newIndex].indent)
        matchedNewIndices.insert(newIndex)
    }
    var seen = reused
    for index in result.indices where !matchedNewIndices.contains(index) {
        if !seen.insert(result[index].id).inserted {
            let block = result[index]
            let fresh = UUID()
            result[index] = EditorBlock(id: fresh, kind: block.kind, text: block.text, indent: block.indent)
            seen.insert(fresh)
        }
    }
    return result
}

/// The `(old, new)` index pairs whose content is equal, ascending in both coordinates: a
/// longest common subsequence after trimming the common prefix and suffix (a revalidation
/// typically changes a few blocks in the middle). The same shape as
/// `BlockNoteAlignment.anchorPairs`, over editor blocks.
private func blockIDReuseMatches(old: [EditorBlock], new: [EditorBlock]) -> [(Int, Int)] {
    var prefix = 0
    while prefix < old.count, prefix < new.count, blockContentEqual(old[prefix], new[prefix]) {
        prefix += 1
    }
    var suffix = 0
    while suffix < old.count - prefix, suffix < new.count - prefix,
        blockContentEqual(old[old.count - 1 - suffix], new[new.count - 1 - suffix])
    {
        suffix += 1
    }

    var pairs: [(Int, Int)] = (0..<prefix).map { ($0, $0) }

    let oldStart = prefix
    let newStart = prefix
    let rows = old.count - suffix - prefix
    let columns = new.count - suffix - prefix
    if rows > 0, columns > 0, (rows + 1) * (columns + 1) <= maxBlockIDReuseTableCells {
        // lengths[i * width + j] = LCS length of old's middle from i and new's middle from j.
        let width = columns + 1
        var lengths = [Int32](repeating: 0, count: (rows + 1) * width)
        for i in stride(from: rows - 1, through: 0, by: -1) {
            for j in stride(from: columns - 1, through: 0, by: -1) {
                if blockContentEqual(old[oldStart + i], new[newStart + j]) {
                    lengths[i * width + j] = lengths[(i + 1) * width + j + 1] + 1
                } else {
                    lengths[i * width + j] = max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
                }
            }
        }
        var i = 0
        var j = 0
        while i < rows, j < columns {
            if blockContentEqual(old[oldStart + i], new[newStart + j]) {
                pairs.append((oldStart + i, newStart + j))
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
        pairs.append((old.count - suffix + k, new.count - suffix + k))
    }
    return pairs
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

/// Whether a block is a leaf that may nest as a child of the list item above
/// it, the way BlockNote nests a photo or a file under a checklist item: an
/// image, an attachment, or a paragraph that is nothing but one link — the
/// spelling an attachment takes when the document is parsed without a server
/// origin (`parseAttachmentLink`), which must nest exactly as the attachment
/// does or an origin-aware parse and an origin-less one would disagree about
/// the document's structure.
///
/// A leaf never has children of its own: `nestingBase` lets the block after a
/// nested leaf go no deeper than the leaf itself.
func blockNestsAsLeaf(_ block: EditorBlock) -> Bool {
    switch block.kind {
    case .image, .attachment:
        return true
    case .paragraph:
        return paragraphIsLinkLine(block.text)
    case .heading, .bulletItem, .numberedItem, .checklistItem, .quote, .codeBlock, .divider, .unknown:
        return false
    }
}

/// A paragraph whose whole text is a single `[label](url)` link on one line —
/// the origin-free shape `parseAttachmentLink` checks first. A newline would
/// put the link's tail at column zero when the serializer indents it.
func paragraphIsLinkLine(_ text: String) -> Bool {
    !text.contains(where: \.isNewline) && attachmentLinkShape(text) != nil
}

/// The deepest the block *after* `previous` may be nested: one level under a
/// list item, the same level as a nested leaf (its sibling — a leaf has no
/// children), and zero after anything else.
func nestingBase(of previous: EditorBlock) -> Int {
    if blockIsListItem(previous.kind) { return previous.indent + 1 }
    if blockNestsAsLeaf(previous), previous.indent > 0 { return previous.indent }
    return 0
}

/// A block nested under a list item: a list item or a nestable leaf with a
/// non-zero indent. What a list item's subtree is made of.
private func isNestedListChild(_ block: EditorBlock) -> Bool {
    block.indent > 0 && (blockIsListItem(block.kind) || blockNestsAsLeaf(block))
}

/// Clamps every block's `indent` to what its position allows: zero for
/// anything that isn't a list item or a nestable leaf (`blockNestsAsLeaf`), and
/// at most `nestingBase` of the block directly above — one level deeper than a
/// list item, level with a nested leaf, zero after anything else.
///
/// Edits are written freely (a conversion, a merge, a move, a deletion) and
/// this restores the invariant afterwards, so no single edit has to reason
/// about the items around it. An item whose parent disappears is adopted by
/// the item that now precedes it, never stranded at a depth nothing reaches.
/// A document with no nested leaves normalizes exactly as before they existed:
/// a leaf at indent zero gives the block after it a base of zero.
func normalizedListIndents(_ blocks: [EditorBlock]) -> [EditorBlock] {
    var result = blocks
    for index in result.indices {
        let allowed: Int
        if index > 0, blockIsListItem(result[index].kind) || blockNestsAsLeaf(result[index]) {
            allowed = min(nestingBase(of: result[index - 1]), maxListIndent)
        } else {
            allowed = 0
        }
        result[index].indent = max(0, min(result[index].indent, allowed))
    }
    return result
}

/// The end (exclusive) of the list item at `index` together with everything
/// nested under it — deeper list items and the media leaves among them: its
/// children move with it when it is indented or outdented.
func listSubtreeEnd(of index: Int, in blocks: [EditorBlock]) -> Int {
    let depth = blocks[index].indent
    var end = index + 1
    while end < blocks.count, blockIsListItem(blocks[end].kind) || blockNestsAsLeaf(blocks[end]),
        blocks[end].indent > depth
    {
        end += 1
    }
    return end
}

/// Whether the block at `index` can move one level deeper: it is a list item
/// and the block above it allows a deeper level (a list item at its level or
/// deeper, or a nested leaf deeper than it — so there is a parent to nest under).
func canIndentListItem(at index: Int, in blocks: [EditorBlock]) -> Bool {
    guard blocks.indices.contains(index), index > 0, blockIsListItem(blocks[index].kind) else { return false }
    return nestingBase(of: blocks[index - 1]) > blocks[index].indent && blocks[index].indent < maxListIndent
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

// MARK: - Leaf nesting

/// The indents a nestable leaf at `index` may take where it stands, or nil when
/// the block is not one (`blockNestsAsLeaf`).
///
/// The upper bound is `nestingBase` of the block above. The lower bound keeps
/// what follows attached: when the next block is itself nested (a sibling leaf
/// or a sibling list item under the same parent), moving this leaf shallower
/// than it would leave it with no parent to reach, and normalization would
/// pull it — and everything after it — out of the list. A leaf is never the
/// thing that orphans its later siblings.
func leafIndentRange(at index: Int, in blocks: [EditorBlock]) -> ClosedRange<Int>? {
    guard blocks.indices.contains(index), blockNestsAsLeaf(blocks[index]) else { return nil }
    let upper = index > 0 ? min(nestingBase(of: blocks[index - 1]), maxListIndent) : 0
    var lower = 0
    if index + 1 < blocks.count, isNestedListChild(blocks[index + 1]) {
        lower = blocks[index + 1].indent
    }
    return min(lower, upper)...upper
}

/// Whether the nestable leaf at `index` can move one level deeper in place.
func canIndentLeaf(at index: Int, in blocks: [EditorBlock]) -> Bool {
    guard let range = leafIndentRange(at: index, in: blocks) else { return false }
    return blocks[index].indent < range.upperBound
}

/// Whether the nestable leaf at `index` is nested and so can move one level out.
/// Always possible for a nested leaf: when its later siblings pin it in place
/// it moves past them instead (`outdentingLeaf`).
func canOutdentLeaf(at index: Int, in blocks: [EditorBlock]) -> Bool {
    guard blocks.indices.contains(index), blockNestsAsLeaf(blocks[index]) else { return false }
    return blocks[index].indent > 0
}

/// The blocks with the leaf at `index` nested one level deeper, or nil when it
/// can't be. Nothing moves; the leaf joins the list item above (or the level of
/// the nested leaf above).
func indentingLeaf(at index: Int, in blocks: [EditorBlock]) -> [EditorBlock]? {
    guard canIndentLeaf(at: index, in: blocks) else { return nil }
    var result = blocks
    result[index].indent += 1
    return normalizedListIndents(result)
}

/// The blocks with the leaf at `index` one level shallower, or nil when it
/// isn't nested.
///
/// In place when nothing after it depends on its level. Otherwise — a later
/// sibling under the same parent follows — the leaf moves to just after its
/// parent's subtree, at the parent's level, so the siblings keep their parent
/// and the leaf still ends up where an outdent says: one level out, under the
/// parent's own parent.
func outdentingLeaf(at index: Int, in blocks: [EditorBlock]) -> [EditorBlock]? {
    guard canOutdentLeaf(at: index, in: blocks), let range = leafIndentRange(at: index, in: blocks) else {
        return nil
    }
    let newIndent = blocks[index].indent - 1
    var result = blocks
    if newIndent >= range.lowerBound {
        result[index].indent = newIndent
        return normalizedListIndents(result)
    }
    // The parent is the nearest block above that is shallower than the leaf —
    // normalization guarantees it is the list item one level up.
    guard let parent = (0..<index).last(where: { blocks[$0].indent < blocks[index].indent }),
        blockIsListItem(blocks[parent].kind)
    else { return nil }
    let end = listSubtreeEnd(of: parent, in: blocks)
    var leaf = result.remove(at: index)
    leaf.indent = newIndent
    // `end` counted the leaf itself; with it removed, the subtree ends one sooner.
    result.insert(leaf, at: end - 1)
    return normalizedListIndents(result)
}

/// The level a nestable leaf takes where a move lands it, at `index` in the
/// already-reordered `blocks` — or nil when the block is not a nestable leaf.
///
/// Dropped just above a nested block (among a list item's children), it joins
/// that level; otherwise it keeps `originalIndent`, the level it had before the
/// move. Either way no deeper than the block above allows. A `requested` level
/// (a drop that states its own) replaces that choice. The result is always
/// clamped into `leafIndentRange`, so a move can neither strand the leaf nor
/// orphan the siblings after it.
func movedLeafIndent(at index: Int, in blocks: [EditorBlock], originalIndent: Int, requested: Int? = nil) -> Int? {
    guard let range = leafIndentRange(at: index, in: blocks) else { return nil }
    let preferred: Int
    if let requested {
        preferred = requested
    } else {
        let base = index > 0 ? nestingBase(of: blocks[index - 1]) : 0
        let following =
            index + 1 < blocks.count && isNestedListChild(blocks[index + 1]) ? blocks[index + 1].indent : 0
        preferred = min(base, max(originalIndent, following))
    }
    return min(max(preferred, range.lowerBound), range.upperBound)
}

/// The blocks with each of `ids` that sits nested (`indent > 0`) but can no
/// longer nest — a link line an edit turned into prose, an empty paragraph a
/// Return split off one — moved to the top level, just past the nested run
/// that follows it. Every other block is left exactly where and as it is.
///
/// Only list items and leaves hold a level (`normalizedListIndents` zeroes
/// anything else), and zeroing such a block *in place* ends the list there:
/// every nested sibling after it — a photo under the same item — would lose
/// its parent and be flattened with it. Moving it past them keeps the siblings
/// attached and loses no content. The block keeps its id, so its row and its
/// focus follow it; adjacent such blocks move together, in order. The caller
/// still funnels through `markDirty`, whose normalization settles the rest.
func detachingUnnestableBlocks(_ ids: Set<UUID>, in blocks: [EditorBlock]) -> [EditorBlock] {
    func detaches(_ block: EditorBlock) -> Bool {
        ids.contains(block.id) && block.indent > 0 && !blockIsListItem(block.kind) && !blockNestsAsLeaf(block)
    }
    var result = blocks
    var index = 0
    while index < result.count {
        guard detaches(result[index]) else {
            index += 1
            continue
        }
        var groupEnd = index + 1
        while groupEnd < result.count, detaches(result[groupEnd]) { groupEnd += 1 }
        var runEnd = groupEnd
        while runEnd < result.count, isNestedListChild(result[runEnd]) { runEnd += 1 }
        var group = Array(result[index..<groupEnd])
        for position in group.indices { group[position].indent = 0 }
        result.removeSubrange(index..<groupEnd)
        result.insert(contentsOf: group, at: runEnd - group.count)
        index = runEnd
    }
    return result
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
/// sub-list), as are leaves nested deeper (a photo under item 1 does not
/// restart item 2), and the count stops at anything shallower or at a sibling
/// of another list kind — so each level of an outline numbers from 1.
func numberedIndex(of index: Int, in blocks: [EditorBlock]) -> Int {
    let depth = blocks[index].indent
    var position = 1
    var cursor = index - 1
    while cursor >= 0 {
        let level = blocks[cursor].indent
        if level > depth, blockNestsAsLeaf(blocks[cursor]) {
            cursor -= 1
            continue
        }
        guard blockIsListItem(blocks[cursor].kind) else { break }
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

/// `numberedIndex(of:in:)` for every block, in one forward pass.
///
/// The reading surface builds every row eagerly (it is deliberately not lazy),
/// so asking `numberedIndex` per row rescanned the list backwards each time —
/// quadratic for a long numbered list. This keeps, per nesting depth, the length
/// of the run of numbered items that a backwards scan from the current position
/// would count, and updates it by the same rules `numberedIndex` applies while
/// walking back: a deeper list item or nested leaf is skipped (the run at a
/// shallower depth survives it), and anything else that is not a same-depth
/// numbered item ends the run at that depth and every deeper one.
func numberedIndices(in blocks: [EditorBlock]) -> [Int] {
    var runs: [Int] = []
    var result: [Int] = []
    result.reserveCapacity(blocks.count)
    for block in blocks {
        let level = max(block.indent, 0)
        if runs.count <= level { runs.append(contentsOf: repeatElement(0, count: level + 1 - runs.count)) }
        result.append(runs[level] + 1)
        if blockNestsAsLeaf(block) {
            // Skipped only by shallower scans; a same-depth or deeper scan stops here.
            for depth in level..<runs.count { runs[depth] = 0 }
        } else if blockIsListItem(block.kind) {
            for depth in (level + 1)..<max(runs.count, level + 1) { runs[depth] = 0 }
            if case .numberedItem = block.kind { runs[level] += 1 } else { runs[level] = 0 }
        } else {
            for depth in 0..<runs.count { runs[depth] = 0 }
        }
    }
    return result
}
