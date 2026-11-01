import SwiftUI

func documentRowDate(_ document: Document, locale: Locale) -> String {
    RelativeDateFormatterCache.shared.string(for: document.updatedAt, relativeTo: Date(), locale: locale)
}

/// The primary destinations, in their system tab-bar order. Profile is always last.
enum AppTab: Hashable {
    case docs
    case shared
    case profile
}

/// Auxiliary destinations on Home's compact-width navigation stack.
enum HomeRoute: Hashable {
    case search
}

/// A native system tab shell with independent navigation state per primary destination.
/// Home owns compact-width Search, so opening a result and going back preserves the query.
/// Regular-width Home keeps its split view and inline sidebar search.
struct MainTabView: View {
    @Environment(\.docsTheme) private var theme
    @Bindable var viewModel: HomeViewModel
    let serverHost: String
    /// Server origin for the editor's off-origin image gate (`imageLoadPolicy`).
    let serverOrigin: String
    /// Advanced by every sign-in, including one made through the re-login sheet — which this
    /// shell survives, so a tab holding account-scoped state must be told to re-read it.
    /// Required, not defaulted — see `ProfileScreen.signInGeneration`.
    let signInGeneration: Int
    var onSignOut: () -> Void = {}

    @State private var selectedTab: AppTab = .docs
    @State private var docsPath = NavigationPath()
    @State private var sharedPath = NavigationPath()
    /// Where a document zooms open from, one namespace per stack (a tab's rows are never the
    /// source for another tab's pushes), and which pushed editors on each stack came from a
    /// row at all — see `DocumentZoomTracker`. The iPad split view pushes nothing and so
    /// registers no sources.
    @Namespace private var docsZoom
    @Namespace private var sharedZoom
    @State private var docsZoomTracker = DocumentZoomTracker()
    @State private var sharedZoomTracker = DocumentZoomTracker()

    @Environment(LocalizationStore.self) private var loc
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    // Built once and retained, so loaded state and recent searches
    // survive switching away and back regardless of what the system does with
    // unselected tab content.
    @State private var searchViewModel: SearchViewModel
    @State private var sharedViewModel: SharedViewModel
    @State private var profileViewModel: ProfileViewModel
    @State private var attachmentsViewModel: AttachmentsViewModel

