import SwiftUI

func documentRowDate(_ document: Document, locale: Locale) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    formatter.locale = locale
    return formatter.localizedString(for: document.updatedAt, relativeTo: Date())
}

/// Push destinations that aren't a `Document` (which routes to the editor).
enum HomeRoute: Hashable {
    case account
}

struct HomeView: View {
    @Bindable var viewModel: HomeViewModel
    let serverHost: String
    var onSignOut: () -> Void = {}

    @State private var selectedTab = "docs"
    @State private var path = NavigationPath()

    // Retained across tab switches so recent searches / loaded state survive.
    @State private var searchViewModel: SearchViewModel
    @State private var sharedViewModel: SharedViewModel
    @State private var profileViewModel: ProfileViewModel

    init(viewModel: HomeViewModel, serverHost: String, onSignOut: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.serverHost = serverHost
        self.onSignOut = onSignOut
        _searchViewModel = State(initialValue: SearchViewModel(client: viewModel.client))
        _sharedViewModel = State(initialValue: SharedViewModel(client: viewModel.client))
        _profileViewModel = State(initialValue: ProfileViewModel(client: viewModel.client))
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                tabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                TabBar(
                    items: [
                        TabBarItem(value: "docs", label: "Schrift", systemImage: "doc.text"),
                        TabBarItem(value: "search", label: "Search", systemImage: "magnifyingglass"),
                        TabBarItem(value: "shared", label: "Shared", systemImage: "person.2"),
                        TabBarItem(value: "me", label: "Profile", systemImage: "person.crop.circle"),
                    ], selection: $selectedTab)
            }
            .background(DocsColor.surfacePage)
            .toolbar(.hidden, for: .navigationBar)
            .restoresInteractivePopGesture()
            .navigationDestination(for: Document.self) { document in
                EditorScreen(
                    client: viewModel.client,
                    documentID: document.id,
                    title: document.title ?? "Untitled document",
                    saveCoordinator: viewModel.saveCoordinator,
                    diagnostics: viewModel.diagnostics,
                    reach: document.linkReach,
                    serverHost: serverHost,
                    linkRole: document.linkRole,
                    initialIsFavorite: document.isFavorite,
                    isOffline: viewModel.isOffline,
                    onBack: { popPath() },
                    onDeleted: {
                        popPath()
                        Task { await viewModel.load() }
                    },
                    onOpenDocument: { path.append($0) }
                )
                .toolbar(.hidden, for: .navigationBar)
            }
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .account:
                    AccountScreen(viewModel: profileViewModel, serverHost: serverHost, onBack: { popPath() })
                        .toolbar(.hidden, for: .navigationBar)
                }
            }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case "search":
            SearchScreen(viewModel: searchViewModel, serverHost: serverHost, onOpenDocument: { path.append($0) })
        case "shared":
            SharedScreen(viewModel: sharedViewModel, serverHost: serverHost, onOpenDocument: { path.append($0) })
        case "me":
            ProfileScreen(
                viewModel: profileViewModel,
                serverHost: serverHost,
                isOffline: viewModel.isOffline,
                onOpenAccount: { path.append(HomeRoute.account) },
                onSignOut: onSignOut
            )
        default:
            DocumentListView(
                viewModel: viewModel,
                serverHost: serverHost,
                onSelect: { path.append($0) },
                onSearchTap: { selectedTab = "search" },
                onNewDocument: {
                    Task {
                        if let document = await viewModel.createDocument() {
                            path.append(document)
                        }
                    }
                }
            )
        }
    }

    private func popPath() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }
}

#Preview {
    HomeView(
        viewModel: HomeViewModel(client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!)),
        serverHost: "docs.llun.dev")
}
