import UIKit

/// Shared TextKit 2 fragment geometry and drop-line indicator helpers used by
/// both `NativeMediaDropController` and `NativeBlockDragController`.
@MainActor
enum NativeDropLayoutHelper {
    /// Scaled list indent step matching `AttributedDocumentProjection` and `NativeBlockFragment`.
    static func scaledListGutter(for textView: UITextView) -> CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(
            for: NativeBlockMetrics.listGutter, compatibleWith: textView.traitCollection)
    }

    /// Creates the shared 2 pt rounded drop-cursor line view.
    static func makeDropLineView() -> UIView {
        let view = UIView()
        view.isHidden = true
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.layer.cornerRadius = 1
        return view
    }

    /// Positions and tints a 2 pt `brandFill` drop line indented to `depth`
    /// list levels in `textView`'s coordinate space.
    static func layoutDropLine(
        _ lineView: UIView,
        indicatorY: CGFloat,
        depth: Int,
        in textView: NativeTextView
    ) {
        let inset = textView.textContainerInset
        let clampedDepth = max(0, depth)
        let indent = CGFloat(clampedDepth) * scaledListGutter(for: textView)
        let x: CGFloat
        let maxWidth: CGFloat
        if textView.effectiveUserInterfaceLayoutDirection == .rightToLeft {
            let rightEdge = textView.bounds.width - inset.right - indent
            maxWidth = max(44, rightEdge - inset.left)
            x = max(inset.left, rightEdge - maxWidth)
        } else {
            let lead = inset.left + indent
            let trail = inset.right
            maxWidth = max(44, textView.bounds.width - lead - trail)
            x = min(lead, max(inset.left, textView.bounds.width - trail - maxWidth))
        }
        lineView.backgroundColor = textView.blockControls.color(\.brandFill)
        lineView.frame = CGRect(x: x, y: round(indicatorY - 1), width: maxWidth, height: 2)
    }

    /// Returns the TextKit 2 layout fragment frame (in text container coordinates)
    /// for the block at `index`, without forcing full-document layout.
    static func fragmentFrame(
        forBlockAt index: Int,
        entries: [ProjectionRangeIndex.Entry],
        contentManager: NSTextContentManager,
        layoutManager: NSTextLayoutManager,
        docStart: NSTextLocation
    ) -> CGRect? {
        guard entries.indices.contains(index) else { return nil }
        let offset = entries[index].range.location
        guard let loc = contentManager.location(docStart, offsetBy: offset),
            let fragment = layoutManager.textLayoutFragment(for: loc)
        else { return nil }
        return fragment.layoutFragmentFrame
    }

    /// Hit-tests the laid-out TextKit 2 fragment at `containerPoint` and returns
    /// its block index in `surface.blocks`.
    static func blockIndex(
        at containerPoint: CGPoint,
        in textView: NativeTextView,
        surface: NativeTextSurface
    ) -> Int? {
        guard let layoutManager = textView.textLayoutManager,
            let contentManager = layoutManager.textContentManager,
            let fragment = layoutManager.textLayoutFragment(for: containerPoint)
        else { return nil }
        let docStart = contentManager.documentRange.location
        let utf16Offset = contentManager.offset(from: docStart, to: fragment.rangeInElement.location)
        guard utf16Offset != NSNotFound,
            let entry = surface.rangeIndex.entry(atUTF16: max(0, utf16Offset)),
            let index = surface.rangeIndex.position(for: entry.blockID),
            surface.blocks.indices.contains(index),
            !surface.isHidden(position: index)
        else { return nil }
        return index
    }
}

/// Constants and card-type eligibility for single-block drag-to-reorder.
enum NativeBlockDragMetrics {
    /// Short hold on the `⋮⋮` handle so quick scrolls still pass through while
    /// grabbing the handle feels immediate.
    static let handlePressDuration: TimeInterval = 0.15
    /// Hold duration on non-text cards (matching classic leaf drag) so quick
    /// taps still open the card's editor or inspector.
    static let cardPressDuration: TimeInterval = 0.4
    /// Distance from the top or bottom visible edge that engages auto-scroll.
    static let autoScrollEdgeThreshold: CGFloat = DocsSpacing.space3XL
    /// Peak auto-scroll speed (points per second) right at the viewport edge.
    static let autoScrollMaxSpeed: CGFloat = 680
    /// Drag handle visual width sitting in the leading margin (no permanent
    /// gutter), staying clear of the default depth-0 text leading edge (`21 pt`).
    static let handleWidth: CGFloat = 20
    /// Drag handle touch-target height (44 pt minimum tap target).
    static let handleHeight: CGFloat = DocsSpacing.rowMinHeight
    /// Non-text block types that support direct 0.4 s long-press dragging.
    static let longPressCardNodes: Set<String> = [
        "image", "file", "video", "audio", "pdf", "divider", "table", "columnList",
    ]
}

/// Pure, UIKit-free auto-scroll edge velocity calculator.
enum NativeBlockDragAutoScroll {
    /// Returns signed vertical scroll velocity in points/second (negative scrolls
    /// toward the top, positive toward the bottom, `0` outside the edge zones).
    static func velocity(
        touchY: CGFloat,
        visibleMinY: CGFloat,
        visibleMaxY: CGFloat,
        edgeThreshold: CGFloat = NativeBlockDragMetrics.autoScrollEdgeThreshold,
        maxSpeed: CGFloat = NativeBlockDragMetrics.autoScrollMaxSpeed
    ) -> CGFloat {
        let viewportHeight = visibleMaxY - visibleMinY
        guard viewportHeight > 0, edgeThreshold > 0, maxSpeed > 0, touchY.isFinite else { return 0 }
        let zone = min(edgeThreshold, viewportHeight / 3)
        guard zone > 0 else { return 0 }
        if touchY < visibleMinY + zone {
            let progress = min(1, max(0, (visibleMinY + zone - touchY) / zone))
            return -maxSpeed * progress * progress
        }
        if touchY > visibleMaxY - zone {
            let progress = min(1, max(0, (touchY - (visibleMaxY - zone)) / zone))
            return maxSpeed * progress * progress
        }
        return 0
    }

    /// Advances `currentOffset` by `velocity * dt` clamped strictly in the
    /// direction of travel. Never moves opposite to `velocity`, and returns
    /// `currentOffset` unchanged when already at or beyond the bound in that
    /// direction.
    static func clampedNextOffset(
        currentOffset: CGFloat,
        velocity: CGFloat,
        dt: CGFloat,
        minOffset: CGFloat,
        maxOffset: CGFloat
    ) -> CGFloat {
        guard currentOffset.isFinite, velocity.isFinite, dt.isFinite, dt > 0,
            minOffset.isFinite, maxOffset.isFinite
        else { return currentOffset }
        let proposed = currentOffset + velocity * dt
        if velocity < 0 {
            guard currentOffset > minOffset else { return currentOffset }
            return min(currentOffset, max(minOffset, proposed))
        }
        if velocity > 0 {
            guard currentOffset < maxOffset else { return currentOffset }
            return max(currentOffset, min(maxOffset, proposed))
        }
        return currentOffset
    }
}

