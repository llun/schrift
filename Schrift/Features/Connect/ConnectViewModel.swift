import Foundation

@MainActor
@Observable
final class ConnectViewModel {
    var serverURLInput: String = ""
    var isPresentingWebLogin = false
    var isSigningIn = false
    var errorKey: L10nKey?
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
            errorKey = .connect_error_invalid_server
            return
        }
        errorKey = nil
        pendingServerURL = url
        isPresentingWebLogin = true
    }

    func selectRecentServer(_ url: URL) {
        errorKey = nil
        pendingServerURL = url
        isPresentingWebLogin = true
    }

    func handleLoginComplete() async {
        isPresentingWebLogin = false
        guard let serverURL = pendingServerURL else { return }

        isSigningIn = true
        errorKey = nil
        defer { isSigningIn = false }

        struct Me: Decodable {}
        let client = apiClientFactory(serverURL)
        do {
            let _: Me = try await client.get("users/me/")
            try sessionStore.signIn(serverURL: serverURL)
            recentServers.addServer(serverURL)
        } catch {
            errorKey = .connect_error_sign_in_failed
        }
    }
}
