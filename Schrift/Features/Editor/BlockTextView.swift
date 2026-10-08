import SwiftUI
import UIKit

enum BlockTextEvent {
    case textChanged(String)
    /// Return was pressed in a single-line block; the block should split at the offset.
    case insertNewline(cursorOffset: Int)
    /// Backspace with the caret at offset 0; the block should merge with its predecessor.
    case deleteAtStart
    case selectionChanged(NSRange)
    case beganEditing
    case endedEditing
    /// The reader tapped a link's visible label. The span is in source coordinates.
    case editLink(InlineLinkSpan)
    case removeLink(InlineLinkSpan)
}

struct BlockTextStyling: Equatable {
    let font: UIFont
    var theme: AppTheme = .white
    let textColor: UIColor
    var tintColor: UIColor { UIColor(theme.colors.brandFill) }
    /// A completed to-do's text is struck through, exactly as the reading
    /// surface strikes it (`BlockTextAppearance.isStruckThrough`). Applied over
    /// the whole buffer under the inline marks, so a `~~span~~` inside a checked
    /// item simply lands on an already-struck line.
    let isStruckThrough: Bool
    /// Code-like blocks disable autocorrection and smart punctuation, which
    /// would otherwise corrupt syntax.
    let isCodeLike: Bool
    /// Multi-line blocks (code, unknown) let Return insert a literal newline.
    let allowsNewlines: Bool
    /// Whether `**bold**`, `[a](b)` etc. are styled — and their syntax hidden —
    /// rather than shown verbatim. False exactly where `InlineMarkdown` declines
    /// to parse: a code block's and an `.unknown` block's text is literal, and
    /// styling it would promise formatting the save would not write.
    let rendersInlineMarkdown: Bool
}

/// The editing surface's view of `blockTextAppearance` — the same table the
/// reading surface reads, converted to UIKit types.
///
/// Takes the whole **block**, not just its kind, because `.unknown` is styled
/// from its text: a paragraph that merely spilled across lines is body prose on
/// both surfaces, while a table or an HTML fragment is monospaced in a panel on
/// both. Styling every `.unknown` as code — which this used to do — meant the
/// commonest one changed typeface, size and background the instant the user
/// tapped it.
///
/// `isCodeLike`/`allowsNewlines` deliberately stay keyed to the **kind**: an
/// `.unknown` block's text is still literal and multi-line whatever it looks
/// like, so autocorrect and smart punctuation must stay off and Return must
/// still insert a newline. Only the *appearance* follows the text.
///
/// **Accepted residual, and it is a trade rather than a win.** Because the
/// appearance follows the text, an `.unknown` block can flip between prose and
/// verbatim *while the user types* — `unknownRendersAsProse` is per-line and
/// refuses a line starting with a space, a tab, `|`, `<` or `![`, so indenting
/// the first line of a prose `.unknown` changes its typeface and size and drops
/// a panel around it under the caret. On `main` that could not happen, because
/// the editing surface styled every `.unknown` as code unconditionally — and
/// that is precisely why tapping *any* prose `.unknown` used to reflow it, which
/// is the defect this file exists to fix. The flip is now confined to typing a
/// structural character at the start of a line in a kind that is itself the
/// parser's fallback; the reflow it replaced happened on every tap, on every
/// such block. Neither is free; this one is rarer and it is the one the reading
/// surface has always had.
func blockTextStyling(for block: EditorBlock, dynamicTypeSize: DynamicTypeSize = .large, theme: AppTheme = .white)
    -> BlockTextStyling
{
    let appearance = blockTextAppearance(for: block.kind, text: block.text, theme: theme)
    let isLiteral: Bool
    let allowsNewlines: Bool
    switch block.kind {
    case .codeBlock, .unknown:
        isLiteral = true
        allowsNewlines = true
    case .heading, .paragraph, .bulletItem, .numberedItem, .checklistItem, .quote, .divider, .image, .attachment:
        // `.divider`/`.image`/`.attachment` never host a text view (they render
        // as leaves); grouped here only to keep the switch exhaustive.
        isLiteral = false
        allowsNewlines = false
    }
    return BlockTextStyling(
        font: appearance.uiFont(dynamicTypeSize: dynamicTypeSize),
        theme: theme,
        textColor: appearance.uiColor,
        isStruckThrough: appearance.isStruckThrough,
        isCodeLike: isLiteral,
        allowsNewlines: allowsNewlines,
        rendersInlineMarkdown: rendersInlineMarkdown(block.kind)
    )
}