/// Pure handle-visibility and card-eligibility policy.
enum NativeBlockDragHandlePolicy {
    /// Decides which block (if any) displays the contextual `⋮⋮` drag handle.
    static func targetBlockID(
        isEditable: Bool,
        canReorder: Bool,
        isDragging: Bool,
        hoveredBlockID: String?,
        caretBlockID: String?,
        blocks: [BlockSnapshot],
        expanded: Set<String> = [],
        hidden: [Bool]? = nil
    ) -> String? {
        guard isEditable, canReorder, !isDragging else { return nil }
        if let hoveredBlockID {
            return NativeBlockReorder.canDrag(hoveredBlockID, in: blocks, expanded: expanded, hidden: hidden)
                ? hoveredBlockID : nil
        }
        guard let caretBlockID else { return nil }
        return NativeBlockReorder.canDrag(caretBlockID, in: blocks, expanded: expanded, hidden: hidden)
            ? caretBlockID : nil
    }

    /// Whether a block's node supports direct 0.4 s card long-press dragging.
    static func isLongPressDraggableCard(node: String) -> Bool {
        NativeBlockDragMetrics.longPressCardNodes.contains(node)
    }
}

/// A laid-out visible block frame passed into `NativeBlockDragSlotResolver`.
struct NativeVisibleBlockFrame: Equatable, Sendable {
    let index: Int
    let frame: CGRect
}

/// Resolved drop candidate during a live drag gesture.
struct NativeBlockDragCandidate: Equatable, Sendable {
    let dropTarget: NativeBlockDropTarget
    let slotIndex: Int
    let indicatorY: CGFloat
}

/// Pure slot and horizontal-indent resolver built on top of `NativeBlockReorder.dropTarget`.
enum NativeBlockDragSlotResolver {
    /// Converts a horizontal drag delta into snapped indent level steps.
    static func indentSteps(translationX: CGFloat, step: CGFloat, isRTL: Bool) -> Int {
        guard step > 0, translationX.isFinite else { return 0 }
        let steps = Int(min(max((translationX / step).rounded(), -1_000), 1_000))
        return isRTL ? -steps : steps
    }

    /// Resolves the valid drop target and indicator Y coordinate for a drag at
    /// `touchY` with horizontal offset `horizontalOffset` (in points from drag start).
    static func resolve(
        draggedBlockID: String,
        blocks: [BlockSnapshot],
        expanded: Set<String> = [],
        hidden: [Bool]? = nil,
        visibleFrames: [NativeVisibleBlockFrame],
        touchY: CGFloat,
        horizontalOffset: CGFloat,
        indentStep: CGFloat,
        isRTL: Bool = false
    ) -> NativeBlockDragCandidate? {
        guard let sourceIndex = blocks.firstIndex(where: { $0.id == draggedBlockID }),
            touchY.isFinite, horizontalOffset.isFinite
        else { return nil }

        let subtree = subtreeRange(startingAt: sourceIndex, in: blocks)
        let candidates =
            visibleFrames
            .filter { blocks.indices.contains($0.index) && !subtree.contains($0.index) }
            .sorted { $0.index < $1.index }
        guard !candidates.isEmpty else { return nil }

        let hiddenFlags = effectiveHiddenFlags(in: blocks, expanded: expanded, hidden: hidden)
        let sourceDepth = blocks[sourceIndex].depth
        let steps = indentSteps(translationX: horizontalOffset, step: indentStep, isRTL: isRTL)
        let requestedDepth = max(0, sourceDepth + steps)

        let slotIndex: Int
        let indicatorY: CGFloat

        if let nextPos = candidates.firstIndex(where: { touchY < $0.frame.midY }) {
            let next = candidates[nextPos]
            slotIndex = next.index
            if nextPos == 0 {
                indicatorY = next.frame.minY
            } else {
                let prev = candidates[nextPos - 1]
                let gap = next.frame.minY - prev.frame.maxY
                if gap > 1 {
                    // Dragged block sits between `prev` and `next` (in-place nesting/outdenting):
                    // anchor right beneath `prev` so the indented drop line sits under its new parent.
                    indicatorY = prev.frame.maxY + min(DocsSpacing.space4xs, gap / 2)
                } else {
                    indicatorY = next.frame.minY
                }
            }
        } else if let last = candidates.last {
            slotIndex = nextVisibleIndex(after: last.index, in: blocks, hidden: hiddenFlags) ?? blocks.count
            indicatorY = last.frame.maxY
        } else {
            return nil
        }

        guard
            let dropTarget = NativeBlockReorder.dropTarget(
                moving: draggedBlockID,
                in: blocks,
                expanded: expanded,
                hidden: hiddenFlags,
                slotIndex: slotIndex,
                requestedDepth: requestedDepth)
        else { return nil }

        return NativeBlockDragCandidate(dropTarget: dropTarget, slotIndex: slotIndex, indicatorY: indicatorY)
    }

    private static func subtreeRange(startingAt index: Int, in blocks: [BlockSnapshot]) -> Range<Int> {
        let baseDepth = blocks[index].depth
        var end = index + 1
        while end < blocks.count, blocks[end].depth > baseDepth { end += 1 }
        return index..<end
    }

    private static func effectiveHiddenFlags(
        in blocks: [BlockSnapshot], expanded: Set<String>, hidden: [Bool]?
    ) -> [Bool] {
        if let hidden, hidden.count == blocks.count { return hidden }
        var result: [Bool] = []
        result.reserveCapacity(blocks.count)
        var foldedDepth: Int?
        for block in blocks {
            if let depth = foldedDepth, block.depth <= depth { foldedDepth = nil }
            result.append(foldedDepth != nil)
            let isToggle =
                !block.isOpaque
                && BlockNoteWriter.isToggle(node: block.node, props: block.props.map { ($0.key, $0.value) })
            if foldedDepth == nil, isToggle, !expanded.contains(block.id) {
                foldedDepth = block.depth
            }
        }
        return result
    }

    private static func nextVisibleIndex(after index: Int, in blocks: [BlockSnapshot], hidden: [Bool]) -> Int? {
        var cursor = index + 1
        while cursor < blocks.count {
            if !hidden[cursor] { return cursor }
            cursor += 1
        }
        return nil
    }
}

/// Pure VoiceOver announcement builder after a drag-to-reorder drop commits.
enum NativeBlockDragAnnouncement {
    static let maxSummaryScalars = 40

    static func message(
        for destination: NativeMoveDestination,
        in blocks: [BlockSnapshot],
        labels: NativeEditorLabels
    ) -> String {
        switch destination {
        case .before(let id):
            if blocks.first?.id == id {
                return labels.dragMovedToTop
            }
            return String(format: labels.dragMovedBefore, blockSummary(id, in: blocks, labels: labels))
        case .after(let id):
            return String(format: labels.dragMovedAfter, blockSummary(id, in: blocks, labels: labels))
        case .firstChild(of: let id):
            return String(format: labels.dragMovedInside, blockSummary(id, in: blocks, labels: labels))
        }
    }

    static func blockSummary(_ id: String, in blocks: [BlockSnapshot], labels: NativeEditorLabels) -> String {
        guard let block = blocks.first(where: { $0.id == id }) else { return labels.paragraph }
        if AttributedDocumentProjection.isPlaceholder(block) {
            return AttributedDocumentProjection.attachmentLabel(for: block, labels: labels)
        }
        let raw = block.runs
            .map { run -> String in
                if let inline = run.inlineObject {
                    return inline.accessibilityLabel(labels: labels)
                }
                return run.text
            }
            .joined()
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty {
            let scalars = raw.unicodeScalars
            if scalars.count > maxSummaryScalars {
                return String(scalars.prefix(maxSummaryScalars)).trimmingCharacters(in: .whitespaces) + "…"
            }
            return raw
        }
        return kindLabel(for: block.node, labels: labels)
    }

