import SwiftUI

struct ConnectView: View {
    @Bindable var viewModel: ConnectViewModel

    var body: some View {
        VStack(spacing: DocsSpacing.spaceLG) {
            VStack(spacing: DocsSpacing.spaceXS) {
                Image("SchriftLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .shadow(color: DocsColor.brandFill.opacity(0.28), radius: 12, x: 0, y: 8)
                    .padding(.bottom, DocsSpacing.spaceXS)
                Text("Welcome to Schrift")
                    .font(DocsFont.title1)
                    .foregroundStyle(DocsColor.textPrimary)
                Text("Connect to any Schrift server to write, organize and collaborate — in real time.")
                    .font(DocsFont.callout)
                    .foregroundStyle(DocsColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DocsSpacing.spaceMD)
            }

            DocsTextField(
                label: "Schrift server",
                text: $viewModel.serverURLInput,
                placeholder: "schrift.example.org",
                icon: "cloud",
                helper: "The app signs in with your existing session — no password stored."
            )

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.danger)
            }

            DocsButton(title: signInTitle, icon: "arrow.right", fullWidth: true, pill: true, isDisabled: viewModel.isSigningIn) {
                viewModel.startSignIn()
            }

            if viewModel.isSigningIn {
                ProgressView()
            }

            if !viewModel.recentServers.servers.isEmpty {
                ListSection(header: "Recent servers") {
                    ForEach(viewModel.recentServers.servers, id: \.self) { server in
                        ListRow(systemImage: "server.rack", title: server.host ?? server.absoluteString, showsChevron: true, action: {
                            viewModel.selectRecentServer(server)
                        })
                    }
                }
                .disabled(viewModel.isSigningIn)
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
