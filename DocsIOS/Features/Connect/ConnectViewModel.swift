import Foundation

@MainActor
@Observable
final class ConnectViewModel {
    var serverURLInput: String = ""
    var isPresentingWebLogin = false
    var isSigningIn = false
    var errorMessage: String?
    private(set) var pendingServerURL: URL?

    let sessionStore: SessionStore
    let recentServers: RecentServersStore
    private let apiClientFactory: (URL) -> DocsAPIClient

    init(
        sessionStore: SessionStore,
        recentServers: RecentServersStore,
        apiClientFactory: @escaping (URL) -> DocsAPIClient = { serverURL in
            DocsAPIClient(baseURL: serverURL.appendingPathComponent("api/v1.0/"))
        }
    ) {
        self.sessionStore = sessionStore
        self.recentServers = recentServers
        self.apiClientFactory = apiClientFactory
    }

    func startSignIn() {
        guard let url = normalizedServerURL(from: serverURLInput) else {
            errorMessage = "Enter a valid server address."
            return
        }
        errorMessage = nil
        pendingServerURL = url
        isPresentingWebLogin = true
    }

    func selectRecentServer(_ url: URL) {
        errorMessage = nil
        pendingServerURL = url
        isPresentingWebLogin = true
    }

    func handleLoginComplete() async {
        isPresentingWebLogin = false
        guard let serverURL = pendingServerURL else { return }

        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }

        struct Me: Decodable {}
        let client = apiClientFactory(serverURL)
        do {
            let _: Me = try await client.get("users/me/")
            try sessionStore.signIn(serverURL: serverURL)
            recentServers.addServer(serverURL)
        } catch {
            errorMessage = "Sign-in could not be confirmed. Please try again."
        }
    }
}