    private static func kindLabel(for node: String, labels: NativeEditorLabels) -> String {
        switch node {
        case "divider": labels.divider
        case "pageBreak": labels.pageBreak
        case "heading": labels.heading
        case "callout": labels.callout
        case "bulletListItem": labels.bulletList
        case "numberedListItem": labels.numberedList
        case "checkListItem": labels.checklist
        case "quote": labels.quote
        case "codeBlock": labels.codeBlock
        case "toggleListItem": labels.toggle
        case "table": labels.table
        case "columnList": labels.columns
        case "paragraph": labels.paragraph
        default: labels.kind(node)
        }
    }
}

extension NativeInlineObject {
    fileprivate func accessibilityLabel(labels: NativeEditorLabels) -> String {
        switch self {
        case .interlink(_, _, let title, _, _):
            let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? labels.chipUntitled : trimmed
        case .mention(_, let fullName):
            return fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        case .mentionSearch:
            return ""
        case .math(let source):
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? labels.math : trimmed
        }
    }
}

/// Injectable haptics abstraction for drag-to-reorder.
@MainActor
protocol NativeBlockDragHaptics: AnyObject {
    func prepare()
    func lift()
    func targetChanged()
    func drop()
}

/// Default UIKit haptics matching the app's tactile feedback rules (never gated by Reduce Motion).
@MainActor
final class NativeSystemDragHaptics: NativeBlockDragHaptics {
    private let liftFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private let dropFeedback = UIImpactFeedbackGenerator(style: .light)

    func prepare() {
        liftFeedback.prepare()
        selectionFeedback.prepare()
        dropFeedback.prepare()
    }

    func lift() {
        liftFeedback.impactOccurred()
        selectionFeedback.prepare()
    }

    func targetChanged() {
        selectionFeedback.selectionChanged()
        selectionFeedback.prepare()
    }

    func drop() {
        dropFeedback.impactOccurred()
    }
}

/// Composes the `⋮⋮` grip icon from the bundled Material Symbols `more_horiz`
/// glyph (two rotated vertical columns of three dots, matching Material
/// `drag_indicator` proportions on the 24-unit grid).
@MainActor
enum NativeDragGripIcon {
    static func templateImage(pointSize: CGFloat = 16) -> UIImage {
        let size = CGSize(width: ceil(pointSize * 0.78), height: ceil(pointSize))
        let baseGlyph = MaterialIcon.more_horiz.uiImage(pointSize: pointSize)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            let cg = ctx.cgContext
            let colOffset = pointSize * 0.125
            if let baseGlyph {
                let drawSize = baseGlyph.size
                for dx in [-colOffset, colOffset] {
                    cg.saveGState()
                    cg.translateBy(x: size.width / 2 + dx, y: size.height / 2)
                    cg.rotate(by: .pi / 2)
                    baseGlyph.draw(
                        in: CGRect(
                            x: -drawSize.width / 2, y: -drawSize.height / 2,
                            width: drawSize.width, height: drawSize.height))
                    cg.restoreGState()
                }
            } else {
                // Defensive fallback if font failed to register in an isolated host.
                UIColor.label.setFill()
                let dotR = max(1.2, pointSize * 0.08)
                let rowStep = pointSize * 0.25
                for dx in [-colOffset, colOffset] {
                    for dy in [-rowStep, 0, rowStep] {
                        let rect = CGRect(
                            x: size.width / 2 + dx - dotR, y: size.height / 2 + dy - dotR,
                            width: dotR * 2, height: dotR * 2)
                        cg.fillEllipse(in: rect)
                    }
                }
            }
        }
        return image.withRenderingMode(.alwaysTemplate)
    }
}

/// Contextual `⋮⋮` drag handle placed beside the active or pointer-hovered block.
@MainActor
final class NativeBlockDragHandleView: UIControl, UIPointerInteractionDelegate {
    private let pillView = UIView()
    private let iconView = UIImageView()
    private var isPointerHovering = false
    /// Text-side hit boundary in this view's local X coordinates, computed from
    /// `textContainerInset + lineFragmentPadding + depthIndent` (RTL-mirrored).
    var textLeadingBoundaryX: CGFloat?
    /// Mirrors outward expansion and the text-side boundary in RTL layouts.
    var isRightToLeft = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        layer.zPosition = 10
        isAccessibilityElement = true
        accessibilityIdentifier = "nativeEditor.dragHandle"
        accessibilityTraits = .button

        pillView.isUserInteractionEnabled = false
        pillView.layer.cornerRadius = DocsRadius.sm
        pillView.alpha = 0
        addSubview(pillView)

        iconView.isUserInteractionEnabled = false
        iconView.contentMode = .center
        iconView.image = NativeDragGripIcon.templateImage(pointSize: 16)
        addSubview(iconView)

        addInteraction(UIPointerInteraction(delegate: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Keeps the visual chrome in the margin while expanding the hit area
    /// vertically to 44 pt and outward away from the text, never reaching or
    /// crossing the text's leading edge (`textLeadingBoundaryX`).
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dy = max(0, (DocsSpacing.rowMinHeight - bounds.height) / 2)
        guard point.y >= bounds.minY - dy, point.y < bounds.maxY + dy else {
            return false
        }
        if isRightToLeft {
            let minX: CGFloat
            if let boundary = textLeadingBoundaryX {
                guard point.x > boundary else { return false }
                minX = max(bounds.minX, boundary)
            } else {
                minX = bounds.minX
            }
            let maxX = max(bounds.maxX, minX + DocsSpacing.rowMinHeight)
            return point.x >= minX && point.x < maxX
        } else {
            let maxX: CGFloat
            if let boundary = textLeadingBoundaryX {
                guard point.x < boundary else { return false }
                maxX = min(bounds.maxX, boundary)
            } else {
                maxX = bounds.maxX
            }
            let minX = min(bounds.minX, maxX - DocsSpacing.rowMinHeight)
            return point.x >= minX && point.x < maxX
        }
    }

    override var isHighlighted: Bool {
        didSet { updateHighlightChrome() }
    }

    var isShowingHighlightChrome: Bool {
        pillView.alpha > 0.01
    }

    func resetInteractionState() {
        isPointerHovering = false
        isHighlighted = false
        updateHighlightChrome()
    }

    func setPointerHoveringForTesting(_ hovering: Bool) {
        isPointerHovering = hovering
        updateHighlightChrome()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let pillSize = CGSize(width: min(bounds.width, 18), height: 26)
        pillView.frame = CGRect(
            x: round((bounds.width - pillSize.width) / 2),
            y: round((bounds.height - pillSize.height) / 2),
            width: pillSize.width,
            height: pillSize.height)
        iconView.frame = pillView.frame
    }

    func applyTheme(controls: NativeBlockControls, active: Bool = false) {
        let pointSize = min(
            22,
            max(
                14,
                UIFontMetrics(forTextStyle: .body).scaledValue(for: 16, compatibleWith: controls.traits).rounded()))
        iconView.image = NativeDragGripIcon.templateImage(pointSize: pointSize)
        pillView.backgroundColor = controls.color(\.surfaceMuted)
        iconView.tintColor =
            (active || isHighlighted || isPointerHovering)
            ? controls.color(\.textSecondary) : controls.color(\.textTertiary)
        accessibilityLabel = controls.labels.dragHandle
        updateHighlightChrome()
    }

    private func updateHighlightChrome() {
        pillView.alpha = (isHighlighted || isPointerHovering) ? 1 : 0
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        let targeted = UITargetedPreview(view: pillView)
        return UIPointerStyle(effect: .highlight(targeted))
    }

    func pointerInteraction(
        _ interaction: UIPointerInteraction, willEnter region: UIPointerRegion,
        animator: any UIPointerInteractionAnimating
    ) {
        isPointerHovering = true
        animator.addAnimations { self.updateHighlightChrome() }
    }

    func pointerInteraction(
        _ interaction: UIPointerInteraction, willExit region: UIPointerRegion,
        animator: any UIPointerInteractionAnimating
    ) {
        isPointerHovering = false
        animator.addAnimations { self.updateHighlightChrome() }
    }
}

/// Floating lifted preview shown under the user's finger/pointer while dragging a block.
@MainActor
final class NativeBlockDragPreviewView: UIView {
    let gripPointSize: CGFloat

