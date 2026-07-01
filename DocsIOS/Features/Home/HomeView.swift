import SwiftUI

func documentRowDate(_ document: Document) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: document.updatedAt, relativeTo: Date())
}

struct HomeView: View {
    @Bindable var viewModel: HomeViewModel
    let serverHost: String

    @State private var selectedTab = "docs"
    @State private var documentPendingFavoriteChoice: Document?
    @State private var path: [Document] = []

    var body: some View {
        NavigationStack(path: $path) {
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

                TabBar(items: [
                    TabBarItem(value: "docs", label: "Docs", systemImage: "doc.text"),
                    TabBarItem(value: "search", label: "Search", systemImage: "magnifyingglass"),
                    TabBarItem(value: "shared", label: "Shared", systemImage: "person.2"),
                    TabBarItem(value: "me", label: "Profile", systemImage: "person.crop.circle"),
                ], selection: $selectedTab)
            }
            .background(DocsColor.surfacePage)
            .toolbar(.hidden, for: .navigationBar)
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
            .navigationDestination(for: Document.self) { document in
                EditorView(
                    viewModel: EditorViewModel(
                        client: viewModel.client,
                        documentID: document.id,
                        title: document.title ?? "Untitled document"
                    ),
                    reach: document.linkReach,
                    onBack: { path.removeLast() }
                )
                .toolbar(.hidden, for: .navigationBar)
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
                            onOpen: { path.append(document) },
                            onMore: { documentPendingFavoriteChoice = document }
                        )
                    }
                }
            }
        }
    }
}

#Preview {
    HomeView(viewModel: HomeViewModel(client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!)), serverHost: "docs.llun.dev")
}
