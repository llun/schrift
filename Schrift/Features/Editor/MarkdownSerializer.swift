import Foundation

/// Serializes editor blocks back to canonical markdown.
///
/// Adjacent list items (bullets, numbered items, checklists) and adjacent
/// quote lines are joined with a single newline so they keep forming one
/// structure; indented `.unknown` continuation content (nested lists, indented
/// code under a list item) stays tightly bound to its classified neighbors.
/// All other neighbors are separated by a blank line. Empty paragraphs are
/// dropped — markdown has no representation for them. Output ends with a
/// single trailing newline.
func serializeMarkdown(_ blocks: [EditorBlock]) -> String {
    let renderable = blocks.filter { block in
        if case .paragraph = block.kind, block.text.isEmpty {
            return false
        }
        return true
    }
    guard !renderable.isEmpty else { return "" }

    var output = ""
    for (index, block) in renderable.enumerated() {
        if index > 0 {
            output += joinsTightly(renderable[index - 1], block) ? "\n" : "\n\n"
        }
        output += serializeBlock(block, numberedIndex: numberedIndex(of: index, in: renderable))
    }
    return output + "\n"
}

private func joinsTightly(_ first: EditorBlock, _ second: EditorBlock) -> Bool {
    if isRunKind(first.kind), isRunKind(second.kind) {
        return true
    }
    if first.kind == .quote, second.kind == .quote {
        return true
    }
    // Indented continuation content binds to an adjacent classified block; a
    // blank line would restructure it (e.g. turn a tight nested list loose).
    // Only classified neighbors are safe to join: a paragraph or another
    // unknown next to it would be absorbed into one unknown run on re-parse.
    if isIndentedUnknown(first), isColumnZeroClassified(second.kind) {
        return true
    }
    if isColumnZeroClassified(first.kind), isIndentedUnknown(second) {
        return true
    }
    return false
}

private func isIndentedUnknown(_ block: EditorBlock) -> Bool {
    guard block.kind == .unknown else { return false }
    return block.text.hasPrefix(" ") || block.text.hasPrefix("\t")
}

private func isColumnZeroClassified(_ kind: BlockKind) -> Bool {
    switch kind {
    case .paragraph, .unknown:
        return false
    default:
        return true
    }
}

func serializeBlock(_ block: EditorBlock, numberedIndex: Int) -> String {
    switch block.kind {
    case .heading(let level):
        return String(repeating: "#", count: max(1, min(6, level))) + " " + block.text
    case .paragraph:
        return block.text
    case .bulletItem:
        return "- " + block.text
    case .numberedItem:
        return "\(numberedIndex). " + block.text
    case .checklistItem(let checked):
        return (checked ? "- [x] " : "- [ ] ") + block.text
    case .quote:
        return "> " + block.text
    case .codeBlock(let language):
        let fence = String(repeating: "`", count: max(3, longestBacktickRun(in: block.text) + 1))
        if block.text.isEmpty {
            return fence + language + "\n" + fence
        }
        return fence + language + "\n" + block.text + "\n" + fence
    case .divider:
        return "---"
    case .image(let alt, let url):
        return "![\(alt)](\(url))"
    case .unknown:
        return block.text
    }
}

private func isRunKind(_ kind: BlockKind) -> Bool {
    switch kind {
    case .bulletItem, .numberedItem, .checklistItem:
        return true
    default:
        return false
    }
}

private func longestBacktickRun(in text: String) -> Int {
    var longest = 0
    var current = 0
    for character in text {
        if character == "`" {
            current += 1
            longest = max(longest, current)
        } else {
            current = 0
        }
    }
    return longest
}
