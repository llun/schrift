import SwiftUI

func documentRowDate(_ document: Document, locale: Locale) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    formatter.locale = locale
    return formatter.localizedString(for: document.updatedAt, relativeTo: Date())
}

/// The app's top-level destinations.
///
/// Order is the order they appear, and `search` is last because it is the
/// system's *search role* — on iOS 26 that renders as the separated circular
/// button at the trailing edge of the floating tab bar rather than as a fourth
/// tab in the capsule, which is what the handoff asks for.
enum AppTab: Hashable, CaseIterable {
    case docs
    case shared
    case profile
    case search
}

/// The app shell: a system `TabView` hosting one navigation stack per tab.
///
/// This is deliberately the platform's own tab bar rather than a drawn one. It
/// buys the whole set of behaviors the handoff's "native first" rule is after —
/// the Liquid Glass capsule, minimize-on-scroll, the separated search role,
/// safe areas, and the iPad tab strip — none of which a custom bar gets.
///
/// **One stack per tab, not one around the whole shell.** `.toolbar(.hidden,
/// for: .tabBar)` only reaches the bar from inside a tab's own stack; each tab
/// keeps its own navigation state across switches; and the search tab's
/// `.searchable` field has to live in its own stack to bind to the search role.
struct MainTabView: View {
    @Bindable var viewModel: HomeViewModel
    let serverHost: String
    /// Server origin for the editor's off-origin image gate (`imageLoadPolicy`).
    let serverOrigin: String
    var onSignOut: () -> Void = {}

    @State private var selectedTab: AppTab = .docs
    @State private var docsPath = NavigationPath()
    @State private var sharedPath = NavigationPath()
    @State private var searchPath = NavigationPath()

    @Environment(LocalizationStore.self) private var loc
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    // Built once and retained, so a tab's loaded state and recent searches
    // survive switching away and back regardless of what the system does with
    // unselected tab content.
    @State private var searchViewModel: SearchViewModel
    @State private var sharedViewModel: SharedViewModel
    @State private var profileViewModel: ProfileViewModel

    init(
        viewModel: HomeViewModel, serverHost: String, serverOrigin: String, onSignOut: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.serverHost = serverHost
        self.serverOrigin = serverOrigin
        self.onSignOut = onSignOut
        _searchViewModel = State(initialValue: SearchViewModel(client: viewModel.client))
        _sharedViewModel = State(initialValue: SharedViewModel(client: viewModel.client))
        _profileViewModel = State(initialValue: ProfileViewModel(client: viewModel.client))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(value: AppTab.docs) {
                docsTab
            } label: {
                tabLabel(loc[.home_title], icon: .description)
            }

            Tab(value: AppTab.shared) {
                sharedTab
            } label: {
                tabLabel(loc[.shared_title], icon: .group)
            }

            Tab(value: AppTab.profile) {
                profileTab
            } label: {
                tabLabel(loc[.common_profile], icon: .account_circle)
            }

            // The system supplies this one's label and its separated placement.
            Tab(value: AppTab.search, role: .search) {
                searchTab
            }
        }
        .tint(DocsColor.brandFill)
        .tabBarMinimizeBehavior(.onScrollDown)
    }

    // MARK: - Tabs

    /// On a regular width this is the split view (list beside editor); on a
    /// compact one the list pushes the editor. Both are inside the docs tab, so
    /// iPad now reaches every other tab too — it previously had no tab bar at all.
    @ViewBuilder
    private var docsTab: some View {
        if horizontalSizeClass == .regular {
            // The split view owns its own create action: it opens a document by
            // selecting it, not by pushing onto this shell's path.
            HomeSplitView(viewModel: viewModel, serverHost: serverHost, serverOrigin: serverOrigin)
        } else {
            NavigationStack(path: $docsPath) {
                DocumentListView(
                    viewModel: viewModel,
                    serverHost: serverHost,
                    onSelect: { docsPath.append($0) },
                    onSearchTap: { selectedTab = .search },
                    onNewDocument: createDocument
                )
                .navigationDestination(for: Document.self) { document in
                    editorScreen(for: document, path: $docsPath)
                }
                .restoresInteractivePopGesture()
            }
        }
    }

    private var sharedTab: some View {
        NavigationStack(path: $sharedPath) {
            SharedScreen(
                viewModel: sharedViewModel, serverHost: serverHost, onOpenDocument: { sharedPath.append($0) }
            )
            .navigationDestination(for: Document.self) { document in
                editorScreen(for: document, path: $sharedPath)
            }
            .restoresInteractivePopGesture()
        }
    }

    private var searchTab: some View {
        NavigationStack(path: $searchPath) {
            SearchScreen(
                viewModel: searchViewModel, serverHost: serverHost, onOpenDocument: { searchPath.append($0) }
            )
            .navigationDestination(for: Document.self) { document in
                editorScreen(for: document, path: $searchPath)
            }
            .restoresInteractivePopGesture()
        }
    }

    /// Profile pushes nothing today, so it needs no path of its own — but it is
    /// still wrapped in a stack so it gets the same large-title chrome as the
    /// other roots.
    private var profileTab: some View {
        NavigationStack {
            ProfileScreen(
                viewModel: profileViewModel,
                serverHost: serverHost,
                isOffline: viewModel.isOffline,
                onSignOut: onSignOut
            )
        }
    }

    // MARK: - Shared pieces

    /// Material Symbols are the app's icon set, so a tab's glyph is the bundled
    /// font rendered to a template image — `Image(systemName:)` is never used
    /// here. Fixed size: the system lays the tab bar out and scales its own
    /// labels.
    private func tabLabel(_ title: String, icon: MaterialIcon) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(uiImage: icon.uiImage(pointSize: 24) ?? UIImage())
        }
    }

    /// One builder for all three stacks that can open a document, so the editor
    /// is configured identically no matter which tab it was reached from.
    private func editorScreen(for document: Document, path: Binding<NavigationPath>) -> some View {
        EditorScreen(
            client: viewModel.client,
            documentID: document.id,
            title: document.title ?? loc[.common_untitled],
            saveCoordinator: viewModel.saveCoordinator,
            diagnostics: viewModel.diagnostics,
            reach: document.linkReach,
            serverHost: serverHost,
            serverOrigin: serverOrigin,
            linkRole: document.linkRole,
            initialIsFavorite: document.isFavorite,
            isOffline: viewModel.isOffline,
            onBack: { pop(path) },
            onDeleted: {
                pop(path)
                Task { await viewModel.load() }
            },
            onOpenDocument: { path.wrappedValue.append($0) }
        )
        // The editor is a full-screen surface: the tab bar steps aside for it,
        // and returns when the stack pops.
        .toolbar(.hidden, for: .tabBar)
        .toolbar(.hidden, for: .navigationBar)
    }

    private func createDocument() {
        Task {
            if let document = await viewModel.createDocument() {
                docsPath.append(document)
            }
        }
    }

    private func pop(_ path: Binding<NavigationPath>) {
        guard !path.wrappedValue.isEmpty else { return }
        path.wrappedValue.removeLast()
    }
}

#Preview {
    MainTabView(
        viewModel: HomeViewModel(client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!)),
        serverHost: "docs.llun.dev",
        serverOrigin: "https://docs.llun.dev"
    )
    .environment(LocalizationStore())
    .environment(AppearanceStore())
}
