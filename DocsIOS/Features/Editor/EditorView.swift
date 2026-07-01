import SwiftUI

struct EditorView: View {
    @Bindable var viewModel: EditorViewModel
    let reach: LinkReach
    var onBack: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            NavBar(
                title: viewModel.title,
                backTitle: "Docs",
                onBack: onBack,
                trailingActions: [
                    NavBarAction(systemImage: "square.and.arrow.up", label: "Share", action: {}),
                    NavBarAction(systemImage: "ellipsis", label: "Options", action: {}),
                ]
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

            ScrollView {
                if viewModel.isLoading {
                    ProgressView()
                        .padding(DocsSpacing.spaceBase)
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
        }
        .background(DocsColor.surfacePage)
        .task {
            await viewModel.load()
        }
    }
}

#Preview {
    EditorView(
        viewModel: EditorViewModel(
            client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!),
            documentID: UUID(),
            title: "Q3 Planning"
        ),
        reach: .restricted
    )
}
