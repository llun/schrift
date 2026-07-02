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
}

struct BlockTextStyling: Equatable {
    let font: UIFont
    let textColor: UIColor
    /// Code-like blocks disable autocorrection and smart punctuation, which
    /// would otherwise corrupt syntax.
    let isCodeLike: Bool
    /// Multi-line blocks (code, unknown) let Return insert a literal newline.
    let allowsNewlines: Bool
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
            allowsNewlines: false
        )
    case .quote:
        return BlockTextStyling(
            font: .italicSystemFont(ofSize: DocsTypographySpec.body.size),
            textColor: UIColor(DocsColor.textSecondary),
            isCodeLike: false,
            allowsNewlines: false
        )
    case .codeBlock, .unknown:
        return BlockTextStyling(
            font: .monospacedSystemFont(ofSize: DocsTypographySpec.code.size, weight: .regular),
            textColor: UIColor(DocsColor.textPrimary),
            isCodeLike: true,
            allowsNewlines: true
        )
    case .paragraph, .bulletItem, .numberedItem, .checklistItem, .divider:
        return BlockTextStyling(
            font: .systemFont(ofSize: DocsTypographySpec.body.size),
            textColor: UIColor(DocsColor.textPrimary),
            isCodeLike: false,
            allowsNewlines: false
        )
    }
}

final class EditorUITextView: UITextView {
    /// Invoked when backspace is pressed with the caret at the very start and
    /// nothing selected. Returning true swallows the key.
    var onDeleteAtStart: (@MainActor () -> Bool)?

    override func deleteBackward() {
        if selectedRange == NSRange(location: 0, length: 0), onDeleteAtStart?() == true {
            return
        }
        super.deleteBackward()
    }
}

/// A growing, per-block text view with the hooks a block editor needs:
/// Return interception (split), backspace-at-start (merge), selection
/// reporting, and model-driven focus and caret placement.
struct BlockTextView: UIViewRepresentable {
    @Binding var text: String
    let styling: BlockTextStyling
    let isFocused: Bool
    let cursorRequest: EditorViewModel.CursorRequest?
    var onEvent: (BlockTextEvent) -> Void
    var onCursorRequestHandled: (UUID) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> EditorUITextView {
        let view = EditorUITextView()
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
        applyStyling(to: view)
        view.text = text
        return view
    }

    func updateUIView(_ uiView: EditorUITextView, context: Context) {
        context.coordinator.parent = self

        if uiView.text != text {
            context.coordinator.isApplyingModelChange = true
            uiView.text = text
            context.coordinator.isApplyingModelChange = false
            uiView.invalidateIntrinsicContentSize()
        }
        if context.coordinator.appliedStyling != styling {
            applyStyling(to: uiView)
            context.coordinator.appliedStyling = styling
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
        uiView.selectedRange = NSRange(location: offset, length: length)
        coordinator.isApplyingModelChange = false
        // Clearing the consumed request mutates observed state, so it must
        // happen outside the current view update.
        Task { @MainActor in
            onCursorRequestHandled(request.token)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: BlockTextView
        var appliedStyling: BlockTextStyling?
        var consumedCursorToken: UUID?
        var isApplyingModelChange = false

        init(_ parent: BlockTextView) {
            self.parent = parent
            self.appliedStyling = parent.styling
        }

        func handleDeleteAtStart() -> Bool {
            parent.onEvent(.deleteAtStart)
            return true
        }

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
                textView.invalidateIntrinsicContentSize()
                parent.onEvent(.textChanged(updated))
                return false
            }

            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingModelChange else { return }
            textView.invalidateIntrinsicContentSize()
            parent.onEvent(.textChanged(textView.text ?? ""))
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingModelChange else { return }
            parent.onEvent(.selectionChanged(textView.selectedRange))
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
