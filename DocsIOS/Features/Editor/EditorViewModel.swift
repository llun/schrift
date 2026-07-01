import Foundation

@MainActor
@Observable
final class EditorViewModel {
    var title: String
    var blocks: [MarkdownBlock] = []
    var isLoading = false
    var errorMessage: String?

    private let client: DocsAPIClient
    private let documentID: UUID

    init(client: DocsAPIClient, documentID: UUID, title: String) {
        self.client = client
        self.documentID = documentID
        self.title = title
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let formatted = try await client.formattedContent(documentID: documentID)
            if let fetchedTitle = formatted.title {
                title = fetchedTitle
            }
            blocks = parseMarkdownBlocks(formatted.content ?? "")
        } catch {
            errorMessage = "Couldn't load this document. Pull to refresh to try again."
        }
        isLoading = false
    }
}
