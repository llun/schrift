import Foundation

@MainActor
@Observable
final class SharedViewModel {
    enum Scope {
        case withMe
        case byMe
    }

    var scope: Scope = .withMe
    var sharedWithMe: [Document] = []
    var sharedByMe: [Document] = []
    var isLoading = false
    var errorMessage: String?

    let client: DocsAPIClient

    init(client: DocsAPIClient) {
        self.client = client
    }

    var documents: [Document] {
        scope == .withMe ? sharedWithMe : sharedByMe
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let withMe = try await client.listDocuments(isCreatorMe: false, ordering: "-updated_at").results
            let byMe = try await client.listDocuments(isCreatorMe: true, ordering: "-updated_at").results
            sharedWithMe = withMe
            sharedByMe = byMe
        } catch {
            errorMessage = "Could not load shared documents. Check your connection and try again."
        }
    }
}
