import SwiftUI
import UIKit

// The "page chip": how a link to another document on this server is drawn on
// **both** editor surfaces — a rounded `brandFillSubtle` background, `textBrand`
// ink, no underline, and a small `description` (page) glyph before the title.
// External links keep the ordinary underlined link styling.
//
// It is display only. The saved markdown is the same `[Title](url)` it always
// was: the reading surface splits its `AttributedString` into segments, and the
// editing surface draws the chip *around* its raw-markdown buffer without
// inserting a character (the link's hidden `[` becomes the icon's slot), so
// `UITextView.text` stays byte-identical to `block.text` and every `NSRange` is
// still a source offset.
//
// The two surfaces must wrap a chip identically, or tapping into edit mode
// re-flows the paragraph. So everything with a width — the icon slot, the
// trailing padding — comes from `DocumentLinkChipMetrics`, in whole points,
// and both surfaces build the icon from the one `documentLinkChipIconImage`.
//
// Concurrency: the metrics, band, span and background functions are pure value
// code with no annotations, like the rest of the editor's style table. The file
// also holds UIKit/SwiftUI drawing types — `DocumentLinkChipLayoutManager` (an
// `NSLayoutManager` subclass the editing surface owns) and the reading
// surface's renderer — and `DocumentLinkChipIconCache`, which is `@MainActor`
// because it is mutable shared state read from view bodies.

// MARK: - Metrics

/// The chip's measurements for a block whose font is `fontSize` points — so the
/// chip scales with Dynamic Type exactly as the text beside it does.
///
/// Whole points on purpose: the reading surface reserves the icon slot with an
/// inline image, whose width is its pixel size, and the editing surface with a
/// control glyph's bounding box. A fractional width would round differently in
/// the two and a line near its wrap point could break in one surface only.
struct DocumentLinkChipMetrics: Hashable {
    /// Background drawn before the icon, inside the slot.
    let leadingPadding: CGFloat
    /// The page glyph's em square.
    let iconSize: CGFloat
    /// Space between the glyph and the title, inside the slot.
    let iconGap: CGFloat
    /// Background drawn past the title's last glyph. Reserves no width: it
    /// overlaps the following character (almost always a space) identically on
    /// both surfaces, so it cannot change where a line wraps.
    let trailingPadding: CGFloat
    let cornerRadius: CGFloat

    init(fontSize: CGFloat) {
        leadingPadding = max(2, (fontSize * 0.18).rounded())
        iconSize = max(8, (fontSize * 0.9).rounded())
        iconGap = max(2, (fontSize * 0.12).rounded())
        trailingPadding = leadingPadding
        cornerRadius = DocsRadius.md
    }

    /// The horizontal space the chip adds before its title — on both surfaces.
    var slotWidth: CGFloat { leadingPadding + iconSize + iconGap }
}

/// The vertical band the icon image occupies around the baseline.
///
/// Kept strictly inside the font's ascender/descender (1pt either side, in whole
/// points), so the inline image can never make a reading line taller than the
/// editing line it is swapped for. Both surfaces place the image with this band,
/// so the glyph sits at the same height on both.
struct DocumentLinkChipIconBand: Hashable {
    /// The image's bottom edge relative to the baseline (negative is below it).
    let baselineOffset: CGFloat
    let height: CGFloat

    init(ascender: CGFloat, descender: CGFloat) {
        height = max(1, (ascender - descender).rounded(.down) - 2)
        baselineOffset = descender + 1
    }

    init(font: UIFont) {
        self.init(ascender: font.ascender, descender: font.descender)
    }
}

/// The icon slot as a template image: `slotWidth` wide (leading padding, glyph,
/// gap), `band.height` tall, the page glyph centred vertically in it.
///
/// One image for both surfaces — the reading surface inlines it in the `Text`,
/// the editing surface draws it into the slot its control glyph reserves.
func documentLinkChipIconImage(metrics: DocumentLinkChipMetrics, band: DocumentLinkChipIconBand) -> UIImage {
    let canvas = CGSize(width: metrics.slotWidth, height: band.height)
    let side = min(metrics.iconSize, band.height)
    let font = MaterialSymbolFont.uiFont(size: side, fill: false)
    let glyph = NSAttributedString(
        string: String(MaterialIcon.description.character),
        attributes: [.font: font, .foregroundColor: UIColor.black])
    let top = (band.height - side) / 2
    let image = UIGraphicsImageRenderer(size: canvas).image { _ in
        // Material Symbols glyphs fill their em square directly above the
        // baseline, and `draw(at:)` puts the baseline `ascender` below the
        // point — so this lands the square's top edge at `top`.
        glyph.draw(at: CGPoint(x: metrics.leadingPadding, y: top + side - font.ascender))
    }
    return image.withRenderingMode(.alwaysTemplate)
}

