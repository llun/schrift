import SwiftUI

struct DocumentListView: View {
    @Bindable var viewModel: HomeViewModel
    let serverHost: String
    var onSelect: (Document) -> Void

    @State private var documentPendingFavoriteChoice: Document?

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "Docs", subtitle: serverHost, largeTitle: true)

            VStack(spacing: DocsSpacing.spaceSM) {
                SearchField(text: $viewModel.searchQuery, placeholder: "Search documents")

                SegmentedControl(
                    segments: HomeFilter.allCases.map(\.title),
                    selectedIndex: Binding(
                        get: { viewModel.selectedFilter.rawValue },
                        set: { newValue in
                            let filter = HomeFilter(rawValue: newValue) ?? .all
                            Task { await viewModel.selectFilter(filter) }
                        }
                    )
                )
            }
            .padding(.horizontal, DocsSpacing.gutter)
            .padding(.vertical, DocsSpacing.spaceSM)

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
                } else if !viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    documentSection(title: "Search Results", documents: viewModel.searchResults)
                } else {
                    if viewModel.showsPinnedSection {
                        documentSection(title: "Pinned", documents: viewModel.pinnedDocuments)
                    }
                    documentSection(title: "Recent", documents: viewModel.recentDocuments)
                }
            }
        }
        .background(DocsColor.surfacePage)
        .task {
            await viewModel.load()
        }
        .onChange(of: viewModel.searchQuery) {
            Task { await viewModel.search() }
        }
        .confirmationDialog(
            "Document Options",
            isPresented: Binding(
                get: { documentPendingFavoriteChoice != nil },
                set: { if !$0 { documentPendingFavoriteChoice = nil } }
            ),
            presenting: documentPendingFavoriteChoice
        ) { document in
            Button(document.isFavorite ? "Unpin" : "Pin") {
                Task { await viewModel.toggleFavorite(document) }
            }
        }
    }

    @ViewBuilder
    private func documentSection(title: String, documents: [Document]) -> some View {
        if !documents.isEmpty {
            ListSection(header: title) {
                VStack(spacing: 0) {
                    ForEach(documents) { document in
                        DocRow(
                            emoji: nil,
                            title: document.title ?? "Untitled document",
                            pinned: document.isFavorite,
                            reach: document.linkReach,
                            date: documentRowDate(document),
                            onOpen: { onSelect(document) },
                            onMore: { documentPendingFavoriteChoice = document }
                        )
                    }
                }
            }
        }
    }
}

#Preview {
    DocumentListView(
        viewModel: HomeViewModel(client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!)),
        serverHost: "docs.llun.dev",
        onSelect: { _ in }
    )
}
