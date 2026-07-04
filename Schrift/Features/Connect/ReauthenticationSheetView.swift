import SwiftUI

/// Sheet presented over the signed-in app when the server session has expired
/// (`SessionStore.needsReauthentication`). Hosts the same OIDC web login as
/// first sign-in — `WKWebsiteDataStore.default()` still holds the IdP's own
/// cookies, so this often completes without any typing — then confirms and
/// re-persists the session via `ReauthenticationViewModel`.
struct ReauthenticationSheetView: View {
    @Bindable var viewModel: ReauthenticationViewModel
    let onAuthenticated: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                WebLoginView(
                    url: authenticationURL(server: viewModel.serverURL),
                    serverHost: viewModel.serverURL.host ?? "",
                    onLoginComplete: {
                        Task {
                            await viewModel.handleLoginComplete()
                            if viewModel.errorMessage == nil {
                                onAuthenticated()
                            }
                        }
                    }
                )

                if viewModel.isConfirming {
                    ProgressView()
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(DocsFont.footnote)
                        .foregroundStyle(DocsColor.danger)
                        .padding(DocsSpacing.spaceSM)
                        .frame(maxWidth: .infinity)
                        .background(DocsColor.surfacePage)
                }
            }
            .navigationTitle("Session expired")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
        .interactiveDismissDisabled(viewModel.isConfirming)
    }
}

#Preview {
    ReauthenticationSheetView(
        viewModel: ReauthenticationViewModel(
            serverURL: URL(string: "https://docs.example.org")!,
            sessionStore: SessionStore()
        ),
        onAuthenticated: {},
        onCancel: {}
    )
}
