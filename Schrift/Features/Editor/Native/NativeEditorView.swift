import SwiftUI

struct NativeEditorView: View {
    let session: NativeEditorSession
    let title: String
    @Environment(LocalizationStore.self) private var loc
    @Environment(\.docsTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if session.hasUnsupportedRoot {
                ContentUnavailableView(
                    loc[.native_editor_preserved_title], systemImage: "doc.richtext",
                    description: Text(loc[.native_editor_preserved_body]))
            } else if session.surface.blocks.isEmpty {
                ContentUnavailableView(
                    loc[.editor_empty_title], systemImage: "doc.text",
                    description: Text(loc[.editor_empty_body]))
            } else {
                NativeTextCanvas(
                    session: session, contentSize: uiContentSizeCategory(for: dynamicTypeSize),
                    labels: NativeEditorLabels(
                        preservedBlock: loc[.native_editor_preserved_block],
                        unknownBlock: loc[.native_editor_unknown_block])
                )
                .id(ObjectIdentifier(session))
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let key = session.input?.noticeKey {
                Text(loc[key])
                    .font(.footnote)
                    .padding()
                    .accessibilityIdentifier("nativeEditor.inputNotice")
            }
        }
        .background(theme.colors.surfacePage)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct NativeTextCanvas: UIViewRepresentable {
    let session: NativeEditorSession
    let contentSize: UIContentSizeCategory
    let labels: NativeEditorLabels

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> NativeTextView {
        updatePresentation(context.coordinator)
        return session.textView
    }

    func updateUIView(_ view: NativeTextView, context: Context) {
        updatePresentation(context.coordinator)
    }

    private func updatePresentation(_ coordinator: Coordinator) {
        coordinator.update(
            surface: session.surface, presentation: NativeTextPresentation(contentSize: contentSize, labels: labels))
    }

    @MainActor
    final class Coordinator {
        private weak var surface: NativeTextSurface?
        private var presentation: NativeTextPresentation?

        func update(surface: NativeTextSurface, presentation: NativeTextPresentation) {
            // UIViewRepresentable may update while UIKit handles selection.
            // Unchanged inputs must never even request a storage reconciliation.
            guard self.surface !== surface || self.presentation != presentation else { return }
            self.surface = surface
            self.presentation = presentation
            surface.updatePresentation(
                traits: UITraitCollection(preferredContentSizeCategory: presentation.contentSize),
                labels: presentation.labels)
        }
    }
}
