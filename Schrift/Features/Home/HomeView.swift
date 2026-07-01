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
    @State private var path: [Document] = []

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                DocumentListView(viewModel: viewModel, serverHost: serverHost, onSelect: { path.append($0) })

                TabBar(items: [
                    TabBarItem(value: "docs", label: "Docs", systemImage: "doc.text"),
                    TabBarItem(value: "search", label: "Search", systemImage: "magnifyingglass"),
                    TabBarItem(value: "shared", label: "Shared", systemImage: "person.2"),
                    TabBarItem(value: "me", label: "Profile", systemImage: "person.crop.circle"),
                ], selection: $selectedTab)
            }
            .background(DocsColor.surfacePage)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Document.self) { document in
                EditorView(
                    viewModel: EditorViewModel(
                        client: viewModel.client,
                        documentID: document.id,
                        title: document.title ?? "Untitled document"
                    ),
                    reach: document.linkReach,
                    serverHost: serverHost,
                    linkRole: document.linkRole,
                    initialIsFavorite: document.isFavorite,
                    onBack: { path.removeLast() },
                    onDeleted: {
                        path.removeLast()
                        Task { await viewModel.load() }
                    }
                )
                .toolbar(.hidden, for: .navigationBar)
            }
        }
    }
}

#Preview {
    HomeView(viewModel: HomeViewModel(client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!)), serverHost: "docs.llun.dev")
}
