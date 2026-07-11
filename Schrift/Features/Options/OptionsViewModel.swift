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
    var errorKey: L10nKey?
    private(set) var didDelete = false

    private let client: DocsAPIClient
    private let documentID: UUID

    init(client: DocsAPIClient, documentID: UUID, isFavorite: Bool) {
        self.client = client
        self.documentID = documentID
        self.isFavorite = isFavorite
    }

    func toggleFavorite() async {
        errorKey = nil
        do {
            try await client.setFavorite(documentID: documentID, isFavorite: !isFavorite)
            isFavorite.toggle()
        } catch {
            errorKey = .options_error_toggle_favorite
        }
    }

    @discardableResult
    func duplicate() async -> UUID? {
        isDuplicating = true
        errorKey = nil
        defer { isDuplicating = false }
        do {
            return try await client.duplicateDocument(documentID: documentID)
        } catch {
            errorKey = .options_error_duplicate
            return nil
        }
    }

    func delete() async {
        isDeleting = true
        errorKey = nil
        do {
            try await client.deleteDocument(documentID: documentID)
            didDelete = true
        } catch {
            errorKey = .options_error_delete
        }
        isDeleting = false
    }
}