/// The attributes every character of a block starts from, before its inline
/// marks are laid over them.
///
/// `setAttributes` *replaces* the whole range, so anything a block carries at
/// block level has to be in here — a strikethrough added only to the marked
/// spans would be wiped off the rest of the line on the next keystroke's
/// restyle. The same dictionary seeds `typingAttributes`, so a character typed
/// at the end of a completed to-do is struck through as it is entered rather
/// than a frame later.
func baseTextAttributes(for styling: BlockTextStyling) -> [NSAttributedString.Key: Any] {
    var attributes: [NSAttributedString.Key: Any] = [
        .font: styling.font,
        .foregroundColor: styling.textColor,
    ]
    if styling.isStruckThrough {
        attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
    }
    return attributes
}

/// A `UITextView` whose buffer is the block's raw markdown, drawn as rich text.
///
/// Markdown syntax (`**`, `` ` ``, `[`, `](url)`) is **suppressed to zero width**
/// rather than removed, via TextKit 1 glyph nulling. That single decision is why
/// there is no display↔source offset map anywhere in this editor:
/// `text.length == block.text.length` at all times, so every `NSRange` the view
/// model computes is already a source offset, and the full-overwrite save
/// re-parses exactly the characters this view holds.
///
/// The cost is that the caret can address positions the user cannot see;
/// `snappedSelection` and `caretBeforeBackspace` handle that.
/// `NSLayoutManagerDelegate` predates Swift concurrency and is not
/// `@MainActor`-isolated, but every call reaches us on the main thread during
/// layout of a main-actor view.
final class EditorUITextView: UITextView, @preconcurrency NSLayoutManagerDelegate {
    var onWillCompose: (@MainActor (EditorUITextView, Bool) -> Void)?
    var onDidCompose: (@MainActor (EditorUITextView) -> Void)?
    var hasCompositionHandoff: (@MainActor () -> Bool)?
    private(set) var isChangingWindowAttachment = false

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        onWillCompose?(self, true)
        super.setMarkedText(markedText, selectedRange: selectedRange)
        onDidCompose?(self)
    }

    override func unmarkText() {
        onWillCompose?(self, false)
        super.unmarkText()
        onDidCompose?(self)
    }

    override func insertText(_ text: String) {
        let composing = markedTextRange != nil || hasCompositionHandoff?() == true
        if composing { onWillCompose?(self, false) }
        super.insertText(text)
        if composing { onDidCompose?(self) }
    }

    override func replace(_ range: UITextRange, withText text: String) {
        let composing = markedTextRange != nil || hasCompositionHandoff?() == true
        if composing { onWillCompose?(self, false) }
        super.replace(range, withText: text)
        if composing { onDidCompose?(self) }
    }
    /// Invoked when backspace is pressed with the caret at the very start and
    /// nothing selected. Returning true swallows the key.
    var onDeleteAtStart: (@MainActor () -> Bool)?
    var onPendingDeleteBackward: (@MainActor () -> Bool)?
    /// Invoked for Tab (`false`) and Shift-Tab (`true`) on a hardware keyboard.
    /// Returning true swallows the key; otherwise Tab types a tab character as
    /// it always has, and Shift-Tab does nothing.
    var onTabKey: (@MainActor (Bool) -> Bool)?
    /// Invoked when the user taps a link's visible label. The view is passed
    /// back rather than captured, so the stored closure cannot retain it.
    var onLinkTapped: (@MainActor (EditorUITextView, InlineLinkSpan, CGPoint) -> Void)?
    /// A lazy row can receive its last model update before joining a window.
    var onWindowAttached: (@MainActor (EditorUITextView) -> Void)?

    /// Source ranges drawn at zero width. Read by the glyph-suppression delegate
    /// on every layout pass, so it must be set before glyphs are invalidated.
    fileprivate(set) var hiddenRanges: [NSRange] = []
    fileprivate(set) var linkSpans: [InlineLinkSpan] = []

    /// Builds the view on **TextKit 1**. `UITextView` defaults to TextKit 2 on
    /// iOS 16+, whose layout fragments offer no equivalent of
    /// `NSGlyphProperty.null`; assembling the stack by hand is the supported way
    /// to opt out. A factory rather than an `init()`, which would shadow the
    /// inherited one and silently give some caller a TextKit 2 view.
    static func textKit1() -> EditorUITextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let view = EditorUITextView(frame: .zero, textContainer: container)
        layoutManager.delegate = view

        let recognizer = UITapGestureRecognizer(target: view, action: #selector(handleLinkTap(_:)))
        // The text view's own tap must still place the caret; ours only adds a menu.
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = view
        view.addGestureRecognizer(recognizer)
        return view
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        isChangingWindowAttachment = newWindow !== window
        super.willMove(toWindow: newWindow)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        isChangingWindowAttachment = window == nil
        if window != nil { onWindowAttached?(self) }
    }

    // MARK: - Glyph suppression

    /// Marks the markdown punctuation's glyphs `.null`: not drawn, and zero
    /// advance. The characters keep their indexes in the text storage — that is
    /// the whole trick.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes: UnsafePointer<Int>,
        font: UIFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard !hiddenRanges.isEmpty else { return 0 }
        var updated = [NSLayoutManager.GlyphProperty](repeating: [], count: glyphRange.length)
        var changed = false
        for offset in 0..<glyphRange.length {
            let characterIndex = characterIndexes[offset]
            if hiddenRanges.contains(where: { NSLocationInRange(characterIndex, $0) }) {
                updated[offset] = .null
                changed = true
            } else {
                updated[offset] = properties[offset]
            }
        }
        guard changed else { return 0 }  // 0 = keep the default properties
        layoutManager.setGlyphs(
            glyphs, properties: updated, characterIndexes: characterIndexes,
            font: font, forGlyphRange: glyphRange)
        return glyphRange.length
    }

    /// Repaints the (short) block from its own buffer: base attributes
    /// everywhere, then the marked spans, then the hidden ranges the glyph pass
    /// reads. Attribute-only edits leave the characters alone, so no
    /// `.textChanged` event is produced and the selection survives.
    ///
    /// Skipped while an input method is composing, whose marked-text attributes
    /// must not be overwritten.
    ///
    /// Takes the whole `BlockTextStyling` rather than the two or three fields it
    /// happens to need: a field added to the block's appearance that this forgot
    /// to apply is a silent rendering difference against the reading surface,
    /// which is exactly how the strikethrough on a completed to-do came to exist
    /// on one surface only.
    func applyInlineStyling(_ styling: BlockTextStyling) {
        guard markedTextRange == nil else { return }
        let font = styling.font
        let source = text ?? ""
        let full = NSRange(location: 0, length: (source as NSString).length)
        let layout =
            styling.rendersInlineMarkdown
            ? InlineMarkdown.layout(of: source)
            : InlineLayout(spans: [], syntax: [], links: [])

        // Before `endEditing` triggers a layout pass that reads them.
        hiddenRanges = layout.syntax
        linkSpans = layout.links

        let selection = selectedRange
        textStorage.beginEditing()
        textStorage.setAttributes(baseTextAttributes(for: styling), range: full)
        for span in layout.spans {
            textStorage.addAttributes(
                inlineTextAttributes(for: span.marks, base: font, theme: styling.theme), range: span.range)
        }
        textStorage.endEditing()

        layoutManager.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
        if selectedRange != selection {
            selectedRange = selection
        }
    }

    // MARK: - Caret rules

    override func deleteBackward() {
        if markedTextRange != nil {
            onWillCompose?(self, false)
            super.deleteBackward()
            onDidCompose?(self)
            return
        }
        if markedTextRange == nil, onPendingDeleteBackward?() == true { return }
        // Never delete a character the user cannot see: skipping the hidden run
        // first turns "backspace past a link" into "delete the label's last
        // letter" rather than "delete the closing paren and reveal the URL".
        if selectedRange.length == 0, selectedRange.location > 0 {
            let normalized = caretBeforeBackspace(from: selectedRange.location, hidden: hiddenRanges)
            if normalized != selectedRange.location {
                selectedRange = NSRange(location: normalized, length: 0)
            }
        }
        if selectedRange == NSRange(location: 0, length: 0), onDeleteAtStart?() == true {
            return
        }
        super.deleteBackward()
    }

    // MARK: - Tab and Shift-Tab

    /// Tab and Shift-Tab as key commands, ahead of the system's own handling (a
    /// tab character, or focus navigation on iPad). Not offered while text is
    /// being composed: the input method owns the keyboard until it commits.
    override var keyCommands: [UIKeyCommand]? {
        let inherited = super.keyCommands ?? []
        guard onTabKey != nil, markedTextRange == nil else { return inherited }
        let indent = UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(tabKeyPressed))
        let outdent = UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(shiftTabKeyPressed))
        indent.wantsPriorityOverSystemBehavior = true
        outdent.wantsPriorityOverSystemBehavior = true
        return inherited + [indent, outdent]
    }

    @objc private func tabKeyPressed() {
        if onTabKey?(false) != true {
            insertText("\t")
        }
    }

    @objc private func shiftTabKeyPressed() {
        _ = onTabKey?(true)
    }

    // MARK: - Link tap

    @objc fileprivate func handleLinkTap(_ recognizer: UITapGestureRecognizer) {
        // The first tap on an unfocused block belongs to focusing it.
        guard isFirstResponder else { return }
        let point = recognizer.location(in: self)
        guard let span = linkSpan(at: point) else { return }
        onLinkTapped?(self, span, point)
    }

    /// The link whose *visible label* contains `point`, if any.
    ///
    /// Hit-testing the link's full source range would arm the menu over its
    /// zero-width syntax, which occupies the same pixels as whatever sits next to
    /// it — tapping the space after a link would open the menu. Enumerating the
    /// label's enclosing rects (rather than one bounding box) keeps a label that
    /// wraps across lines from claiming the empty tail of the first line.
    func linkSpan(at point: CGPoint) -> InlineLinkSpan? {
        guard !linkSpans.isEmpty else { return nil }
        let origin = CGPoint(x: textContainerInset.left, y: textContainerInset.top)
        return linkSpans.first { span in
            let glyphRange = layoutManager.glyphRange(forCharacterRange: span.labelRange, actualCharacterRange: nil)
            var hit = false
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: textContainer
            ) { rect, stop in
                if rect.offsetBy(dx: origin.x, dy: origin.y).contains(point) {
                    hit = true
                    stop.pointee = true
                }
            }
            return hit
        }
    }
}

