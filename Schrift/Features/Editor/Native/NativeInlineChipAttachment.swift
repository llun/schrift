import UIKit

/// Immutable value description of one inline chip (`interlinkingLinkInline`,
/// `userMentionInline`, or `mentionSearchInline`). Value equality lets
/// `NSAttributedString.isEqual` stay exact when reconciling `NSTextStorage`
/// against a fresh projection.
struct NativeInlineChipContent: Equatable, Hashable, Sendable {
    enum Kind: Equatable, Hashable, Sendable {
        case interlink
        case disabledInterlink
        case mention
        case mentionSearch
    }

    var object: NativeInlineObject
    var kind: Kind
    var displayLabel: String
    var accessibilityLabel: String
    var hasIcon: Bool
    var fontSize: CGFloat
    var fontDescriptorTraits: UInt32
    var band: DocumentLinkChipIconBand
    var size: CGSize
}

/// A 1-UTF-16-unit `\u{FFFC}` inline pill attachment rendered into a cached
/// `UIImage` sized strictly within `DocumentLinkChipIconBand(font:)`, so line
/// heights never jump and scrolling allocates zero `UIView` subviews.
final class NativeInlineChipAttachment: NSTextAttachment {
    let content: NativeInlineChipContent
    private let font: UIFont

    @MainActor
    init(content: NativeInlineChipContent, font: UIFont, traits: UITraitCollection) {
        self.content = content
        self.font = font
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = false
        bounds = CGRect(x: 0, y: content.band.baselineOffset, width: content.size.width, height: content.size.height)
        image = NativeInlineChipImageCache.assetImage(content: content, font: font, traits: traits)
    }

    required init?(coder: NSCoder) { nil }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? NativeInlineChipAttachment)?.content == content
    }

    override var hash: Int { content.hashValue }

    override var description: String { "NativeInlineChipAttachment(\(content.displayLabel))" }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
        textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint
    ) -> CGRect {
        CGRect(x: 0, y: content.band.baselineOffset, width: content.size.width, height: content.size.height)
    }

    override func image(
        for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> UIImage? {
        guard Thread.isMainThread else { return image }
        nonisolated(unsafe) let attachment = self
        nonisolated(unsafe) let container = textContainer
        return MainActor.assumeIsolated {
            let controls = container?.textLayoutManager?.delegate as? NativeBlockControls
            let theme = controls?.theme ?? .white
            let traits = controls?.traits ?? .current
            let scale = NativeInlineChipImageCache.resolvedScale(for: traits)
            return NativeInlineChipImageCache.image(
                content: attachment.content, font: attachment.font, theme: theme,
                isDark: traits.userInterfaceStyle == .dark, scale: scale)
        }
    }

    @MainActor
    static func content(
        for object: NativeInlineObject, font: UIFont, labels: NativeEditorLabels, geometry: NativeAttachmentGeometry
    ) -> NativeInlineChipContent {
        let kind: NativeInlineChipContent.Kind
        let displayLabel: String
        let accessibilityLabel: String
        let hasIcon: Bool

        switch object {
        case .interlink(let docID, _, let title, let disabled, _):
            hasIcon = true
            if !disabled, !docID.isEmpty {
                kind = .interlink
                displayLabel = object.visibleText { geometry.documentTitles[$0] }
                accessibilityLabel = String(format: labels.named, labels.chipPage, displayLabel)
            } else {
                kind = .disabledInterlink
                let raw = (title?.isEmpty == false ? title : nil) ?? (docID.isEmpty ? nil : docID)
                displayLabel = raw ?? labels.chipUntitled
                accessibilityLabel =
                    raw.map { String(format: labels.named, labels.chipPage, $0) } ?? labels.chipUntitled
            }
        case .mention:
            hasIcon = false
            kind = .mention
            displayLabel = object.visibleText
            accessibilityLabel = String(format: labels.named, labels.chipMention, displayLabel)
        case .mentionSearch(_, let trigger):
            hasIcon = false
            kind = .mentionSearch
            displayLabel = (trigger?.isEmpty == false ? trigger! : "@")
            accessibilityLabel = String(format: labels.named, labels.chipMention, displayLabel)
        }

        let metrics = DocumentLinkChipMetrics(fontSize: font.pointSize)
        let band = DocumentLinkChipIconBand(font: font)
        let leading = hasIcon ? metrics.slotWidth : metrics.leadingPadding
        let textWidth = ceil((displayLabel as NSString).size(withAttributes: [.font: font]).width)
        let naturalWidth = leading + textWidth + metrics.trailingPadding
        let maxWidth = max(leading + metrics.trailingPadding, floor(geometry.usableWidth))
        let width = min(naturalWidth, maxWidth)

        return NativeInlineChipContent(
            object: object,
            kind: kind,
            displayLabel: displayLabel,
            accessibilityLabel: accessibilityLabel,
            hasIcon: hasIcon,
            fontSize: font.pointSize,
            fontDescriptorTraits: font.fontDescriptor.symbolicTraits.rawValue,
            band: band,
            size: CGSize(width: width, height: band.height))
    }

    @MainActor
    static func attachment(
        for object: NativeInlineObject, font: UIFont, traits: UITraitCollection, labels: NativeEditorLabels,
        geometry: NativeAttachmentGeometry
    ) -> NativeInlineChipAttachment {
        NativeInlineChipAttachment(
            content: content(for: object, font: font, labels: labels, geometry: geometry),
            font: font,
            traits: traits)
    }
}

