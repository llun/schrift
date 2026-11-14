import Foundation

/// BlockNote 0.56's inline styles as the native editor writes them: Yjs
/// format attributes beside the text, never characters in it. A boolean style
/// is `{}`, a colour `{"stringValue":"red"}` and a link `{"href":"…"}`.
enum NativeMark {
    /// The boolean styles the formatting bar toggles.
    static let toggles = ["bold", "italic", "underline", "strike", "code"]
    /// BlockNote's colour names, in its palette order.
    static let colors = ["gray", "brown", "red", "orange", "yellow", "green", "blue", "purple", "pink"]
    static let textColor = "textColor"
    static let backgroundColor = "backgroundColor"
    static let link = "link"
    private static let known: Set<String> = Set(toggles + [textColor, backgroundColor, link])

    static func colorValue(_ name: String) -> String { json(["stringValue": name]) }

    /// Built like the Markdown writer's link value (`JSONSerialization`, no
    /// escaped slashes), so the stored bytes match it.
    static func linkValue(_ href: String) -> String { json(["href": href]) }

    static func colorName(from valueJSON: String) -> String? {
        guard let data = valueJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["stringValue"] as? String
    }

    /// BlockNote's link does not grow from its edges (`inclusive: false`).
    /// Marks this build does not know are treated the same way, so typing
    /// never spreads a mark whose behaviour is unknown.
    static func isInclusive(_ key: String) -> Bool { key != link && known.contains(key) }

    private static func json(_ object: [String: String]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

/// One mark change over a document-ordered range that may span blocks: it
/// starts in the command's `blockID` at `startOffset` and ends in
/// `endBlockID` at `endOffset` (replica UTF-16 offsets). `attributes` names
/// only the keys that change (`"null"` removes one), so every other mark in
/// the range, known or not, is kept.
struct NativeMarkCommand: Equatable, Sendable {
    let startOffset: Int
    let endBlockID: String
    let endOffset: Int
    let attributes: [TextMark]
}

/// The marks at a selection, read from the surface's runs with ProseMirror's
/// rules, which BlockNote's typing follows.
enum NativeMarkSelection {
    typealias Span = (range: Range<Int>, marks: [TextMark])

    static func spans(_ runs: [InlineRun]) -> [Span] {
        var cursor = 0
        return runs.map { run in
            let length = run.text.utf16.count
            defer { cursor += length }
            return (cursor..<(cursor + length), run.marks.map { TextMark(key: $0.key, valueJSON: $0.valueJSON) })
        }
    }

    /// `$pos.marks()`: inside a run, its marks; at a boundary, the run before's
    /// (else the run after's) without the non-inclusive marks the other side
    /// lacks. An empty block has none.
    static func typing(_ runs: [InlineRun], at offset: Int) -> [TextMark] {
        let spans = spans(runs)
        if let inside = spans.first(where: { $0.range.lowerBound < offset && offset < $0.range.upperBound }) {
            return inside.marks
        }
        let before = spans.last { !$0.range.isEmpty && $0.range.upperBound == offset }
        let after = spans.first { !$0.range.isEmpty && $0.range.lowerBound == offset }
        guard let main = before ?? after else { return [] }
        let other = before == nil ? nil : after
        return main.marks.filter { NativeMark.isInclusive($0.key) || other?.marks.contains($0) == true }
    }

    /// `marksAcross`, for typing over a selection: the first replaced
    /// character's marks, without the non-inclusive marks the character after
    /// the range lacks.
    static func typing(_ runs: [InlineRun], replacing range: Range<Int>) -> [TextMark] {
        let spans = spans(runs)
        guard let first = spans.first(where: { $0.range.contains(range.lowerBound) }) else {
            return typing(runs, at: range.lowerBound)
        }
        let next = spans.first { $0.range.contains(range.upperBound) }
        return first.marks.filter { NativeMark.isInclusive($0.key) || next?.marks.contains($0) == true }
    }

    /// What a Yjs insertion with no explicit marks inherits: the marks of the
    /// character before `offset`.
    static func inherited(_ runs: [InlineRun], at offset: Int) -> [TextMark] {
        guard offset > 0 else { return [] }
        return spans(runs).first { $0.range.contains(offset - 1) }?.marks ?? []
    }

    static func same(_ a: [TextMark], _ b: [TextMark]) -> Bool {
        a.count == b.count && a.allSatisfy(b.contains)
    }

    /// The marks every character of `range` carries, across blocks; nil when
    /// it holds no text. Placeholders and separators carry none and are
    /// skipped, so a half-bold selection reads as not bold.
    static func common(in blocks: [BlockSnapshot], index: ProjectionRangeIndex, range: NSRange) -> [TextMark]? {
        guard range.length > 0, let start = index.textPosition(atUTF16: range.location),
            let end = index.textPosition(atUTF16: NSMaxRange(range), isUpperBound: true)
        else { return nil }
        var common: [TextMark]?
        for position in start.position...end.position
        where !AttributedDocumentProjection.isPlaceholder(blocks[position]) {
            let lower = position == start.position ? start.offset : 0
            let upper = position == end.position ? end.offset : index.entries[position].textRange.length
            let selection = lower..<max(lower, upper)
            for (run, span) in zip(blocks[position].runs, spans(blocks[position].runs))
            where run.inlineObject == nil && span.range.overlaps(selection) {
                common = common.map { $0.filter(span.marks.contains) } ?? span.marks
            }
        }
        return common
    }

    /// The link run around `offset` (the character after it, else before),
    /// extended over neighbours with the same destination.
    static func linkRange(_ runs: [InlineRun], at offset: Int) -> (range: Range<Int>, href: String)? {
        let spans = spans(runs)
        func link(_ span: Span) -> TextMark? { span.marks.first { $0.key == NativeMark.link } }
        guard
            let index = spans.firstIndex(where: { $0.range.contains(offset) && link($0) != nil })
                ?? spans.firstIndex(where: { $0.range.contains(offset - 1) && link($0) != nil }),
            let mark = link(spans[index]), let href = YBlockProjection.linkHref(from: mark.valueJSON)
        else { return nil }
        var lower = index
        var upper = index
        while lower > 0, link(spans[lower - 1]) == mark { lower -= 1 }
        while upper + 1 < spans.count, link(spans[upper + 1]) == mark { upper += 1 }
        return (spans[lower].range.lowerBound..<spans[upper].range.upperBound, href)
    }
}

/// The range a link edit targets, captured when the sheet opens: the
/// selection, or the whole link around a caret. `href` is nil for a new link.
struct NativeLinkTarget: Identifiable, Equatable {
    let id = UUID()
    let range: NSRange
    let label: String
    let href: String?
}
