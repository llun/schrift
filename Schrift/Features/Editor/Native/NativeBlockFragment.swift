import UIKit

/// The native surface's block chrome sizes, beside the classic editor's
/// `EditorBlockMetrics` (which the projection also reads) and scaled with
/// Dynamic Type by `AttributedDocumentProjection`.
enum NativeBlockMetrics {
    /// The leading gutter a bullet, number, checkbox or callout emoji sits in.
    static let listGutter = DocsSpacing.spaceLG
    /// A code block's header row, where its language control sits.
    static let codeHeaderHeight = DocsSpacing.spaceLG
    /// The empty line a divider or page break draws its rule across.
    static let ruleHeight = DocsSpacing.spaceMD
}

/// Disposable visual chrome for one native block: the bullet, the number, the
/// quote bar, the callout box and emoji, the code panel, and the divider and
/// page-break rules (a page break is dashed and labelled, never a divider).
///
/// Everything here is drawn, never stored: no marker character enters storage
/// or the Yjs replica. Colours are the app theme's, resolved at draw time, so a
/// theme or light/dark change only redraws; sizes come from the block's
/// Dynamic Type font and paragraph style.
final class NativeBlockFragment: NSTextLayoutFragment {
    /// Supplies the theme, labels and traits; set by the layout delegate.
    weak var controls: NativeBlockControls?

    private func attribute<Value>(_ key: NSAttributedString.Key, as type: Value.Type = Value.self) -> Value? {
        guard let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 else {
            return nil
        }
        return paragraph.attributedString.attribute(key, at: 0, effectiveRange: nil) as? Value
    }

    var blockType: String? { attribute(.nativeBlockType) }
    var blockID: String? { attribute(.nativeBlockID) }

    /// The first line's vertical centre and baseline, in fragment coordinates.
    var firstLineMetrics: (minY: CGFloat, midY: CGFloat, baseline: CGFloat)? {
        guard let line = textLineFragments.first else { return nil }
        let bounds = line.typographicBounds
        return (bounds.minY, bounds.midY, bounds.minY + line.glyphOrigin.y)
    }

    private var textBounds: CGRect {
        let lines = textLineFragments.map(\.typographicBounds)
        guard let first = lines.first else { return .zero }
        return lines.dropFirst().reduce(first) { $0.union($1) }
    }

