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
    private let serverCapabilities: ServerCapabilityStore
    private let serverConfigStore: ServerConfigStore
    private let apiClientFactory: (URL) -> DocsAPIClient
    private let pendingWebDataClear: () -> Task<Void, Never>?
    private var presentWebLoginTask: Task<Void, Never>?

    init(
        sessionStore: SessionStore,
        recentServers: RecentServersStore,
        serverCapabilities: ServerCapabilityStore = ServerCapabilityStore(),
        serverConfigStore: ServerConfigStore = ServerConfigStore(),
        apiClientFactory: @escaping (URL) -> DocsAPIClient = { serverURL in
            DocsAPIClient(baseURL: serverURL.appendingPathComponent("api/v1.0/"))
        },
        pendingWebDataClear: @escaping () -> Task<Void, Never>? = { pendingWebLoginDataClear }
    ) {
        self.pendingWebDataClear = pendingWebDataClear
        self.sessionStore = sessionStore
        self.recentServers = recentServers
        self.serverCapabilities = serverCapabilities
        self.serverConfigStore = serverConfigStore
        self.apiClientFactory = apiClientFactory
    }

    func startSignIn() {
        presentWebLoginTask?.cancel()
        guard let url = normalizedServerURL(from: serverURLInput) else {
            errorKey = .connect_error_invalid_server
            return
        }
        errorKey = nil
        pendingServerURL = url
        presentWebLogin()
    }

    func selectRecentServer(_ url: URL) {
        errorKey = nil
        pendingServerURL = url
        presentWebLogin()
    }

    /// After every wipe of the web view's store still under way (a sign-out a moment ago, and
    /// any chained behind it); a later tap replaces an earlier wait.
    private func presentWebLogin() {
        presentWebLoginTask?.cancel()
        guard pendingWebDataClear() != nil else {
            isPresentingWebLogin = true
            return
        }
        presentWebLoginTask = Task {
            var awaited: Task<Void, Never>?
            while let clear = pendingWebDataClear(), clear != awaited {
                awaited = clear
                await clear.value
            }
            guard !Task.isCancelled else { return }
            isPresentingWebLogin = true
        }
    }

    /// The web login is about to write its cookies (PR13a review W1).
    func cookiesWillChange() {
        sessionStore.noteSessionCookiesWillChange()
    }

    func handleLoginComplete() async {
        isPresentingWebLogin = false
        // The same handover the re-login sheet makes: this login's cookies are already live in
        // the shared storage, whatever the confirmation below does. A sign-out has normally
        // emptied the identity stores long before anyone reaches this screen, so there is
        // usually nothing to forget — but the rule belongs to the cookie handover, not to
        // whichever path happened to precede it. See `SessionStore.noteSessionCookiesReplaced`.
        sessionStore.noteSessionCookiesReplaced()
        guard let serverURL = pendingServerURL else { return }

        isSigningIn = true
        errorKey = nil
        defer { isSigningIn = false }

        let client = apiClientFactory(serverURL)
        do {
            let userID = try await client.confirmSession()
            // Schrift supports only Docs 6+ servers, so learn the capability before signing in:
            // a pre-Docs 6 server is refused here rather than failing request by request later.
            // A fetch that proves nothing (offline, 5xx, undecodable) is *unknown*, never
            // legacy — it signs in normally and the launch gate re-checks next time.
            let configResult = await fetchServerConfig(client)
            let capability = serverCapability(from: configResult)
            if let origin = siteOrigin(for: serverURL) {
                // Keep the whole config, not just the capability: the native editor's offline
                // create needs the collaboration org, and RootView's hook only fills it later.
                if case .success(let config) = configResult {
                    serverConfigStore.remember(config, forServerOrigin: origin)
                }
                // An answer that proves nothing also clears a stale cached legacy: the user just
                // proved the server answers, so the launch gate must not block them on old news.
                if let capability {
                    serverCapabilities.record(capability, forServerOrigin: origin)
                } else {
                    serverCapabilities.clear(forServerOrigin: origin)
                }
            }
            // Refused exactly as a failed confirmation leaves things: no sign-in, the error
            // shown, and the handed-over cookies left unpersisted in the shared storage (only
            // `signIn` writes them to the Keychain), so a retry can reuse the IdP's session.
            guard capability != .legacy else {
                errorKey = .server_unsupported
                return
            }
            try sessionStore.signIn(serverURL: serverURL, userID: userID)
            recentServers.addServer(serverURL)
        } catch {
            errorKey = .connect_error_sign_in_failed
        }
    }

    /// The config fetch as a value, so a failure is *unknown* rather than a failed sign-in.
    private func fetchServerConfig(_ client: DocsAPIClient) async -> Result<ServerConfig, any Error> {
        do {
            return .success(try await client.serverConfig())
        } catch {
            return .failure(error)
        }
    }
}