// MARK: - Backgrounds

/// One chip's extent on one line, in the surface's own coordinates.
struct DocumentLinkChipPiece: Equatable {
    /// Identifies the chip (so two chips on one line stay two backgrounds).
    let chip: Int
    /// Identifies the line (so a chip that wraps gets one background per line).
    let line: Int
    let rect: CGRect
}

/// The rounded backgrounds to fill, one per chip per line: the union of that
/// chip's pieces on the line, the last line of each chip extended by
/// `trailingPadding`. Shared so both surfaces turn their glyph geometry into
/// backgrounds by the same rule.
func documentLinkChipBackgrounds(_ pieces: [DocumentLinkChipPiece], trailingPadding: CGFloat) -> [CGRect] {
    var order: [(chip: Int, line: Int)] = []
    var rects: [Int: [Int: CGRect]] = [:]
    for piece in pieces where !piece.rect.isNull && !piece.rect.isInfinite {
        if let existing = rects[piece.chip]?[piece.line] {
            rects[piece.chip]?[piece.line] = existing.union(piece.rect)
        } else {
            rects[piece.chip, default: [:]][piece.line] = piece.rect
            order.append((piece.chip, piece.line))
        }
    }
    return order.compactMap { key in
        guard let lines = rects[key.chip], var rect = lines[key.line] else { return nil }
        if key.line == lines.keys.max() {
            rect.size.width += trailingPadding
        }
        return rect
    }
}

// MARK: - Editing surface

/// A document link the editing surface draws as a chip, in source coordinates.
struct DocumentLinkChipSpan: Equatable {
    /// The link's opening `[`: hidden syntax, laid out as the icon slot.
    let slotIndex: Int
    /// The visible title.
    let labelRange: NSRange
}

/// The links in `layout` that are document links on `serverHost`.
///
/// Only a link whose `[` is hidden syntax qualifies — the slot replaces a
/// zero-width glyph, so a visible character can never be turned into space —
/// and only one with a non-empty title, which is what the chip draws behind.
func documentLinkChipSpans(in layout: InlineLayout, serverHost: String) -> [DocumentLinkChipSpan] {
    guard !serverHost.isEmpty else { return [] }
    return layout.links.compactMap { link in
        guard link.labelRange.length > 0, isDocumentLink(href: link.url, serverHost: serverHost) else { return nil }
        let slot = link.range.location
        guard slot < link.labelRange.location, layout.syntax.contains(where: { NSLocationInRange(slot, $0) })
        else { return nil }
        return DocumentLinkChipSpan(slotIndex: slot, labelRange: link.labelRange)
    }
}

/// The editing surface's TextKit 1 layout manager: draws each chip's rounded
/// background behind its glyphs and the page glyph into its slot.
///
/// The slot's *width* is not drawn here — `EditorUITextView` lays the hidden `[`
/// out as a whitespace control glyph `slotWidth` wide — so this class only paints;
/// it never changes where anything is.
final class DocumentLinkChipLayoutManager: NSLayoutManager {
    struct Appearance {
        let fill: UIColor
        let iconColor: UIColor
        let metrics: DocumentLinkChipMetrics
        let band: DocumentLinkChipIconBand
        let icon: UIImage
    }

