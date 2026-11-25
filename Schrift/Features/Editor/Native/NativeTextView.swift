import UIKit

/// Standard TextKit 2 storage and one main scroll owner. This surface never
/// requests a document-height measurement or forces full-document layout.
final class NativeTextView: UITextView {
    weak var inputCoordinator: NativeInputCoordinator?
    private(set) var mediaDropController: NativeMediaDropController!
    private(set) var blockDragController: NativeBlockDragController!
    /// UIKit's own marked-text application must reach storage directly; the
    /// command path would refuse it as a second writer.
    private(set) var isApplyingMarkedText = false

    override var isEditable: Bool {
        didSet {
            if isEditable != oldValue {
                blockDragController?.editingModeDidChange()
            }
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            blockDragController?.tearDown()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            blockDragController?.didMoveToWindow()
            onDidMoveToWindow?()
        }
    }

    /// Clamp hit-tests past the last visible block's text to the end of that
    /// block's text range (skipping trailing synthetic `"\n"` and hidden blocks).
    override func closestPosition(to point: CGPoint) -> UITextPosition? {
        guard let position = super.closestPosition(to: point) else { return nil }
        return clampedClosestPosition(for: position)
    }

    func clampedClosestPosition(for position: UITextPosition) -> UITextPosition {
        guard textStorage.length > 0, markedTextRange == nil,
            let surface = blockControls?.surface,
            surface.rangeIndex.length == textStorage.length,
            let lastVisible = surface.rangeIndex.entries.indices.reversed().first(where: {
                !surface.isHidden(position: $0)
            })
        else { return position }
        let visibleEnd = NSMaxRange(surface.rangeIndex.entries[lastVisible].textRange)
        guard offset(from: beginningOfDocument, to: position) > visibleEnd else { return position }
        return self.position(from: beginningOfDocument, offset: visibleEnd) ?? position
    }

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
    /// UIKit's own Tab (a tab character) and focus movement. Active inline pickers
    /// claim Escape, Up, Down, and Return ahead of slash, table, and exit commands.
    override var keyCommands: [UIKeyCommand]? {
        guard inputCoordinator != nil, isEditable else { return super.keyCommands }
        var commands: [UIKeyCommand] = []
        var registeredEscape = false
        if inputCoordinator?.claimsInlinePickerKey(.escape) == true
            || inputCoordinator?.inlinePickerSource != nil
        {
            commands.append(
                UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(nativeEscape)))
            registeredEscape = true
        }
        if inputCoordinator?.claimsInlinePickerKey(.up) == true {
            commands.append(
                UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(nativePickerUp)))
        }
        if inputCoordinator?.claimsInlinePickerKey(.down) == true {
            commands.append(
                UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(nativePickerDown))
            )
        }
        if inputCoordinator?.hasHighlightedInlinePicker == true {
            commands.append(UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(nativePickerReturn)))
        }
        if inputCoordinator?.sourceKind == nil {
            commands.append(contentsOf: [
                UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(nativeIndent)),
                UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(nativeOutdent)),
            ])
        }
        if inputCoordinator?.canFormat == true {
            commands.append(contentsOf: [
                UIKeyCommand(input: "b", modifierFlags: .command, action: #selector(nativeBold)),
                UIKeyCommand(input: "i", modifierFlags: .command, action: #selector(nativeItalic)),
                UIKeyCommand(input: "u", modifierFlags: .command, action: #selector(nativeUnderline)),
                UIKeyCommand(input: "x", modifierFlags: [.command, .shift], action: #selector(nativeStrikethrough)),
                UIKeyCommand(input: "e", modifierFlags: .command, action: #selector(nativeInlineCode)),
                UIKeyCommand(input: "k", modifierFlags: .command, action: #selector(nativeLink)),
            ])
        }
        // A table cell (PR11a): Escape returns to the document.
        if inputCoordinator?.tableMove != nil {
            if !registeredEscape {
                commands.append(
                    UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(nativeEscape)))
                registeredEscape = true
            }
            // Shift-Return: a hard break in the cell (PR11b).
            commands.append(UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(nativeLineBreak)))
            // ⌘Return: Done (PR11c).
            commands.append(UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(nativeDone)))
        }
        // A column (PR12a) or focused source editor (PR14): Escape returns.
        if inputCoordinator?.tableMove == nil, inputCoordinator?.onExit != nil, !registeredEscape {
            commands.append(
                UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(nativeEscape)))
        }
        // Focused source editor (PR14) or root Editing mode (G04): ⌘Return closes as Done.
        if inputCoordinator?.tableMove == nil, isEditable, inputCoordinator?.onDone != nil {
            commands.append(UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(nativeDone)))
        }
        // ⌘⇧V: Paste and Match Style (literal plain text, skipping HTML/Markdown/internal payloads).
        commands.append(
            UIKeyCommand(
                title: blockControls?.labels.pasteAndMatchStyle ?? NativeEditorLabels().pasteAndMatchStyle,
                action: #selector(pasteAndMatchStyle(_:)),
                input: "v",
                modifierFlags: [.command, .shift]))
        for command in commands { command.wantsPriorityOverSystemBehavior = true }
        return (super.keyCommands ?? []) + commands
    }

    @objc private func nativePickerUp() {
        guard markedTextRange == nil else { return }
        _ = inputCoordinator?.handleInlinePickerKey(.up)
    }

    @objc private func nativePickerDown() {
        guard markedTextRange == nil else { return }
        _ = inputCoordinator?.handleInlinePickerKey(.down)
    }

    @objc private func nativePickerReturn() {
        guard markedTextRange == nil else { return }
        if inputCoordinator?.commitHighlightedInlinePicker() == true { return }
        inputCoordinator?.typeKey("\n")
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
        if inputCoordinator?.tableMove?(.done) == nil { inputCoordinator?.onDone?() }
    }

    @objc private func nativeBold() {
        guard markedTextRange == nil else { return }
        inputCoordinator?.toggleMark("bold")
    }

    @objc private func nativeItalic() {
        guard markedTextRange == nil else { return }
        inputCoordinator?.toggleMark("italic")
    }

    @objc private func nativeUnderline() {
        guard markedTextRange == nil else { return }
        inputCoordinator?.toggleMark("underline")
    }

    @objc private func nativeStrikethrough() {
        guard markedTextRange == nil else { return }
        inputCoordinator?.toggleMark("strike")
    }

    @objc private func nativeInlineCode() {
        guard markedTextRange == nil else { return }
        inputCoordinator?.toggleMark("code")
    }

    @objc private func nativeLink() {
        guard markedTextRange == nil, let inputCoordinator, let target = inputCoordinator.linkTarget() else { return }
        inputCoordinator.onRequestLinkEdit?(target)
    }

    @objc override func toggleBoldface(_ sender: Any?) { nativeBold() }
    @objc override func toggleItalics(_ sender: Any?) { nativeItalic() }
    @objc override func toggleUnderline(_ sender: Any?) { nativeUnderline() }

    /// Active inline pickers claim Escape, Up, Down, and Return ahead of table
    /// cell navigation; a table cell's hardware arrows (PR11c) go to the table
    /// editor next, and anything neither takes is the text view's.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let inputCoordinator, markedTextRange == nil, presses.count == 1,
            let key = presses.first?.key, key.modifierFlags.subtracting([.numericPad]).isEmpty
        {
            switch key.keyCode {
            case .keyboardEscape where inputCoordinator.claimsInlinePickerKey(.escape):
                _ = inputCoordinator.handleInlinePickerKey(.escape)
                handledPresses.formUnion(presses.map(ObjectIdentifier.init))
                return
            case .keyboardUpArrow where inputCoordinator.claimsInlinePickerKey(.up):
                _ = inputCoordinator.handleInlinePickerKey(.up)
                handledPresses.formUnion(presses.map(ObjectIdentifier.init))
                return
            case .keyboardDownArrow where inputCoordinator.claimsInlinePickerKey(.down):
                _ = inputCoordinator.handleInlinePickerKey(.down)
                handledPresses.formUnion(presses.map(ObjectIdentifier.init))
                return
            case .keyboardReturnOrEnter, .keyboardReturn:
                if inputCoordinator.hasHighlightedInlinePicker, inputCoordinator.commitHighlightedInlinePicker() {
                    handledPresses.formUnion(presses.map(ObjectIdentifier.init))
                    return
                }
            default:
                break
            }
        }
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
        if inputCoordinator?.handleInlinePickerKey(.escape) == true { return }
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

    /// One command: media/files, Schrift's lossless payloads, same-origin
    /// interlink, parsed HTML/Markdown blocks, or literal plain text.
    override func paste(_ sender: Any?) {
        guard let inputCoordinator, isEditable, markedTextRange == nil else { return }
        if inputCoordinator.tableKey?(.paste) == true { return }
        inputCoordinator.pasteFromPasteboard()
    }

    /// Literal plain-text paste (Paste and Match Style / ⌘⇧V), bypassing HTML,
    /// Markdown, media and internal Schrift payloads.
    override func pasteAndMatchStyle(_ sender: Any?) {
        guard let inputCoordinator, isEditable, markedTextRange == nil else { return }
        if inputCoordinator.tableKey?(.pastePlain) == true { return }
        inputCoordinator.pastePlainTextFromPasteboard()
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
        case "nativeEscape":
            let allowed =
                markedTextRange == nil
                && (inputCoordinator?.claimsInlinePickerKey(.escape) == true
                    || inputCoordinator?.tableMove != nil
                    || inputCoordinator?.onExit != nil)
            return allowed
        case "toggleBoldface:", "toggleItalics:", "toggleUnderline:",
            "nativeBold", "nativeItalic", "nativeUnderline", "nativeStrikethrough", "nativeInlineCode":
            return markedTextRange == nil && (inputCoordinator?.canFormat ?? false)
        case "nativeLink":
            return markedTextRange == nil
                && inputCoordinator?.onRequestLinkEdit != nil
                && inputCoordinator?.linkTarget() != nil
        case "paste:":
            return inputCoordinator?.canPasteFromPasteboard() ?? false
        case "pasteAndMatchStyle:":
            return inputCoordinator?.canPastePlainTextFromPasteboard() ?? false
        default: break
        }
        return super.canPerformAction(action, withSender: sender)
    }

    /// Checkbox and code-language controls, the Headings rotor and the layout
    /// delegate that draws block chrome (PR05b).
    private(set) var blockControls: NativeBlockControls!

    static let maxAccessibilityValueUTF16 = 10_000

    /// VoiceOver reads the text without a folded toggle's children, which
    /// layout also leaves out (PR06b). With nothing folded, the whole text.
    /// A preview block reads as its label ("Image: alt", "Table, 3 by 4"),
    /// not as an object replacement character (PR06e), bounded to avoid
    /// multi-megabyte main-thread copies (PR14).
    override var accessibilityValue: String? {
        get {
            var visible = ""
            var count = 0
            var truncated = false
            func appendText(_ chunk: String) -> Bool {
                let remaining = Self.maxAccessibilityValueUTF16 - count
                guard remaining > 0 else {
                    truncated = true
                    return false
                }
                if chunk.utf16.count <= remaining {
                    visible += chunk
                    count += chunk.utf16.count
                    return true
                }
                for character in chunk {
                    let units = character.utf16.count
                    if count + units > Self.maxAccessibilityValueUTF16 { break }
                    visible.append(character)
                    count += units
                }
                truncated = true
                return false
            }
            func append(_ range: NSRange) {
                guard range.length > 0, !truncated else { return }
                textStorage.enumerateAttribute(.attachment, in: range) { value, run, stop in
                    let chunk: String
                    if let attachment = value as? NativeBlockAttachment {
                        chunk = attachment.content.label
                    } else if let chip = value as? NativeInlineChipAttachment {
                        let unit = chip.content.accessibilityLabel
                        let repeatCount = min(
                            run.length, max(1, (Self.maxAccessibilityValueUTF16 - count) / max(1, unit.utf16.count) + 1)
                        )
                        chunk = Array(repeating: unit, count: repeatCount).joined()
                    } else {
                        let sliceLength = min(run.length, Self.maxAccessibilityValueUTF16 - count + 1)
                        let subrange = (textStorage.string as NSString).rangeOfComposedCharacterSequences(
                            for: NSRange(location: run.location, length: min(run.length, sliceLength)))
                        chunk = (textStorage.string as NSString).substring(with: subrange)
                    }
                    if !appendText(chunk) {
                        stop.pointee = true
                    }
                }
            }
            var location = 0
            for range in blockControls?.surface?.hiddenRanges ?? [] {
                append(NSRange(location: location, length: range.location - location))
                location = NSMaxRange(range)
                if truncated { break }
            }
            append(NSRange(location: location, length: textStorage.length - location))
            if truncated { visible += "…" }
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
    /// Tap-to-edit recognizers when the document is opened in Reading mode (G04).
    let editTapRecognizer = UITapGestureRecognizer()
    let editDoubleTapRecognizer = UITapGestureRecognizer()
    var onRequestEdit: (() -> Void)?
    var onDidMoveToWindow: (() -> Void)?
    weak var headerAccessoryView: UIView?
    weak var footerAccessoryView: UIView?
    private var lastEditTapDate: TimeInterval = 0

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

    private func tappableInlineMath(at point: CGPoint) -> (blockID: String, offsetInBlock: Int)? {
        guard let hit = inlineObjectHit(at: point), case .math = hit.object else { return nil }
        return blockPosition(atUTF16: hit.offset)
    }

    private func blockPosition(atUTF16 utf16Offset: Int) -> (blockID: String, offsetInBlock: Int)? {
        if let surface = blockControls?.surface,
            let pos = surface.rangeIndex.textPosition(atUTF16: utf16Offset),
            surface.blocks.indices.contains(pos.position)
        {
            return (surface.blocks[pos.position].id, pos.offset)
        }
        guard utf16Offset >= 0, utf16Offset < textStorage.length,
            let blockID = textStorage.attribute(.nativeBlockID, at: utf16Offset, effectiveRange: nil) as? String
        else { return nil }
        var blockStart = utf16Offset
        while blockStart > 0,
            (textStorage.attribute(.nativeBlockID, at: blockStart - 1, effectiveRange: nil) as? String) == blockID
        {
            blockStart -= 1
        }
        return (blockID, utf16Offset - blockStart)
    }

    func chipTapShouldBegin(at point: CGPoint) -> Bool {
        guard !isDragging, !isDecelerating,
            markedTextRange == nil,
            !hasActiveDragOrLongPress
        else { return false }
        if blockControls?.onOpenDocument != nil, navigableInterlink(at: point) != nil {
            return true
        }
        if blockControls?.onOpenSource != nil, tappableInlineMath(at: point) != nil {
            return true
        }
        return false
    }

    private var hasActiveDragOrLongPress: Bool {
        if blockDragController?.isDragging == true { return true }
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

    func editTapShouldBegin(at point: CGPoint) -> Bool {
        guard !isEditable else { return false }
        return canTriggerEditTap(at: point)
    }

    func editDoubleTapShouldBegin(at point: CGPoint) -> Bool {
        let withinTransition = Date.timeIntervalSinceReferenceDate - lastEditTapDate < 0.75
        guard !isEditable || withinTransition else { return false }
        return canTriggerEditTap(at: point)
    }

    private func canTriggerEditTap(at point: CGPoint) -> Bool {
        guard inputCoordinator != nil, onRequestEdit != nil,
            !isDragging, !isDecelerating,
            markedTextRange == nil,
            !hasActiveDragOrLongPress
        else { return false }
        if let headerAccessoryView, !headerAccessoryView.isHidden, headerAccessoryView.frame.contains(point) {
            return false
        }
        if let footerAccessoryView, !footerAccessoryView.isHidden, footerAccessoryView.frame.contains(point) {
            return false
        }
        if let hitView = hitTest(point, with: nil) {
            var current: UIView? = hitView
            while let view = current {
                if view === headerAccessoryView || view === footerAccessoryView || view is UIControl
                    || view is NativeAttachmentView
                {
                    return false
                }
                if view === self { break }
                current = view.superview
            }
        }
        if chipTapShouldBegin(at: point) || linkHit(at: point) {
            return false
        }
        return true
    }

    private func linkHit(at point: CGPoint) -> Bool {
        guard let layout = textLayoutManager, let content = layout.textContentManager, textStorage.length > 0 else {
            return false
        }
        if layout.textViewportLayoutController.viewportRange == nil {
            layout.textViewportLayoutController.layoutViewport()
        }
        let containerPoint = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        guard let fragment = layout.textLayoutFragment(for: containerPoint) else { return false }
        let fragRange = fragment.rangeInElement
        let startOffset = content.offset(from: content.documentRange.location, to: fragRange.location)
        let endOffset = content.offset(from: content.documentRange.location, to: fragRange.endLocation)
        guard startOffset != NSNotFound, endOffset > startOffset else { return false }
        let clampedEnd = min(endOffset, textStorage.length)
        guard startOffset < clampedEnd else { return false }
        guard blockControls?.surface?.isHidden(atUTF16: startOffset) != true else { return false }
        var hit = false
        let searchRange = NSRange(location: startOffset, length: clampedEnd - startOffset)
        textStorage.enumerateAttribute(.link, in: searchRange) { value, attrRange, stop in
            guard value != nil,
                let start = content.location(content.documentRange.location, offsetBy: attrRange.location),
                let end = content.location(start, offsetBy: attrRange.length),
                let range = NSTextRange(location: start, end: end)
            else { return }
            layout.enumerateTextSegments(in: range, type: .standard, options: .rangeNotRequired) { _, frame, _, _ in
                let viewFrame = frame.offsetBy(dx: self.textContainerInset.left, dy: self.textContainerInset.top)
                if !frame.isNull, !frame.isEmpty, viewFrame.contains(point) {
                    hit = true
                    return false
                }
                return true
            }
            if hit { stop.pointee = true }
        }
        return hit
    }

    @objc private func handleEditTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let point = recognizer.location(in: self)
        guard editTapShouldBegin(at: point) else { return }
        lastEditTapDate = Date.timeIntervalSinceReferenceDate
        let pos = closestPosition(to: point)
        onRequestEdit?()
        guard isEditable else { return }
        if !isFirstResponder {
            _ = becomeFirstResponder()
        }
        if let pos {
            selectedTextRange = textRange(from: pos, to: pos)
        }
    }

    @objc private func handleEditDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let point = recognizer.location(in: self)
        guard editDoubleTapShouldBegin(at: point) else { return }
        if !isEditable {
            onRequestEdit?()
        }
        guard isEditable else { return }
        if !isFirstResponder {
            _ = becomeFirstResponder()
        }
        if selectedRange.length == 0 {
            selectWordForDoubleTap(at: point)
        }
    }

    func selectWordForDoubleTap(at point: CGPoint) {
        guard let pos = closestPosition(to: point) else { return }
        let wordRange =
            tokenizer.rangeEnclosingPosition(
                pos, with: .word, inDirection: UITextDirection.storage(.backward))
            ?? tokenizer.rangeEnclosingPosition(
                pos, with: .word, inDirection: UITextDirection.storage(.forward))
        if let wordRange, !touchesHiddenContent(wordRange) {
            selectedTextRange = wordRange
        } else {
            selectedTextRange = textRange(from: pos, to: pos)
        }
    }

    private func touchesHiddenContent(_ range: UITextRange) -> Bool {
        guard let surface = blockControls?.surface else { return false }
        let start = offset(from: beginningOfDocument, to: range.start)
        let end = offset(from: beginningOfDocument, to: range.end)
        guard start >= 0, end > start else { return false }
        return surface.isHidden(atUTF16: start) || surface.isHidden(atUTF16: end - 1)
    }

    /// Handles a tap at `point` (in this text view's coordinates), invoking
    /// `blockControls.onOpenDocument` for a resolved interlink chip or
    /// `blockControls.onOpenSource` for an inline `.math` chip.
    @discardableResult
    func handleChipTap(at point: CGPoint) -> Bool {
        guard chipTapShouldBegin(at: point) else { return false }
        if let target = navigableInterlink(at: point), let onOpenDocument = blockControls?.onOpenDocument {
            onOpenDocument(target.uuid, target.blockID)
            return true
        }
        if let target = tappableInlineMath(at: point), let onOpenSource = blockControls?.onOpenSource {
            onOpenSource(.inlineMath(blockID: target.blockID, utf16Offset: target.offsetInBlock))
            return true
        }
        return false
    }

    private func inlineChipAccessibilityActions() -> [UIAccessibilityCustomAction] {
        var actions: [UIAccessibilityCustomAction] = []
        if let onOpenDocument = blockControls?.onOpenDocument, let target = selectedNavigableInterlink() {
            let name = blockControls?.labels.openLink ?? NativeEditorLabels().openLink
            actions.append(
                UIAccessibilityCustomAction(name: name) { _ in
                    onOpenDocument(target.uuid, target.blockID)
                    return true
                })
        }
        if let onOpenSource = blockControls?.onOpenSource, let target = selectedInlineMath() {
            let name = blockControls?.labels.openMathSource ?? NativeEditorLabels().openMathSource
            actions.append(
                UIAccessibilityCustomAction(name: name) { _ in
                    onOpenSource(.inlineMath(blockID: target.blockID, utf16Offset: target.offsetInBlock))
                    return true
                })
        }
        return actions
    }

    private func candidateInlineChipOffsets() -> [Int] {
        let length = textStorage.length
        guard length > 0 else { return [] }
        let range = selectedRange
        guard range.location != NSNotFound else { return [] }
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
        return candidateOffsets
    }

    private func selectedNavigableInterlink() -> (uuid: UUID, blockID: String)? {
        for offset in candidateInlineChipOffsets() {
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

    private func selectedInlineMath() -> (blockID: String, offsetInBlock: Int)? {
        for offset in candidateInlineChipOffsets() {
            guard blockControls?.surface?.isHidden(atUTF16: offset) != true,
                let inline = textStorage.attribute(.nativeInlineObject, at: offset, effectiveRange: nil)
                    as? NativeInlineObject,
                case .math = inline,
                let target = blockPosition(atUTF16: offset)
            else { continue }
            return target
        }
        return nil
    }

    /// UIKit's caret reveal (typing, a selection change) treats all of
    /// `adjustedContentInset` as covered, but the document header and the
    /// subpages footer sit in `contentInset` and scroll with the text. On a
    /// short page the text between them looked a few lines tall, so each
    /// keystroke scrolled to fit the caret, then the taller selection rect,
    /// and back again. Only the safe-area part of the inset covers the text.
    override func scrollRectToVisible(_ rect: CGRect, animated: Bool) {
        guard isScrollEnabled, contentInset.top != 0 || contentInset.bottom != 0 else {
            return super.scrollRectToVisible(rect, animated: animated)
        }
        guard let y = Self.revealOffset(for: rect, in: self) else { return }
        setContentOffset(CGPoint(x: contentOffset.x, y: y), animated: animated)
    }

    /// The smallest scroll that shows `rect` between the safe areas (its top
    /// when it is taller than that), clamped to the content; nil when none.
    private static func revealOffset(for rect: CGRect, in view: UIScrollView) -> CGFloat? {
        let safeTop = view.adjustedContentInset.top - view.contentInset.top
        let safeBottom = view.adjustedContentInset.bottom - view.contentInset.bottom
        let current = view.contentOffset.y
        var y = current
        if rect.maxY > y + view.bounds.height - safeBottom { y = rect.maxY - view.bounds.height + safeBottom }
        if rect.minY < y + safeTop { y = rect.minY - safeTop }
        let minY = -view.adjustedContentInset.top
        let maxY = max(minY, view.contentSize.height + view.adjustedContentInset.bottom - view.bounds.height)
        y = min(max(y, minY), maxY)
        return abs(y - current) > 0.5 ? y : nil
    }

    override func layoutSubviews() {
        // Attachment paragraphs are sized for this width before TextKit lays out.
        blockControls?.updateAttachmentWidth()
        let anchor = blockControls?.prepareAspectRatioRefresh()
        super.layoutSubviews()
        blockControls?.completeAspectRatioRefresh(anchor)
        blockControls?.layoutControls()
        blockDragController?.textViewDidLayout()
        // After the viewport settled: collaborators' cursors on screen (PR10).
        cursorOverlay.layout(in: self)
        chipAccessibilityOverlay.frame = bounds
        orderAuxiliarySubviews()
        blockDragController?.bringChromeToFront(in: self)
        mediaDropController?.bringIndicatorsToFront(in: self)
        if !hasReportedFirstVisibleContent {
            if !NativeEditorDiagnosticsStore.shared.isCollecting {
                hasReportedFirstVisibleContent = true
            } else if hasVisibleRenderedContent {
                hasReportedFirstVisibleContent = true
                onFirstVisibleContent?()
            }
        }
        onLayout?()
        onGeometry?()
    }

    private var hasVisibleRenderedContent: Bool {
        guard bounds.width > 0, bounds.height > 0, let layout = textLayoutManager else { return false }
        if textStorage.length == 0 { return true }
        var hasFragment = false
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: []) { _ in
            hasFragment = true
            return false
        }
        return hasFragment
    }

    /// Orders auxiliary subviews top-to-bottom so VoiceOver traverses header,
    /// visible block controls / attachments, footer, and collaborator overlay
    /// deterministically without altering TextKit's own text element or rotors.
    func orderAuxiliarySubviews() {
        var ordered: [UIView] = []
        if let headerAccessoryView, headerAccessoryView.superview === self {
            ordered.append(headerAccessoryView)
        }
        var mid: [UIView] = []
        if let blockControls {
            mid.append(contentsOf: blockControls.orderedControlViews.filter { $0.superview === self })
        }
        for subview in subviews where subview is NativeAttachmentView {
            mid.append(subview)
        }
        mid.sort {
            if abs($0.frame.minY - $1.frame.minY) > 0.5 {
                return $0.frame.minY < $1.frame.minY
            }
            return $0.frame.minX < $1.frame.minX
        }
        if let dragHandle = blockDragController?.handleView, !dragHandle.isHidden, dragHandle.superview === self {
            let rowControlIDs: Set<ObjectIdentifier>
            if let handleBlockID = blockDragController?.handleBlockID {
                var ids = Set((blockControls?.controlViews(for: handleBlockID) ?? []).map(ObjectIdentifier.init))
                for view in mid {
                    if let attachment = view as? NativeAttachmentView, attachment.content.blockID == handleBlockID {
                        ids.insert(ObjectIdentifier(view))
                    }
                }
                rowControlIDs = ids
            } else {
                rowControlIDs = []
            }
            if let lastRowControlIndex = mid.lastIndex(where: { rowControlIDs.contains(ObjectIdentifier($0)) }) {
                mid.insert(dragHandle, at: lastRowControlIndex + 1)
            } else if let nextRowIndex = mid.firstIndex(where: { $0.frame.minY > dragHandle.frame.minY + 0.5 }) {
                mid.insert(dragHandle, at: nextRowIndex)
            } else {
                mid.append(dragHandle)
            }
        }
        ordered.append(contentsOf: mid)
        if let footerAccessoryView, footerAccessoryView.superview === self {
            ordered.append(footerAccessoryView)
        }
        if cursorOverlay.superview === self {
            ordered.append(cursorOverlay)
        }
        if chipAccessibilityOverlay.superview === self {
            ordered.append(chipAccessibilityOverlay)
        }
        reorderIfNeeded(ordered, in: self)

        var nestedByParent: [ObjectIdentifier: [UIView]] = [:]
        for container in subviews
        where container !== headerAccessoryView && container !== footerAccessoryView
            && container !== cursorOverlay && container !== chipAccessibilityOverlay
        {
            collectAttachmentViews(in: container, into: &nestedByParent)
        }
        for views in nestedByParent.values where views.count > 1 {
            guard let parent = views.first?.superview else { continue }
            let sorted = views.sorted {
                if abs($0.frame.minY - $1.frame.minY) > 0.5 {
                    return $0.frame.minY < $1.frame.minY
                }
                return $0.frame.minX < $1.frame.minX
            }
            reorderIfNeeded(sorted, in: parent)
        }
    }

    private func collectAttachmentViews(in root: UIView, into map: inout [ObjectIdentifier: [UIView]]) {
        for child in root.subviews {
            if child is NativeAttachmentView {
                map[ObjectIdentifier(root), default: []].append(child)
            } else {
                collectAttachmentViews(in: child, into: &map)
            }
        }
    }

    private func reorderIfNeeded(_ desired: [UIView], in parent: UIView) {
        guard desired.count > 1 else { return }
        let desiredIDs = Set(desired.map(ObjectIdentifier.init))
        let current = parent.subviews.filter { desiredIDs.contains(ObjectIdentifier($0)) }
        guard current.count == desired.count else { return }
        let alreadyOrdered = zip(current, desired).allSatisfy { $0 === $1 }
        guard !alreadyOrdered else { return }
        for view in desired {
            parent.bringSubviewToFront(view)
        }
    }

    /// After every layout pass: scrolling, size changes (PR10b's reading position).
    var onLayout: (() -> Void)?
    /// After the first layout pass that produces visible rendered content (PR15).
    var onFirstVisibleContent: (() -> Void)?
    private var hasReportedFirstVisibleContent = false
    /// After every layout pass too: the column editor's layout (PR12c).
    var onGeometry: (() -> Void)?
    /// The text view became first responder: the column editor's active column (PR12c).
    var onFocus: (() -> Void)?
    /// The text view became first responder for diagnostics time-to-edit measurement (PR15).
    var onBecameFirstResponder: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            onFocus?()
            onBecameFirstResponder?()
        }
        return became
    }

    /// Collaborators' cursors (PR10), painted over the text, never touched.
    let cursorOverlay = NativeCursorOverlay()
    /// Accessibility overlay exposing visible navigable inline chips without
    /// adding per-chip `UIView` subviews or intercepting touches.
    private let chipAccessibilityOverlay = NativeInlineChipAccessibilityOverlay()

    /// Visible, unfolded navigable interlink chips for VoiceOver and UI tests.
    func visibleNavigableInterlinkChips() -> [(offset: Int, uuid: UUID, label: String, frame: CGRect)] {
        guard blockControls?.onOpenDocument != nil, textStorage.length > 0 else { return [] }
        let visibleBounds = bounds.inset(by: UIEdgeInsets(top: -16, left: -16, bottom: -16, right: -16))
        var chips: [(offset: Int, uuid: UUID, label: String, frame: CGRect)] = []
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(.attachment, in: fullRange) { value, run, _ in
            guard let chip = value as? NativeInlineChipAttachment,
                case .interlink(let docID, _, _, let disabled, _) = chip.content.object,
                !disabled,
                let uuid = UUID(uuidString: docID)
            else { return }
            for offset in run.location..<NSMaxRange(run) {
                guard blockControls?.surface?.isHidden(atUTF16: offset) != true,
                    let frame = inlineChipFrame(atUTF16: offset),
                    !frame.isNull, !frame.isEmpty,
                    frame.intersects(visibleBounds)
                else { continue }
                chips.append((offset, uuid, chip.content.accessibilityLabel, frame))
            }
        }
        return chips
    }

    init() {
        super.init(frame: .zero, textContainer: nil)
        precondition(textLayoutManager != nil, "The native editor requires TextKit 2")
        blockControls = NativeBlockControls(textView: self)
        textLayoutManager?.delegate = blockControls
        // Folded toggle children are left out of layout (PR06b).
        (textLayoutManager?.textContentManager as? NSTextContentStorage)?.delegate = blockControls
        accessibilityCustomRotors = [blockControls.headingRotor]
        // Chrome colours resolve at draw time: light/dark only redraws.
        registerForTraitChanges([
            UITraitUserInterfaceStyle.self,
            UITraitPreferredContentSizeCategory.self,
            UITraitHorizontalSizeClass.self,
        ]) { (view: NativeTextView, _) in
            view.blockControls.invalidateChrome()
            view.blockDragController?.traitEnvironmentDidChange()
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
        chipAccessibilityOverlay.textView = self
        addSubview(chipAccessibilityOverlay)
        chipTapRecognizer.addTarget(self, action: #selector(handleChipTap(_:)))
        chipTapRecognizer.numberOfTapsRequired = 1
        chipTapRecognizer.cancelsTouchesInView = false
        chipTapRecognizer.delaysTouchesBegan = false
        chipTapRecognizer.delaysTouchesEnded = false
        chipTapRecognizer.delegate = blockControls
        addGestureRecognizer(chipTapRecognizer)
        editTapRecognizer.addTarget(self, action: #selector(handleEditTap(_:)))
        editTapRecognizer.numberOfTapsRequired = 1
        editTapRecognizer.cancelsTouchesInView = false
        editTapRecognizer.delaysTouchesBegan = false
        editTapRecognizer.delaysTouchesEnded = false
        editTapRecognizer.delegate = blockControls
        addGestureRecognizer(editTapRecognizer)
        editDoubleTapRecognizer.addTarget(self, action: #selector(handleEditDoubleTap(_:)))
        editDoubleTapRecognizer.numberOfTapsRequired = 2
        editDoubleTapRecognizer.cancelsTouchesInView = false
        editDoubleTapRecognizer.delaysTouchesBegan = false
        editDoubleTapRecognizer.delaysTouchesEnded = false
        editDoubleTapRecognizer.delegate = blockControls
        addGestureRecognizer(editDoubleTapRecognizer)
        mediaDropController = NativeMediaDropController(textView: self)
        addInteraction(UIDropInteraction(delegate: mediaDropController))
        textDropDelegate = mediaDropController
        blockDragController = NativeBlockDragController(textView: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class NativeInlineChipAccessibilityOverlay: UIView {
    weak var textView: NativeTextView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }

    override var accessibilityElements: [Any]? {
        get { buildElements() }
        set {}
    }

    private func buildElements() -> [Any] {
        guard let textView, !textView.isHidden else { return [] }
        return textView.visibleNavigableInterlinkChips().map { chip in
            let frameInOverlay = convert(chip.frame, from: textView)
            let tapPoint = CGPoint(x: chip.frame.midX, y: chip.frame.midY)
            let element = NativeInlineChipAccessibilityElement(accessibilityContainer: self) { [weak textView] in
                textView?.handleChipTap(at: tapPoint) ?? false
            }
            element.isAccessibilityElement = true
            element.accessibilityTraits = .button
            element.accessibilityIdentifier = "nativeEditor.chip.interlink.\(chip.uuid.uuidString.lowercased())"
            element.accessibilityLabel = chip.label
            element.accessibilityFrameInContainerSpace = frameInOverlay
            return element
        }
    }
}

private final class NativeInlineChipAccessibilityElement: UIAccessibilityElement {
    private let activateHandler: () -> Bool

    init(accessibilityContainer: Any, activate: @escaping () -> Bool) {
        self.activateHandler = activate
        super.init(accessibilityContainer: accessibilityContainer)
    }

    override func accessibilityActivate() -> Bool {
        activateHandler()
    }
}
