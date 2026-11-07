import UIKit

extension NSAttributedString.Key {
    static let nativeBlockID = NSAttributedString.Key("schrift.native.blockID")
    static let nativeBlockType = NSAttributedString.Key("schrift.native.blockType")
    static let nativeSeparator = NSAttributedString.Key("schrift.native.separator")
    static let nativePlaceholder = NSAttributedString.Key("schrift.native.placeholder")
}

struct NativeEditorLabels: Equatable {
    var preservedBlock = Strings_en.table[.native_editor_preserved_block]!
    var unknownBlock = Strings_en.table[.native_editor_unknown_block]!
}

/// Disposable presentation, never a serialization or write-back source.
/// Unknown/opaque objects survive in the owning replica and occupy a labelled
/// paragraph here. No list marker is inserted into the authored text.
enum AttributedDocumentProjection {
    private static let prose: Set<String> = [
        "paragraph", "heading", "bulletListItem", "numberedListItem", "checkListItem", "codeBlock", "quote",
    ]

    static func isPlaceholder(_ block: BlockSnapshot) -> Bool {
        block.isOpaque || !prose.contains(block.node)
    }

    static func displayText(for block: BlockSnapshot, labels: NativeEditorLabels = NativeEditorLabels()) -> String {
        guard !isPlaceholder(block) else {
            let label = block.node.isEmpty ? labels.unknownBlock : block.node
            return String(format: labels.preservedBlock, label)
        }
        return block.runs.map(\.text).joined()
    }

    @MainActor
    static func attributedString(
        blocks: [BlockSnapshot], traits: UITraitCollection = .current, labels: NativeEditorLabels = NativeEditorLabels()
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for block in blocks { result.append(attributedBlock(block, traits: traits, labels: labels)) }
        return result
    }

    @MainActor
    static func attributedBlock(
        _ block: BlockSnapshot, traits: UITraitCollection, labels: NativeEditorLabels = NativeEditorLabels()
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = DocsSpacing.spaceSM
        switch block.props.first(where: { $0.key == "textAlignment" })?.value {
        case .string("center"): paragraph.alignment = .center
        case .string("right"): paragraph.alignment = .right
        case .string("justify"): paragraph.alignment = .justified
        default: paragraph.alignment = .natural
        }
        if ["bulletListItem", "numberedListItem", "checkListItem", "quote"].contains(block.node) {
            paragraph.headIndent = DocsSpacing.spaceLG
            paragraph.firstLineHeadIndent = DocsSpacing.spaceLG
        }
        var base: [NSAttributedString.Key: Any] = [
            .nativeBlockID: block.id, .nativeBlockType: block.node,
            .font: font(block: block, marks: [], traits: traits),
            .foregroundColor: UIColor.label, .paragraphStyle: paragraph,
        ]
        let result = NSMutableAttributedString(string: "")
        if isPlaceholder(block) {
            base[.nativePlaceholder] = true
            base[.foregroundColor] = UIColor.secondaryLabel
            result.append(NSAttributedString(string: displayText(for: block, labels: labels), attributes: base))
        } else {
            for run in block.runs {
                var attributes = base
                attributes[.font] = font(block: block, marks: run.marks.map(\.key), traits: traits)
                for mark in run.marks {
                    switch mark.key {
                    case "strike": attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    case "underline": attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    case "link":
                        if let href = YBlockProjection.linkHref(from: mark.valueJSON), let url = URL(string: href) {
                            attributes[.link] = url
                        }
                    default: break
                    }
                }
                result.append(NSAttributedString(string: run.text, attributes: attributes))
            }
        }
        base[.nativeSeparator] = true
        result.append(NSAttributedString(string: "\n", attributes: base))
        return result
    }

    @MainActor
    private static func font(block: BlockSnapshot, marks: [String], traits: UITraitCollection) -> UIFont {
        var spec = DocsTypographySpec.body
        if block.node == "heading" {
            switch block.props.first(where: { $0.key == "level" })?.value {
            case .int(1): spec = DocsTypographySpec.title1
            case .int(2): spec = DocsTypographySpec.title2
            default: spec = DocsTypographySpec.headline
            }
        } else if block.node == "codeBlock" || marks.contains("code") {
            spec = DocsTypographySpec.code
        }
        let monospaced = block.node == "codeBlock" || marks.contains("code")
        let weight: UIFont.Weight = spec.weight == .bold ? .bold : (spec.weight == .semibold ? .semibold : .regular)
        var font =
            monospaced
            ? UIFont.monospacedSystemFont(ofSize: spec.size, weight: weight)
            : UIFont.systemFont(ofSize: spec.size, weight: weight)
        var symbolic = font.fontDescriptor.symbolicTraits
        if marks.contains("bold") { symbolic.insert(.traitBold) }
        if marks.contains("italic") { symbolic.insert(.traitItalic) }
        if let descriptor = font.fontDescriptor.withSymbolicTraits(symbolic) {
            font = UIFont(descriptor: descriptor, size: spec.size)
        }
        return UIFontMetrics(forTextStyle: uiFontTextStyle(for: spec.textStyle))
            .scaledFont(for: font, compatibleWith: traits)
    }
}
