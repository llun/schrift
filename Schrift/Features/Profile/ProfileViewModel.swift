import Foundation

@MainActor
@Observable
final class ProfileViewModel {
    var user: CurrentUser?
    var serverVersion: String?
    var isLoading = false

    let client: DocsAPIClient

    init(client: DocsAPIClient) {
        self.client = client
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        // Tolerate failure on either fetch: leave the field nil, show no error banner.
        async let fetchedUser = try? client.currentUser()
        async let fetchedVersion = try? client.serverConfig().version
        user = await fetchedUser
        serverVersion = await fetchedVersion
    }
}