/// Bounded cache of rendered inline-chip pill images keyed by chip content,
/// theme, appearance, and scale.
@MainActor
enum NativeInlineChipImageCache {
    private struct Key: Hashable {
        let content: NativeInlineChipContent
        let theme: AppTheme
        let isDark: Bool
        let scale: CGFloat
    }

    private struct AssetKey: Hashable {
        let content: NativeInlineChipContent
        let scale: CGFloat
    }

    private static let capacity = 128
    private static var images: [Key: UIImage] = [:]
    private static var assets: [AssetKey: UIImage] = [:]

    static func resolvedScale(for traits: UITraitCollection) -> CGFloat {
        traits.displayScale > 0 ? traits.displayScale : UIGraphicsImageRendererFormat.preferred().scale
    }

    static func assetImage(content: NativeInlineChipContent, font: UIFont, traits: UITraitCollection) -> UIImage {
        let scale = resolvedScale(for: traits)
        let key = AssetKey(content: content, scale: scale)
        if let existing = assets[key] { return existing }
        if assets.count >= capacity { assets.removeAll() }

        let light = image(content: content, font: font, theme: .white, isDark: false, scale: scale)
        let dark = image(content: content, font: font, theme: .white, isDark: true, scale: scale)
        let asset = UIImageAsset()
        let scaleTraits = UITraitCollection(displayScale: scale)
        asset.register(light, with: scaleTraits.modifyingTraits { $0.userInterfaceStyle = .light })
        asset.register(dark, with: scaleTraits.modifyingTraits { $0.userInterfaceStyle = .dark })
        let resolved = asset.image(with: traits)
        assets[key] = resolved
        return resolved
    }

    static func image(
        content: NativeInlineChipContent, font: UIFont, theme: AppTheme, isDark: Bool, scale: CGFloat
    ) -> UIImage {
        let key = Key(content: content, theme: theme, isDark: isDark, scale: scale)
        if let existing = images[key] { return existing }
        if images.count >= capacity { images.removeAll() }
        let rendered = render(content: content, font: font, theme: theme, isDark: isDark, scale: scale)
        images[key] = rendered
        return rendered
    }

    private static func render(
        content: NativeInlineChipContent, font: UIFont, theme: AppTheme, isDark: Bool, scale: CGFloat
    ) -> UIImage {
        let palette = DocsPalette(theme: theme, isDark: isDark)
        let (fillHex, inkHex): (UInt32, UInt32) =
            switch content.kind {
            case .interlink: (palette.brandFillSubtle, palette.textBrand)
            case .disabledInterlink: (palette.surfaceMuted, palette.textSecondary)
            case .mention: (palette.surfaceMuted, palette.textPrimary)
            case .mentionSearch: (palette.surfaceMuted, palette.textTertiary)
            }
        let fill = uiColor(fillHex)
        let ink = uiColor(inkHex)
        let metrics = DocumentLinkChipMetrics(fontSize: content.fontSize)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: content.size, format: format).image { _ in
            let rect = CGRect(origin: .zero, size: content.size)
            let radius = min(metrics.cornerRadius, rect.height / 2, rect.width / 2)
            fill.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: radius).fill()

            if content.hasIcon {
                let icon = DocumentLinkChipIconCache.image(metrics: metrics, band: content.band)
                    .withTintColor(ink, renderingMode: .alwaysOriginal)
                icon.draw(at: .zero)
            }

            let textX = content.hasIcon ? metrics.slotWidth : metrics.leadingPadding
            let availableWidth = max(0, content.size.width - textX - metrics.trailingPadding)
            if availableWidth > 0 {
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byTruncatingTail
                let baselineY = content.band.height + content.band.baselineOffset
                let textY = baselineY - font.ascender
                let textRect = CGRect(x: textX, y: textY, width: availableWidth, height: ceil(font.lineHeight))
                (content.displayLabel as NSString).draw(
                    with: textRect,
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                    attributes: [.font: font, .foregroundColor: ink, .paragraphStyle: style],
                    context: nil)
            }
        }
    }

    private static func uiColor(_ hex: UInt32) -> UIColor {
        let c = hexColorComponents(hex)
        return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
    }
}
