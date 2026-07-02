import SwiftUI

struct ConnectView: View {
    @Bindable var viewModel: ConnectViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Hero — vertically centered in the space above the form.
            VStack(spacing: DocsSpacing.space3xs) {
                Image("SchriftLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .shadow(color: DocsColor.brandLogo.opacity(0.28), radius: 12, x: 0, y: 8)
                    .padding(.bottom, DocsSpacing.spaceBase + DocsSpacing.space4xs)
                Text("Welcome to Schrift")
                    .font(DocsFont.title1)
                    .foregroundStyle(DocsColor.textPrimary)
                Text("Connect to any server to write, organize and collaborate — in real time.")
                    .font(DocsFont.callout)
                    .foregroundStyle(DocsColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.top, DocsSpacing.space2xs)
                    .padding(.horizontal, DocsSpacing.spaceMD)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Form group — pinned to the bottom.
            VStack(spacing: 14) {
                DocsTextField(
                    label: "Server",
                    text: $viewModel.serverURLInput,
                    placeholder: "schrift.example.org",
                    icon: "cloud",
                    helper: "The app signs in with your existing session — no password stored."
                )

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(DocsFont.footnote)
                        .foregroundStyle(DocsColor.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                DocsButton(title: signInTitle, size: .large, icon: "rectangle.portrait.and.arrow.right", fullWidth: true, pill: true, isDisabled: viewModel.isSigningIn) {
                    viewModel.startSignIn()
                }

                if viewModel.isSigningIn {
                    ProgressView()
                }

                if !viewModel.recentServers.servers.isEmpty {
                    recentServers
                }
            }
            .padding(.bottom, DocsSpacing.spaceXS)
        }
        .padding(.horizontal, DocsSpacing.spaceMD)
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

    private var recentServers: some View {
        VStack(alignment: .leading, spacing: DocsSpacing.space2xs) {
            Text("Recent servers")
                .font(DocsFont.caption)
                .textCase(.uppercase)
                .tracking(DocsTypographySpec.caption.size * DocsTracking.eyebrow)
                .foregroundStyle(DocsColor.textTertiary)
                .padding(.leading, DocsSpacing.space3xs)

            ForEach(viewModel.recentServers.servers, id: \.self) { server in
                Button {
                    viewModel.selectRecentServer(server)
                } label: {
                    HStack(spacing: DocsSpacing.space2xs + DocsSpacing.space3xs) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 20))
                            .foregroundStyle(DocsColor.textTertiary)
                        Text(server.host ?? server.absoluteString)
                            .font(DocsFont.subhead)
                            .foregroundStyle(DocsColor.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 16))
                            .foregroundStyle(DocsColor.gray300)
                    }
                    .padding(.horizontal, DocsSpacing.spaceSM)
                    .padding(.vertical, 10)
                    .background(DocsColor.surfaceSunken)
                    .clipShape(RoundedRectangle(cornerRadius: DocsRadius.md))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(viewModel.isSigningIn)
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
