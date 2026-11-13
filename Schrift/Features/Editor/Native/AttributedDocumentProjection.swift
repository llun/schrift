import UIKit

extension NSAttributedString.Key {
    static let nativeBlockID = NSAttributedString.Key("schrift.native.blockID")
    static let nativeBlockType = NSAttributedString.Key("schrift.native.blockType")
    static let nativeSeparator = NSAttributedString.Key("schrift.native.separator")
    static let nativePlaceholder = NSAttributedString.Key("schrift.native.placeholder")
    /// Block chrome inputs (PR05b), plain values so storage compares equal to a
    /// fresh projection: a numbered item's displayed number, a checkbox's
    /// state, a code block's language and a callout's emoji. Display only:
    /// none of them is ever text, and none reaches Yjs.
    static let nativeListNumber = NSAttributedString.Key("schrift.native.listNumber")
    static let nativeChecked = NSAttributedString.Key("schrift.native.checked")
    static let nativeCodeLanguage = NSAttributedString.Key("schrift.native.codeLanguage")
    static let nativeCalloutEmoji = NSAttributedString.Key("schrift.native.calloutEmoji")
    static let nativeCalloutBackground = NSAttributedString.Key("schrift.native.calloutBackground")
    /// A nested block's depth (PR06a), so chrome and panels start at its indent.
    static let nativeDepth = NSAttributedString.Key("schrift.native.depth")
    /// A toggle list item or toggle heading (PR06b): its disclosure button sits
    /// in the gutter. Whether it is folded is view state, never an attribute.
    static let nativeToggle = NSAttributedString.Key("schrift.native.toggle")
}

struct NativeEditorLabels: Equatable {
    var preservedBlock = Strings_en.table[.native_editor_preserved_block]!
    var unknownBlock = Strings_en.table[.native_editor_unknown_block]!
    var pageBreak = Strings_en.table[.native_editor_page_break]!
    var codeLanguage = Strings_en.table[.native_editor_code_language]!
    var markDone = Strings_en.table[.editor_checklist_done_a11y]!
    var markNotDone = Strings_en.table[.editor_checklist_not_done_a11y]!
    var done = Strings_en.table[.editor_checklist_state_done_a11y]!
    var notDone = Strings_en.table[.editor_checklist_state_not_done_a11y]!
    var toggle = Strings_en.table[.native_editor_toggle]!
    var expanded = Strings_en.table[.native_editor_toggle_expanded]!
    var collapsed = Strings_en.table[.native_editor_toggle_collapsed]!
    /// Collaborators' carets and badges for VoiceOver (PR10b), each `%@` the name.
    var peerCursor = Strings_en.table[.native_editor_peer_cursor]!
    var peerSelection = Strings_en.table[.native_editor_peer_selection]!
    var peerFolded = Strings_en.table[.native_editor_peer_folded]!
    // Preview names and states (PR06e).
    var named = Strings_en.table[.native_editor_attachment_named]!
    var image = Strings_en.table[.editor_image_a11y]!
    var video = Strings_en.table[.native_editor_video]!
    var audio = Strings_en.table[.native_editor_audio]!
    var file = Strings_en.table[.native_editor_file]!
    var pdf = Strings_en.table[.native_editor_pdf]!
    var table = Strings_en.table[.native_editor_table]!
    var tableMore = Strings_en.table[.native_editor_table_more]!
    var columns = Strings_en.table[.native_editor_columns]!
    /// "Column 2 of 3": a column's VoiceOver container and the group card's value (PR12c).
    var column = Strings_en.table[.native_editor_column]!
    var columnsRotor = Strings_en.table[.native_editor_columns_rotor]!
    var math = Strings_en.table[.native_editor_math]!
    var diagram = Strings_en.table[.native_editor_diagram]!
    var imageExternal = Strings_en.table[.editor_image_external]!
    var imageExternalA11y = Strings_en.table[.editor_image_external_a11y]!
    var imageOffline = Strings_en.table[.editor_image_offline]!
    var imageFailed = Strings_en.table[.editor_image_failed]!
    /// A media card's states (PR13a): no url yet, ours uploading, a peer's upload.
    var mediaEmpty = Strings_en.table[.native_editor_media_empty]!
    var mediaUploading = Strings_en.table[.native_editor_media_uploading]!
    var mediaUploadFailed = Strings_en.table[.native_editor_media_upload_stopped]!
    var mediaUploadWaiting = Strings_en.table[.native_editor_media_upload_queued]!
    var uploadElsewhere = Strings_en.table[.native_editor_upload_elsewhere]!
    /// The block menu's title and actions (PR06d): the edit menu and VoiceOver.
    var blockMenu = Strings_en.table[.native_editor_block_actions]!
    var blockActions = Dictionary(
        uniqueKeysWithValues: NativeBlockAction.allCases.map { ($0, Strings_en.table[$0.labelKey]!) })
}

