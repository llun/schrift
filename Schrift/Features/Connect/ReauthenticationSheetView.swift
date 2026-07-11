import SwiftUI

/// Sheet presented over the signed-in app when the server session has expired
/// (`SessionStore.needsReauthentication`). Hosts the same OIDC web login as
/// first sign-in — `WKWebsiteDataStore.default()` still holds the IdP's own
/// cookies, so this often completes without any typing — then confirms and
/// re-persists the session via `ReauthenticationViewModel`.
struct ReauthenticationSheetView: View {
    // Built once in init and held in @State so a parent body re-evaluation
    // while the sheet is open (e.g. an iPad size-class change mid-login) can't
    // rebuild the VM and reset its transient isConfirming/errorKey or the
    // embedded WebLoginView's progress. Dismiss removes the view, so the next
    // 401 re-presents with a fresh VM.
    @State private var viewModel: ReauthenticationViewModel
    let onAuthenticated: () -> Void
    let onCancel: () -> Void
    @Environment(LocalizationStore.self) private var loc

    init(
        serverURL: URL,
        sessionStore: SessionStore,
        onAuthenticated: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        _viewModel = State(initialValue: ReauthenticationViewModel(serverURL: serverURL, sessionStore: sessionStore))
        self.onAuthenticated = onAuthenticated
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            ZStack {
                WebLoginView(
                    url: authenticationURL(server: viewModel.serverURL),
                    serverHost: viewModel.serverURL.host ?? "",
                    onLoginComplete: {
                        Task {
                            await viewModel.handleLoginComplete()
                            if viewModel.errorKey == nil {
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
                if let errorKey = viewModel.errorKey {
                    Text(loc[errorKey])
                        .font(DocsFont.footnote)
                        .foregroundStyle(DocsColor.danger)
                        .padding(DocsSpacing.spaceSM)
                        .frame(maxWidth: .infinity)
                        .background(DocsColor.surfacePage)
                }
            }
            .navigationTitle(loc[.reauth_title])
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc[.common_cancel], action: onCancel)
                }
            }
        }
        .interactiveDismissDisabled(viewModel.isConfirming)
    }
}

#Preview {
    ReauthenticationSheetView(
        serverURL: URL(string: "https://docs.example.org")!,
        sessionStore: SessionStore(),
        onAuthenticated: {},
        onCancel: {}
    )
    .environment(LocalizationStore())
}
