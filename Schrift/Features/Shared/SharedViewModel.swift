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

        // Load each scope independently so a failure in one doesn't discard the
        // other's results (partial success is kept).
        var failed = false
        do {
            sharedWithMe = try await client.listDocuments(isCreatorMe: false, ordering: "-updated_at").results
        } catch {
            failed = true
        }
        do {
            sharedByMe = try await client.listDocuments(isCreatorMe: true, ordering: "-updated_at").results
        } catch {
            failed = true
        }
        if failed {
            errorMessage = "Could not load shared documents. Check your connection and try again."
        }
    }
}