    var chips: [DocumentLinkChipSpan] = []
    var chipAppearance: Appearance?

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let appearance = chipAppearance, !chips.isEmpty, let context = UIGraphicsGetCurrentContext() else {
            return
        }
        // `cgColor` resolves a dynamic colour against the trait collection
        // UIKit installs for this draw, so light/dark follow the view.
        context.saveGState()
        context.setFillColor(appearance.fill.cgColor)
        let backgrounds = documentLinkChipBackgrounds(
            chipPieces(), trailingPadding: appearance.metrics.trailingPadding)
        for rect in backgrounds {
            let shifted = rect.offsetBy(dx: origin.x, dy: origin.y)
            let radius = min(appearance.metrics.cornerRadius, shifted.height / 2, shifted.width / 2)
            context.addPath(
                CGPath(roundedRect: shifted, cornerWidth: radius, cornerHeight: radius, transform: nil))
        }
        context.fillPath()
        context.restoreGState()
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let appearance = chipAppearance, !chips.isEmpty, let storage = textStorage,
            let container = textContainers.first
        else { return }
        let icon = appearance.icon.withTintColor(
            UIColor(cgColor: appearance.iconColor.cgColor), renderingMode: .alwaysOriginal)
        for chip in chips where chip.slotIndex < storage.length {
            let glyph = glyphIndexForCharacter(at: chip.slotIndex)
            guard glyph < numberOfGlyphs else { continue }
            let slot = boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let baseline = line.minY + location(forGlyphAt: glyph).y
            // Up from the baseline by the band, in UIKit's flipped coordinates.
            let frame = CGRect(
                x: slot.minX + origin.x,
                y: baseline - appearance.band.baselineOffset - appearance.band.height + origin.y,
                width: appearance.metrics.slotWidth, height: appearance.band.height)
            icon.draw(in: frame)
        }
    }

    /// Each chip's glyphs (slot through title) split by line fragment, with the
    /// vertical extent of the block font's ascender/descender — the same box a
    /// SwiftUI run's typographic bounds give the reading surface.
    private func chipPieces() -> [DocumentLinkChipPiece] {
        guard let storage = textStorage, let container = textContainers.first else { return [] }
        var pieces: [DocumentLinkChipPiece] = []
        for (index, chip) in chips.enumerated() {
            let end = NSMaxRange(chip.labelRange)
            guard chip.slotIndex < end, end <= storage.length,
                let font = storage.attribute(.font, at: chip.slotIndex, effectiveRange: nil) as? UIFont
            else { continue }
            let chipGlyphs = glyphRange(
                forCharacterRange: NSRange(location: chip.slotIndex, length: end - chip.slotIndex),
                actualCharacterRange: nil)
            var glyph = chipGlyphs.location
            var line = 0
            while glyph < NSMaxRange(chipGlyphs) {
                var lineGlyphs = NSRange(location: NSNotFound, length: 0)
                let lineRect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
                guard lineGlyphs.location != NSNotFound, lineGlyphs.length > 0 else { break }
                let piece = NSIntersectionRange(lineGlyphs, chipGlyphs)
                if piece.length > 0 {
                    let bounds = boundingRect(forGlyphRange: piece, in: container)
                    let baseline = lineRect.minY + location(forGlyphAt: piece.location).y
                    pieces.append(
                        DocumentLinkChipPiece(
                            chip: index, line: line,
                            rect: CGRect(
                                x: bounds.minX, y: baseline - font.ascender, width: bounds.width,
                                height: font.ascender - font.descender)))
                }
                line += 1
                glyph = NSMaxRange(lineGlyphs)
            }
        }
        return pieces
    }
}

// MARK: - Reading surface

/// Marks the runs of a reading-surface `AttributedString` that came from a
/// **markdown** document link — set before bare URLs are autolinked, so an
/// autolinked document URL stays an ordinary link (the editing surface has no
/// autolinker, so chipping it while reading would add width the editing
/// surface lacks and re-wrap the line on the swap).
enum DocumentLinkChipAttribute: AttributedStringKey {
    typealias Value = Bool
    static let name = "dev.llun.Schrift.documentLinkChip"
}

/// Memoizes the reading surface's chip icon, which `body` would otherwise
/// re-render on every evaluation. Keyed by size, because one screen mixes a few
/// (a heading's chip and a paragraph's): a single entry would thrash between
/// them on every render. Bounded, since Dynamic Type changes add sizes; a
/// screen's blocks share a handful at most, so clearing on overflow is enough.
@MainActor
enum DocumentLinkChipIconCache {
    private struct Key: Hashable {
        let metrics: DocumentLinkChipMetrics
        let band: DocumentLinkChipIconBand
    }

    private static let capacity = 16
    private static var icons: [Key: UIImage] = [:]

