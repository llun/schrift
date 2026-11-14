import UIKit

/// Presentation and accessibility request for opening a source block (`mathBlock`,
/// `diagram`) or an inline `math` chip in the focused source editor (PR14).
enum NativeSourceRequest: Equatable, Hashable, Sendable, Identifiable {
    case block(blockID: String)
    case inlineMath(blockID: String, utf16Offset: Int)

    var id: Self { self }
}

/// Exact source preview formatting, typography, and accessibility labels for
/// `mathBlock`, `diagram`, and inline `math` chips. Never renders math or
/// diagrams and never makes syntax-validity claims.
enum NativeSourcePreview {
    /// Explicit "source" title for the focused source editor (PR14).
    static func editorTitle(for kind: NativeSourceKind, labels: NativeEditorLabels) -> String {
        switch kind {
        case .mathBlock, .inlineMath: labels.mathSource
        case .diagram: labels.diagramSource
        }
    }

    /// Explicit "source" header label for a `.source` preview card.
    static func headerLabel(for node: String, labels: NativeEditorLabels) -> String {
        switch node {
        case SourceBlock.mathBlock: labels.mathSource
        case SourceBlock.diagram: labels.diagramSource
        default: labels.kind(node)
        }
    }

    /// Exact source body for a `.source` preview card, preserving leading
    /// indentation and internal blank lines, or the explicit empty-source
    /// placeholder when `lines` is empty.
    static func displayBody(lines: [String], labels: NativeEditorLabels) -> (text: String, isEmpty: Bool) {
        guard !lines.isEmpty else { return (labels.sourceEmpty, true) }
        return (lines.joined(separator: "\n"), false)
    }

    /// Dynamic Type-scaled font for a `.source` preview card's body.
    @MainActor
    static func sourceCardBodyFont(isEmpty: Bool, traits: UITraitCollection) -> UIFont {
        if isEmpty {
            return NativeAttachmentLayout.detailFont(traits)
        }
        return NativeAttachmentLayout.sourceFont(traits)
    }

    /// VoiceOver label for a `.source` preview card (`"Math source"` / `"Diagram source"`).
    static func blockAccessibilityLabel(node: String, labels: NativeEditorLabels) -> String {
        headerLabel(for: node, labels: labels)
    }

    /// VoiceOver value for a `.source` preview card: exact source lines (or
    /// empty-source placeholder), plus `"… more"` when truncated.
    static func blockAccessibilityValue(lines: [String], lineCount: Int, labels: NativeEditorLabels) -> String {
        let (body, isEmpty) = displayBody(lines: lines, labels: labels)
        if !isEmpty, lineCount > lines.count {
            return "\(body)\n\(labels.tableMore)"
        }
        return body
    }

    /// Pill display and VoiceOver labels for an inline `.math` chip. Preserves
    /// single-line source text verbatim when non-whitespace; empty or
    /// whitespace-only source uses the explicit source label.
    static func inlineMathContent(
        source: String, labels: NativeEditorLabels
    ) -> (displayLabel: String, accessibilityLabel: String, isEmpty: Bool) {
        let clipped = NativeInlineObject.math(source: source).clippedVisibleText()
        if clipped.trimmingCharacters(in: .whitespaces).isEmpty {
            return (labels.mathSource, labels.mathSource, true)
        }
        return (
            clipped,
            String(format: labels.named, labels.mathSource, clipped),
            false
        )
    }

    /// Dynamic Type font for an inline chip. Non-empty `.math` chips draw in a
    /// monospaced face scaled with `lineFont` so source text is visually
    /// distinct from prose while staying inside `DocumentLinkChipIconBand(font: lineFont)`.
    static func inlineChipFont(
        for kind: NativeInlineChipContent.Kind, isPlaceholder: Bool, lineFont: UIFont
    ) -> UIFont {
        guard kind == .math, !isPlaceholder else { return lineFont }
        let scaledSize = max(11, (lineFont.pointSize * 0.92).rounded())
        var font = UIFont.monospacedSystemFont(ofSize: scaledSize, weight: .regular)
        let traits = lineFont.fontDescriptor.symbolicTraits.intersection([.traitBold, .traitItalic])
        if !traits.isEmpty, let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
            font = UIFont(descriptor: descriptor, size: scaledSize)
        }
        return font
    }
}