    init(
        viewModel: HomeViewModel, serverHost: String, serverOrigin: String, signInGeneration: Int,
        onSignOut: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.serverHost = serverHost
        self.serverOrigin = serverOrigin
        self.signInGeneration = signInGeneration
        self.onSignOut = onSignOut
        // The coordinator so these tabs can strike through a document whose deletion is
        // queued, and offer the undo. Home's own list reads it directly (it owns the
        // coordinator); these two are given it here.
        _searchViewModel = State(
            initialValue: SearchViewModel(
                client: viewModel.client, saveCoordinator: viewModel.saveCoordinator,
                availability: viewModel.availability))
        _sharedViewModel = State(
            initialValue: SharedViewModel(
                client: viewModel.client, saveCoordinator: viewModel.saveCoordinator,
                availability: viewModel.availability))
        _profileViewModel = State(initialValue: ProfileViewModel(client: viewModel.client))
        _attachmentsViewModel = State(
            initialValue: AttachmentsViewModel(
                serverOrigin: serverOrigin,
                isPendingDelete: { [saveCoordinator = viewModel.saveCoordinator, user = viewModel.signedInUser] in
                    saveCoordinator.isListablePendingDelete(documentID: $0, currentUserID: user.userID)
                }))
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
        }
        .tint(theme.colors.brandFill)
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
                    onSelect: {
                        push(
                            DocumentEditorRoute(document: $0), from: .home, path: $docsPath,
                            tracker: $docsZoomTracker)
                    },
                    onSearchTap: {
                        docsZoomTracker.push(nil)
                        docsPath.append(HomeRoute.search)
                    },
                    onNewDocument: createDocument
                )
                .navigationDestination(for: DocumentEditorRoute.self) { route in
                    editorScreen(for: route, path: $docsPath, tracker: $docsZoomTracker)
                        .documentZoomDestination(
                            source: docsZoomTracker.source(for: route.document.id), in: docsZoom)
                }
                .navigationDestination(for: HomeRoute.self) { route in
                    switch route {
                    case .search:
                        SearchScreen(
                            viewModel: searchViewModel, serverHost: serverHost,
                            onOpenDocument: {
                                push(
                                    DocumentEditorRoute(document: $0), from: .search, path: $docsPath,
                                    tracker: $docsZoomTracker)
                            }
                        )
                    }
                }
            }
            .environment(\.documentZoomNamespace, docsZoom)
            // Popping back from an editor (or Search) may leave a rename the list has not seen,
            // so a shrinking path marks the list stale and fetches once regardless of the 30 s freshness window.
            .onChange(of: docsPath.count) { old, new in
                docsZoomTracker.trim(to: new)
                if new < old {
                    viewModel.markListStale()
                    Task { await viewModel.loadIfStale() }
                }
            }
        }
    }

    private var sharedTab: some View {
        NavigationStack(path: $sharedPath) {
            SharedScreen(
                viewModel: sharedViewModel, serverHost: serverHost, signInGeneration: signInGeneration,
                onOpenDocument: {
                    push(
                        DocumentEditorRoute(document: $0), from: .shared, path: $sharedPath,
                        tracker: $sharedZoomTracker)
                }
            )
            .navigationDestination(for: DocumentEditorRoute.self) { route in
                editorScreen(for: route, path: $sharedPath, tracker: $sharedZoomTracker)
                    .documentZoomDestination(
                        source: sharedZoomTracker.source(for: route.document.id), in: sharedZoom)
            }
        }
        .environment(\.documentZoomNamespace, sharedZoom)
        .onChange(of: sharedPath.count) { _, new in
            sharedZoomTracker.trim(to: new)
        }
    }

    /// Profile pushes its account detail and the attachments list. No explicit
    /// path binding: nothing needs to drive either programmatically.
    private var profileTab: some View {
        NavigationStack {
            ProfileScreen(
                viewModel: profileViewModel,
                serverHost: serverHost,
                isOffline: viewModel.isOffline,
                signInGeneration: signInGeneration,
                onSignOut: onSignOut,
                onWorkOfflineChanged: { viewModel.availability.preferencesChanged() }
            )
            .navigationDestination(for: ProfileRoute.self) { route in
                switch route {
                case .account:
                    AccountScreen(
                        user: profileViewModel.user,
                        serverHost: serverHost,
                        // The origin the app already derived for the image gate
                        // — no second source of truth for where the server is.
                        serverURL: URL(string: serverOrigin)
                    )
                case .attachments:
                    AttachmentsScreen(
                        viewModel: attachmentsViewModel, isOffline: viewModel.availability.isOffline)
                }
            }
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

    /// One builder for Home (including Search) and Shared, so the editor
    /// is configured identically no matter which tab it was reached from.
    private func editorScreen(
        for route: DocumentEditorRoute, path: Binding<NavigationPath>, tracker: Binding<DocumentZoomTracker>
    ) -> some View {
        let document = route.document
        return EditorScreen(
            client: viewModel.client,
            documentID: document.id,
            title: document.title ?? loc[.common_untitled],
            saveCoordinator: viewModel.saveCoordinator,
            entryIntent: route.entryIntent,
            diagnostics: viewModel.diagnostics,
            availability: viewModel.availability,
            reach: document.linkReach,
            serverHost: serverHost,
            serverOrigin: serverOrigin,
            linkRole: document.linkRole,
            initialIsFavorite: document.isFavorite,
            pinRow: document,
            onDeleted: {
                pop(path)
                Task { await viewModel.load() }
            },
            // Page chips and "new page" are not opened from a row: no zoom source.
            onOpenDocument: { push(DocumentEditorRoute(document: $0), from: nil, path: path, tracker: tracker) },
            onCreatedDocument: {
                push(DocumentEditorRoute(createdDocument: $0), from: nil, path: path, tracker: tracker)
            }
        )
        // The editor is a full-screen surface: the tab bar steps aside for it,
        // and returns when the stack pops. Its navigation bar is the system's
        // now, so nothing here hides it — and with no hidden bar there is no
        // disabled edge-swipe to restore.
        .toolbar(.hidden, for: .tabBar)
    }

    private func createDocument() {
        Task {
            if let document = await viewModel.createDocument() {
                push(
                    DocumentEditorRoute(createdDocument: document), from: nil, path: $docsPath,
                    tracker: $docsZoomTracker)
            }
        }
    }

    /// Push an editor, recording whether it came from a row (and which list) so its destination
    /// can zoom out of that row. Every append to a path goes through here or pushes `nil`
    /// itself, keeping the tracker parallel to the path.
    private func push(
        _ route: DocumentEditorRoute, from surface: DocumentZoomSurface?, path: Binding<NavigationPath>,
        tracker: Binding<DocumentZoomTracker>
    ) {
        tracker.wrappedValue.push(
            surface.map { DocumentZoomSourceID(documentID: route.document.id, surface: $0) })
        path.wrappedValue.append(route)
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
        serverOrigin: "https://docs.llun.dev",
        signInGeneration: 0
    )
    .environment(LocalizationStore())
    .environment(AppearanceStore())
    .environment(ThemeStore())
    .environment(AttachmentLoader.inert())
    .environment(ImageLoader.inert())
}
