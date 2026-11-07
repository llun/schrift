import UIKit

/// Standard TextKit 2 storage and one main scroll owner. This surface never
/// requests a document-height measurement or forces full-document layout.
final class NativeTextView: UITextView {
    weak var inputCoordinator: NativeInputCoordinator?

    /// PR07 owns collaborative undo. UIKit-only history would diverge from Yjs.
    override var undoManager: UndoManager? { nil }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        inputCoordinator?.refuseMarkedText()
        // Intentionally never call super: provisional text is not a command.
    }

    /// UITextInput replacements (for example, a keyboard replacement) must
    /// use the same command path even when UIKit bypasses its delegate.
    override func replace(_ range: UITextRange, withText text: String) {
        guard let inputCoordinator, isEditable else { return }
        let location = offset(from: beginningOfDocument, to: range.start)
        let length = offset(from: range.start, to: range.end)
        inputCoordinator.replace(range: NSRange(location: location, length: length), with: text)
    }

    /// On iOS 26 `insertText`/`deleteBackward` change storage without asking the
    /// delegate, so key input takes the command path here and never calls super.
    override func insertText(_ text: String) {
        guard let inputCoordinator, isEditable else { return }
        inputCoordinator.replace(range: selectedRange, with: text)
    }

    override func deleteBackward() {
        guard let inputCoordinator, isEditable else { return }
        var range = selectedRange
        if range.length == 0 {
            // Nothing precedes the document start; never reach into another block.
            guard range.location > 0 else { return }
            range = (textStorage.string as NSString).rangeOfComposedCharacterSequence(at: range.location - 1)
        }
        inputCoordinator.replace(range: range, with: "")
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if ["undo:", "redo:", "toggleBoldface:", "toggleItalics:", "toggleUnderline:"].contains(
            NSStringFromSelector(action))
        {
            return false
        }
        return super.canPerformAction(action, withSender: sender)
    }

    init() {
        super.init(frame: .zero, textContainer: nil)
        precondition(textLayoutManager != nil, "The native editor requires TextKit 2")
        isEditable = false
        isSelectable = true
        isScrollEnabled = true
        alwaysBounceVertical = true
        backgroundColor = .clear
        adjustsFontForContentSizeCategory = true
        textContainerInset = UIEdgeInsets(
            top: DocsSpacing.spaceBase, left: DocsSpacing.spaceBase,
            bottom: DocsSpacing.spaceLG, right: DocsSpacing.spaceBase)
        accessibilityIdentifier = "nativeEditor.text"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
