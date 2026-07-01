import SwiftUI

struct RootView: View {
    @State private var sessionStore = SessionStore()
    @State private var recentServers = RecentServersStore()

    var body: some View {
        if sessionStore.isAuthenticated {
            VStack(spacing: DocsSpacing.spaceSM) {
                Text("Docs")
                    .font(DocsFont.largeTitle)
                    .foregroundStyle(DocsColor.textPrimary)
                Text("Connected to your documents")
                    .font(DocsFont.body)
                    .foregroundStyle(DocsColor.textSecondary)
            }
            .padding(DocsSpacing.spaceBase)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DocsColor.surfacePage)
        } else {
            ConnectView(viewModel: ConnectViewModel(sessionStore: sessionStore, recentServers: recentServers))
        }
    }
}

#Preview {
    RootView()
}
