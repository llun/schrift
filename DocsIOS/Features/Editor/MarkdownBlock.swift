import Foundation

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case bulletItem(text: String)
    case checklistItem(checked: Bool, text: String)
    case quote(text: String)
}

func parseMarkdownBlocks(_ markdown: String) -> [MarkdownBlock] {
    markdown
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .map(parseMarkdownLine)
}

private func parseMarkdownLine(_ line: String) -> MarkdownBlock {
    if let heading = parseHeading(line) {
        return heading
    }
    if let checklistItem = parseChecklistItem(line) {
        return checklistItem
    }
    if let bullet = parseBulletItem(line) {
        return bullet
    }
    if let quote = parseQuote(line) {
        return quote
    }
    return .paragraph(text: line)
}

private func parseHeading(_ line: String) -> MarkdownBlock? {
    var level = 0
    var index = line.startIndex
    while index < line.endIndex, line[index] == "#", level < 6 {
        level += 1
        index = line.index(after: index)
    }
    guard level > 0, index < line.endIndex, line[index] == " " else { return nil }
    let text = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
    return .heading(level: level, text: text)
}

private func parseChecklistItem(_ line: String) -> MarkdownBlock? {
    for prefix in ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] ", "* [X] "] {
        if line.hasPrefix(prefix) {
            let checked = prefix.contains("x") || prefix.contains("X")
            let text = String(line.dropFirst(prefix.count))
            return .checklistItem(checked: checked, text: text)
        }
    }
    return nil
}

private func parseBulletItem(_ line: String) -> MarkdownBlock? {
    for prefix in ["- ", "* "] {
        if line.hasPrefix(prefix) {
            return .bulletItem(text: String(line.dropFirst(prefix.count)))
        }
    }
    return nil
}

private func parseQuote(_ line: String) -> MarkdownBlock? {
    guard line.hasPrefix(">") else { return nil }
    let rest = line.dropFirst()
    return .quote(text: rest.trimmingCharacters(in: .whitespaces))
}
