import SwiftUI

struct OptionsSheetView: View {
    @Bindable var viewModel: OptionsViewModel
    let shareURL: URL?
    let markdown: String
    var onShare: (() -> Void)? = nil
    var onDeleted: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(LocalizationStore.self) private var loc
    @State private var isConfirmingDelete = false
    @State private var isPresentingVersionHistory = false
    @State private var versionHistoryViewModel: VersionHistoryViewModel
    private let restoreURL: URL?

    init(
        viewModel: OptionsViewModel,
        client: DocsAPIClient,
        documentID: UUID,
        serverHost: String,
        shareURL: URL?,
        markdown: String,
        onShare: (() -> Void)? = nil,
        onDeleted: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.shareURL = shareURL
        self.markdown = markdown
        self.onShare = onShare
        self.onDeleted = onDeleted
        self.restoreURL = documentShareURL(serverHost: serverHost, documentID: documentID)
        _versionHistoryViewModel = State(
            initialValue: VersionHistoryViewModel(client: client, documentID: documentID))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let errorKey = viewModel.errorKey {
                    Text(loc[errorKey])
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
                                title: viewModel.isFavorite ? loc[.options_unpin] : loc[.options_pin],
                                value: viewModel.isFavorite ? loc[.options_pinned] : nil,
                                action: { Task { await viewModel.toggleFavorite() } }
                            )
                        }

                        ListSection {
                            ListRow(systemImage: "link", title: loc[.options_copy_link], action: { copyLink() })
                            if onShare != nil {
                                ProfileRowDivider()
                                ListRow(
                                    systemImage: "person.2", title: loc[.options_share], showsChevron: true,
                                    action: {
                                        onShare?()
                                        dismiss()
                                    })
                            }
                            ProfileRowDivider()
                            ListRow(
                                systemImage: "doc.plaintext", title: loc[.options_copy_markdown],
                                action: { copyMarkdown() })
                        }

                        ListSection {
                            ListRow(
                                systemImage: "clock.arrow.circlepath", title: loc[.versions_title],
                                showsChevron: true,
                                action: { isPresentingVersionHistory = true })
                        }

                        ListSection {
                            ListRow(
                                systemImage: "doc.on.doc", title: loc[.options_duplicate],
                                action: {
                                    Task {
                                        await viewModel.duplicate()
                                        dismiss()
                                    }
                                })
                        }

                        ListSection {
                            ListRow(
                                systemImage: "trash", title: loc[.options_delete_document], isDestructive: true,
                                action: { isConfirmingDelete = true })
                        }
                    }
                    .padding(.horizontal, DocsSpacing.gutter)
                    .padding(.top, DocsSpacing.space3xs)
                }
            }
            .background(DocsColor.surfacePage)
            .navigationTitle(loc[.options_title])
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc[.common_done]) { dismiss() }
                }
            }
            .confirmationDialog(
                loc[.options_delete_confirm_title], isPresented: $isConfirmingDelete, titleVisibility: .visible
            ) {
                Button(loc[.options_delete], role: .destructive) {
                    Task {
                        await viewModel.delete()
                        if viewModel.didDelete {
                            dismiss()
                            onDeleted?()
                        }
                    }
                }
            }
            .sheet(isPresented: $isPresentingVersionHistory) {
                VersionHistorySheetView(viewModel: versionHistoryViewModel, restoreURL: restoreURL)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
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
    let client = DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!)
    let documentID = UUID()
    OptionsSheetView(
        viewModel: OptionsViewModel(client: client, documentID: documentID, isFavorite: false),
        client: client,
        documentID: documentID,
        serverHost: "docs.llun.dev",
        shareURL: URL(string: "https://docs.llun.dev/docs/abc/"),
        markdown: "# Sample"
    )
    .environment(LocalizationStore())
}
