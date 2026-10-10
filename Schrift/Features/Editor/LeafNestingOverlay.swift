import Foundation

// The server's markdown export loses one piece of structure the editor models: a photo or
// file nested under a list item. BlockNote 0.51.4's `blocksToMarkdownLossy` prints such a
// leaf at column zero after a blank line, and the list it interrupted restarts at the top
// level — so `* a` with children `[image, * b]` exports as `* a`, the image, `* b`, all flat.
// The document's BlockNote tree (`formatted-content/?content_format=json`) still has the
// nesting. This file holds the pure halves of putting it back: a model of what the export
// does (`flattenedLikeServerExport`, which `canonicalMarkdown` also uses), a cheap gate for
// whether a markdown body could be hiding nesting at all, and the overlay itself.

// MARK: - The export's flattening

/// `blocks` as the server's markdown export would read back: every leaf nested under a list
/// item (`blockNestsAsLeaf`, `indent > 0`) at the top level, and the list it interrupted
/// restarted there.
///
/// The model, verified against `@blocknote/server-util` 0.51.4 on every shape in
/// `LeafNestingOverlayTests`: once a nested leaf breaks the list, the next list item starts a
/// new list at depth 0, and the items after it keep their depth *relative to that one* —
/// clamped at 0, and re-anchored whenever an item is shallower than the shift (so a later
/// top-level item and its own children come back unchanged). `T{img, Sub{SubSub}}, Next`
/// exports as `T`, img, `Sub`, `  SubSub`, `Next`; `A{B{img}, C}, D` as `A`, `  B`, img, `C`,
/// `D`. A document with no nested leaf passes through unchanged.
///
/// Leaf-nesting comparisons must go through this rather than merely zeroing leaf indents:
/// zeroing and renormalizing re-attaches the *second* sibling after a leaf (`T{img, Sub,
/// Sub2}` would keep `Sub2` under `Sub`), which the export does not do.
func flattenedLikeServerExport(_ blocks: [EditorBlock]) -> [EditorBlock] {
    var result = normalizedListIndents(blocks)
    // How many levels the current run of list items has been pulled up by.
    var shift = 0
    // A nested leaf ended the list: the next list item opens a new one at the top.
    var listBroken = false
    for index in result.indices {
        let block = result[index]
        if blockIsListItem(block.kind) {
            shift = listBroken ? block.indent : min(shift, block.indent)
            listBroken = false
            result[index].indent = block.indent - shift
        } else if block.indent > 0, blockNestsAsLeaf(block) {
            result[index].indent = 0
            listBroken = true
        } else {
            // Anything else already sits at the top level, and so does whatever follows it.
            shift = 0
            listBroken = false
        }
    }
    return normalizedListIndents(result)
}

// MARK: - When to ask

/// Whether `markdown` could be the export of a document with a leaf nested under a list item:
/// some image, attachment or link line sits at the top level directly after a list item —
/// the only shape the export's flattening produces (the first leaf of a flattened run always
/// follows its parent or something in its parent's subtree, and that is a list item).
///
/// It gates an extra request on every content read, so it is deliberately cheap and
/// deliberately loose: a false positive costs one GET whose overlay then declines; a false
/// negative only means today's flat rendering. Parsed without an origin — an attachment is
/// then a link-line paragraph, which nests exactly alike.
func markdownMayHideLeafNesting(_ markdown: String) -> Bool {
    guard markdown.contains("](") else { return false }
    let blocks = parseEditorBlocks(markdown)
    return blocks.indices.dropFirst().contains { index in
        blocks[index].indent == 0 && blockNestsAsLeaf(blocks[index]) && blockIsListItem(blocks[index - 1].kind)
    }
}

// MARK: - The overlay

/// What a block is matched on, on both sides. List items by kind; media leaves by url,
/// byte-for-byte (the export writes the url it holds, and nothing here normalizes it).
private enum LeafNestingAnchor: Equatable {
    case bulletItem
    case numberedItem
    case checklistItem
    case image(url: String)
    case file(url: String)
}

private func markdownAnchor(_ block: EditorBlock) -> LeafNestingAnchor? {
    switch block.kind {
    case .bulletItem:
        return .bulletItem
    case .numberedItem:
        return .numberedItem
    case .checklistItem:
        return .checklistItem
    case .image(_, let url):
        return .image(url: url)
    case .attachment(_, let url):
        return .file(url: url)
    case .heading, .paragraph, .quote, .codeBlock, .divider, .unknown:
        return nil
    }
}

/// The tree node's anchor, or nil for a node the markdown export does not print as one of
/// the anchored lines — which is then not matched at all.
///
/// - A `video` exports as `![name](url)`, image syntax, so it anchors as an image.
/// - A docs `pdf` block exports as a `[name](url)` link only with `showPreview: false`; with
///   the default preview it exports **nothing** (an `<iframe>` BlockNote cannot print), so it
///   must not be matched against anything.
/// - A media block with no url (the web's empty "add an image" placeholder) exports nothing.
private func treeAnchor(_ node: BlockNoteTreeNode) -> LeafNestingAnchor? {
    let url = node.url.flatMap { $0.isEmpty ? nil : $0 }
    switch node.type {
    case "bulletListItem":
        return .bulletItem
    case "numberedListItem":
        return .numberedItem
    case "checkListItem":
        return .checklistItem
    case "image", "video":
        return url.map { .image(url: $0) }
    case "file":
        return url.map { .file(url: $0) }
    case "pdf":
        return node.showPreview == false ? url.map { .file(url: $0) } : nil
    default:
        return nil
    }
}

private func treeNodeIsListItem(_ node: BlockNoteTreeNode) -> Bool {
    node.type == "bulletListItem" || node.type == "numberedListItem" || node.type == "checkListItem"
}