/// Disposable presentation, never a serialization or write-back source.
/// Unknown/opaque objects survive in the owning replica and occupy one
/// attachment character here: a bounded, read-only preview (PR06e,
/// `NativeBlockAttachment`). No list marker is inserted into the authored text: bullets,
/// numbers, checkboxes, quote bars, panels and rules are fragment chrome
/// (`NativeBlockFragment`) and controls (`NativeBlockControls`).
enum AttributedDocumentProjection {
    private static let prose = NativeBlockPreview.proseNodes

    /// A preview block's one character in storage (one UTF-16 unit).
    static let attachmentCharacter = "\u{FFFC}"

    /// A toggle list item or toggle heading that renders as text (PR06b).
    static func isToggle(_ block: BlockSnapshot) -> Bool {
        !isPlaceholder(block)
            && BlockNoteWriter.isToggle(node: block.node, props: block.props.map { ($0.key, $0.value) })
    }

    /// A code block's "\n" is displayed as U+2028 (one UTF-16 unit, so offsets
    /// are unchanged): one TextKit paragraph, one panel. Yjs keeps "\n".
    static let codeLineSeparator: Character = "\u{2028}"

    static func isPlaceholder(_ block: BlockSnapshot) -> Bool {
        block.isOpaque || !prose.contains(block.node)
    }

    static func displayText(for block: BlockSnapshot, labels: NativeEditorLabels = NativeEditorLabels()) -> String {
        guard !isPlaceholder(block) else { return attachmentCharacter }
        return block.runs.map { displayed($0.text, in: block) }.joined()
    }

    /// A preview block's preview: the replica's, or a labelled preserved
    /// card for a value-only snapshot that has none.
    static func preview(for block: BlockSnapshot) -> NativeBlockPreview {
        block.preview ?? .preserved(node: block.node, summary: "")
    }

    /// VoiceOver's name for a preview block: "Image: alt", "Video: name",
    /// "Table, 3 by 4", "Columns, 2", "Math", "paragraph (preserved, not
    /// editable yet)".
    static func attachmentLabel(for block: BlockSnapshot, labels: NativeEditorLabels = NativeEditorLabels()) -> String {
        func named(_ kind: String, _ name: String) -> String {
            name.isEmpty ? kind : String(format: labels.named, kind, name)
        }
        switch preview(for: block) {
        case .image(_, let alt, _): return named(labels.image, alt)
        case .file(let node, let name, _): return named(labels.kind(node), name)
        case .table(_, let rows, let columns): return String(format: labels.table, rows, columns)
        case .columns(_, let count): return String(format: labels.columns, count)
        case .source(let node, _, _): return labels.kind(node)
        case .preserved(let node, _):
            return String(format: labels.preservedBlock, node.isEmpty ? labels.unknownBlock : node)
        }
    }

    /// A "\n" inside a block (a code line, a table cell's hard break) is one
    /// TextKit paragraph's line separator, never a paragraph break.
    private static func displayed(_ text: String, in block: BlockSnapshot) -> String {
        text.replacingOccurrences(of: "\n", with: String(codeLineSeparator))
    }

    /// BlockNote 0.56's numbering (`NumberedListIndexingDecorationPlugin`): a
    /// numbered item continues its previous sibling; the first of a run
    /// starts at its `start` prop (unset or 0 is 1). Nil for other blocks.
    /// `blocks` is preorder, so a parent's children run between its siblings.
    static func listNumbers(in blocks: [BlockSnapshot]) -> [Int?] {
        var previous: [String?: Int] = [:]
        return blocks.map { block in
            guard block.node == "numberedListItem", !isPlaceholder(block) else {
                previous[block.parentID] = nil
                return nil
            }
            let number: Int
            if let last = previous[block.parentID] {
                number = last &+ 1
            } else if case .int(let start)? = block.props.first(where: { $0.key == "start" })?.value, start != 0 {
                number = start
            } else {
                number = 1
            }
            previous[block.parentID] = number
            return number
        }
    }

