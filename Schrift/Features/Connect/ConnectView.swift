import SwiftUI

struct ConnectView: View {
    @Bindable var viewModel: ConnectViewModel
    @Environment(LocalizationStore.self) private var loc

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
                    .accessibilityHidden(true)
                Text(loc[.connect_hero_title])
                    .font(DocsFont.title1)
                    .foregroundStyle(DocsColor.textPrimary)
                Text(loc[.connect_hero_subtitle])
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
                    label: loc[.connect_server_label],
                    text: $viewModel.serverURLInput,
                    placeholder: loc[.connect_server_placeholder],
                    icon: .cloud,
                    helper: loc[.connect_server_helper],
                    error: viewModel.errorKey.map { loc[$0] }
                )
                // Without this, iOS capitalizes the first letter and offers to autocorrect
                // the hostname. `normalizedServerURL` lowercases it anyway, but the user
                // should not have to watch it fight their keyboard.
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

                DocsButton(
                    title: signInTitle, size: .large, icon: .login, fullWidth: true,
                    pill: true, isDisabled: viewModel.isSigningIn
                ) {
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
            Text(loc[.connect_recent_servers])
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
                        MaterialSymbol(.dns, size: 20)
                            .foregroundStyle(DocsColor.textTertiary)
                        Text(server.host ?? server.absoluteString)
                            .font(DocsFont.subhead)
                            .foregroundStyle(DocsColor.textPrimary)
                        Spacer()
                        MaterialSymbol(.chevron_right, size: 18)
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
            return loc.format(.connect_sign_in_to, host)
        }
        return loc[.connect_sign_in]
    }
}

#Preview {
    ConnectView(viewModel: ConnectViewModel(sessionStore: SessionStore(), recentServers: RecentServersStore()))
        .environment(LocalizationStore())
}
