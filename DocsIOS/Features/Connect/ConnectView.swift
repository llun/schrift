import SwiftUI

struct ConnectView: View {
    @Bindable var viewModel: ConnectViewModel

    var body: some View {
        VStack(spacing: DocsSpacing.spaceLG) {
            VStack(spacing: DocsSpacing.spaceXS) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(DocsColor.brandFill)
                Text("Welcome to Docs")
                    .font(DocsFont.title1)
                    .foregroundStyle(DocsColor.textPrimary)
            }

            DocsTextField(label: "Server", text: $viewModel.serverURLInput, placeholder: "docs.example.com")

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.danger)
            }

            DocsButton(title: signInTitle, fullWidth: true) {
                viewModel.startSignIn()
            }

            if !viewModel.recentServers.servers.isEmpty {
                ListSection(header: "Recent servers") {
                    ForEach(viewModel.recentServers.servers, id: \.self) { server in
                        ListRow(systemImage: "clock", title: server.host ?? server.absoluteString, action: {
                            viewModel.selectRecentServer(server)
                        })
                    }
                }
            }

            Spacer()
        }
        .padding(DocsSpacing.spaceBase)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DocsColor.surfacePage)
        .sheet(isPresented: $viewModel.isPresentingWebLogin) {
            if let url = viewModel.pendingServerURL {
                WebLoginView(
                    url: authenticationURL(server: url),
                    serverHost: url.host ?? "",
                    onLoginComplete: {
                        Task { await viewModel.handleLoginComplete() }
                    }
                )
            }
        }
    }

    private var signInTitle: String {
        if let host = normalizedServerURL(from: viewModel.serverURLInput)?.host {
            return "Sign in to \(host)"
        }
        return "Sign in"
    }
}

#Preview {
    ConnectView(viewModel: ConnectViewModel(sessionStore: SessionStore(), recentServers: RecentServersStore()))
}
