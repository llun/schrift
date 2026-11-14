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
        guard
            blocks[start.position...end.position].allSatisfy({
                $0.depth >= depth && $0.node != "tableParagraph" && !TableGrid.isParagraphID($0.id)
            })
        else { return nil }
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
    static func plainText(for range: NSRange, surface: NativeTextSurface, serverOrigin: String = "") -> String? {
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
            let total = index.entries[position].textRange.length
            let lower = position == start.position ? start.offset : 0
            let upper = position == end.position ? end.offset : total
            lines.append(plainText(in: block, range: lower..<max(lower, upper), serverOrigin: serverOrigin))
        }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    @MainActor
    static func touchesInlineObject(_ range: NSRange, surface: NativeTextSurface) -> Bool {
        let index = surface.rangeIndex
        guard range.length > 0, let start = index.textPosition(atUTF16: range.location),
            let end = index.textPosition(atUTF16: NSMaxRange(range), isUpperBound: true)
        else { return false }
        for position in start.position...end.position {
            let block = surface.blocks[position]
            guard block.hasInlineObjects, !AttributedDocumentProjection.isPlaceholder(block),
                !surface.isHidden(position: position)
            else { continue }
            let lower = position == start.position ? start.offset : 0
            let upper = position == end.position ? end.offset : index.entries[position].textRange.length
            let selected = lower..<max(lower, upper)
            var offset = 0
            for run in block.runs {
                let len = (run.text as NSString).length
                let runRange = offset..<(offset + len)
                offset += len
                if run.inlineObject != nil, runRange.overlaps(selected) {
                    return true
                }
            }
        }
        return false
    }

    @MainActor
    static func inlineSlices(for range: NSRange, surface: NativeTextSurface) -> [ReplicaInlineSlice]? {
        let index = surface.rangeIndex
        guard range.length > 0, let start = index.textPosition(atUTF16: range.location),
            let end = index.textPosition(atUTF16: NSMaxRange(range), isUpperBound: true)
        else { return nil }
        var slices: [ReplicaInlineSlice] = []
        for position in start.position...end.position {
            let block = surface.blocks[position]
            guard !AttributedDocumentProjection.isPlaceholder(block), !surface.isHidden(position: position) else {
                continue
            }
            let total = index.entries[position].textRange.length
            let lower = position == start.position ? start.offset : 0
            let upper = position == end.position ? end.offset : total
            slices.append(ReplicaInlineSlice(blockID: block.id, range: lower..<max(lower, upper)))
        }
        return slices.isEmpty ? nil : slices
    }

    private static func plainText(in block: BlockSnapshot, range: Range<Int>, serverOrigin: String) -> String {
        var offset = 0
        var result = ""
        for run in block.runs {
            let runNS = run.text as NSString
            let length = runNS.length
            let runEnd = offset + length
            let sliceLower = max(range.lowerBound, offset)
            let sliceUpper = min(range.upperBound, runEnd)
            if sliceLower < sliceUpper {
                if let inline = run.inlineObject {
                    result += plainText(for: inline, serverOrigin: serverOrigin)
                } else {
                    result += runNS.substring(
                        with: NSRange(location: sliceLower - offset, length: sliceUpper - sliceLower))
                }
            }
            offset = runEnd
        }
        return result
    }

    private static func plainText(for inline: NativeInlineObject, serverOrigin: String) -> String {
        switch inline {
        case .mention:
            return inline.visibleText
        case .mentionSearch:
            return ""
        case .math(let source):
            return strippingObjectReplacementCharacters(source)
        case .interlink(let docID, _, _, let disabled, _):
            guard !disabled else { return "" }
            let origin = NativeInlineObject.trimmingTrailingSlashes(serverOrigin)
            if !origin.isEmpty, !docID.isEmpty, let encoded = NativeInlineObject.encodeURIComponent(docID) {
                return "\(origin)/docs/\(encoded)/"
            }
            return inline.visibleText
        }
    }

    static func strippingObjectReplacementCharacters(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{fffc}", with: "")
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