    init(
        block: BlockSnapshot,
        childCount: Int,
        controls: NativeBlockControls,
        maxWidth: CGFloat
    ) {
        self.gripPointSize = max(
            14,
            UIFontMetrics(forTextStyle: .body).scaledValue(for: 16, compatibleWith: controls.traits).rounded())
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false

        backgroundColor = controls.color(\.surfaceRaised)
        layer.cornerRadius = DocsRadius.md
        layer.borderWidth = 1
        layer.borderColor = controls.color(\.borderFocus).cgColor
        layer.shadowColor = controls.color(\.surfaceScrim).withAlphaComponent(1).cgColor
        layer.shadowOpacity = controls.traits.userInterfaceStyle == .dark ? 0.36 : 0.16
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 6)

        let grip = UIImageView(image: NativeDragGripIcon.templateImage(pointSize: gripPointSize))
        grip.tintColor = controls.color(\.textSecondary)
        grip.contentMode = .center
        grip.setContentHuggingPriority(.required, for: .horizontal)
        grip.setContentCompressionResistancePriority(.required, for: .horizontal)

        let summary = NativeBlockDragAnnouncement.blockSummary(block.id, in: [block], labels: controls.labels)
        let titleLabel = UILabel()
        titleLabel.text = summary
        titleLabel.font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: controls.traits)
        titleLabel.textColor = controls.color(\.textPrimary)
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail

        let row = UIStackView(arrangedSubviews: [grip, titleLabel])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = DocsSpacing.spaceXS
        row.translatesAutoresizingMaskIntoConstraints = false

