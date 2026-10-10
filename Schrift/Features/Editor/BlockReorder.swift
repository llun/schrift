import SwiftUI
import UIKit

// MARK: - Which blocks can be dragged

/// Whether the editing canvas lets this block be picked up and dragged.
///
/// Only the **leaves** (divider, image, attachment) are draggable. They have no
/// text view, so a long press on one means nothing else; on a text row the same
/// long press belongs to `UITextView` (caret loupe, selection), and taking it
/// away would break text editing. Moving a leaf past text rows is what puts a
/// photo under a checklist item, which is the case this exists for. Sliding an
/// image or attachment sideways while dragging nests it under the list item
/// above (`leafDragPreviewIndent`); a divider never nests.
func blockIsReorderable(_ kind: BlockKind) -> Bool {
    switch kind {
    case .divider, .image, .attachment: true
    default: false
    }
}

// MARK: - Where a dragged block lands

/// The index the dragged block should occupy in the **final** array, or nil
/// when the drop would leave it where it is.
///
/// Every other block counts as "above" the drop when its centre sits above
/// the dragged row's centre. `frames` holds only the rows the lazy canvas has
/// realized, so a missing frame keeps its original side of the dragged block:
/// a drag can't reach a row the canvas hasn't laid out, because the canvas
/// doesn't scroll during a drag.
///
/// A pure function so the decision is testable without hosting the canvas.
func blockReorderDestination(
    draggedID: UUID,
    dragCenterY: CGFloat,
    order: [UUID],
    frames: [UUID: CGRect]
) -> Int? {
    guard let source = order.firstIndex(of: draggedID) else { return nil }
    var destination = 0
    for (index, id) in order.enumerated() where id != draggedID {
        let isAbove = frames[id].map { $0.midY < dragCenterY } ?? (index < source)
        if isAbove { destination += 1 }
    }
    return destination == source ? nil : destination
}

/// The in-progress drag of one block on the editing canvas.
struct BlockReorderDrag: Equatable {
    let blockID: UUID
    /// The row's centre when the drag began, in the canvas's frame space. Captured
    /// once: the row's recorded frame follows the drag offset afterwards.
    let startMidY: CGFloat
    /// Distance from where the press began, in points. The height reorders; the
    /// width slides a nestable leaf between list levels (`leafDragIndentSteps`).
    var translation: CGSize = .zero

    var centerY: CGFloat { startMidY + translation.height }
}

// MARK: - Nesting while dragging

/// How many list levels a horizontal drag of `translationX` points moves a leaf:
/// the drag divided by one level's inset (`EditorBlockMetrics.listIndentStep`),
/// rounded to the nearest level. Positive is deeper.
///
/// In a right-to-left layout the indent grows leftwards, so the same finger
/// movement means the opposite number of levels.
func leafDragIndentSteps(translationX: CGFloat, step: CGFloat, layoutDirection: LayoutDirection) -> Int {
    guard step > 0, translationX.isFinite else { return 0 }
    // Bounded before the conversion: `Int(_:)` traps on a value it can't hold.
    let steps = Int(min(max((translationX / step).rounded(), -1_000), 1_000))
    return layoutDirection == .rightToLeft ? -steps : steps
}

/// The blocks as they would stand with the dragged one moved to `destination`
/// (nil: where it is), and the index it would land at. Mirrors the move in
/// `EditorViewModel.moveBlock`, destination clamp included, without touching the
/// dragged block's indent (the landing level is decided afterwards).
private func leafDragLanding(
    blocks: [EditorBlock], blockID: UUID, destination: Int?
) -> (blocks: [EditorBlock], index: Int, originalIndent: Int)? {
    guard let source = blocks.firstIndex(where: { $0.id == blockID }) else { return nil }
    let target = min(max(destination ?? source, 0), blocks.count - 1)
    var moved = blocks
    if target != source {
        let block = moved.remove(at: source)
        moved.insert(block, at: target)
    }
    return (moved, target, blocks[source].indent)
}

/// The levels a dragged nestable leaf may take if it were dropped at
/// `destination` (nil: its current index) — `leafIndentRange` evaluated in the
/// array after the move. Nil for a block that never nests (a divider).
func leafDragIndentRange(blocks: [EditorBlock], blockID: UUID, destination: Int?) -> ClosedRange<Int>? {
    guard let landing = leafDragLanding(blocks: blocks, blockID: blockID, destination: destination) else {
        return nil
    }
    return leafIndentRange(at: landing.index, in: landing.blocks)
}

/// The level the dragged leaf shows (and takes on drop): the level a plain move
/// to `destination` would give it (`movedLeafIndent`), shifted by the horizontal
/// `steps` and clamped into the range that destination allows. Nil for a block
/// that never nests.
func leafDragPreviewIndent(blocks: [EditorBlock], blockID: UUID, destination: Int?, steps: Int) -> Int? {
    guard let landing = leafDragLanding(blocks: blocks, blockID: blockID, destination: destination),
        let base = movedLeafIndent(
            at: landing.index, in: landing.blocks, originalIndent: landing.originalIndent)
    else { return nil }
    return movedLeafIndent(
        at: landing.index, in: landing.blocks, originalIndent: landing.originalIndent, requested: base + steps)
}

// MARK: - The gesture

/// A UIKit long press that keeps reporting while the finger moves.
///
/// Not a SwiftUI `LongPressGesture` sequenced into a `DragGesture`: a SwiftUI
/// drag inside the canvas's `ScrollView` claims the touch and can stop the list
/// scrolling (see `SwipeRevealGesture` for that lesson). A long press is decided
/// by UIKit's own arbitration with the scroll view's pan instead: moving before
/// the press completes fails it, so the canvas scrolls, and once it has begun
/// the pan cannot start, so the canvas holds still while the block moves.
struct BlockReorderGesture: UIGestureRecognizerRepresentable {
    var onBegan: () -> Void
    /// Distance from where the press began, in points.
    var onChanged: (CGSize) -> Void
    var onEnded: (CGSize) -> Void
    var onCancelled: () -> Void

    /// Long enough that a plain tap on an image or attachment card still reaches it.
    static let minimumPressDuration: TimeInterval = 0.4

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    static func makeRecognizer() -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = minimumPressDuration
        recognizer.numberOfTouchesRequired = 1
        return recognizer
    }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        Self.makeRecognizer()
    }

    func updateUIGestureRecognizer(_ recognizer: UILongPressGestureRecognizer, context: Context) {}

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        // Measured in the window, never in the recognizer's view: the row is
        // `.offset` by the drag, so its own space moves with the finger.
        let point = recognizer.location(in: nil)
        let start = context.coordinator.start
        let translation = CGSize(width: point.x - start.x, height: point.y - start.y)
        switch recognizer.state {
        case .began:
            context.coordinator.start = point
            onBegan()
        case .changed:
            onChanged(translation)
        case .ended:
            onEnded(translation)
        case .cancelled, .failed:
            onCancelled()
        default:
            break
        }
    }

    @MainActor
    final class Coordinator {
        var start: CGPoint = .zero
    }
}
