import Foundation

// The pure half of the "In this document" sheet: the heading outline built from an open document's
// blocks, find over the blocks' plain text, the per-section match counts, and the previous/next
// stepping. Nothing here touches SwiftUI, so every rule is unit-testable.
//
// This is about the document that is *open*. `PagesTreeDrawer` is about the other pages around it.

/// One heading in the outline.
struct OutlineItem: Identifiable, Equatable, Sendable {
    /// 1...3. Deeper markdown headings are body text as far as the outline goes.
    let level: Int
    /// The heading as the reader sees it (inline markdown stripped, trimmed). Never empty: a
    /// heading with no text is nothing to jump to and is left out of the outline.
    let title: String
    /// The heading's block — the id the reading surface and the editing canvas both scroll by.
    let blockID: UUID
    /// How many matching blocks sit in this heading's section, the heading itself included. A
    /// section runs to the next heading of the same or a shallower level, so a parent counts the
    /// matches under its sub-headings too. Zero while no query is active.
    var matchCount: Int

    var id: UUID { blockID }
}

/// The deepest heading level the outline lists.
let maxOutlineHeadingLevel = 3

/// The text of `block` as a reader sees it, which is what find matches against.
///
/// Inline markdown is stripped with the same scanner the editor and the save path use
/// (`InlineMarkdown.layout`), so a match never depends on `**`, a link's URL or a backslash
/// escape. A code block and markdown the editor does not model are taken verbatim. A photo has no
/// visible text and an attachment shows only its file name.
func outlinePlainText(of block: EditorBlock) -> String {
    switch block.kind {
    case .heading, .paragraph, .bulletItem, .numberedItem, .checklistItem, .quote:
        let source = block.text as NSString
        return InlineMarkdown.layout(of: block.text).spans
            .map { source.substring(with: $0.range) }
            .joined()
    case .codeBlock, .unknown:
        return block.text
    case .attachment(let name, _):
        return name
    case .image, .divider:
        return ""
    }
}

/// The blocks that contain `query`, in document order.
///
/// Case- and diacritic-insensitive (`cafe` finds `Café`), and the query is trimmed. A blank query
/// finds nothing rather than everything.
func findMatchingBlockIDs(in blocks: [EditorBlock], query: String) -> [UUID] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return [] }
    return blocks.compactMap { block in
        outlinePlainText(of: block).range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            ? block.id : nil
    }
}

/// The document's outline: its level 1...3 headings in order, each carrying how many of
/// `matchingBlockIDs` fall in its section.
///
/// A heading with no text is not listed, but it still ends the section above it — the reader sees a
/// gap there, so a match below it is not "in" the previous heading's section. Matches before the
/// first heading belong to no section.
func buildOutline(blocks: [EditorBlock], matchingBlockIDs: [UUID] = []) -> [OutlineItem] {
    let matches = Set(matchingBlockIDs)
    var items: [OutlineItem] = []
    // Indices into `items` of the headings whose section is still open, shallowest first.
    var open: [Int] = []
    for block in blocks {
        if case .heading(let level) = block.kind, (1...maxOutlineHeadingLevel).contains(level) {
            while let last = open.last, items[last].level >= level { open.removeLast() }
            let title = outlinePlainText(of: block).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                items.append(OutlineItem(level: level, title: title, blockID: block.id, matchCount: 0))
                open.append(items.count - 1)
            }
        }
        if matches.contains(block.id) {
            for index in open { items[index].matchCount += 1 }
        }
    }
    return items
}

/// The index to land on after stepping `step` (+1 next, -1 previous) through `count` matches,
/// wrapping at both ends. With no current match yet, next lands on the first and previous on the
/// last. Nil when there is nothing to step through.
func steppedMatchIndex(from current: Int?, by step: Int, count: Int) -> Int? {
    guard count > 0 else { return nil }
    guard let current, (0..<count).contains(current) else { return step >= 0 ? 0 : count - 1 }
    return ((current + step) % count + count) % count
}
