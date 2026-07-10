import Foundation

struct BlockShortcutMatch: Equatable {
    let kind: BlockKind
    let remainderText: String
}

/// Notion-style typing shortcuts: when a paragraph's text starts with a
/// markdown prefix followed by a space, the block converts and the prefix is
/// consumed. Checked on every text change of a paragraph block.
func detectMarkdownShortcut(text: String) -> BlockShortcutMatch? {
    if let heading = detectHeadingShortcut(text: text) {
        return heading
    }
    for (prefix, checked) in [("[] ", false), ("[ ] ", false), ("[x] ", true), ("[X] ", true)] {
        if text.hasPrefix(prefix) {
            return BlockShortcutMatch(
                kind: .checklistItem(checked: checked), remainderText: String(text.dropFirst(prefix.count)))
        }
    }
    for prefix in ["- ", "* "] {
        if text.hasPrefix(prefix) {
            return BlockShortcutMatch(kind: .bulletItem, remainderText: String(text.dropFirst(prefix.count)))
        }
    }
    if text.hasPrefix("> ") {
        return BlockShortcutMatch(kind: .quote, remainderText: String(text.dropFirst(2)))
    }
    if let numbered = detectNumberedShortcut(text: text) {
        return numbered
    }
    return nil
}

/// Enter-key shortcuts: a paragraph whose entire text is a fence opening or a
/// divider converts on Return instead of splitting.
func detectEnterShortcut(text: String) -> BlockShortcutMatch? {
    if text.hasPrefix("```"), !text.dropFirst(3).contains("`") {
        let language = text.dropFirst(3).trimmingCharacters(in: .whitespaces)
        return BlockShortcutMatch(kind: .codeBlock(language: language), remainderText: "")
    }
    if text == "---" || text == "***" || text == "___" {
        return BlockShortcutMatch(kind: .divider, remainderText: "")
    }
    return nil
}

/// Wraps or unwraps an inline markdown marker (e.g. `**`, `_`, `` ` ``)
/// around the given UTF-16 range. A collapsed selection inserts a marker pair
/// and places the caret between them; a selection already wrapped by the
/// marker is unwrapped (toggle).
func wrapInlineMarker(text: String, range: NSRange, marker: String) -> (text: String, selection: NSRange) {
    let source = text as NSString
    let markerLength = (marker as NSString).length
    var range = range
    range.location = min(max(0, range.location), source.length)
    range.length = min(max(0, range.length), source.length - range.location)

    if range.length > 0 {
        let before = NSRange(location: range.location - markerLength, length: markerLength)
        let after = NSRange(location: range.location + range.length, length: markerLength)
        if before.location >= 0,
            after.location + after.length <= source.length,
            source.substring(with: before) == marker,
            source.substring(with: after) == marker,
            hugsDelimiterRuns(ofExactly: marker, around: range, in: source)
        {
            var unwrapped = source.replacingCharacters(in: after, with: "")
            unwrapped = (unwrapped as NSString).replacingCharacters(in: before, with: "")
            return (unwrapped, NSRange(location: range.location - markerLength, length: range.length))
        }
        let selected = source.substring(with: range)
        let wrapped = source.replacingCharacters(in: range, with: marker + selected + marker)
        return (wrapped, NSRange(location: range.location + markerLength, length: range.length))
    }

    let inserted = source.replacingCharacters(in: range, with: marker + marker)
    return (inserted, NSRange(location: range.location + markerLength, length: 0))
}

/// Whether the delimiter runs hugging `range` are **exactly** `marker`'s length.
///
/// Without this the unwrap branch lets a short marker eat a longer run. Applying
/// `*` to the selected word of `**word**` finds a `*` on each side, unwraps, and
/// silently downgrades bold to italic — invisibly, because the block editor draws
/// markdown syntax at zero width. The same destruction is reachable from the
/// shipping toolbar: Italic (`_`) on a hand-typed `__word__` used to yield
/// `_word_`. Now both wrap instead, and nothing is lost.
private func hugsDelimiterRuns(ofExactly marker: String, around range: NSRange, in source: NSString) -> Bool {
    let markerString = marker as NSString
    guard markerString.length > 0 else { return true }
    let unit = markerString.character(at: 0)
    // Every marker the editor uses is one character repeated. A mixed marker has
    // no single run to measure, so the substring match alone decides.
    guard (0..<markerString.length).allSatisfy({ markerString.character(at: $0) == unit }) else { return true }

    var leading = 0
    var index = range.location - 1
    while index >= 0, source.character(at: index) == unit {
        leading += 1
        index -= 1
    }

    var trailing = 0
    index = range.location + range.length
    while index < source.length, source.character(at: index) == unit {
        trailing += 1
        index += 1
    }

    return leading == markerString.length && trailing == markerString.length
}

private func detectHeadingShortcut(text: String) -> BlockShortcutMatch? {
    var level = 0
    var index = text.startIndex
    while index < text.endIndex, text[index] == "#", level < 6 {
        level += 1
        index = text.index(after: index)
    }
    guard level > 0, index < text.endIndex, text[index] == " " else { return nil }
    return BlockShortcutMatch(kind: .heading(level: level), remainderText: String(text[text.index(after: index)...]))
}

private func detectNumberedShortcut(text: String) -> BlockShortcutMatch? {
    var index = text.startIndex
    var digits = 0
    while index < text.endIndex, text[index].isNumber, digits < 10 {
        digits += 1
        index = text.index(after: index)
    }
    guard digits >= 1, digits <= 9, index < text.endIndex else { return nil }
    guard text[index] == "." || text[index] == ")" else { return nil }
    index = text.index(after: index)
    guard index < text.endIndex, text[index] == " " else { return nil }
    return BlockShortcutMatch(kind: .numberedItem, remainderText: String(text[text.index(after: index)...]))
}
