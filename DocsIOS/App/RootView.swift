import SwiftUI

struct RootView: View {
    @State private var sessionStore = SessionStore()
    @State private var recentServers = RecentServersStore()

    var body: some View {
        if sessionStore.isAuthenticated, let serverURL = sessionStore.serverURL {
            HomeView(
                viewModel: HomeViewModel(client: DocsAPIClient(baseURL: serverURL.appendingPathComponent("api/v1.0/"))),
                serverHost: serverURL.host ?? ""
            )
        } else {
            ConnectView(viewModel: ConnectViewModel(sessionStore: sessionStore, recentServers: recentServers))
        }
    }
}

#Preview {
    RootView()
}
