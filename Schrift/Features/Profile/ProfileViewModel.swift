import Foundation

@MainActor
@Observable
final class ProfileViewModel {
    var user: CurrentUser?
    var isLoading = false
    var errorMessage: String?

    let client: DocsAPIClient

    init(client: DocsAPIClient) {
        self.client = client
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        // Tolerate failure: leave user nil, show no error banner.
        user = try? await client.currentUser()
    }
}
