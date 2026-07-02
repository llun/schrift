import SwiftUI
import UIKit

/// The markdown-source editing surface: one scrollable monospace text view
/// over the whole document. Smart punctuation is disabled so quotes and
/// dashes don't corrupt markdown syntax.
struct MarkdownSourceView: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        SourceTextView(
            text: Binding(
                get: { viewModel.rawMarkdown },
                set: { viewModel.updateRawMarkdown($0) }
            ),
            selection: Binding(
                get: { viewModel.selection },
                set: { viewModel.selection = $0 }
            )
        )
        .padding(.horizontal, DocsSpacing.spaceXS)
    }
}

private struct SourceTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = .monospacedSystemFont(ofSize: DocsTypographySpec.code.size, weight: .regular)
        view.textColor = UIColor(DocsColor.textPrimary)
        view.backgroundColor = .clear
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.text = text
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        if uiView.text != text {
            context.coordinator.isApplyingModelChange = true
            uiView.text = text
            context.coordinator.isApplyingModelChange = false
        }
        if let selection, uiView.selectedRange != selection {
            let length = ((uiView.text ?? "") as NSString).length
            if selection.location + selection.length <= length {
                uiView.selectedRange = selection
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SourceTextView
        var isApplyingModelChange = false

        init(_ parent: SourceTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingModelChange else { return }
            parent.text = textView.text ?? ""
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingModelChange else { return }
            parent.selection = textView.selectedRange
        }
    }
}
