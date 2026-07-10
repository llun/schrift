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
                    label: "Text",
                    text: $label,
                    placeholder: "Link text",
                    helper: "Leave empty to show the address itself."
                )

                DocsTextField(
                    label: "Address",
                    text: Binding(
                        get: { url },
                        set: {
                            url = $0
                            showsURLError = false
                        }),
                    placeholder: "example.com/page",
                    error: showsURLError ? "That address can't be used as a link." : nil
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

                if let onRemove, isEditingExistingLink {
                    Button(role: .destructive) {
                        onRemove()
                    } label: {
                        Label("Remove link", systemImage: "link.badge.minus")
                            .font(DocsFont.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, DocsSpacing.space2xs)
                }

                Spacer()
            }
            .padding(DocsSpacing.gutter)
            .background(DocsColor.surfacePage)
            .navigationTitle(isEditingExistingLink ? "Edit link" : "Add link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditingExistingLink ? "Save" : "Add") {
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
}
