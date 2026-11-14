import UIKit

/// Standard TextKit 2 storage and one main scroll owner. This surface never
/// requests a document-height measurement or forces full-document layout.
final class NativeTextView: UITextView {
    weak var inputCoordinator: NativeInputCoordinator?
    /// UIKit's own marked-text application must reach storage directly; the
    /// command path would refuse it as a second writer.
    private(set) var isApplyingMarkedText = false

    /// The collaborative history's UIKit face (PR07b): Edit ▸ Undo/Redo, the
    /// shake gesture, ⌘Z/⇧⌘Z and the keyboard's undo route to
    /// `NativeUndoManager`. Without typing there is none; UIKit-only history
    /// would diverge from Yjs.
    override var undoManager: UndoManager? { inputCoordinator?.history.system }

    @objc(undo:) func nativeUndo(_ sender: Any?) {
        inputCoordinator?.undo()
    }

    @objc(redo:) func nativeRedo(_ sender: Any?) {
        inputCoordinator?.redo()
    }

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
        // Return and Tab (a hardware Tab without the key command below) are
        // structural; while a barrier is in flight every key is held (PR08b).
        // Typing over a CellSelection clears it (PR11c); the text goes into the active cell.
        if !inputCoordinator.composition.isActive { _ = inputCoordinator.tableKey?(.typing) }
        if inputCoordinator.composition.isActive, text != "\n", text != "\r", text != "\t" {
            dropMarkedText()
            inputCoordinator.commitComposition(text: text)
            return
        }
        inputCoordinator.typeKey(text)
    }

    /// Tab and Shift-Tab nest and unnest the block, as in BlockNote, ahead of
    /// UIKit's own Tab (a tab character) and focus movement.
    override var keyCommands: [UIKeyCommand]? {
        guard inputCoordinator != nil, isEditable else { return super.keyCommands }
        var commands = [
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(nativeIndent)),
            UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(nativeOutdent)),
        ]
        // A table cell (PR11a): Escape returns to the document.
        if inputCoordinator?.tableMove != nil {
            commands.append(
                UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(nativeEscape)))
            // Shift-Return: a hard break in the cell (PR11b).
            commands.append(UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(nativeLineBreak)))
            // ⌘Return: Done (PR11c).
            commands.append(UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(nativeDone)))
        }
        // A column (PR12a): Escape returns to the document.
        if inputCoordinator?.tableMove == nil, inputCoordinator?.onExit != nil {
            commands.append(
                UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(nativeEscape)))
        }
        for command in commands { command.wantsPriorityOverSystemBehavior = true }
        return (super.keyCommands ?? []) + commands
    }

    @objc private func nativeIndent() {
        guard isEditable, markedTextRange == nil else { return }
        inputCoordinator?.insertTab()
    }

    @objc private func nativeLineBreak() {
        guard markedTextRange == nil else { return }
        inputCoordinator?.insertLineBreak()
    }

    @objc private func nativeDone() {
        guard markedTextRange == nil else { return }
        _ = inputCoordinator?.tableMove?(.done)
    }

    /// A table cell's hardware arrows (PR11c) go to the table editor first:
    /// Shift-arrows grow a CellSelection past the cell's edge, and an arrow at
    /// the edge moves to the next cell (prosemirror-tables' `arrow` and
    /// `shiftArrow`). Anything it does not take is the text view's.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let handler = inputCoordinator?.tableKey, markedTextRange == nil, presses.count == 1,
            let key = presses.first?.key, key.modifierFlags.subtracting([.shift, .numericPad]).isEmpty
        {
            let direction: NativeInputCoordinator.TableKey.Direction? =
                switch key.keyCode {
                case .keyboardLeftArrow: .left
                case .keyboardRightArrow: .right
                case .keyboardUpArrow: .up
                case .keyboardDownArrow: .down
                default: nil
                }
            if let direction, handler(.arrow(direction, extend: key.modifierFlags.contains(.shift))) {
                handledPresses.formUnion(presses.map(ObjectIdentifier.init))
                return
            }
        }
        super.pressesBegan(presses, with: event)
    }

    /// The cell this text view edits, as VoiceOver's data table reads it (PR11c).
    var tableCellRanges: (row: NSRange, column: NSRange)?

    /// The presses `pressesBegan` took: their end is not the text view's either.
    private var handledPresses: Set<ObjectIdentifier> = []

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let taken = presses.filter { handledPresses.remove(ObjectIdentifier($0)) != nil }
        let rest = presses.subtracting(taken)
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let taken = presses.filter { handledPresses.remove(ObjectIdentifier($0)) != nil }
        let rest = presses.subtracting(taken)
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }

    @objc private func nativeEscape() {
        guard markedTextRange == nil else { return }
        if inputCoordinator?.tableMove?(.exit) == nil { inputCoordinator?.onExit?() }
    }

    @objc private func nativeOutdent() {
        guard isEditable, markedTextRange == nil else { return }
        inputCoordinator?.outdent()
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
        // A CellSelection's Backspace or Delete empties its cells (PR11c).
        if inputCoordinator.tableKey?(.delete) == true { return }
        // A block start is structural (PR04a); held while a barrier is in flight.
        inputCoordinator.deleteKey()
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
        if inputCoordinator.tableKey?(.copy) == true { return }
        inputCoordinator.copySelection()
    }

    /// UIKit's cut copies and then deletes through the delegate; route it once
    /// as copy plus one range delete instead.
    override func cut(_ sender: Any?) {
        guard let inputCoordinator, isEditable, markedTextRange == nil else { return }
        if inputCoordinator.tableKey?(.cut) == true { return }
        inputCoordinator.cutSelection()
    }

    /// One command: Schrift's lossless payload at a caret, else plain text
    /// over the selection (PR06d).
    override func paste(_ sender: Any?) {
        guard let inputCoordinator, isEditable, markedTextRange == nil else { return }
        if inputCoordinator.tableKey?(.paste) == true { return }
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
        switch NSStringFromSelector(action) {
        case "undo:": return inputCoordinator?.canUndo ?? false
        case "redo:": return inputCoordinator?.canRedo ?? false
        case "toggleBoldface:", "toggleItalics:", "toggleUnderline:": return false
        default: break
        }
        return super.canPerformAction(action, withSender: sender)
    }

    /// Checkbox and code-language controls, the Headings rotor and the layout
    /// delegate that draws block chrome (PR05b).
    private(set) var blockControls: NativeBlockControls!

    /// VoiceOver reads the text without a folded toggle's children, which
    /// layout also leaves out (PR06b). With nothing folded, the whole text.
    /// A preview block reads as its label ("Image: alt", "Table, 3 by 4"),
    /// not as an object replacement character (PR06e).
    override var accessibilityValue: String? {
        get {
            var visible = ""
            func append(_ range: NSRange) {
                guard range.length > 0 else { return }
                textStorage.enumerateAttribute(.attachment, in: range) { value, run, _ in
                    if let attachment = value as? NativeBlockAttachment {
                        visible += attachment.content.label
                    } else if let chip = value as? NativeInlineChipAttachment {
                        visible += Array(repeating: chip.content.accessibilityLabel, count: run.length).joined()
                    } else {
                        visible += (textStorage.string as NSString).substring(with: run)
                    }
                }
            }
            var location = 0
            for range in blockControls?.surface?.hiddenRanges ?? [] {
                append(NSRange(location: location, length: range.location - location))
                location = NSMaxRange(range)
            }
            append(NSRange(location: location, length: textStorage.length - location))
            return visible
        }
        set { super.accessibilityValue = newValue }
    }

    /// VoiceOver's actions for the caret's block (PR06d) and any inline page
    /// link chip touched by the caret/selection (PR13c1).
    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            inlineChipAccessibilityActions()
                + (inputCoordinator?.blockAccessibilityActions() ?? [])
                + (super.accessibilityCustomActions ?? [])
        }
        set { super.accessibilityCustomActions = newValue }
    }

    /// Single-tap recognizer that hit-tests TextKit 2's laid-out glyph segment
    /// frames for resolved inline page link chips in both reader and editor modes.
    let chipTapRecognizer = UITapGestureRecognizer()

    /// Hit-tests TextKit 2's laid-out glyph segment frame for a `.nativeInlineObject`
    /// character at `point` (in this text view's coordinates).
    func inlineObjectHit(at point: CGPoint) -> (offset: Int, object: NativeInlineObject, frame: CGRect)? {
        guard let layout = textLayoutManager, let content = layout.textContentManager, textStorage.length > 0 else {
            return nil
        }
        if layout.textViewportLayoutController.viewportRange == nil {
            layout.textViewportLayoutController.layoutViewport()
        }
        let containerPoint = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        guard let fragment = layout.textLayoutFragment(for: containerPoint) else { return nil }
        let fragRange = fragment.rangeInElement
        let startOffset = content.offset(from: content.documentRange.location, to: fragRange.location)
        let endOffset = content.offset(from: content.documentRange.location, to: fragRange.endLocation)
        guard startOffset != NSNotFound, endOffset > startOffset else { return nil }
        let clampedEnd = min(endOffset, textStorage.length)
        guard startOffset < clampedEnd else { return nil }
        guard blockControls?.surface?.isHidden(atUTF16: startOffset) != true else { return nil }

        var hit: (offset: Int, object: NativeInlineObject, frame: CGRect)?
        let searchRange = NSRange(location: startOffset, length: clampedEnd - startOffset)
        textStorage.enumerateAttribute(.nativeInlineObject, in: searchRange) { value, attrRange, stop in
            guard let object = value as? NativeInlineObject else { return }
            for offset in attrRange.location..<NSMaxRange(attrRange) {
                guard let frame = inlineChipSegmentFrame(atUTF16: offset, layout: layout, content: content) else {
                    continue
                }
                let viewFrame = frame.offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
                if viewFrame.contains(point) {
                    hit = (offset, object, viewFrame)
                    stop.pointee = true
                    return
                }
            }
        }
        return hit
    }

    /// Returns the laid-out TextKit 2 glyph segment frame (in this text view's
    /// coordinates) for the inline chip at `offset`.
    func inlineChipFrame(atUTF16 offset: Int) -> CGRect? {
        guard let layout = textLayoutManager, let content = layout.textContentManager else { return nil }
        if layout.textViewportLayoutController.viewportRange == nil {
            layout.textViewportLayoutController.layoutViewport()
        }
        return inlineChipSegmentFrame(atUTF16: offset, layout: layout, content: content)?
            .offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
    }

    private func inlineChipSegmentFrame(
        atUTF16 offset: Int, layout: NSTextLayoutManager, content: NSTextContentManager
    ) -> CGRect? {
        guard offset >= 0, offset < textStorage.length,
            let start = content.location(content.documentRange.location, offsetBy: offset),
            let end = content.location(start, offsetBy: 1),
            let range = NSTextRange(location: start, end: end)
        else { return nil }
        var result: CGRect?
        layout.enumerateTextSegments(in: range, type: .standard, options: .rangeNotRequired) { _, frame, _, _ in
            if !frame.isNull, !frame.isEmpty {
                result = frame
                return false
            }
            return true
        }
        return result
    }

    private func navigableInterlink(at point: CGPoint) -> (uuid: UUID, blockID: String)? {
        guard let hit = inlineObjectHit(at: point),
            case .interlink(let docID, let blockID, _, let disabled, _) = hit.object,
            !disabled,
            let uuid = UUID(uuidString: docID)
        else { return nil }
        return (uuid, blockID ?? "")
    }

    func chipTapShouldBegin(at point: CGPoint) -> Bool {
        guard blockControls?.onOpenDocument != nil,
            !isDragging, !isDecelerating,
            markedTextRange == nil,
            !hasActiveDragOrLongPress,
            navigableInterlink(at: point) != nil
        else { return false }
        return true
    }

    private var hasActiveDragOrLongPress: Bool {
        let localActive = (gestureRecognizers ?? []).contains { recognizer in
            guard recognizer !== chipTapRecognizer else { return false }
            let isDragOrPress = recognizer is UIPanGestureRecognizer || recognizer is UILongPressGestureRecognizer
            return isDragOrPress && (recognizer.state == .began || recognizer.state == .changed)
        }
        if localActive { return true }
        var ancestor = superview
        while let current = ancestor {
            if let scroll = current as? UIScrollView, scroll.isDragging || scroll.isDecelerating {
                return true
            }
            ancestor = current.superview
        }
        return false
    }

    @objc private func handleChipTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        _ = handleChipTap(at: recognizer.location(in: self))
    }

    /// Handles a tap at `point` (in this text view's coordinates), invoking
    /// `blockControls.onOpenDocument` for a resolved interlink chip.
    @discardableResult
    func handleChipTap(at point: CGPoint) -> Bool {
        guard chipTapShouldBegin(at: point),
            let target = navigableInterlink(at: point),
            let onOpenDocument = blockControls?.onOpenDocument
        else { return false }
        onOpenDocument(target.uuid, target.blockID)
        return true
    }

    private func inlineChipAccessibilityActions() -> [UIAccessibilityCustomAction] {
        guard let onOpenDocument = blockControls?.onOpenDocument,
            let target = selectedNavigableInterlink()
        else { return [] }
        let name = blockControls?.labels.openLink ?? NativeEditorLabels().openLink
        return [
            UIAccessibilityCustomAction(name: name) { _ in
                onOpenDocument(target.uuid, target.blockID)
                return true
            }
        ]
    }

    private func selectedNavigableInterlink() -> (uuid: UUID, blockID: String)? {
        let length = textStorage.length
        guard length > 0 else { return nil }
        let range = selectedRange
        guard range.location != NSNotFound else { return nil }

        var candidateOffsets: [Int] = []
        if range.length > 0 {
            let start = max(0, min(range.location, length))
            let end = max(start, min(NSMaxRange(range), length))
            if start < end {
                candidateOffsets.append(contentsOf: start..<end)
            }
        } else {
            let loc = max(0, min(range.location, length))
            if loc < length { candidateOffsets.append(loc) }
            if loc > 0 { candidateOffsets.append(loc - 1) }
        }

        for offset in candidateOffsets {
            guard blockControls?.surface?.isHidden(atUTF16: offset) != true,
                let inline = textStorage.attribute(.nativeInlineObject, at: offset, effectiveRange: nil)
                    as? NativeInlineObject,
                case .interlink(let docID, let blockID, _, let disabled, _) = inline,
                !disabled,
                let uuid = UUID(uuidString: docID)
            else { continue }
            return (uuid, blockID ?? "")
        }
        return nil
    }

    override func layoutSubviews() {
        // Attachment paragraphs are sized for this width before TextKit lays out.
        blockControls?.updateAttachmentWidth()
        super.layoutSubviews()
        blockControls?.layoutControls()
        // After the viewport settled: collaborators' cursors on screen (PR10).
        cursorOverlay.layout(in: self)
        onLayout?()
        onGeometry?()
    }

    /// After every layout pass: scrolling, size changes (PR10b's reading position).
    var onLayout: (() -> Void)?
    /// After every layout pass too: the column editor's layout (PR12c).
    var onGeometry: (() -> Void)?
    /// The text view became first responder: the column editor's active column (PR12c).
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }

    /// Collaborators' cursors (PR10), painted over the text, never touched.
    let cursorOverlay = NativeCursorOverlay()

    init() {
        super.init(frame: .zero, textContainer: nil)
        precondition(textLayoutManager != nil, "The native editor requires TextKit 2")
        blockControls = NativeBlockControls(textView: self)
        textLayoutManager?.delegate = blockControls
        // Folded toggle children are left out of layout (PR06b).
        (textLayoutManager?.textContentManager as? NSTextContentStorage)?.delegate = blockControls
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
        addSubview(cursorOverlay)
        chipTapRecognizer.addTarget(self, action: #selector(handleChipTap(_:)))
        chipTapRecognizer.numberOfTapsRequired = 1
        chipTapRecognizer.cancelsTouchesInView = false
        chipTapRecognizer.delaysTouchesBegan = false
        chipTapRecognizer.delaysTouchesEnded = false
        chipTapRecognizer.delegate = blockControls
        addGestureRecognizer(chipTapRecognizer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
