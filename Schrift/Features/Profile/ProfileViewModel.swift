import Foundation

@MainActor
@Observable
final class ProfileViewModel {
    var user: CurrentUser?
    var serverVersion: String?
    var isLoading = false

    let client: DocsAPIClient
    private let signedInUser: SignedInUserStore

    init(client: DocsAPIClient, signedInUser: SignedInUserStore = SignedInUserStore()) {
        self.client = client
        self.signedInUser = signedInUser
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        // Tolerate failure on either fetch: leave the field nil, show no error banner.
        async let fetchedUser = try? client.currentUser()
        async let fetchedVersion = try? client.serverConfig().version
        user = await fetchedUser
        serverVersion = await fetchedVersion
        // Keep the persisted account id fresh from the one screen that fetches the user on
        // every visit. Offline document creation cannot mint or list a record without it, and
        // this is a free refresh on a fetch the screen already makes.
        signedInUser.remember(user?.id)
    }
}
