import SwiftUI

/// Creates or retargets a `[label](url)`.
///
/// Deliberately not backed by a view model: it does no networking and owns no
/// state beyond two text fields, which are seeded from the request and handed
/// back on save. `EditorViewModel` does the validation and the string surgery.
struct LinkEditorSheet: View {
    let request: EditorViewModel.LinkEditorRequest
    /// Returns false when the destination cannot be embedded safely, which
    /// keeps the sheet open with the field marked.
    let onSave: (String, String) -> Bool
    let onRemove: (() -> Void)?
    let onCancel: () -> Void

    @State private var label: String
    @State private var url: String
    @State private var showsURLError = false

    @Environment(LocalizationStore.self) private var loc

    init(
        request: EditorViewModel.LinkEditorRequest,
        onSave: @escaping (String, String) -> Bool,
        onRemove: (() -> Void)? = nil,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.onSave = onSave
        self.onRemove = onRemove
        self.onCancel = onCancel
        _label = State(initialValue: request.label)
        _url = State(initialValue: request.url)
    }

    private var isEditingExistingLink: Bool { request.span != nil }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: DocsSpacing.spaceBase) {
                DocsTextField(
                    label: loc[.editor_link_text_label],
                    text: $label,
                    placeholder: loc[.editor_link_text_placeholder],
                    helper: loc[.editor_link_text_helper]
                )

                DocsTextField(
                    label: loc[.editor_link_address_label],
                    text: Binding(
                        get: { url },
                        set: {
                            url = $0
                            showsURLError = false
                        }),
                    placeholder: loc[.editor_link_address_placeholder],
                    error: showsURLError ? loc[.editor_link_address_error] : nil
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

                if let onRemove, isEditingExistingLink {
                    Button(role: .destructive) {
                        onRemove()
                    } label: {
                        Label(loc[.editor_link_remove], systemImage: "link.badge.minus")
                            .font(DocsFont.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, DocsSpacing.space2xs)
                }

                Spacer()
            }
            .padding(DocsSpacing.gutter)
            .background(DocsColor.surfacePage)
            .navigationTitle(isEditingExistingLink ? loc[.editor_link_edit_title] : loc[.editor_link_add_title])
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc[.common_cancel], action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditingExistingLink ? loc[.editor_link_save] : loc[.editor_link_add]) {
                        showsURLError = !onSave(label, url)
                    }
                    .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview("Add") {
    LinkEditorSheet(
        request: .init(blockID: UUID(), span: nil, label: "docs", url: "", range: NSRange(location: 0, length: 4)),
        onSave: { _, _ in true },
        onCancel: {}
    )
    .environment(LocalizationStore())
}

#Preview("Edit") {
    LinkEditorSheet(
        request: .init(
            blockID: UUID(),
            span: InlineLinkSpan(
                range: NSRange(location: 0, length: 24),
                labelRange: NSRange(location: 1, length: 4),
                label: "docs",
                url: "https://docs.llun.dev/"),
            label: "docs",
            url: "https://docs.llun.dev/",
            range: NSRange(location: 0, length: 24)),
        onSave: { _, _ in true },
        onRemove: {},
        onCancel: {}
    )
    .environment(LocalizationStore())
}
