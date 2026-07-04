import Foundation

/// Drives the re-login sheet RootView presents when the server session dies
/// (any request 401s → `SessionStore.needsReauthentication`). Mirrors
/// `ConnectViewModel.handleLoginComplete`: confirm the fresh cookies with
/// `GET users/me/`, then `signIn` — which re-persists the session cookies to
/// the Keychain and clears the flag, dismissing the sheet.
@MainActor
@Observable
final class ReauthenticationViewModel {
    var isConfirming = false
    var errorMessage: String?

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
        isConfirming = true
        errorMessage = nil
        defer { isConfirming = false }

        struct Me: Decodable {}
        let client = apiClientFactory(serverURL)
        do {
            let _: Me = try await client.get("users/me/")
            try sessionStore.signIn(serverURL: serverURL)
        } catch {
            errorMessage = "Sign-in could not be confirmed. Please try again."
        }
    }
}
