import Foundation

/// The native editor's clipboard. Copy gives one line per block; cut is copy
/// plus one range delete; paste replaces the selection with the pasteboard's
/// plain text as one command, newlines splitting blocks. Since PR06d a copy
/// of whole sibling subtrees (`wholeBlocks`, or the block menu's Copy block)
/// also carries their lossless `BlockNoteSubtreePayload`, which a paste at a
/// caret prefers (`NativeInputCoordinator.pasteFromPasteboard`).
enum NativeClipboard {
    /// The roots of the whole subtrees `range` selects: it runs from a
    /// block's text start to a block's text end, nothing in it is shallower
    /// than its first block, and every later descendant of the last root is
    /// folded away. Nil for any other selection (part of a block, or visible
    /// children left out), which copies as plain text only.
    @MainActor
    static func wholeBlocks(for range: NSRange, surface: NativeTextSurface) -> [String]? {
        let index = surface.rangeIndex
        guard range.length > 0, let start = index.textPosition(atUTF16: range.location),
            let end = index.textPosition(atUTF16: NSMaxRange(range), isUpperBound: true),
            start.offset == 0, end.offset == index.entries[end.position].textRange.length,
            start.position <= end.position
        else { return nil }
        let blocks = surface.blocks
        let depth = blocks[start.position].depth
        guard blocks[start.position...end.position].allSatisfy({ $0.depth >= depth }) else { return nil }
        var next = end.position + 1
        while next < blocks.count, blocks[next].depth > depth {
            guard surface.isHidden(position: next) else { return nil }
            next += 1
        }
        return blocks[start.position...end.position].filter { $0.depth == depth }.map(\.id)
    }

    /// The selected text of every block in the range, one line per block. A
    /// range from a block's end to the next block's start is one line break.
    /// Preserved placeholders contribute nothing: their label is not content.
    /// Neither does a folded toggle's hidden content (PR06b): copy is what shows.
    /// Nil when nothing copyable is selected, so the pasteboard is left alone.
    @MainActor
    static func plainText(for range: NSRange, surface: NativeTextSurface) -> String? {
        let index = surface.rangeIndex
        guard range.length > 0, let start = index.textPosition(atUTF16: range.location),
            let end = index.textPosition(atUTF16: NSMaxRange(range), isUpperBound: true)
        else { return nil }
        var lines: [String] = []
        for position in start.position...end.position {
            let block = surface.blocks[position]
            guard !AttributedDocumentProjection.isPlaceholder(block), !surface.isHidden(position: position) else {
                continue
            }
            // The model's text, not the display: a code block's line breaks are "\n".
            let text = block.runs.map(\.text).joined() as NSString
            let lower = position == start.position ? start.offset : 0
            let upper = position == end.position ? end.offset : text.length
            lines.append(text.substring(with: NSRange(location: lower, length: max(0, upper - lower))))
        }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    /// A paste larger than this is refused whole, never written in part. Both
    /// bounds keep one paste under half the 5,000-paragraph document the
    /// performance tests type into: the range command writes every new block in
    /// one transaction and the surface inserts them in one patch.
    static let maxPasteUTF16 = 200_000
    static let maxPasteLines = 2_000

    static func isTooLarge(_ text: String) -> Bool {
        text.utf16.count > maxPasteUTF16
            || text.utf16.lazy.filter { $0 == 0x0A }.count >= maxPasteLines
    }

    /// Every line break (CRLF, CR, U+2028, U+2029, NEL, …) becomes "\n", the
    /// one separator a range command splits blocks at.
    static func normalizingLineBreaks(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars {
            scalars.append(CharacterSet.newlines.contains(scalar) ? "\n" : scalar)
        }
        return String(scalars)
    }
}
