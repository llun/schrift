import Foundation

func documentShareURL(serverHost: String, documentID: UUID) -> URL? {
    URL(string: "https://\(serverHost)/docs/\(documentID.uuidString.lowercased())/")
}

@MainActor
@Observable
final class OptionsViewModel {
    var isFavorite: Bool
    var isDuplicating = false
    var isDeleting = false
    var errorMessage: String?
    private(set) var didDelete = false

    private let client: DocsAPIClient
    private let documentID: UUID

    init(client: DocsAPIClient, documentID: UUID, isFavorite: Bool) {
        self.client = client
        self.documentID = documentID
        self.isFavorite = isFavorite
    }

    func toggleFavorite() async {
        errorMessage = nil
        do {
            try await client.setFavorite(documentID: documentID, isFavorite: !isFavorite)
            isFavorite.toggle()
        } catch {
            errorMessage = "Couldn't update favorite. Please try again."
        }
    }

    @discardableResult
    func duplicate() async -> UUID? {
        isDuplicating = true
        errorMessage = nil
        defer { isDuplicating = false }
        do {
            return try await client.duplicateDocument(documentID: documentID)
        } catch {
            errorMessage = "Couldn't duplicate document. Please try again."
            return nil
        }
    }

    func delete() async {
        isDeleting = true
        errorMessage = nil
        do {
            try await client.deleteDocument(documentID: documentID)
            didDelete = true
        } catch {
            errorMessage = "Couldn't delete document. Please try again."
        }
        isDeleting = false
    }
}
