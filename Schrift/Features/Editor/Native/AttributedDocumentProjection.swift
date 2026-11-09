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
                attributes.merge(
                    markAttributes(
                        block: block, marks: run.marks.map { TextMark(key: $0.key, valueJSON: $0.valueJSON) },
                        traits: traits)
                ) { _, new in new }
                result.append(NSAttributedString(string: run.text, attributes: attributes))
            }
        }
        base[.nativeSeparator] = true
        result.append(NSAttributedString(string: "\n", attributes: base))
        return result
    }

    /// What one mark set adds to a run: font traits, underline, strike, link
    /// and colours. Display only: marks this build does not know add nothing
    /// and stay in the snapshot (and the replica) untouched. The caret's
    /// typing attributes use it too.
    @MainActor
    static func markAttributes(
        block: BlockSnapshot, marks: [TextMark], traits: UITraitCollection
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(block: block, marks: marks.map(\.key), traits: traits), .foregroundColor: UIColor.label,
        ]
        for mark in marks {
            switch mark.key {
            case "strike": attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case "underline": attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            case "link":
                if let href = YBlockProjection.linkHref(from: mark.valueJSON), let url = URL(string: href) {
                    attributes[.link] = url
                }
            case NativeMark.textColor:
                if let color = NativeMark.colorName(from: mark.valueJSON).flatMap({ textColors[$0] }) {
                    attributes[.foregroundColor] = color
                }
            case NativeMark.backgroundColor:
                if let color = NativeMark.colorName(from: mark.valueJSON).flatMap({ backgroundColors[$0] }) {
                    attributes[.backgroundColor] = color
                }
            default: break
            }
        }
        return attributes
    }

    /// BlockNote 0.56's default palette as dynamic colours: the replica stores
    /// only the name, and light/dark resolves at draw time, so a theme change
    /// rewrites neither storage nor Yjs. Shared instances keep a fresh
    /// projection equal to storage.
    private static let textColors = palette([
        "gray": (0x9B9A97, 0xBEBDB8), "brown": (0x64473A, 0x9F8B82), "red": (0xE03E3E, 0xE03E3E),
        "orange": (0xD9730D, 0xD9730D), "yellow": (0xDFAB01, 0xDFAB01), "green": (0x4D6461, 0x4D6461),
        "blue": (0x0B6E99, 0x0B6E99), "purple": (0x6940A5, 0x6940A5), "pink": (0xAD1A72, 0xAD1A72),
    ])

    private static let backgroundColors = palette([
        "gray": (0xEBECED, 0x454B4E), "brown": (0xE9E5E3, 0x4A4442), "red": (0xFBE4E4, 0x5D1715),
        "orange": (0xF6E2DD, 0x5C3B2D), "yellow": (0xFBF3DB, 0x564A1E), "green": (0xDDEDEA, 0x2B3D3A),
        "blue": (0xDDEBF1, 0x143A4E), "purple": (0xEAE4F2, 0x3C2D49), "pink": (0xF4DFEB, 0x4E2C3C),
    ])

    private static func palette(_ hex: [String: (light: UInt32, dark: UInt32)]) -> [String: UIColor] {
        func color(_ value: UInt32) -> UIColor {
            UIColor(
                red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
        return hex.mapValues { pair in
            let light = color(pair.light)
            let dark = color(pair.dark)
            return UIColor { $0.userInterfaceStyle == .dark ? dark : light }
        }
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
