import Foundation

/// Plain-text clipboard for the native editor. Copy gives one line per block;
/// cut is copy plus one range delete; paste replaces the selection with the
/// pasteboard's plain text as one command, newlines splitting blocks (rich
/// content contributes only its plain text). Lossless rich and subtree
/// transfer is PR06.
enum NativeClipboard {
    /// The selected text of every block in the range, one line per block. A
    /// range from a block's end to the next block's start is one line break.
    /// Preserved placeholders contribute nothing: their label is not content.
    @MainActor
    static func plainText(for range: NSRange, surface: NativeTextSurface) -> String? {
        let index = surface.rangeIndex
        guard range.length > 0, let start = index.textPosition(atUTF16: range.location),
            let end = index.textPosition(atUTF16: NSMaxRange(range), isUpperBound: true)
        else { return nil }
        var lines: [String] = []
        for position in start.position...end.position {
            let block = surface.blocks[position]
            guard !AttributedDocumentProjection.isPlaceholder(block) else { continue }
            let text = AttributedDocumentProjection.displayText(for: block, labels: surface.labels) as NSString
            let lower = position == start.position ? start.offset : 0
            let upper = position == end.position ? end.offset : text.length
            lines.append(text.substring(with: NSRange(location: lower, length: max(0, upper - lower))))
        }
        return lines.joined(separator: "\n")
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
