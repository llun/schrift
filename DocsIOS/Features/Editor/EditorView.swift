import SwiftUI

struct EditorView: View {
    @Bindable var viewModel: EditorViewModel
    let reach: LinkReach
    let serverHost: String
    var linkRole: LinkRole? = nil
    var initialIsFavorite: Bool = false
    var onBack: (() -> Void)? = nil
    var onDeleted: (() -> Void)? = nil

    @State private var isPresentingShareSheet = false
    @State private var isPresentingOptionsSheet = false
    @State private var optionsViewModel: OptionsViewModel?

    var body: some View {
        VStack(spacing: 0) {
            NavBar(
                title: viewModel.title,
                backTitle: "Docs",
                onBack: onBack,
                trailingActions: trailingActions
            )

            HStack(spacing: DocsSpacing.spaceXS) {
                Text(viewModel.title)
                    .font(DocsFont.title1)
                    .foregroundStyle(DocsColor.textPrimary)
                LinkReachPill(reach: reach)
                Spacer()
            }
            .padding(.horizontal, DocsSpacing.gutter)
            .padding(.top, DocsSpacing.spaceSM)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.danger)
                    .padding(.horizontal, DocsSpacing.gutter)
            }

            if viewModel.isLoading {
                ProgressView()
                    .padding(DocsSpacing.spaceBase)
                Spacer()
            } else if viewModel.isEditing {
                TextEditor(text: $viewModel.rawMarkdown)
                    .font(DocsFont.body)
                    .padding(.horizontal, DocsSpacing.spaceXS)
                    .disabled(viewModel.isSaving)
            } else {
                ScrollView {
                    if viewModel.blocks.isEmpty {
                        if viewModel.errorMessage == nil {
                            ContentUnavailableView(
                                "Empty Document",
                                systemImage: "doc.text",
                                description: Text("This document doesn't have any content yet.")
                            )
                            .padding(.top, DocsSpacing.spaceLG)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: DocsSpacing.spaceSM) {
                            ForEach(Array(viewModel.blocks.enumerated()), id: \.offset) { _, block in
                                MarkdownBlockView(block: block)
                            }
                        }
                        .padding(DocsSpacing.gutter)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .refreshable {
                    await viewModel.load()
                }
            }
        }
        .background(DocsColor.surfacePage)
        .task {
            await viewModel.load()
        }
        .sheet(isPresented: $isPresentingShareSheet) {
            ShareSheetView(
                viewModel: ShareViewModel(
                    client: viewModel.client,
                    documentID: viewModel.documentID,
                    linkReach: reach,
                    linkRole: linkRole
                )
            )
        }
        .sheet(isPresented: $isPresentingOptionsSheet) {
            if let optionsViewModel {
                OptionsSheetView(
                    viewModel: optionsViewModel,
                    shareURL: documentShareURL(serverHost: serverHost, documentID: viewModel.documentID),
                    markdown: viewModel.rawMarkdown,
                    onDeleted: onDeleted
                )
            }
        }
    }

    private var trailingActions: [NavBarAction] {
        if viewModel.isEditing {
            return [
                NavBarAction(systemImage: "xmark", label: "Cancel", action: { viewModel.cancelEditing() }),
                NavBarAction(systemImage: "checkmark", label: "Save", action: { Task { await viewModel.save() } }),
            ]
        }
        return [
            NavBarAction(systemImage: "square.and.arrow.up", label: "Share", action: { isPresentingShareSheet = true }),
            NavBarAction(systemImage: "pencil", label: "Edit", action: { viewModel.startEditing() }),
            NavBarAction(systemImage: "ellipsis", label: "Options", action: {
                if optionsViewModel == nil {
                    optionsViewModel = OptionsViewModel(client: viewModel.client, documentID: viewModel.documentID, isFavorite: initialIsFavorite)
                }
                isPresentingOptionsSheet = true
            }),
        ]
    }
}

#Preview {
    EditorView(
        viewModel: EditorViewModel(
            client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!),
            documentID: UUID(),
            title: "Q3 Planning"
        ),
        reach: .restricted,
        serverHost: "docs.llun.dev"
    )
}
