import SwiftUI

/// The silent half of re-authentication: the same OIDC web login the re-login sheet hosts,
/// mounted invisibly behind the app while `SessionStore.isSilentlyReauthenticating`.
///
/// The login web view shares `WKWebsiteDataStore.default()` with the sheet, so when the
/// identity provider still remembers the user the whole redirect chain completes without
/// any input — and that is the common case on launch, when only the server's own session
/// has lapsed. Presenting that as a sheet put a login popup on screen that closed itself a
/// moment later; running it here keeps the app's cached content on screen throughout.
///
/// Anything that cannot finish unattended escalates to the sheet; when is
/// `SilentReauthenticationAttempt`'s decision, and the escalation names this attempt so a
/// leftover task can never escalate a later one. Confirmation and persistence are
/// `ReauthenticationViewModel`'s, unchanged, so a silent sign-in forgets and re-learns the
/// account exactly as the sheet does.
struct SilentReauthenticationView: View {
    @State private var viewModel: ReauthenticationViewModel
    @State private var attempt: SilentReauthenticationAttempt
    @Environment(\.scenePhase) private var scenePhase
    let onAuthenticated: () -> Void

    init(serverURL: URL, sessionStore: SessionStore, onAuthenticated: @escaping () -> Void) {
        _viewModel = State(initialValue: ReauthenticationViewModel(serverURL: serverURL, sessionStore: sessionStore))
        let attemptID = sessionStore.reauthenticationAttempt
        _attempt = State(
            initialValue: SilentReauthenticationAttempt(escalate: { [weak sessionStore] in
                sessionStore?.escalateReauthentication(attempt: attemptID)
            }))
        self.onAuthenticated = onAuthenticated
    }

    var body: some View {
        WebLoginView(
            url: authenticationURL(server: viewModel.serverURL),
            serverHost: viewModel.serverURL.host ?? "",
            onLoginComplete: {
                Task {
                    await viewModel.handleLoginComplete()
                    let succeeded = viewModel.errorKey == nil
                    attempt.confirmationFinished(succeeded: succeeded)
                    if succeeded { onAuthenticated() }
                }
            },
            onProgress: { attempt.handle($0) }
        )
        // Laid out (a web view with no size may never be scheduled to load) but never seen,
        // touched or read aloud. Transparency, not `isHidden`/`.hidden()`: WebKit throttles a
        // hidden view's page, and this page has to keep running its redirects and scripts.
        .frame(width: 1, height: 1)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onDisappear { attempt.cancel() }
        // `initial`: an attempt that begins while the scene is already backgrounded (a 401
        // landing as the app leaves) starts paused instead of timing out while suspended.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { attempt.resume() } else { attempt.pause() }
        }
    }
}
