import SwiftUI

private struct AuthenticatedHomeContainer: View {
    @State private var viewModel: HomeViewModel
    let serverHost: String
    let onSignOut: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(serverURL: URL, onSignOut: @escaping () -> Void) {
        _viewModel = State(initialValue: HomeViewModel(client: DocsAPIClient(baseURL: serverURL.appendingPathComponent("api/v1.0/"))))
        serverHost = serverURL.host ?? ""
        self.onSignOut = onSignOut
    }

    var body: some View {
        if horizontalSizeClass == .regular {
            HomeSplitView(viewModel: viewModel, serverHost: serverHost)
        } else {
            HomeView(viewModel: viewModel, serverHost: serverHost, onSignOut: onSignOut)
        }
    }
}

struct RootView: View {
    @State private var sessionStore = SessionStore()
    @State private var recentServers = RecentServersStore()

    var body: some View {
        if sessionStore.isAuthenticated, let serverURL = sessionStore.serverURL {
            AuthenticatedHomeContainer(serverURL: serverURL, onSignOut: { try? sessionStore.signOut() })
        } else {
            ConnectView(viewModel: ConnectViewModel(sessionStore: sessionStore, recentServers: recentServers))
        }
    }
}

#Preview {
    RootView()
}