extension EditorUITextView: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

/// A growing, per-block text view with the hooks a block editor needs:
/// Return interception (split), backspace-at-start (merge), selection
/// reporting, model-driven focus and caret placement, and inline markdown
/// rendered as rich text over its own markdown source.
struct BlockTextView: UIViewRepresentable {
    var blockID: UUID? = nil
    var resolveInputTarget: (UUID) -> BlockTextView? = { _ in nil }
    var pendingComposition: (UUID?) -> EditorViewModel.PendingComposition? = { _ in nil }
    var compositionStyling: (EditorBlock) -> BlockTextStyling = { blockTextStyling(for: $0) }
    var onCompositionChange: (UUID, String, NSRange, Bool) -> Void = { _, _, _, _ in }
    /// Resolve at UIKit update time: SwiftUI can cache a Binding's read value
    /// before a newer keyboard delegate event reaches the model.
    var text: () -> String
    let styling: BlockTextStyling
    let isFocused: () -> Bool
    var hasPendingFocusTarget: () -> Bool = { false }
    let cursorRequest: () -> EditorViewModel.CursorRequest?
    var onEvent: (BlockTextEvent) -> Void
    /// Tab (`false`) or Shift-Tab (`true`); returns whether the key was handled.
    var onTabKey: (Bool) -> Bool = { _ in false }
    var onCursorRequestHandled: (UUID) -> Void = { _ in }
    /// Keyboard events may arrive before a structural edit reaches UIKit.
    var onPendingInput: (String, UUID?) -> Bool = { _, _ in false }
    var onPendingSourceReplacement: (NSRange, String, String, UUID?) -> Bool = { _, _, _, _ in false }
    var hasPendingSelection: (UUID?) -> Bool = { _ in false }
    /// Pre-resolved link-menu titles, passed down from the SwiftUI layer (which
    /// owns `LocalizationStore`). The coordinator never sees the store — it just
    /// reads these plain strings when building the `UIEditMenuInteraction` menu.
    var editLinkTitle: String = "Edit link"
    var removeLinkTitle: String = "Remove link"

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> EditorUITextView {
        let view = EditorUITextView.textKit1()
        view.onWillCompose = { [weak coordinator = context.coordinator] view, preparesHandoff in
            coordinator?.willCompose(in: view, preparesHandoff: preparesHandoff)
        }
        view.onDidCompose = { [weak coordinator = context.coordinator] view in
            coordinator?.didCompose(in: view)
        }
        view.hasCompositionHandoff = { [weak coordinator = context.coordinator] in
            coordinator?.compositionBlockID != nil
        }
        view.delegate = context.coordinator
        view.isScrollEnabled = false
        // The document scrolls as a whole. Inner row edge effects can obscure
        // the first text line on iOS 27 even with scrolling disabled.
        view.topEdgeEffect.isHidden = true
        view.bottomEdgeEffect.isHidden = true
        view.leftEdgeEffect.isHidden = true
        view.rightEdgeEffect.isHidden = true
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.onDeleteAtStart = { [weak coordinator = context.coordinator] in
            coordinator?.handleDeleteAtStart() ?? false
        }
        view.onTabKey = { [weak coordinator = context.coordinator] outdent in
            coordinator?.parent.onTabKey(outdent) ?? false
        }
        view.onPendingDeleteBackward = { [weak coordinator = context.coordinator] in
            guard let coordinator else { return false }
            return coordinator.parent.onPendingInput("", coordinator.consumedCursorToken)
        }
        view.onLinkTapped = { [weak coordinator = context.coordinator] view, span, point in
            coordinator?.presentLinkMenu(in: view, for: span, at: point)
        }
        view.onWindowAttached = { [weak coordinator = context.coordinator] view in
            guard let coordinator else { return }
            coordinator.parent.syncFocus(on: view, coordinator: coordinator)
        }
        applyStyling(to: view)
        view.text = text()
        restyleInlineMarkdown(in: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: EditorUITextView, context: Context) {
        let current: BlockTextView
        if let target = context.coordinator.handoffBlockID, target != blockID,
            let resolved = resolveInputTarget(target)
        {
            current = resolved
        } else {
            current = self
            context.coordinator.handoffBlockID = nil
        }
        if context.coordinator.parent.blockID != current.blockID {
            context.coordinator.resetSourceState()
        }
        context.coordinator.parent = current
        current.reconcile(uiView, coordinator: context.coordinator)
    }

    fileprivate func reconcile(_ uiView: EditorUITextView, coordinator: Coordinator) {
        // Observation can reenter before a delegate's model write finishes.
        // Keep text and its cursor token together until that publication ends.
        guard coordinator.textChangeDepth == 0 else { return }
        guard coordinator.nativeCompositionDepth == 0 else { return }
        // UIKit owns the characters, marked attributes, and selection until commit.
        if uiView.markedTextRange != nil {
            // A reused row can attach before its coordinator receives the new
            // identity. Retry current focus without touching UIKit's marked range.
            syncFocus(on: uiView, coordinator: coordinator)
            return
        }

        var needsRestyle = false
        let currentText = text()
        if uiView.text != currentText {
            coordinator.isApplyingModelChange = true
            uiView.text = currentText
            coordinator.isApplyingModelChange = false
            needsRestyle = true
        }
        if coordinator.appliedStyling != styling {
            applyStyling(to: uiView)
            coordinator.appliedStyling = styling
            needsRestyle = true
        }
        if needsRestyle {
            restyleInlineMarkdown(in: uiView, coordinator: coordinator)
            uiView.invalidateIntrinsicContentSize()
        }

        syncFocus(on: uiView, coordinator: coordinator)
        consumeCursorRequest(on: uiView, coordinator: coordinator)
        coordinator.hasUnreconciledSourceReplacement = false
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: EditorUITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: fitted.height)
    }

