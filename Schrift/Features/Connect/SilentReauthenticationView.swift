import SwiftUI

/// How long a silent re-login may run before the sheet takes over, however it is going.
let silentReauthenticationTimeout: Duration = .seconds(15)

/// How long a page the hidden login stopped on (`onStoppedBeforeLogin`) gets before the
/// sheet takes over. Not zero, because an IdP answering with `response_mode=form_post`
/// finishes loading a page whose script then submits it back to the server — a page that
/// looks stopped and is not. A real login form never moves on by itself.
let silentReauthenticationStopGrace: Duration = .seconds(2)

/// The silent half of re-authentication: the same OIDC web login the re-login sheet hosts,
/// mounted invisibly behind the app while `SessionStore.isSilentlyReauthenticating`.
///
/// The login web view shares `WKWebsiteDataStore.default()` with the sheet, so when the
/// identity provider still remembers the user the whole redirect chain completes without
/// any input — and that is the common case on launch, when only the server's own session
/// has lapsed. Presenting that as a sheet put a login popup on screen that closed itself a
/// moment later; running it here keeps the app's cached content on screen throughout.
///
/// Anything that cannot finish unattended — the chain stops on the IdP's login form, a load
/// fails, the confirming `/users/me/` fails, or it simply runs out of time — escalates to the
/// sheet (`SessionStore.escalateReauthentication`), which is exactly what every 401 used to
/// show. Confirmation and persistence are `ReauthenticationViewModel`'s, unchanged, so a
/// silent sign-in forgets and re-learns the account exactly as the sheet does.
struct SilentReauthenticationView: View {
    @State private var viewModel: ReauthenticationViewModel
    @State private var stopGrace: Task<Void, Never>?
    let onAuthenticated: () -> Void

    init(serverURL: URL, sessionStore: SessionStore, onAuthenticated: @escaping () -> Void) {
        _viewModel = State(initialValue: ReauthenticationViewModel(serverURL: serverURL, sessionStore: sessionStore))
        self.onAuthenticated = onAuthenticated
    }

    var body: some View {
        WebLoginView(
            url: authenticationURL(server: viewModel.serverURL),
            serverHost: viewModel.serverURL.host ?? "",
            onLoginComplete: {
                stopGrace?.cancel()
                Task {
                    await viewModel.handleLoginComplete()
                    if viewModel.errorKey == nil {
                        onAuthenticated()
                    } else {
                        viewModel.sessionStore.escalateReauthentication()
                    }
                }
            },
            onStoppedBeforeLogin: {
                stopGrace?.cancel()
                stopGrace = Task {
                    try? await Task.sleep(for: silentReauthenticationStopGrace)
                    guard !Task.isCancelled, !viewModel.isConfirming else { return }
                    viewModel.sessionStore.escalateReauthentication()
                }
            }
        )
        // Laid out (a web view with no size may never be scheduled to load) but never seen,
        // touched or read aloud.
        .frame(width: 1, height: 1)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            try? await Task.sleep(for: silentReauthenticationTimeout)
            guard !Task.isCancelled, !viewModel.isConfirming else { return }
            viewModel.sessionStore.escalateReauthentication()
        }
        .onDisappear { stopGrace?.cancel() }
    }
}