/// The tree's anchors in document (pre-)order with their depth, or nil when an anchor sits
/// under anything but list items — a photo nested under a paragraph, a heading or a toggle
/// has no spelling in the editor's model, so the whole overlay declines rather than guess.
///
/// Iterative, so a deep tree costs heap rather than stack (the decode already bounds it at
/// `BlockNoteTreeNode.maxNestingDepth`).
private func anchoredTreeNodes(_ nodes: [BlockNoteTreeNode]) -> [(anchor: LeafNestingAnchor, depth: Int)]? {
    var result: [(anchor: LeafNestingAnchor, depth: Int)] = []
    var stack: [(node: BlockNoteTreeNode, depth: Int, underListItemsOnly: Bool)] = nodes.reversed().map {
        (node: $0, depth: 0, underListItemsOnly: true)
    }
    while let entry = stack.popLast() {
        if let anchor = treeAnchor(entry.node) {
            guard entry.underListItemsOnly else { return nil }
            result.append((anchor: anchor, depth: entry.depth))
        }
        let childrenUnderListItemsOnly = entry.underListItemsOnly && treeNodeIsListItem(entry.node)
        for child in entry.node.children.reversed() {
            stack.append((node: child, depth: entry.depth + 1, underListItemsOnly: childrenUnderListItemsOnly))
        }
    }
    return result
}

/// `markdown` — the server's markdown export of a document — with the leaf nesting its
/// BlockNote `tree` holds put back, as the editor's own nested spelling; or nil when the tree
/// cannot be applied with certainty, or would change nothing. **All or nothing**: nil means
/// "install `markdown` as it is", which is exactly the flat rendering the app has always had.
///
/// Every list item, image and attachment is an *anchor*. Both sides list theirs in document
/// order — the markdown's parsed blocks, the tree's pre-order walk with each node's depth —
/// and the sequences must be identical, so the tree can only re-level blocks the markdown
/// already has, one for one. Each anchored block then takes its tree depth: the leaves the
/// export flattened, and also the list items it pulled up after them (`* a` with children
/// `[image, * b]` exports `* b` at the top level too).
///
/// It declines when:
/// - the markdown does not survive the editor's own round trip (`markdownSurvivesRoundTrip`);
/// - the anchor sequences differ (a url, a kind, a block one side has and the other lacks —
///   including a tree and a markdown read from either side of a co-author's write);
/// - an anchor sits under anything but list items in the tree;
/// - the flat model cannot hold a tree depth (`normalizedListIndents` clamped one — e.g. a
///   file's caption, which exports as a paragraph, sits between two children of one item,
///   so the second child has no list item above it to nest under);
/// - the result does not read back as the markdown under the export's flattening
///   (`canonicalMarkdown`, which is `flattenedLikeServerExport` underneath) — the proof that
///   the tree's structure *explains* the markdown rather than contradicting it, e.g. a tree
///   that un-nests a list item the markdown shows nested;
/// - the result does not round-trip through the parser to the same blocks.
///
/// Blocks that are not anchors (paragraphs, headings, a caption) keep their parsed level,
/// which for anything but a list item or leaf is the top.
func markdownRecoveringLeafNesting(_ markdown: String, tree: [BlockNoteTreeNode], serverOrigin: String) -> String? {
    guard markdownSurvivesRoundTrip(markdown, serverOrigin: serverOrigin) else { return nil }
    let parsed = parseEditorBlocks(markdown, serverOrigin: serverOrigin)
    let markdownAnchors: [(index: Int, anchor: LeafNestingAnchor)] = parsed.indices.compactMap { index in
        markdownAnchor(parsed[index]).map { (index: index, anchor: $0) }
    }
    guard let treeAnchors = anchoredTreeNodes(tree), treeAnchors.count == markdownAnchors.count,
        zip(markdownAnchors, treeAnchors).allSatisfy({ $0.anchor == $1.anchor })
    else { return nil }

    var restored = parsed
    for (markdownSide, treeSide) in zip(markdownAnchors, treeAnchors) {
        restored[markdownSide.index].indent = treeSide.depth
    }
    let normalized = normalizedListIndents(restored)
    guard zip(markdownAnchors, treeAnchors).allSatisfy({ normalized[$0.index].indent == $1.depth }),
        normalized.map(\.indent) != parsed.map(\.indent)
    else { return nil }

    let recovered = serializeMarkdown(normalized)
    guard canonicalMarkdown(recovered) == canonicalMarkdown(markdown),
        markdownSurvivesRoundTrip(recovered, serverOrigin: serverOrigin),
        blocksContentEqual(parseEditorBlocks(recovered, serverOrigin: serverOrigin), normalized)
    else { return nil }
    return recovered
}

/// Whether `fetched` should replace `displayed` on a clean screen although the two compare
/// equal (`canonicalMarkdown` is leaf-nesting insensitive): `fetched` nests a leaf, and its
/// structure differs from what is on screen.
///
/// The case it exists for is a body cached flat (before the overlay, or while it could not
/// run) whose revalidation comes back with its nesting restored: same content, so the
/// ordinary "server changed" test says no, and the nesting would only appear on the next
/// open. Deliberately one-way — a *flat* fetch never replaces a nested screen, because a flat
/// read is also what a transiently failed overlay produces.
func fetchedMarkdownRevealsLeafNesting(_ fetched: String, over displayed: String) -> Bool {
    guard fetched != displayed else { return false }
    let fetchedBlocks = parseEditorBlocks(fetched)
    guard fetchedBlocks.contains(where: { $0.indent > 0 && blockNestsAsLeaf($0) }) else { return false }
    return serializeMarkdown(fetchedBlocks) != serializeMarkdown(parseEditorBlocks(displayed))
}
