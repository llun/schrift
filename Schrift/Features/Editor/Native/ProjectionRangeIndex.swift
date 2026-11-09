import Foundation

/// UTF-16 document coordinates. Every block owns one UI paragraph separator;
/// that separator is never part of its replica text. Duplicate IDs remain
/// visible but are deliberately not addressable through the ID lookup.
struct ProjectionRangeIndex {
    struct Entry: Equatable {
        let blockID: String
        let range: NSRange
        var textRange: NSRange { NSRange(location: range.location, length: range.length - 1) }
        var separatorRange: NSRange { NSRange(location: NSMaxRange(range) - 1, length: 1) }
    }

    private(set) var entries: [Entry] = []
    private var positions: [String: Int] = [:]
    private(set) var length = 0

    init(blocks: [BlockSnapshot] = [], labels: NativeEditorLabels = NativeEditorLabels()) {
        var duplicates: Set<String> = []
        for block in blocks {
            let count = AttributedDocumentProjection.displayText(for: block, labels: labels).utf16.count + 1
            if positions[block.id] != nil { duplicates.insert(block.id) }
            positions[block.id] = entries.count
            entries.append(Entry(blockID: block.id, range: NSRange(location: length, length: count)))
            length += count
        }
        for id in duplicates { positions[id] = nil }
        positions[""] = nil
    }

    func position(for blockID: String) -> Int? { positions[blockID] }

    /// A text/props patch measures only its block. Shift cached offsets without
    /// walking or reprojecting the text of unaffected blocks.
    mutating func replace(at position: Int, with block: BlockSnapshot, labels: NativeEditorLabels) {
        let previous = entries[position]
        let count = AttributedDocumentProjection.displayText(for: block, labels: labels).utf16.count + 1
        let delta = count - previous.range.length
        entries[position] = Entry(blockID: block.id, range: NSRange(location: previous.range.location, length: count))
        if delta != 0 {
            for following in (position + 1)..<entries.count {
                let entry = entries[following]
                entries[following] = Entry(
                    blockID: entry.blockID,
                    range: NSRange(location: entry.range.location + delta, length: entry.range.length))
            }
            length += delta
        }
        if previous.blockID != block.id {
            positions = [:]
            var seen: Set<String> = []
            var duplicates: Set<String> = []
            for (index, entry) in entries.enumerated() {
                if !seen.insert(entry.blockID).inserted { duplicates.insert(entry.blockID) }
                positions[entry.blockID] = index
            }
            for id in duplicates { positions[id] = nil }
            positions[""] = nil
        }
    }

    func entry(for blockID: String) -> Entry? {
        positions[blockID].map { entries[$0] }
    }

    /// Separators map to their structural owner. The end-of-document boundary
    /// has no owner; it is not a character in the last block's XmlText.
    func entry(atUTF16 offset: Int) -> Entry? {
        position(atUTF16: offset).map { entries[$0] }
    }

    /// A document offset as a block position and an offset in that block's
    /// displayed text: a separator is its block's text end. As a range's upper
    /// bound the end-of-document boundary is the last block's text end; as a
    /// caret it has no owner.
    func textPosition(atUTF16 offset: Int, isUpperBound: Bool = false) -> (position: Int, offset: Int)? {
        if isUpperBound, offset == length, let last = entries.indices.last {
            return (last, entries[last].textRange.length)
        }
        guard let position = position(atUTF16: offset) else { return nil }
        let entry = entries[position]
        return (position, min(offset - entry.textRange.location, entry.textRange.length))
    }

    private func position(atUTF16 offset: Int) -> Int? {
        guard offset >= 0, offset < length else { return nil }
        var lower = 0
        var upper = entries.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if NSMaxRange(entries[middle].range) <= offset { lower = middle + 1 } else { upper = middle }
        }
        return lower < entries.count ? lower : nil
    }

    func documentRange(blockID: String, textRange: Range<Int>) -> NSRange? {
        guard let entry = entry(for: blockID), textRange.lowerBound >= 0,
            textRange.upperBound <= entry.textRange.length
        else { return nil }
        return NSRange(location: entry.range.location + textRange.lowerBound, length: textRange.count)
    }
}
