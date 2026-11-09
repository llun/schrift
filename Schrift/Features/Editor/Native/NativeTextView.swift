import UIKit

/// Standard TextKit 2 storage and one main scroll owner. This surface never
/// requests a document-height measurement or forces full-document layout.
final class NativeTextView: UITextView {
    weak var inputCoordinator: NativeInputCoordinator?
    /// UIKit's own marked-text application must reach storage directly; the
    /// command path would refuse it as a second writer.
    private(set) var isApplyingMarkedText = false

    /// PR07 owns collaborative undo. UIKit-only history would diverge from Yjs.
    override var undoManager: UndoManager? { nil }

    /// Marked text is provisional: UIKit owns the range in storage and the
    /// composition session captures the replacement anchors before it exists.
    /// An unsupported composition keeps the preserved read-only refusal.
    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        guard !isApplyingMarkedText else { return super.setMarkedText(markedText, selectedRange: selectedRange) }
        mark(markedText) { super.setMarkedText(markedText, selectedRange: selectedRange) }
    }

    /// The system Japanese and Chinese keyboards mark attributed (segmented)
    /// text through this entry point, not `setMarkedText`.
    override func setAttributedMarkedText(_ markedText: NSAttributedString?, selectedRange: NSRange) {
        guard !isApplyingMarkedText else {
            return super.setAttributedMarkedText(markedText, selectedRange: selectedRange)
        }
        mark(markedText?.string) { super.setAttributedMarkedText(markedText, selectedRange: selectedRange) }
    }

    private func mark(_ markedText: String?, apply: () -> Void) {
        guard let inputCoordinator, isEditable else { return }
        guard let markedText, !markedText.isEmpty else {
            dropMarkedText()
            inputCoordinator.cancelComposition()
            return
        }
        guard inputCoordinator.beginComposition(markedText: markedText) else {
            inputCoordinator.refuseComposition()
            return
        }
        isApplyingMarkedText = true
        apply()
        isApplyingMarkedText = false
    }

    /// UIKit keeps the marked text in storage; the commit writes what UIKit
    /// displays and reconciles it to the projection, so clear the marked
    /// state first.
    override func unmarkText() {
        guard let inputCoordinator, inputCoordinator.composition.isActive else {
            super.unmarkText()
            return
        }
        let marked = markedTextRange.flatMap { text(in: $0) }
        dropMarkedText()
        inputCoordinator.commitComposition(text: marked)
    }

    /// UITextInput replacements (for example, a keyboard replacement) must
    /// use the same command path even when UIKit bypasses its delegate.
    override func replace(_ range: UITextRange, withText text: String) {
        guard let inputCoordinator, isEditable else { return }
        if isApplyingMarkedText {
            super.replace(range, withText: text)
            return
        }
        if inputCoordinator.composition.isActive {
            // A keyboard committing a candidate over the marked text; any other
            // range would use offsets that are stale until reconciliation.
            if let marked = markedTextRange, compare(range.start, to: marked.start) == .orderedSame,
                compare(range.end, to: marked.end) == .orderedSame
            {
                dropMarkedText()
                inputCoordinator.commitComposition(text: text)
            }
            return
        }
        let location = offset(from: beginningOfDocument, to: range.start)
        let length = offset(from: range.start, to: range.end)
        inputCoordinator.replace(range: NSRange(location: location, length: length), with: text)
    }

    /// On iOS 26 `insertText`/`deleteBackward` change storage without asking the
    /// delegate, so key input takes the command path here and never calls super.
    /// While text is marked, UIKit's commit replaces the marked range: the
    /// composition session writes it once instead.
    override func insertText(_ text: String) {
        guard let inputCoordinator, isEditable else { return }
        if isApplyingMarkedText {
            super.insertText(text)
            return
        }
        if text == "\n" || text == "\r" {
            inputCoordinator.insertNewline()
            return
        }
        if inputCoordinator.composition.isActive {
            dropMarkedText()
            inputCoordinator.commitComposition(text: text)
            return
        }
        inputCoordinator.replace(range: selectedRange, with: text)
    }

    override func deleteBackward() {
        guard let inputCoordinator, isEditable else { return }
        if inputCoordinator.composition.isActive {
            // Backspace edits the provisional text, never committed storage;
            // an emptied composition cancels.
            let marked = (markedTextRange.flatMap { text(in: $0) } ?? "") as NSString
            // An empty string has no composed character to find (it throws).
            let shorter =
                marked.length == 0
                ? ""
                : marked.replacingCharacters(
                    in: marked.rangeOfComposedCharacterSequence(at: marked.length - 1), with: "")
            setMarkedText(shorter, selectedRange: NSRange(location: shorter.utf16.count, length: 0))
            return
        }
        var range = selectedRange
        if range.length == 0 {
            // A block start is structural (PR04a): a join or a reset to a
            // paragraph, else a quiet no-op. Every other caret takes the command
            // path, which refuses the document-end boundary's separator with a notice.
            if inputCoordinator.isBlockStart(range.location) {
                inputCoordinator.deleteBackwardAtBlockStart()
                return
            }
            guard range.location > 0 else { return }
            range = (textStorage.string as NSString).rangeOfComposedCharacterSequence(at: range.location - 1)
        }
        inputCoordinator.replace(range: range, with: "")
    }

    /// Dictation's final result is ordinary input: the command path, or the
    /// commit of a composition its hypothesis started. Never UIKit's own write.
    override func insertDictationResult(_ dictationResult: [UIDictationPhrase]) {
        insertText(dictationResult.map(\.text).joined())
    }

    /// UIKit's own copy would put the attributed slice, placeholder labels
    /// included, on the pasteboard; while typing is enabled copy is plain text,
    /// one line per block. Like cut and paste, nothing while text is marked:
    /// storage offsets do not match the model then.
    override func copy(_ sender: Any?) {
        guard let inputCoordinator else { return super.copy(sender) }
        guard markedTextRange == nil else { return }
        inputCoordinator.copySelection()
    }

    /// UIKit's cut copies and then deletes through the delegate; route it once
    /// as copy plus one range delete instead.
    override func cut(_ sender: Any?) {
        guard let inputCoordinator, isEditable, markedTextRange == nil else { return }
        inputCoordinator.cutSelection()
    }

    /// Plain text only, as one command over the selection (PR06 brings the
    /// lossless rich clipboard).
    override func paste(_ sender: Any?) {
        guard let inputCoordinator, isEditable, markedTextRange == nil else { return }
        inputCoordinator.pasteFromPasteboard()
    }

    override func pasteAndMatchStyle(_ sender: Any?) {
        paste(sender)
    }

    /// Clears UIKit's marked state without committing it: the composition
    /// session decides what (if anything) is written.
    func dropMarkedText() {
        guard markedTextRange != nil else { return }
        applyMarkedText(nil, selectedRange: NSRange(location: 0, length: 0))
    }

    private func applyMarkedText(_ markedText: String?, selectedRange: NSRange) {
        isApplyingMarkedText = true
        super.setMarkedText(markedText, selectedRange: selectedRange)
        isApplyingMarkedText = false
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if ["undo:", "redo:", "toggleBoldface:", "toggleItalics:", "toggleUnderline:"].contains(
            NSStringFromSelector(action))
        {
            return false
        }
        return super.canPerformAction(action, withSender: sender)
    }

    /// Checkbox and code-language controls, the Headings rotor and the layout
    /// delegate that draws block chrome (PR05b).
    private(set) var blockControls: NativeBlockControls!

    override func layoutSubviews() {
        super.layoutSubviews()
        blockControls?.layoutControls()
    }

    init() {
        super.init(frame: .zero, textContainer: nil)
        precondition(textLayoutManager != nil, "The native editor requires TextKit 2")
        blockControls = NativeBlockControls(textView: self)
        textLayoutManager?.delegate = blockControls
        accessibilityCustomRotors = [blockControls.headingRotor]
        // Chrome colours resolve at draw time: light/dark only redraws.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: NativeTextView, _) in
            view.blockControls.invalidateChrome()
        }
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