    @MainActor
    static func attributedString(
        blocks: [BlockSnapshot], traits: UITraitCollection = .current,
        labels: NativeEditorLabels = NativeEditorLabels(),
        geometry: NativeAttachmentGeometry = NativeAttachmentGeometry()
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for (block, number) in zip(blocks, listNumbers(in: blocks)) {
            result.append(
                attributedBlock(block, traits: traits, labels: labels, listNumber: number, geometry: geometry))
        }
        return result
    }

    /// `listNumber` is the block's place in its numbered run (`listNumbers`);
    /// the surface keeps it current as blocks above change.
    @MainActor
    static func attributedBlock(
        _ block: BlockSnapshot, traits: UITraitCollection, labels: NativeEditorLabels = NativeEditorLabels(),
        listNumber: Int? = nil, geometry: NativeAttachmentGeometry = NativeAttachmentGeometry()
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = DocsSpacing.spaceSM
        switch block.props.first(where: { $0.key == "textAlignment" })?.value {
        case .string("center"): paragraph.alignment = .center
        case .string("right"): paragraph.alignment = .right
        case .string("justify"): paragraph.alignment = .justified
        default: paragraph.alignment = .natural
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
            let attachment = self.attachment(for: block, traits: traits, labels: labels, geometry: geometry)
            // The S2 fix, for attachment paragraphs only: the line is exactly
            // the attachment plus the separator's descent, so TextKit 2's
            // estimate of a paragraph it has not laid out is already final.
            let indent = scaledGutter(traits) * CGFloat(block.depth)
            paragraph.firstLineHeadIndent = indent
            paragraph.headIndent = indent
            paragraph.minimumLineHeight = attachment.content.lineHeight
            paragraph.maximumLineHeight = attachment.content.lineHeight
            if block.depth > 0 { base[.nativeDepth] = block.depth }
            var attributes = base
            attributes[.attachment] = attachment
            result.append(NSAttributedString(string: attachmentCharacter, attributes: attributes))
        } else {
            chrome(block, listNumber: listNumber, traits: traits, paragraph: paragraph, into: &base)
            for run in block.runs {
                var attributes = base
                attributes.merge(
                    markAttributes(
                        block: block, marks: run.marks.map { TextMark(key: $0.key, valueJSON: $0.valueJSON) },
                        traits: traits)
                ) { _, new in new }
                result.append(NSAttributedString(string: displayed(run.text, in: block), attributes: attributes))
            }
        }
        base[.nativeSeparator] = true
        result.append(NSAttributedString(string: "\n", attributes: base))
        return result
    }

