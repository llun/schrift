import SwiftUI

struct OptionsSheetView: View {
    @Bindable var viewModel: OptionsViewModel
    let shareURL: URL?
    let markdown: String
    var onDeleted: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingDelete = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(DocsFont.footnote)
                        .foregroundStyle(DocsColor.danger)
                        .padding(.horizontal, DocsSpacing.gutter)
                        .padding(.top, DocsSpacing.spaceSM)
                }

                ListSection {
                    VStack(spacing: 0) {
                        ListRow(
                            systemImage: viewModel.isFavorite ? "pin.slash" : "pin",
                            title: viewModel.isFavorite ? "Unpin" : "Pin",
                            action: { Task { await viewModel.toggleFavorite() } }
                        )
                        ListRow(systemImage: "link", title: "Copy link", action: { copyLink() })
                        ListRow(systemImage: "doc.on.doc", title: "Copy as Markdown", action: { copyMarkdown() })
                        ListRow(systemImage: "plus.square.on.square", title: "Duplicate", action: {
                            Task {
                                await viewModel.duplicate()
                                dismiss()
                            }
                        })
                        ListRow(title: "Delete document", isDestructive: true, action: { isConfirmingDelete = true })
                    }
                }

                Spacer()
            }
            .background(DocsColor.surfacePage)
            .navigationTitle("Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Delete this document?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Task {
                        await viewModel.delete()
                        if viewModel.didDelete {
                            dismiss()
                            onDeleted?()
                        }
                    }
                }
            }
        }
    }

    private func copyLink() {
        if let shareURL {
            UIPasteboard.general.string = shareURL.absoluteString
        }
        dismiss()
    }

    private func copyMarkdown() {
        UIPasteboard.general.string = markdown
        dismiss()
    }
}

#Preview {
    OptionsSheetView(
        viewModel: OptionsViewModel(
            client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!),
            documentID: UUID(),
            isFavorite: false
        ),
        shareURL: URL(string: "https://docs.llun.dev/docs/abc/"),
        markdown: "# Sample"
    )
}
