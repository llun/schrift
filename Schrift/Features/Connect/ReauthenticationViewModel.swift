import Foundation

/// Drives the re-login sheet RootView presents when the server session dies
/// (any request 401s → `SessionStore.needsReauthentication`). Mirrors
/// `ConnectViewModel.handleLoginComplete`: forget whose session this was, confirm
/// the fresh cookies with `GET users/me/`, then `signIn` — which re-persists the
/// session cookies to the Keychain and clears the flag, dismissing the sheet.
///
/// The forget comes first because only it is unconditional; the sheet may have been
/// answered by a different account, and everything after the confirmation is skipped
/// when that one request fails.
@MainActor
@Observable
final class ReauthenticationViewModel {
    var isConfirming = false
    var errorKey: L10nKey?

    let serverURL: URL
    let sessionStore: SessionStore
    private let apiClientFactory: (URL) -> DocsAPIClient

    init(
        serverURL: URL,
        sessionStore: SessionStore,
        apiClientFactory: @escaping (URL) -> DocsAPIClient = { serverURL in
            // Deliberately the default client (no onSessionExpired hook): a
            // still-401 confirmation shows the inline error below instead of
            // re-poking the reauthentication flag mid-flow.
            DocsAPIClient(baseURL: serverURL.appendingPathComponent("api/v1.0/"))
        }
    ) {
        self.serverURL = serverURL
        self.sessionStore = sessionStore
        self.apiClientFactory = apiClientFactory
    }

    func handleLoginComplete() async {
        // Before the confirmation, not after it. The web view has already put this login's
        // cookies in the shared storage, so whoever was signed in a moment ago may no longer be
        // whose session this is — and the confirmation below can fail, leaving a perfectly
        // valid session that never 401s again to correct it. See `noteSessionCookiesReplaced`.
        sessionStore.noteSessionCookiesReplaced()
        isConfirming = true
        errorKey = nil
        defer { isConfirming = false }

        struct Me: Decodable {}
        let client = apiClientFactory(serverURL)
        do {
            let _: Me = try await client.get("users/me/")
            try sessionStore.signIn(serverURL: serverURL)
        } catch {
            errorKey = .reauth_error_sign_in_failed
        }
    }
}