    static func image(metrics: DocumentLinkChipMetrics, band: DocumentLinkChipIconBand) -> UIImage {
        let key = Key(metrics: metrics, band: band)
        if let icon = icons[key] { return icon }
        if icons.count >= capacity { icons.removeAll() }
        let icon = documentLinkChipIconImage(metrics: metrics, band: band)
        icons[key] = icon
        return icon
    }
}

/// A run of reading-surface text: ordinary, or one document link's title.
enum InlineTextSegment: Equatable {
    case text(AttributedString)
    case documentLink(AttributedString)

    var isDocumentLink: Bool {
        if case .documentLink = self { return true }
        return false
    }
}

/// Splits `markdownInlineText`'s output at document-link boundaries. Adjacent
/// runs of one link (a title with a bold word) form one chip; the marker
/// attribute is stripped so nothing but SwiftUI's own attributes reaches `Text`.
func inlineTextSegments(_ attributed: AttributedString) -> [InlineTextSegment] {
    var segments: [InlineTextSegment] = []
    var current = AttributedString()
    var currentIsChip = false
    var currentLink: URL?

    func flush() {
        guard !current.characters.isEmpty else { return }
        segments.append(currentIsChip ? .documentLink(current) : .text(current))
        current = AttributedString()
    }

    for run in attributed.runs {
        let isChip = run.attributes[DocumentLinkChipAttribute.self] == true
        let link = run.link
        if isChip != currentIsChip || (isChip && link != currentLink) {
            flush()
        }
        currentIsChip = isChip
        currentLink = link
        var piece = AttributedString(attributed[run.range])
        piece[DocumentLinkChipAttribute.self] = nil
        current.append(piece)
    }
    flush()
    return segments
}

/// Tags a chip's runs in the composed `Text`, so the renderer can find them.
struct DocumentLinkChipTextAttribute: TextAttribute {
    let chip: Int
}

/// The reading surface's composed `Text`: ordinary segments as they are, each
/// document link as icon + word joiner + title, tagged for the renderer.
///
/// Built by interpolation (`Text + Text` is deprecated on iOS 26). The word
/// joiner keeps the icon on the title's line, as the editing surface's `[`
/// (an opening bracket, which never ends a line) does.
func documentLinkChipText(
    _ segments: [InlineTextSegment], icon: Image, band: DocumentLinkChipIconBand, iconColor: Color
) -> Text {
    var composed = Text(verbatim: "")
    for (index, segment) in segments.enumerated() {
        switch segment {
        case .text(let content):
            composed = Text("\(composed)\(Text(content))")
        case .documentLink(let title):
            let glyph = Text(icon).baselineOffset(band.baselineOffset).foregroundStyle(iconColor)
            let chip = Text("\(glyph)\u{2060}\(Text(title))")
                .customAttribute(DocumentLinkChipTextAttribute(chip: index))
            composed = Text("\(composed)\(chip)")
        }
    }
    return composed
}

/// Fills each chip's rounded background behind the text, then draws the text.
struct DocumentLinkChipRenderer: TextRenderer {
    let fill: Color
    let metrics: DocumentLinkChipMetrics

    /// The trailing padding can reach past the `Text`'s own frame (a chip that
    /// ends the widest line); without this it would be clipped while the
    /// editing surface, whose text view spans the row, shows it.
    var displayPadding: EdgeInsets {
        EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: metrics.trailingPadding)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var pieces: [DocumentLinkChipPiece] = []
        for (lineIndex, line) in layout.enumerated() {
            for run in line {
                guard let chip = run[DocumentLinkChipTextAttribute.self] else { continue }
                pieces.append(DocumentLinkChipPiece(chip: chip.chip, line: lineIndex, rect: run.typographicBounds.rect))
            }
        }
        for rect in documentLinkChipBackgrounds(pieces, trailingPadding: metrics.trailingPadding) {
            let radius = min(metrics.cornerRadius, rect.height / 2, rect.width / 2)
            context.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(fill))
        }
        for line in layout {
            context.draw(line)
        }
    }
}

/// Applies the chip renderer only where a block has a chip, so every other
/// block keeps SwiftUI's default text drawing.
struct DocumentLinkChipRendering: ViewModifier {
    let renderer: DocumentLinkChipRenderer?

    @ViewBuilder func body(content: Content) -> some View {
        if let renderer {
            content.textRenderer(renderer)
        } else {
            content
        }
    }
}
