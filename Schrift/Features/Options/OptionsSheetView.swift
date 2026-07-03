import SwiftUI

struct OptionsSheetView: View {
    @Bindable var viewModel: OptionsViewModel
    let shareURL: URL?
    let markdown: String
    var onShare: (() -> Void)? = nil
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

                ScrollView {
                    VStack(spacing: DocsSpacing.spaceBase) {
                        ListSection {
                            ListRow(
                                systemImage: viewModel.isFavorite ? "pin.slash" : "pin",
                                title: viewModel.isFavorite ? "Unpin" : "Pin",
                                value: viewModel.isFavorite ? "Pinned" : nil,
                                action: { Task { await viewModel.toggleFavorite() } }
                            )
                        }

                        ListSection {
                            ListRow(systemImage: "link", title: "Copy link", action: { copyLink() })
                            if onShare != nil {
                                ProfileRowDivider()
                                ListRow(
                                    systemImage: "person.2", title: "Share", showsChevron: true,
                                    action: {
                                        onShare?()
                                        dismiss()
                                    })
                            }
                            ProfileRowDivider()
                            ListRow(systemImage: "doc.plaintext", title: "Copy as Markdown", action: { copyMarkdown() })
                        }

                        ListSection {
                            ListRow(
                                systemImage: "doc.on.doc", title: "Duplicate",
                                action: {
                                    Task {
                                        await viewModel.duplicate()
                                        dismiss()
                                    }
                                })
                        }

                        ListSection {
                            ListRow(
                                systemImage: "trash", title: "Delete document", isDestructive: true,
                                action: { isConfirmingDelete = true })
                        }
                    }
                    .padding(.horizontal, DocsSpacing.gutter)
                    .padding(.top, DocsSpacing.space3xs)
                }
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
