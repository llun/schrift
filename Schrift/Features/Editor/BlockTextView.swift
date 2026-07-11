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
    let textColor: UIColor
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

func blockTextStyling(for kind: BlockKind) -> BlockTextStyling {
    switch kind {
    case .heading(let level):
        let spec: TypographySpec
        switch level {
        case 1: spec = DocsTypographySpec.title1
        case 2: spec = DocsTypographySpec.title2
        default: spec = DocsTypographySpec.headline
        }
        return BlockTextStyling(
            font: .systemFont(ofSize: spec.size, weight: spec.weight == .bold ? .bold : .semibold),
            textColor: UIColor(DocsColor.textPrimary),
            isCodeLike: false,
            allowsNewlines: false,
            rendersInlineMarkdown: rendersInlineMarkdown(kind)
        )
    case .quote:
        return BlockTextStyling(
            font: .italicSystemFont(ofSize: DocsTypographySpec.body.size),
            textColor: UIColor(DocsColor.textSecondary),
            isCodeLike: false,
            allowsNewlines: false,
            rendersInlineMarkdown: rendersInlineMarkdown(kind)
        )
    case .codeBlock, .unknown:
        return BlockTextStyling(
            font: .monospacedSystemFont(ofSize: DocsTypographySpec.code.size, weight: .regular),
            textColor: UIColor(DocsColor.textPrimary),
            isCodeLike: true,
            allowsNewlines: true,
            rendersInlineMarkdown: rendersInlineMarkdown(kind)
        )
    case .paragraph, .bulletItem, .numberedItem, .checklistItem, .divider, .image:
        // `.divider`/`.image` never host a text view (they render as leaves);
        // grouped here only to keep the switch exhaustive with a sane default.
        return BlockTextStyling(
            font: .systemFont(ofSize: DocsTypographySpec.body.size),
            textColor: UIColor(DocsColor.textPrimary),
            isCodeLike: false,
            allowsNewlines: false,
            rendersInlineMarkdown: rendersInlineMarkdown(kind)
        )
    }
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
    /// Invoked when backspace is pressed with the caret at the very start and
    /// nothing selected. Returning true swallows the key.
    var onDeleteAtStart: (@MainActor () -> Bool)?
    /// Invoked when the user taps a link's visible label. The view is passed
    /// back rather than captured, so the stored closure cannot retain it.
    var onLinkTapped: (@MainActor (EditorUITextView, InlineLinkSpan, CGPoint) -> Void)?

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
    func applyInlineStyling(font: UIFont, textColor: UIColor, rendersInlineMarkdown: Bool) {
        guard markedTextRange == nil else { return }
        let source = text ?? ""
        let full = NSRange(location: 0, length: (source as NSString).length)
        let layout =
            rendersInlineMarkdown
            ? InlineMarkdown.layout(of: source)
            : InlineLayout(spans: [], syntax: [], links: [])

        // Before `endEditing` triggers a layout pass that reads them.
        hiddenRanges = layout.syntax
        linkSpans = layout.links

        let selection = selectedRange
        textStorage.beginEditing()
        textStorage.setAttributes([.font: font, .foregroundColor: textColor], range: full)
        for span in layout.spans {
            textStorage.addAttributes(inlineTextAttributes(for: span.marks, base: font), range: span.range)
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
    @Binding var text: String
    let styling: BlockTextStyling
    let isFocused: Bool
    let cursorRequest: EditorViewModel.CursorRequest?
    var onEvent: (BlockTextEvent) -> Void
    var onCursorRequestHandled: (UUID) -> Void = { _ in }
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
        view.delegate = context.coordinator
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.onDeleteAtStart = { [weak coordinator = context.coordinator] in
            coordinator?.handleDeleteAtStart() ?? false
        }
        view.onLinkTapped = { [weak coordinator = context.coordinator] view, span, point in
            coordinator?.presentLinkMenu(in: view, for: span, at: point)
        }
        applyStyling(to: view)
        view.text = text
        restyleInlineMarkdown(in: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: EditorUITextView, context: Context) {
        context.coordinator.parent = self

        var needsRestyle = false
        if uiView.text != text {
            context.coordinator.isApplyingModelChange = true
            uiView.text = text
            context.coordinator.isApplyingModelChange = false
            needsRestyle = true
        }
        if context.coordinator.appliedStyling != styling {
            applyStyling(to: uiView)
            context.coordinator.appliedStyling = styling
            needsRestyle = true
        }
        if needsRestyle {
            restyleInlineMarkdown(in: uiView, coordinator: context.coordinator)
            uiView.invalidateIntrinsicContentSize()
        }

        syncFocus(on: uiView, coordinator: context.coordinator)
        consumeCursorRequest(on: uiView, coordinator: context.coordinator)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: EditorUITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: fitted.height)
    }

    private func applyStyling(to view: EditorUITextView) {
        view.font = styling.font
        view.textColor = styling.textColor
        view.typingAttributes = [.font: styling.font, .foregroundColor: styling.textColor]
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
        view.applyInlineStyling(
            font: styling.font, textColor: styling.textColor, rendersInlineMarkdown: styling.rendersInlineMarkdown)
        coordinator.isApplyingModelChange = false
    }

    /// Applies focus synchronously: deferring into a task can drop updates or
    /// steal focus back after the user has already moved on. Delegate echoes
    /// of programmatic changes are suppressed via `isApplyingModelChange`.
    private func syncFocus(on uiView: EditorUITextView, coordinator: Coordinator) {
        if isFocused, !uiView.isFirstResponder, uiView.window != nil {
            coordinator.isApplyingModelChange = true
            uiView.becomeFirstResponder()
            coordinator.isApplyingModelChange = false
        } else if !isFocused, uiView.isFirstResponder {
            coordinator.isApplyingModelChange = true
            uiView.resignFirstResponder()
            coordinator.isApplyingModelChange = false
        }
    }

    private func consumeCursorRequest(on uiView: EditorUITextView, coordinator: Coordinator) {
        guard let request = cursorRequest, coordinator.consumedCursorToken != request.token else { return }
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
        private var editMenuInteraction: UIEditMenuInteraction?
        private var menuSpan: InlineLinkSpan?

        init(_ parent: BlockTextView) {
            self.parent = parent
            self.appliedStyling = parent.styling
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
            guard !isApplyingModelChange else { return }
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
            parent.onEvent(.textChanged(textView.text ?? ""))
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingModelChange else { return }
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
            parent.onEvent(.endedEditing)
        }
    }
}