    private func applyStyling(to view: EditorUITextView, using override: BlockTextStyling? = nil) {
        let styling = override ?? styling
        view.font = styling.font
        view.textColor = styling.textColor
        view.tintColor = styling.tintColor
        view.typingAttributes = baseTextAttributes(for: styling)
        if styling.isCodeLike {
            view.autocorrectionType = .no
            view.autocapitalizationType = .none
            view.smartQuotesType = .no
            view.smartDashesType = .no
            view.smartInsertDeleteType = .no
        } else {
            view.autocorrectionType = .default
            view.autocapitalizationType = .sentences
            view.smartQuotesType = .default
            view.smartDashesType = .default
            view.smartInsertDeleteType = .default
        }
    }

    /// Repaints the block, suppressing the delegate echo of the selection
    /// restore `applyInlineStyling` performs.
    fileprivate func restyleInlineMarkdown(in view: EditorUITextView, coordinator: Coordinator) {
        coordinator.isApplyingModelChange = true
        view.applyInlineStyling(styling)
        coordinator.isApplyingModelChange = false
    }

    /// Applies focus synchronously: deferring into a task can drop updates or
    /// steal focus back after the user has already moved on. Delegate echoes
    /// of programmatic changes are suppressed via `isApplyingModelChange`.
    private func syncFocus(on uiView: EditorUITextView, coordinator: Coordinator) {
        let focused = isFocused()
        if focused, !uiView.isFirstResponder, uiView.window != nil {
            coordinator.isApplyingModelChange = true
            uiView.becomeFirstResponder()
            coordinator.isApplyingModelChange = false
        } else if !focused, uiView.isFirstResponder, !hasPendingFocusTarget() {
            // Another row takes the responder directly once it joins a window.
            // Resigning first creates a gap in which keyboard events disappear.
            coordinator.isApplyingModelChange = true
            uiView.resignFirstResponder()
            coordinator.isApplyingModelChange = false
        }
    }

