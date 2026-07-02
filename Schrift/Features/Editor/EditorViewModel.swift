import Foundation

@MainActor
@Observable
final class EditorViewModel {
    var title: String
    var blocks: [MarkdownBlock] = []
    var rawMarkdown: String = ""
    var subpages: [Document] = []
    var updatedAt: Date? = nil
    var isEditing = false
    var isLoading = false
    var isSaving = false
    var errorMessage: String?

    let client: DocsAPIClient
    let documentID: UUID
    private var savedMarkdown: String = ""

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
            savedMarkdown = formatted.content ?? ""
            rawMarkdown = savedMarkdown
            blocks = parseMarkdownBlocks(savedMarkdown)
            updatedAt = formatted.updatedAt
            await loadChildren()
        } catch {
            errorMessage = "Couldn't load this document. Pull to refresh to try again."
        }
        isLoading = false
    }

    func loadChildren() async {
        subpages = (try? await client.listChildren(documentID: documentID))?.results ?? []
    }

    func addSubpage() async -> Document? {
        try? await client.createChild(documentID: documentID, title: "Untitled subpage")
    }

    func startEditing() {
        isEditing = true
        errorMessage = nil
    }

    func cancelEditing() {
        rawMarkdown = savedMarkdown
        isEditing = false
        errorMessage = nil
    }

    func save() async {
        isSaving = true
        errorMessage = nil
        do {
            try await client.saveDocumentContent(documentID: documentID, title: title, markdown: rawMarkdown)
            savedMarkdown = rawMarkdown
            blocks = parseMarkdownBlocks(rawMarkdown)
            isEditing = false
        } catch {
            errorMessage = "Couldn't save changes. Please try again."
        }
        isSaving = false
    }
}
