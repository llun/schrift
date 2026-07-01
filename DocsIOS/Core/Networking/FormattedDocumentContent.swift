import Foundation

struct FormattedDocumentContent: Codable, Equatable, Sendable {
    let id: UUID
    let title: String?
    let content: String?
    let createdAt: Date
    let updatedAt: Date
}

extension DocsAPIClient {
    func formattedContent(documentID: UUID, format: String = "markdown") async throws -> FormattedDocumentContent {
        let path = "documents/\(documentID.uuidString.lowercased())/formatted-content/?content_format=\(format)"
        return try await get(path)
    }
}