    private func consumeCursorRequest(on uiView: EditorUITextView, coordinator: Coordinator) {
        guard let request = cursorRequest(), coordinator.consumedCursorToken != request.token else { return }
        coordinator.consumedCursorToken = request.token
        let textLength = ((uiView.text ?? "") as NSString).length
        let offset = min(max(0, request.offset), textLength)
        let length = min(max(0, request.length), textLength - offset)
        coordinator.isApplyingModelChange = true
        // The view model computes source offsets, which may name a hidden
        // character (a caret placed at the end of a block ending in a link).
        uiView.selectedRange = snappedSelection(
            NSRange(location: offset, length: length), hidden: uiView.hiddenRanges)
        coordinator.isApplyingModelChange = false
        // Clearing the consumed request mutates observed state, so it must
        // happen outside the current view update.
        Task { @MainActor in
            onCursorRequestHandled(request.token)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, @preconcurrency UIEditMenuInteractionDelegate {
        var parent: BlockTextView
        var appliedStyling: BlockTextStyling?
        var consumedCursorToken: UUID?
        var isApplyingModelChange = false
        var textChangeDepth = 0
        var hasUnreconciledSourceReplacement = false
        var nativeCompositionDepth = 0
        var compositionBlockID: UUID?
        var handoffBlockID: UUID?
        private var editMenuInteraction: UIEditMenuInteraction?
        private var menuSpan: InlineLinkSpan?

        init(_ parent: BlockTextView) {
            self.parent = parent
            self.appliedStyling = parent.styling
        }

        func resetSourceState() {
            hasUnreconciledSourceReplacement = false
            menuSpan = nil
        }

        func willCompose(in view: EditorUITextView, preparesHandoff: Bool) {
            nativeCompositionDepth += 1
            guard preparesHandoff, nativeCompositionDepth == 1, compositionBlockID == nil, view.markedTextRange == nil,
                let pending = parent.pendingComposition(consumedCursorToken)
            else { return }
            compositionBlockID = pending.block.id
            if let target = parent.resolveInputTarget(pending.block.id) {
                handoffBlockID = pending.block.id
                parent = target
            }
            resetSourceState()
            isApplyingModelChange = true
            view.text = pending.block.text
            let styling = parent.compositionStyling(pending.block)
            parent.applyStyling(to: view, using: styling)
            view.applyInlineStyling(styling)
            appliedStyling = styling
            view.selectedRange = pending.selection
            isApplyingModelChange = false
        }

        func didCompose(in view: EditorUITextView) {
            nativeCompositionDepth -= 1
            guard nativeCompositionDepth == 0 else { return }
            textViewDidChange(view)
            if view.markedTextRange == nil { compositionBlockID = nil }
            textViewDidChangeSelection(view)
            parent.reconcile(view, coordinator: self)
        }

        func handleDeleteAtStart() -> Bool {
            parent.onEvent(.deleteAtStart)
            return true
        }

        // MARK: Link menu

        /// `UIEditMenuInteraction` rather than the iOS 17 `UITextItem` callbacks:
        /// those are not delivered by an *editable* text view, where a tap means
        /// "place the caret".
        func presentLinkMenu(in textView: EditorUITextView, for span: InlineLinkSpan, at point: CGPoint) {
            menuSpan = span
            let interaction: UIEditMenuInteraction
            if let existing = editMenuInteraction {
                interaction = existing
            } else {
                interaction = UIEditMenuInteraction(delegate: self)
                textView.addInteraction(interaction)
                editMenuInteraction = interaction
            }
            interaction.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
        }

        func editMenuInteraction(
            _ interaction: UIEditMenuInteraction,
            menuFor configuration: UIEditMenuConfiguration,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard let span = menuSpan else { return nil }
            // The suggested actions are the text view's own cut/copy/paste, which
            // make no sense for a tap that selected nothing.
            return UIMenu(children: [
                UIAction(
                    title: parent.editLinkTitle, image: MaterialIcon.link.uiImage(pointSize: 17)
                ) { [weak self] _ in
                    self?.parent.onEvent(.editLink(span))
                },
                UIAction(
                    title: parent.removeLinkTitle, image: MaterialIcon.link_off.uiImage(pointSize: 17),
                    attributes: .destructive
                ) { [weak self] _ in
                    self?.parent.onEvent(.removeLink(span))
                },
            ])
        }

        // MARK: UITextViewDelegate

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if nativeCompositionDepth > 0 || compositionBlockID != nil { return true }
            // A correction names a range in the source row; it is not a key
            // typed at the pending destination. Composing input stays in UIKit.
            if textView.markedTextRange == nil, range == textView.selectedRange,
                parent.onPendingInput(text, consumedCursorToken)
            {
                return false
            }
            if textView.markedTextRange == nil, range != textView.selectedRange {
                let sourceText = textView.text ?? ""
                // A handled correction changes the model without changing this
                // old buffer. Even a matching repeated prefix has stale offsets.
                if hasUnreconciledSourceReplacement, sourceText != parent.text() { return false }
                hasUnreconciledSourceReplacement = false
                if parent.onPendingSourceReplacement(range, text, sourceText, consumedCursorToken) {
                    // Set after publication: a reentrant update may still have
                    // read the model before that correction finished writing.
                    hasUnreconciledSourceReplacement = true
                    return false
                }
            }
            guard !parent.styling.allowsNewlines else { return true }
            let current = (textView.text ?? "") as NSString

            if text == "\n" {
                if range.length > 0 {
                    parent.onEvent(.textChanged(current.replacingCharacters(in: range, with: "")))
                }
                parent.onEvent(.insertNewline(cursorOffset: range.location))
                return false
            }

            // Pasted multi-line content collapses to spaces in single-line blocks.
            if text.contains("\n") {
                let sanitized = text.replacingOccurrences(of: "\n", with: " ")
                let updated = current.replacingCharacters(in: range, with: sanitized)
                textView.text = updated
                textView.selectedRange = NSRange(location: range.location + (sanitized as NSString).length, length: 0)
                if let editor = textView as? EditorUITextView {
                    parent.restyleInlineMarkdown(in: editor, coordinator: self)
                }
                textView.invalidateIntrinsicContentSize()
                parent.onEvent(.textChanged(updated))
                return false
            }

            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingModelChange, nativeCompositionDepth == 0 else { return }
            textChangeDepth += 1
            defer {
                textChangeDepth -= 1
                if textChangeDepth == 0, let editor = textView as? EditorUITextView {
                    parent.reconcile(editor, coordinator: self)
                }
            }
            // Attribute edits/layout can reenter UIKit and deliver a queued row
            // update. Publish this captured buffer before that update can read
            // the previous model value and overwrite the latest keystroke.
            if let target = compositionBlockID {
                parent.onCompositionChange(
                    target, textView.text ?? "", textView.selectedRange, textView.markedTextRange != nil)
            } else {
                parent.onEvent(.textChanged(textView.text ?? ""))
            }
            // Only blocks that render inline markdown need a per-keystroke
            // restyle. Code and `.unknown` blocks style nothing and hide nothing,
            // yet they are the only ones that grow unbounded (`allowsNewlines`),
            // and `applyInlineStyling` invalidates glyphs and layout across the
            // *whole* block — which would re-lay-out every line of a long code
            // block on every character. `applyStyling` has already given them
            // their font, color and typing attributes.
            //
            // Converting a block to or from one of those kinds changes `styling`,
            // so `updateUIView` restyles unconditionally and clears the outgoing
            // block's hidden ranges. Skipping here cannot strand them.
            if let editor = textView as? EditorUITextView, parent.styling.rendersInlineMarkdown {
                parent.restyleInlineMarkdown(in: editor, coordinator: self)
            }
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingModelChange, nativeCompositionDepth == 0 else { return }
            if let target = compositionBlockID {
                parent.onCompositionChange(
                    target, textView.text ?? "", textView.selectedRange, textView.markedTextRange != nil)
                return
            }
            guard !parent.hasPendingSelection(consumedCursorToken) else { return }
            guard let editor = textView as? EditorUITextView else { return }
            // Re-entrant by design: assigning `selectedRange` fires this again,
            // and the second pass finds the selection already snapped.
            let snapped = snappedSelection(editor.selectedRange, hidden: editor.hiddenRanges)
            if snapped != editor.selectedRange {
                editor.selectedRange = snapped
                return
            }
            parent.onEvent(.selectionChanged(snapped))
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            guard !isApplyingModelChange else { return }
            parent.onEvent(.beganEditing)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            guard !isApplyingModelChange else { return }
            // A structural row move can end the outgoing native attachment
            // before its pending focus/caret request reaches the reused view.
            if let editor = textView as? EditorUITextView, editor.isChangingWindowAttachment,
                parent.hasPendingFocusTarget()
            {
                return
            }
            parent.onEvent(.endedEditing)
        }
    }
}