    @MainActor
    private static func scaledGutter(_ traits: UITraitCollection) -> CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(for: NativeBlockMetrics.listGutter, compatibleWith: traits)
    }

    /// A preview block's attachment, sized for `geometry` (S2: `previewWidth`
    /// and a cached aspect ratio, else a placeholder height).
    @MainActor
    static func attachment(
        for block: BlockSnapshot, traits: UITraitCollection, labels: NativeEditorLabels,
        geometry: NativeAttachmentGeometry
    ) -> NativeBlockAttachment {
        let preview = preview(for: block)
        let separator = font(block: block, marks: [], traits: traits)
        let width =
            geometry.usableWidth - scaledGutter(traits) * CGFloat(block.depth)
        var ratio: CGFloat?
        if case .image(let url, _, _) = preview { ratio = geometry.aspectRatios[url] }
        let descent = ceil(-separator.descender)
        let size = NativeAttachmentLayout.size(
            for: preview, width: width, traits: traits, aspectRatio: ratio,
            minimumHeight: ceil(separator.lineHeight) - descent)
        return NativeBlockAttachment(
            content: NativeAttachmentContent(
                blockID: block.id, preview: preview, label: attachmentLabel(for: block, labels: labels), size: size,
                descent: descent))
    }

    /// The room each block's chrome needs, scaled with Dynamic Type from the
    /// classic editor's tokens, and the values its fragment and controls read.
    @MainActor
    private static func chrome(
        _ block: BlockSnapshot, listNumber: Int?, traits: UITraitCollection, paragraph: NSMutableParagraphStyle,
        into attributes: inout [NSAttributedString.Key: Any]
    ) {
        let metrics = UIFontMetrics(forTextStyle: .body)
        func scaled(_ value: CGFloat) -> CGFloat { metrics.scaledValue(for: value, compatibleWith: traits) }
        func prop(_ key: String) -> YAnyValue? { block.props.first { $0.key == key }?.value }
        // Each level nests one list gutter further in, chrome and all.
        let depth = scaled(NativeBlockMetrics.listGutter) * CGFloat(block.depth)
        func indent(_ leading: CGFloat, trailing: CGFloat = 0) {
            paragraph.firstLineHeadIndent = depth + leading
            paragraph.headIndent = depth + leading
            paragraph.tailIndent = -trailing
        }
        if block.depth > 0 {
            attributes[.nativeDepth] = block.depth
            indent(0)
        }
        if isToggle(block) {
            // The disclosure button's gutter, like a list marker's.
            attributes[.nativeToggle] = true
            indent(scaled(NativeBlockMetrics.listGutter))
        }
        let padding = EditorBlockMetrics.decorationPadding
        switch block.node {
        case "heading":
            if case .int(let level)? = prop("level") { attributes[.accessibilityTextHeadingLevel] = level }
        case "bulletListItem":
            indent(scaled(NativeBlockMetrics.listGutter))
        case "numberedListItem":
            indent(scaled(NativeBlockMetrics.listGutter))
            if let listNumber { attributes[.nativeListNumber] = listNumber }
        case "checkListItem":
            indent(scaled(NativeBlockMetrics.listGutter))
            attributes[.nativeChecked] = prop("checked") == .bool(true)
        case "quote":
            indent(EditorBlockMetrics.quoteBarWidth + padding, trailing: padding)
            paragraph.paragraphSpacingBefore = EditorBlockMetrics.quoteVerticalPadding
            paragraph.paragraphSpacing += EditorBlockMetrics.quoteVerticalPadding
        case "callout":
            indent(scaled(NativeBlockMetrics.listGutter) + padding, trailing: padding)
            paragraph.paragraphSpacingBefore = padding
            paragraph.paragraphSpacing += padding
            if case .string(let emoji)? = prop("emoji") { attributes[.nativeCalloutEmoji] = emoji }
            if case .string(let name)? = prop("backgroundColor"), backgroundColors[name] != nil {
                attributes[.nativeCalloutBackground] = name
            }
        case "codeBlock":
            indent(padding, trailing: padding)
            // The language control sits in a header row above the first line.
            paragraph.paragraphSpacingBefore = scaled(NativeBlockMetrics.codeHeaderHeight)
            paragraph.paragraphSpacing += padding
            paragraph.lineBreakMode = .byCharWrapping
            if case .string(let language)? = prop("language") { attributes[.nativeCodeLanguage] = language }
        case "divider", "pageBreak":
            // An empty paragraph tall enough for its rule (and the badge).
            paragraph.minimumLineHeight = scaled(NativeBlockMetrics.ruleHeight)
        default:
            break
        }
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
                // Only a scheme the editor writes is tappable; the mark itself stays.
                if let href = YBlockProjection.linkHref(from: mark.valueJSON), isOpenableLink(href),
                    let url = URL(string: href)
                {
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

    /// A BlockNote background colour name as the shared dynamic colour.
    static func backgroundColor(named name: String) -> UIColor? { backgroundColors[name] }

    /// A BlockNote text colour name as the shared dynamic colour.
    static func textColor(named name: String) -> UIColor? { textColors[name] }

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
        // A quote is italic prose, as on the classic surfaces.
        if marks.contains("italic") || block.node == "quote" { symbolic.insert(.traitItalic) }
        if let descriptor = font.fontDescriptor.withSymbolicTraits(symbolic) {
            font = UIFont(descriptor: descriptor, size: spec.size)
        }
        return UIFontMetrics(forTextStyle: uiFontTextStyle(for: spec.textStyle))
            .scaledFont(for: font, compatibleWith: traits)
    }
}
