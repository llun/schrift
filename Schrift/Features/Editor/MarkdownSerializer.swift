import Foundation

/// Serializes editor blocks back to canonical markdown.
///
/// Adjacent list items (bullets, numbered items, checklists) are joined with a
/// single newline so they form one list; all other neighbors are separated by
/// a blank line. Empty paragraphs are dropped — markdown has no representation
/// for them. Output ends with a single trailing newline.
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
            let previous = renderable[index - 1]
            output += isRunKind(previous.kind) && isRunKind(block.kind) ? "\n" : "\n\n"
        }
        output += serializeBlock(block, numberedIndex: numberedIndex(of: index, in: renderable))
    }
    return output + "\n"
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
