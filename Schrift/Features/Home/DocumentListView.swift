import SwiftUI

struct DocumentListView: View {
    @Bindable var viewModel: HomeViewModel
    let serverHost: String
    var onSelect: (Document) -> Void
    /// When set, the search field becomes a read-only shortcut into the Search tab
    /// (phone). Left nil on iPad, where the field performs inline search.
    var onSearchTap: (() -> Void)? = nil
    /// When set, shows a "New doc" nav-bar action that creates and opens a document.
    var onNewDocument: (() -> Void)? = nil

    @AppStorage("schrift.workOffline") private var workOffline = false
    @State private var documentPendingFavoriteChoice: Document?

    var body: some View {
        VStack(spacing: 0) {
            NavBar(
                title: "Schrift",
                subtitle: serverHost,
                largeTitle: true,
                titleBadge: (viewModel.isOffline || workOffline) ? Badge(text: "Offline", tone: .warning, icon: "wifi.slash") : nil,
                trailingActions: onNewDocument.map { [NavBarAction(systemImage: "square.and.pencil", label: "New doc", action: $0)] } ?? []
            )

            VStack(spacing: DocsSpacing.spaceSM) {
                if let onSearchTap {
                    Button(action: onSearchTap) {
                        SearchField(text: .constant(""), placeholder: "Search \(serverHost)")
                            .allowsHitTesting(false)
                    }
                    .buttonStyle(.plain)
                } else {
                    SearchField(text: $viewModel.searchQuery, placeholder: "Search documents")
                }

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
                    if viewModel.searchResults.isEmpty {
                        if viewModel.errorMessage == nil {
                            ContentUnavailableView.search(text: viewModel.searchQuery)
                        }
                    } else {
                        documentSection(title: "Search Results", documents: viewModel.searchResults)
                    }
                } else if viewModel.pinnedDocuments.isEmpty && viewModel.recentDocuments.isEmpty {
                    if viewModel.errorMessage == nil {
                        ContentUnavailableView(
                            "No Documents",
                            systemImage: "doc.text",
                            description: Text("Documents you create or that are shared with you will appear here.")
                        )
                    }
                } else {
                    if viewModel.showsPinnedSection {
                        documentSection(title: "Pinned", documents: viewModel.pinnedDocuments)
                    }
                    documentSection(
                        title: viewModel.selectedFilter == .shared ? "Shared with me" : "Recent",
                        documents: viewModel.recentDocuments
                    )
                }
            }
            .refreshable {
                await viewModel.load()
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
