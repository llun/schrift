import SwiftUI

private struct AuthenticatedHomeContainer: View {
    @State private var viewModel: HomeViewModel
    let serverURL: URL
    let serverHost: String
    let sessionStore: SessionStore
    let onSignOut: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(serverURL: URL, sessionStore: SessionStore, onSignOut: @escaping () -> Void) {
        // The one client every feature shares: its onSessionExpired hook is
        // what turns any real 401 into the re-login sheet below (idempotent —
        // concurrent 401s just re-set the same flag).
        let client = DocsAPIClient(
            baseURL: serverURL.appendingPathComponent("api/v1.0/"),
            onSessionExpired: { Task { @MainActor in sessionStore.noteSessionExpired() } }
        )
        _viewModel = State(initialValue: HomeViewModel(client: client))
        self.serverURL = serverURL
        serverHost = serverURL.host ?? ""
        self.sessionStore = sessionStore
        self.onSignOut = onSignOut
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                HomeSplitView(viewModel: viewModel, serverHost: serverHost)
            } else {
                HomeView(viewModel: viewModel, serverHost: serverHost, onSignOut: onSignOut)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { sessionStore.needsReauthentication },
                // Swipe-dismiss = cancel: keep showing cached data; the next
                // failing request re-presents the sheet.
                set: { if !$0 { sessionStore.cancelReauthentication() } }
            )
        ) {
            ReauthenticationSheetView(
                serverURL: serverURL,
                sessionStore: sessionStore,
                onAuthenticated: {
                    let homeViewModel = viewModel
                    Task { await homeViewModel.load() }
                },
                onCancel: { sessionStore.cancelReauthentication() }
            )
        }
    }
}

struct RootView: View {
    @State private var sessionStore = SessionStore()
    @State private var recentServers = RecentServersStore()

    var body: some View {
        if sessionStore.isAuthenticated, let serverURL = sessionStore.serverURL {
            AuthenticatedHomeContainer(
                serverURL: serverURL,
                sessionStore: sessionStore,
                onSignOut: {
                    // Full document bodies must not survive sign-out on disk. The
                    // metadata caches (DocumentCacheStore's document lists and
                    // DocumentChildrenCacheStore's sub-page lists) and unsaved
                    // drafts (PendingDraftStore) keep their existing behavior — a
                    // recorded decision, see the 2026-07-03 spec and the
                    // instant-local-doc-lists plan.
                    DocumentContentCacheStore().removeAll()
                    try? sessionStore.signOut()
                })
        } else {
            ConnectView(viewModel: ConnectViewModel(sessionStore: sessionStore, recentServers: recentServers))
        }
    }
}

#Preview {
    RootView()
}