    private var containerWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
    }

    override var renderingSurfaceBounds: CGRect {
        guard blockType != nil else { return super.renderingSurfaceBounds }
        // Chrome spans the container, which starts left of an indented fragment.
        return super.renderingSurfaceBounds.union(
            CGRect(x: -layoutFragmentFrame.minX, y: 0, width: containerWidth, height: layoutFragmentFrame.height))
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        // UITextView draws its fragments on the main thread; anywhere else the
        // text still draws, only without chrome.
        if let type = blockType, Thread.isMainThread {
            // Both stay on this (main) thread for the synchronous call.
            nonisolated(unsafe) let fragment = self
            nonisolated(unsafe) let context = context
            MainActor.assumeIsolated {
                guard let controls = fragment.controls else { return }
                context.saveGState()
                fragment.drawChrome(type, at: point, in: context, controls: controls)
                context.restoreGState()
            }
        }
        super.draw(at: point, in: context)
    }

    @MainActor
    private func drawChrome(
        _ type: String, at fragmentOrigin: CGPoint, in context: CGContext, controls: NativeBlockControls
    ) {
        // A nested block's chrome starts at its depth's indent (PR06a).
        let inset =
            CGFloat(attribute(.nativeDepth, as: Int.self) ?? 0)
            * UIFontMetrics(forTextStyle: .body).scaledValue(
                for: NativeBlockMetrics.listGutter, compatibleWith: controls.traits)
        // x from the indent's leading edge, y from the fragment's top.
        let point = CGPoint(x: fragmentOrigin.x - layoutFragmentFrame.minX + inset, y: fragmentOrigin.y)
        let lead = textLayoutManager?.textContainer?.lineFragmentPadding ?? 0
        let font: UIFont = attribute(.font) ?? UIFont.preferredFont(forTextStyle: .body)
        let style: NSParagraphStyle? = attribute(.paragraphStyle)
        // The paragraph's own indent past its depth's.
        let headIndent = (style?.headIndent ?? 0) - inset
        let text = textBounds
        let width = containerWidth - inset
        let padding = EditorBlockMetrics.decorationPadding
        func panel(_ rect: CGRect, _ color: UIColor) {
            context.setFillColor(color.cgColor)
            context.addPath(
                UIBezierPath(roundedRect: rect.offsetBy(dx: point.x, dy: point.y), cornerRadius: DocsRadius.md).cgPath)
            context.fillPath()
        }
        switch type {
        case "bulletListItem":
            guard let line = firstLineMetrics else { return }
            let diameter = max(4, (font.xHeight * 0.55).rounded())
            let center = CGPoint(
                x: point.x + lead + headIndent / 2, y: point.y + line.baseline - font.xHeight / 2)
            context.setFillColor(controls.color(\.textPrimary).cgColor)
            context.fillEllipse(
                in: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter))
        case "numberedListItem":
            guard let line = firstLineMetrics, let number: Int = attribute(.nativeListNumber) else { return }
            let digits = UIFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
            let label = NSAttributedString(
                string: "\(number).", attributes: [.font: digits, .foregroundColor: controls.color(\.textPrimary)])
            let size = label.size()
            let right = lead + headIndent - EditorBlockMetrics.adornmentSpacing / 2
            label.draw(
                at: CGPoint(x: point.x + max(0, right - size.width), y: point.y + line.baseline - digits.ascender))
        case "quote":
            let inset = EditorBlockMetrics.quoteVerticalPadding
            let rect = CGRect(x: 0, y: text.minY - inset, width: width, height: text.height + 2 * inset)
            context.saveGState()
            context.addPath(
                UIBezierPath(roundedRect: rect.offsetBy(dx: point.x, dy: point.y), cornerRadius: DocsRadius.md).cgPath)
            context.clip()
            context.setFillColor(controls.color(\.surfaceSunken).cgColor)
            context.fill(rect.offsetBy(dx: point.x, dy: point.y))
            context.setFillColor(controls.color(\.brandFill).cgColor)
            context.fill(
                CGRect(x: point.x, y: point.y + rect.minY, width: EditorBlockMetrics.quoteBarWidth, height: rect.height)
            )
            context.restoreGState()
        case "callout":
            let rect = CGRect(x: 0, y: text.minY - padding, width: width, height: text.height + 2 * padding)
            let name: String? = attribute(.nativeCalloutBackground)
            panel(
                rect,
                name.flatMap(AttributedDocumentProjection.backgroundColor(named:)) ?? controls.color(\.brandFillSubtle))
            guard let line = firstLineMetrics else { return }
            let emoji: String = attribute(.nativeCalloutEmoji) ?? "💡"
            NSAttributedString(string: emoji, attributes: [.font: font])
                .draw(at: CGPoint(x: point.x + lead + padding, y: point.y + line.baseline - font.ascender))
        case "codeBlock":
            let header = style?.paragraphSpacingBefore ?? 0
            let rect = CGRect(x: 0, y: text.minY - header, width: width, height: text.height + header + padding)
            panel(rect, controls.color(\.surfaceSunken))
        case "divider":
            let y = point.y + text.midY
            context.setStrokeColor(controls.color(\.borderStrong).cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: point.x, y: y))
            context.addLine(to: CGPoint(x: point.x + width, y: y))
            context.strokePath()
        case "pageBreak":
            let y = point.y + text.midY
            let caption = UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: controls.traits)
            let label = NSAttributedString(
                string: controls.labels.pageBreak,
                attributes: [.font: caption, .foregroundColor: controls.color(\.textSecondary)])
            let size = label.size()
            let gap = size.width / 2 + EditorBlockMetrics.adornmentSpacing
            context.setStrokeColor(controls.color(\.borderStrong).cgColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [DocsSpacing.space2xs, DocsSpacing.space3xs])
            for (from, to) in [(0, width / 2 - gap), (width / 2 + gap, width)] where to > from {
                context.move(to: CGPoint(x: point.x + from, y: y))
                context.addLine(to: CGPoint(x: point.x + to, y: y))
            }
            context.strokePath()
            label.draw(at: CGPoint(x: point.x + (width - size.width) / 2, y: y - size.height / 2))
        default:
            break
        }
    }
}