        if childCount > 0 {
            let badgeContainer = UIView()
            badgeContainer.backgroundColor = controls.color(\.brandFillSubtle)
            badgeContainer.layer.cornerRadius = DocsRadius.lg
            badgeContainer.setContentHuggingPriority(.required, for: .horizontal)
            badgeContainer.setContentCompressionResistancePriority(.required, for: .horizontal)

            let badgeLabel = UILabel()
            badgeLabel.text = String(format: controls.labels.dragNestedCount, childCount)
            badgeLabel.font = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: controls.traits)
            badgeLabel.textColor = controls.color(\.textBrand)
            badgeLabel.translatesAutoresizingMaskIntoConstraints = false
            badgeContainer.addSubview(badgeLabel)
            NSLayoutConstraint.activate([
                badgeLabel.leadingAnchor.constraint(
                    equalTo: badgeContainer.leadingAnchor, constant: DocsSpacing.spaceXS),
                badgeLabel.trailingAnchor.constraint(
                    equalTo: badgeContainer.trailingAnchor, constant: -DocsSpacing.spaceXS),
                badgeLabel.topAnchor.constraint(
                    equalTo: badgeContainer.topAnchor, constant: DocsSpacing.space3xs),
                badgeLabel.bottomAnchor.constraint(
                    equalTo: badgeContainer.bottomAnchor, constant: -DocsSpacing.space3xs),
            ])
            row.addArrangedSubview(badgeContainer)
        }

        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DocsSpacing.spaceSM),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DocsSpacing.spaceSM),
            row.topAnchor.constraint(equalTo: topAnchor, constant: DocsSpacing.spaceXS),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DocsSpacing.spaceXS),
        ])

        let constrainedWidth = max(120, min(maxWidth, 340))
        let fitted = systemLayoutSizeFitting(
            CGSize(width: constrainedWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .fittingSizeLevel)
        let finalWidth = min(constrainedWidth, max(120, ceil(fitted.width)))
        let finalHeight = max(DocsSpacing.rowMinHeight, ceil(fitted.height))
        frame = CGRect(origin: .zero, size: CGSize(width: finalWidth, height: finalHeight))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Manages single-block drag-to-reorder on `NativeTextView`: contextual `⋮⋮`
/// handle beside the caret or iPad pointer-hovered block, 0.4 s long-press on
/// non-text cards, lifted preview, indented 2 pt drop line, `CADisplayLink`
/// auto-scroll, haptics, and VoiceOver drop announcements.
@MainActor
final class NativeBlockDragController: NSObject, UIGestureRecognizerDelegate {
    weak var textView: NativeTextView?
    let handleView = NativeBlockDragHandleView()
    let handleLongPressRecognizer = UILongPressGestureRecognizer()
    let cardLongPressRecognizer = UILongPressGestureRecognizer()
    let hoverRecognizer = UIHoverGestureRecognizer()

    var haptics: any NativeBlockDragHaptics = NativeSystemDragHaptics()
    var postAnnouncement: (String) -> Void = { message in
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private let dropLineView = NativeDropLayoutHelper.makeDropLineView()
    private let sourceDimView: UIView = {
        let view = UIView()
        view.isHidden = true
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.layer.cornerRadius = DocsRadius.sm
        return view
    }()

    private var previewView: NativeBlockDragPreviewView?
    private var displayLink: CADisplayLink?
    private var lastDisplayTimestamp: CFTimeInterval = 0

    private(set) var hoveredBlockID: String?
    private(set) var handleBlockID: String?
    private(set) var draggedBlockID: String?
    private(set) var currentCandidate: NativeBlockDragCandidate?

    private var dragStartWindowPoint: CGPoint = .zero
    private var lastWindowPoint: CGPoint = .zero
    private var previewStartCenter: CGPoint = .zero
    private var pendingCardBlockID: String?
    private var dragStartBoundsWidth: CGFloat = 0
    private var dragStartContentSizeCategory: UIContentSizeCategory = .large
    private var dragStartHorizontalSizeClass: UIUserInterfaceSizeClass = .unspecified
    private var isResolvingDuringLayout = false
    private var isAutoScrolling = false

    var isDragging: Bool { draggedBlockID != nil }
    var isHandleVisible: Bool { !handleView.isHidden && handleBlockID != nil }
    var isDropLineVisible: Bool { !dropLineView.isHidden }
    var sourceDimFrame: CGRect? { sourceDimView.isHidden ? nil : sourceDimView.frame }
    var dropLineFrame: CGRect? { dropLineView.isHidden ? nil : dropLineView.frame }

    init(textView: NativeTextView) {
        self.textView = textView
        super.init()

        handleView.isHidden = true
        dropLineView.layer.zPosition = 20
        textView.addSubview(sourceDimView)
        textView.addSubview(handleView)
        textView.addSubview(dropLineView)

        handleLongPressRecognizer.minimumPressDuration = NativeBlockDragMetrics.handlePressDuration
        handleLongPressRecognizer.allowableMovement = 14
        handleLongPressRecognizer.numberOfTouchesRequired = 1
        handleLongPressRecognizer.delegate = self
        handleLongPressRecognizer.addTarget(self, action: #selector(handleLongPress(_:)))
        handleView.addGestureRecognizer(handleLongPressRecognizer)

        cardLongPressRecognizer.minimumPressDuration = NativeBlockDragMetrics.cardPressDuration
        cardLongPressRecognizer.allowableMovement = 14
        cardLongPressRecognizer.numberOfTouchesRequired = 1
        cardLongPressRecognizer.cancelsTouchesInView = true
        cardLongPressRecognizer.delegate = self
        cardLongPressRecognizer.addTarget(self, action: #selector(cardLongPress(_:)))
        textView.addGestureRecognizer(cardLongPressRecognizer)

        hoverRecognizer.addTarget(self, action: #selector(handleHoverGesture(_:)))
        textView.addGestureRecognizer(hoverRecognizer)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil)

        applyTheme()
    }

    func tearDown() {
        clearDragState(animated: false)
        hoveredBlockID = nil
        hideHandle(clearTarget: true)
    }

    @objc private func applicationWillResignActive() {
        cancelDrag()
    }

    func traitEnvironmentDidChange() {
        if isDragging, let textView {
            if textView.traitCollection.preferredContentSizeCategory != dragStartContentSizeCategory
                || textView.traitCollection.horizontalSizeClass != dragStartHorizontalSizeClass
            {
                cancelDrag()
            }
        }
        applyTheme()
    }

    func applyTheme() {
        guard let textView else { return }
        handleView.applyTheme(controls: textView.blockControls, active: isDragging)
        sourceDimView.backgroundColor = textView.blockControls.color(\.surfacePage).withAlphaComponent(0.58)
        if !dropLineView.isHidden, let candidate = currentCandidate {
            NativeDropLayoutHelper.layoutDropLine(
                dropLineView, indicatorY: candidate.indicatorY, depth: candidate.dropTarget.depth, in: textView)
        }
    }

    func editingModeDidChange() {
        if textView?.isEditable != true {
            hoveredBlockID = nil
            cancelDrag()
        }
        updateHandle()
    }

    func bringChromeToFront(in view: NativeTextView) {
        // Keep `handleView` in `orderAuxiliarySubviews`'s reading order; its
        // `layer.zPosition` keeps it visually above text and cards without
        // moving it past the footer for VoiceOver or thrashing on every layout.
        if !sourceDimView.isHidden {
            view.bringSubviewToFront(sourceDimView)
        }
        if !dropLineView.isHidden {
            view.bringSubviewToFront(dropLineView)
        }
    }

    /// Reconciles drag and handle state after any surface patch or fold change:
    /// cancels an active drag only when the dragged block can no longer be
    /// dragged, otherwise re-resolves the source dim and drop target against
    /// the latest finger position.
    func reconcileAfterSurfaceChange() {
        if let draggedID = draggedBlockID, let textView, let surface = textView.blockControls.surface {
            let stillDraggable =
                textView.inputCoordinator?.canReorderBlocks == true
                && NativeBlockReorder.canDrag(
                    draggedID, in: surface.blocks, expanded: surface.expanded, hidden: surface.hidden)
            guard stillDraggable, let position = surface.rangeIndex.position(for: draggedID) else {
                cancelDrag()
                return
            }
            textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
            showSourceDim(for: position, in: textView, surface: surface)
            resolveDropTarget(draggedID: draggedID, in: textView, surface: surface)
            return
        }
        updateHandle()
    }

    /// Called from `NativeTextView.layoutSubviews()`: cancels a drag only on a
    /// bounds width, horizontal size-class, or Dynamic Type change; re-resolves
    /// target/dim on height or content shifts mid-drag; updates handle otherwise.
    func textViewDidLayout() {
        guard let textView else { return }
        if let draggedID = draggedBlockID, let surface = textView.blockControls.surface {
            guard !isAutoScrolling else { return }
            let widthChanged = abs(textView.bounds.width - dragStartBoundsWidth) > 0.5
            let traitsChanged =
                textView.traitCollection.preferredContentSizeCategory != dragStartContentSizeCategory
                || textView.traitCollection.horizontalSizeClass != dragStartHorizontalSizeClass
            if widthChanged || traitsChanged {
                cancelDrag()
                return
            }
            guard !isResolvingDuringLayout else { return }
            isResolvingDuringLayout = true
            defer { isResolvingDuringLayout = false }
            if let position = surface.rangeIndex.position(for: draggedID) {
                showSourceDim(for: position, in: textView, surface: surface)
                resolveDropTarget(draggedID: draggedID, in: textView, surface: surface)
            }
            return
        }
        layoutHandle()
    }

    // MARK: - Contextual Handle Placement

    func updateHandle() {
        guard let textView, let surface = textView.blockControls.surface else {
            hideHandle(clearTarget: true)
            return
        }
        let coordinator = textView.inputCoordinator
        let targetID = NativeBlockDragHandlePolicy.targetBlockID(
            isEditable: textView.isEditable,
            canReorder: coordinator?.canReorderBlocks == true,
            isDragging: isDragging,
            hoveredBlockID: hoveredBlockID,
            caretBlockID: coordinator?.caretBlockID(),
            blocks: surface.blocks,
            expanded: surface.expanded,
            hidden: surface.hidden)
        guard let targetID else {
            hideHandle(clearTarget: true)
            return
        }
        handleBlockID = targetID
        layoutHandle()
    }

    func layoutHandle() {
        guard let textView,
            let surface = textView.blockControls.surface,
            let targetID = handleBlockID,
            !isDragging,
            textView.isEditable,
            textView.inputCoordinator?.canReorderBlocks == true,
            NativeBlockReorder.canDrag(
                targetID, in: surface.blocks, expanded: surface.expanded, hidden: surface.hidden),
            let position = surface.rangeIndex.position(for: targetID),
            surface.blocks.indices.contains(position),
            let layoutManager = textView.textLayoutManager,
            let contentManager = layoutManager.textContentManager
        else {
            hideHandle(clearTarget: true)
            return
        }

        let docStart = contentManager.documentRange.location
        let entry = surface.rangeIndex.entries[position]
        guard let loc = contentManager.location(docStart, offsetBy: entry.range.location),
            let fragment = layoutManager.textLayoutFragment(for: loc),
            fragment.layoutFragmentFrame.height > 0
        else {
            // Keep `handleBlockID` so scrolling back into view or finishing
            // initial layout restores the handle without a new selection change.
            hideHandle(clearTarget: false)
            return
        }

        let block = surface.blocks[position]
        let fragFrame = fragment.layoutFragmentFrame.offsetBy(dx: 0, dy: textView.textContainerInset.top)
        let blockFragment = fragment as? NativeBlockFragment
        let firstLineMidY: CGFloat
        if AttributedDocumentProjection.isPlaceholder(block) {
            firstLineMidY = min(fragFrame.height / 2, DocsSpacing.rowMinHeight / 2)
        } else {
            firstLineMidY = blockFragment?.firstLineMetrics?.midY ?? min(fragFrame.height / 2, 12)
        }

        let padding = textView.textContainer.lineFragmentPadding
        let gutter = NativeDropLayoutHelper.scaledListGutter(for: textView)
        let depthInset = CGFloat(block.depth) * gutter
        let width = NativeBlockDragMetrics.handleWidth
        let height = NativeBlockDragMetrics.handleHeight
        let isRTL = textView.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let x: CGFloat
        let textLeadingX: CGFloat
        if isRTL {
            let leadingEdge = textView.bounds.width - textView.textContainerInset.right - depthInset
            x = min(textView.bounds.width - width, max(0, leadingEdge))
            textLeadingX = leadingEdge - padding
        } else {
            let blockLeadX = textView.textContainerInset.left + depthInset
            x = max(0, blockLeadX - width)
            textLeadingX = blockLeadX + padding
        }
        let y = fragFrame.minY + firstLineMidY - height / 2
        // Keep the handle's frame (and therefore its accessibilityFrame) strictly
        // clear of `textLeadingX` so it never obscures the text's leading edge or
        // `UITextView`'s accessibility activation point.
        let frameX: CGFloat
        let frameWidth: CGFloat
        if isRTL {
            let minX = max(round(x), ceil(textLeadingX) + 1)
            frameX = minX
            frameWidth = min(width, max(0, textView.bounds.width - minX))
        } else {
            frameX = round(x)
            let maxX = floor(textLeadingX) - 1
            frameWidth = min(width, max(0, maxX - frameX))
        }
        guard frameWidth >= 1 else {
            hideHandle(clearTarget: false)
            return
        }
        handleView.frame = CGRect(x: frameX, y: round(y), width: frameWidth, height: height)
        handleView.isRightToLeft = isRTL
        handleView.textLeadingBoundaryX = textLeadingX - frameX
        handleView.applyTheme(controls: textView.blockControls)
        let moved = handleView.isHidden || orderedHandleBlockID != targetID
        handleView.isHidden = false
        // Hit-testing and VoiceOver follow subview order, which only a layout pass refreshes otherwise.
        if moved {
            orderedHandleBlockID = targetID
            textView.orderAuxiliarySubviews()
        }
    }

    /// The block the handle was last ordered beside in the text view's subviews.
    private var orderedHandleBlockID: String?

    private func hideHandle(clearTarget: Bool) {
        if clearTarget {
            handleBlockID = nil
        }
        handleView.resetInteractionState()
        handleView.isHidden = true
    }

    // MARK: - Pointer Hover (iPad)

    @objc private func handleHoverGesture(_ recognizer: UIHoverGestureRecognizer) {
        guard let textView else { return }
        switch recognizer.state {
        case .began, .changed:
            handleHover(at: recognizer.location(in: textView))
        case .ended, .cancelled:
            clearHover()
        default:
            break
        }
    }

    func handleHover(at point: CGPoint) {
        guard let textView, let surface = textView.blockControls.surface,
            textView.isEditable, textView.inputCoordinator?.canReorderBlocks == true, !isDragging
        else {
            clearHover()
            return
        }
        if !handleView.isHidden, handleView.frame.insetBy(dx: -4, dy: -4).contains(point), let current = handleBlockID {
            hoveredBlockID = current
            return
        }
        let nextID = blockID(at: point, in: textView, surface: surface, cardsOnly: false)
        if nextID != hoveredBlockID {
            hoveredBlockID = nextID
            updateHandle()
        }
    }

    func clearHover() {
        guard hoveredBlockID != nil else { return }
        hoveredBlockID = nil
        updateHandle()
    }

    // MARK: - Gesture Handlers

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        let windowPoint = recognizer.location(in: nil)
        switch recognizer.state {
        case .began:
            guard let blockID = handleBlockID else { return }
            beginDrag(blockID: blockID, atWindowPoint: windowPoint)
        case .changed:
            updateDrag(atWindowPoint: windowPoint)
        case .ended:
            endDrag()
        case .cancelled, .failed:
            cancelDrag()
        default:
            break
        }
    }

    @objc private func cardLongPress(_ recognizer: UILongPressGestureRecognizer) {
        let windowPoint = recognizer.location(in: nil)
        switch recognizer.state {
        case .began:
            guard let textView, let surface = textView.blockControls.surface else { return }
            let localPoint = recognizer.location(in: textView)
            let hitID =
                pendingCardBlockID
                ?? blockID(at: localPoint, in: textView, surface: surface, cardsOnly: true)
            pendingCardBlockID = nil
            guard let hitID else { return }
            beginDrag(blockID: hitID, atWindowPoint: windowPoint)
        case .changed:
            updateDrag(atWindowPoint: windowPoint)
        case .ended:
            endDrag()
        case .cancelled, .failed:
            pendingCardBlockID = nil
            cancelDrag()
        default:
            break
        }
    }

    // MARK: - Drag Lifecycle (Programmatically Testable)

    @discardableResult
    func beginDrag(blockID: String, atWindowPoint windowPoint: CGPoint) -> Bool {
        guard let textView,
            let surface = textView.blockControls.surface,
            textView.isEditable,
            textView.inputCoordinator?.canReorderBlocks == true,
            !isDragging,
            NativeBlockReorder.canDrag(
                blockID, in: surface.blocks, expanded: surface.expanded, hidden: surface.hidden),
            let position = surface.rangeIndex.position(for: blockID),
            surface.blocks.indices.contains(position)
        else { return false }

        draggedBlockID = blockID
        dragStartWindowPoint = windowPoint
        lastWindowPoint = windowPoint
        dragStartBoundsWidth = textView.bounds.width
        dragStartContentSizeCategory = textView.traitCollection.preferredContentSizeCategory
        dragStartHorizontalSizeClass = textView.traitCollection.horizontalSizeClass
        currentCandidate = nil
        handleView.resetInteractionState()
        handleView.isHidden = true

        haptics.prepare()
        haptics.lift()

        let block = surface.blocks[position]
        let childCount = subtreeChildCount(startingAt: position, in: surface.blocks)
        showSourceDim(for: position, in: textView, surface: surface)
        showPreview(for: block, childCount: childCount, atWindowPoint: windowPoint, in: textView)
        startAutoScroll()
        updateDrag(atWindowPoint: windowPoint)
        return true
    }

    func updateDrag(atWindowPoint windowPoint: CGPoint) {
        guard let textView, let surface = textView.blockControls.surface, let draggedID = draggedBlockID else { return }
        lastWindowPoint = windowPoint

        if let previewView {
            let dx = windowPoint.x - dragStartWindowPoint.x
            let dy = windowPoint.y - dragStartWindowPoint.y
            let overlayBounds = previewView.superview?.bounds ?? textView.bounds
            let halfW = previewView.bounds.width / 2
            let clampedX = min(
                max(halfW + DocsSpacing.spaceXS, previewStartCenter.x + dx),
                max(halfW + DocsSpacing.spaceXS, overlayBounds.width - halfW - DocsSpacing.spaceXS))
            let halfH = previewView.bounds.height / 2
            let clampedY = min(
                max(halfH + DocsSpacing.spaceXS, previewStartCenter.y + dy),
                max(halfH + DocsSpacing.spaceXS, overlayBounds.height - halfH - DocsSpacing.spaceXS))
            previewView.center = CGPoint(x: clampedX, y: clampedY)
        }

        resolveDropTarget(draggedID: draggedID, in: textView, surface: surface)
    }

    @discardableResult
    func endDrag() -> Bool {
        guard let draggedID = draggedBlockID, let textView, let surface = textView.blockControls.surface else {
            cancelDrag()
            return false
        }
        let candidate = currentCandidate
        let blocksBefore = surface.blocks
        let labels = textView.blockControls.labels

        clearDragState(animated: true)

        guard let candidate, let coordinator = textView.inputCoordinator else {
            updateHandle()
            return false
        }
        let announcement = NativeBlockDragAnnouncement.message(
            for: candidate.dropTarget.destination, in: blocksBefore, labels: labels)
        let posted = coordinator.moveBlock(draggedID, to: candidate.dropTarget.destination) { [weak self] applied in
            guard applied, let self else { return }
            self.haptics.drop()
            self.postAnnouncement(announcement)
        }
        updateHandle()
        return posted
    }

    func cancelDrag() {
        guard isDragging || previewView != nil || !dropLineView.isHidden else { return }
        clearDragState(animated: true)
        updateHandle()
    }

    // MARK: - Drop Resolution & Chrome

    private func resolveDropTarget(
        draggedID: String,
        in textView: NativeTextView,
        surface: NativeTextSurface
    ) {
        let localPoint = textView.convert(lastWindowPoint, from: nil)
        let horizontalOffset = lastWindowPoint.x - dragStartWindowPoint.x
        let visibleFrames = visibleViewportFrames(in: textView, surface: surface)
        let indentStep = NativeDropLayoutHelper.scaledListGutter(for: textView)
        let isRTL = textView.effectiveUserInterfaceLayoutDirection == .rightToLeft

        let nextCandidate = NativeBlockDragSlotResolver.resolve(
            draggedBlockID: draggedID,
            blocks: surface.blocks,
            expanded: surface.expanded,
            hidden: surface.hidden,
            visibleFrames: visibleFrames,
            touchY: localPoint.y,
            horizontalOffset: horizontalOffset,
            indentStep: indentStep,
            isRTL: isRTL)

        if nextCandidate?.dropTarget != currentCandidate?.dropTarget, nextCandidate != nil {
            haptics.targetChanged()
        }
        currentCandidate = nextCandidate

        if let nextCandidate {
            NativeDropLayoutHelper.layoutDropLine(
                dropLineView,
                indicatorY: nextCandidate.indicatorY,
                depth: nextCandidate.dropTarget.depth,
                in: textView)
            dropLineView.isHidden = false
            textView.bringSubviewToFront(dropLineView)
        } else {
            dropLineView.isHidden = true
        }
    }

    private func visibleViewportFrames(
        in textView: NativeTextView,
        surface: NativeTextSurface
    ) -> [NativeVisibleBlockFrame] {
        guard let layoutManager = textView.textLayoutManager else { return [] }
        layoutManager.textViewportLayoutController.layoutViewport()
        guard let viewport = layoutManager.textViewportLayoutController.viewportRange else { return [] }
        let topInset = textView.textContainerInset.top
        var frames: [NativeVisibleBlockFrame] = []
        layoutManager.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            guard fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending else {
                return false
            }
            guard let blockFragment = fragment as? NativeBlockFragment,
                let id = blockFragment.blockID,
                let index = surface.rangeIndex.position(for: id),
                !surface.isHidden(position: index),
                fragment.layoutFragmentFrame.height > 0
            else { return true }
            let viewFrame = fragment.layoutFragmentFrame.offsetBy(dx: 0, dy: topInset)
            frames.append(NativeVisibleBlockFrame(index: index, frame: viewFrame))
            return true
        }
        return frames
    }

    private func showSourceDim(for position: Int, in textView: NativeTextView, surface: NativeTextSurface) {
        let baseDepth = surface.blocks[position].depth
        var end = position + 1
        while end < surface.blocks.count, surface.blocks[end].depth > baseDepth { end += 1 }
        let subtree = position..<end

        // Only union fragments that are already laid out in the viewport so we
        // never realise off-screen descendants or union `.zero` frames up to y=0.
        let visibleFrames = visibleViewportFrames(in: textView, surface: surface)
        var unionRect: CGRect?
        for item in visibleFrames where subtree.contains(item.index) && item.frame.height > 0 {
            unionRect = unionRect.map { $0.union(item.frame) } ?? item.frame
        }
        guard let unionRect else {
            sourceDimView.isHidden = true
            return
        }
        let inset = textView.textContainerInset
        let width = max(44, textView.bounds.width - inset.left - inset.right)
        sourceDimView.backgroundColor = textView.blockControls.color(\.surfacePage).withAlphaComponent(0.58)
        sourceDimView.frame = CGRect(
            x: inset.left,
            y: unionRect.minY,
            width: width,
            height: unionRect.height)
        sourceDimView.isHidden = false
        textView.bringSubviewToFront(sourceDimView)
    }

    private func showPreview(
        for block: BlockSnapshot,
        childCount: Int,
        atWindowPoint windowPoint: CGPoint,
        in textView: NativeTextView
    ) {
        previewView?.removeFromSuperview()
        let overlay: UIView = textView.window ?? textView
        let maxWidth = max(160, overlay.bounds.width - DocsSpacing.spaceLG)
        let preview = NativeBlockDragPreviewView(
            block: block, childCount: childCount, controls: textView.blockControls, maxWidth: maxWidth)
        let pointInOverlay = overlay.convert(windowPoint, from: nil)
        let halfW = preview.bounds.width / 2
        let startCenter = CGPoint(
            x: min(
                max(halfW + DocsSpacing.spaceBase, pointInOverlay.x + halfW * 0.6),
                max(halfW + DocsSpacing.spaceBase, overlay.bounds.width - halfW - DocsSpacing.spaceBase)),
            y: pointInOverlay.y)
        preview.center = startCenter
        previewStartCenter = startCenter
        overlay.addSubview(preview)
        previewView = preview

        if UIAccessibility.isReduceMotionEnabled {
            preview.alpha = 0.94
        } else {
            preview.alpha = 0.7
            preview.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
            UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                preview.alpha = 0.94
                preview.transform = CGAffineTransform(scaleX: 1.02, y: 1.02)
            }
        }
    }

    private func clearDragState(animated: Bool) {
        stopAutoScroll()
        draggedBlockID = nil
        currentCandidate = nil
        dropLineView.isHidden = true
        sourceDimView.isHidden = true

        guard let preview = previewView else { return }
        previewView = nil
        if animated, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(
                withDuration: 0.15, delay: 0, options: [.curveEaseIn, .beginFromCurrentState],
                animations: {
                    preview.alpha = 0
                    preview.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
                },
                completion: { _ in preview.removeFromSuperview() })
        } else {
            preview.removeFromSuperview()
        }
    }

    // MARK: - Auto-Scroll (`CADisplayLink`)

    private func startAutoScroll() {
        stopAutoScroll()
        lastDisplayTimestamp = 0
        let proxy = DisplayLinkProxy(owner: self)
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopAutoScroll() {
        displayLink?.invalidate()
        displayLink = nil
        lastDisplayTimestamp = 0
    }

    fileprivate func autoScrollTick(_ link: CADisplayLink) {
        let dt: CGFloat
        if lastDisplayTimestamp > 0 {
            dt = CGFloat(min(1.0 / 20.0, max(1.0 / 240.0, link.timestamp - lastDisplayTimestamp)))
        } else {
            dt = 1.0 / 60.0
        }
        lastDisplayTimestamp = link.timestamp
        _ = performAutoScrollStep(dt: dt)
    }

    @discardableResult
    func performAutoScrollStep(dt: CGFloat) -> Bool {
        guard let textView, let surface = textView.blockControls.surface, let draggedID = draggedBlockID else {
            stopAutoScroll()
            return false
        }
        guard let scrollOwner = enclosingScrollOwner(for: textView) else { return false }
        let touchInScroll = scrollOwner.convert(lastWindowPoint, from: nil)
        let topSafe = scrollOwner.adjustedContentInset.top - scrollOwner.contentInset.top
        let bottomSafe = scrollOwner.adjustedContentInset.bottom - scrollOwner.contentInset.bottom
        let visibleMinY = scrollOwner.bounds.minY + topSafe
        let visibleMaxY = scrollOwner.bounds.maxY - bottomSafe

        let velocity = NativeBlockDragAutoScroll.velocity(
            touchY: touchInScroll.y, visibleMinY: visibleMinY, visibleMaxY: visibleMaxY)
        guard abs(velocity) > 0.5 else { return false }

        let minOffsetY: CGFloat
        let maxOffsetY: CGFloat
        if let columnContainer = scrollOwner as? ColumnTextContainer,
            let columnBounds = columnContainer.scrollBounds(for: textView)
        {
            minOffsetY = columnBounds.lowerBound
            maxOffsetY = columnBounds.upperBound
        } else {
            minOffsetY = -scrollOwner.adjustedContentInset.top
            maxOffsetY = max(
                minOffsetY,
                scrollOwner.contentSize.height + scrollOwner.adjustedContentInset.bottom - scrollOwner.bounds.height)
        }
        let nextY = NativeBlockDragAutoScroll.clampedNextOffset(
            currentOffset: scrollOwner.contentOffset.y,
            velocity: velocity,
            dt: dt,
            minOffset: minOffsetY,
            maxOffset: maxOffsetY)
        guard abs(nextY - scrollOwner.contentOffset.y) > 0.25 else { return false }

        isAutoScrolling = true
        defer { isAutoScrolling = false }
        scrollOwner.contentOffset.y = nextY
        if scrollOwner !== textView {
            // In `ColumnTextContainer`, lay out the container first so the
            // active column's viewport frame and contentOffset match `nextY`
            // before hit-testing and resolving the new drop target.
            scrollOwner.setNeedsLayout()
            scrollOwner.layoutIfNeeded()
        }
        textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        if let position = surface.rangeIndex.position(for: draggedID) {
            showSourceDim(for: position, in: textView, surface: surface)
        }
        resolveDropTarget(draggedID: draggedID, in: textView, surface: surface)
        return true
    }

    private func enclosingScrollOwner(for textView: NativeTextView) -> UIScrollView? {
        var ancestor = textView.superview
        while let current = ancestor {
            if let container = current as? ColumnTextContainer, container.isScrollEnabled {
                return container
            }
            ancestor = current.superview
        }
        if textView.isScrollEnabled, textView.panGestureRecognizer.isEnabled {
            return textView
        }
        ancestor = textView.superview
        while let current = ancestor {
            if let scroll = current as? UIScrollView, scroll.isScrollEnabled {
                return scroll
            }
            ancestor = current.superview
        }
        return textView.isScrollEnabled ? textView : nil
    }

    // MARK: - Block Hit-Testing

    func cardBlockID(at point: CGPoint) -> String? {
        guard let textView, let surface = textView.blockControls.surface else { return nil }
        return blockID(at: point, in: textView, surface: surface, cardsOnly: true)
    }

    func canBeginCardLongPress(at point: CGPoint) -> Bool {
        guard let textView,
            let surface = textView.blockControls.surface,
            textView.isEditable,
            textView.inputCoordinator?.canReorderBlocks == true,
            !isDragging
        else { return false }
        if !handleView.isHidden, handleView.point(inside: textView.convert(point, to: handleView), with: nil) {
            return false
        }
        guard let id = blockID(at: point, in: textView, surface: surface, cardsOnly: true),
            NativeBlockReorder.canDrag(id, in: surface.blocks, expanded: surface.expanded, hidden: surface.hidden)
        else {
            pendingCardBlockID = nil
            return false
        }
        pendingCardBlockID = id
        return true
    }

    private func blockID(
        at point: CGPoint,
        in textView: NativeTextView,
        surface: NativeTextSurface,
        cardsOnly: Bool
    ) -> String? {
        if let hitView = textView.hitTest(point, with: nil) {
            var current: UIView? = hitView
            while let view = current {
                if let attachment = view as? NativeAttachmentView {
                    let id = attachment.content.blockID
                    if let pos = surface.rangeIndex.position(for: id),
                        surface.blocks.indices.contains(pos),
                        !surface.isHidden(position: pos)
                    {
                        let block = surface.blocks[pos]
                        if !cardsOnly || NativeBlockDragHandlePolicy.isLongPressDraggableCard(node: block.node) {
                            return id
                        }
                    }
                    return nil
                }
                if view === textView { break }
                current = view.superview
            }
        }

        let inset = textView.textContainerInset
        let clampedX = max(
            0, min(textView.bounds.width - inset.left - inset.right, max(0, point.x - inset.left)))
        let containerPoint = CGPoint(x: clampedX, y: point.y - inset.top)
        guard let index = NativeDropLayoutHelper.blockIndex(at: containerPoint, in: textView, surface: surface) else {
            return nil
        }
        let block = surface.blocks[index]
        if cardsOnly, !NativeBlockDragHandlePolicy.isLongPressDraggableCard(node: block.node) {
            return nil
        }
        return block.id
    }

    private func subtreeChildCount(startingAt index: Int, in blocks: [BlockSnapshot]) -> Int {
        let baseDepth = blocks[index].depth
        var end = index + 1
        while end < blocks.count, blocks[end].depth > baseDepth { end += 1 }
        return max(0, end - index - 1)
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let textView,
            let surface = textView.blockControls.surface,
            textView.isEditable,
            textView.inputCoordinator?.canReorderBlocks == true,
            !isDragging
        else { return false }

        if gestureRecognizer === handleLongPressRecognizer {
            guard let id = handleBlockID else { return false }
            return NativeBlockReorder.canDrag(
                id, in: surface.blocks, expanded: surface.expanded, hidden: surface.hidden)
        }
        if gestureRecognizer === cardLongPressRecognizer {
            return canBeginCardLongPress(at: gestureRecognizer.location(in: textView))
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }
}

/// Weak proxy so `CADisplayLink` never retains `NativeBlockDragController`.
@MainActor
private final class DisplayLinkProxy: NSObject {
    weak var owner: NativeBlockDragController?

    init(owner: NativeBlockDragController) {
        self.owner = owner
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let owner else {
            link.invalidate()
            return
        }
        owner.autoScrollTick(link)
    }
}
