import SwiftUI
import UIKit

// MARK: - Which blocks can be dragged

/// Whether the editing canvas lets this block be picked up and dragged.
///
/// Only the **leaves** (divider, image, attachment) are draggable. They have no
/// text view, so a long press on one means nothing else; on a text row the same
/// long press belongs to `UITextView` (caret loupe, selection), and taking it
/// away would break text editing. Moving a leaf past text rows is what puts a
/// photo under a checklist item, which is the case this exists for.
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
    var translation: CGFloat = 0

    var centerY: CGFloat { startMidY + translation }
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
    /// Vertical distance from where the press began, in points.
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat) -> Void
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
        let y = recognizer.location(in: nil).y
        switch recognizer.state {
        case .began:
            context.coordinator.startY = y
            onBegan()
        case .changed:
            onChanged(y - context.coordinator.startY)
        case .ended:
            onEnded(y - context.coordinator.startY)
        case .cancelled, .failed:
            onCancelled()
        default:
            break
        }
    }

    @MainActor
    final class Coordinator {
        var startY: CGFloat = 0
    }
}
