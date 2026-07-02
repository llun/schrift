import Foundation

extension DocsAPIClient {
    func listChildren(documentID: UUID) async throws -> PaginatedResponse<Document> {
        try await get("documents/\(documentID.uuidString.lowercased())/children/")
    }

    struct CreateChildBody: Encodable {
        let title: String
    }

    func createChild(documentID: UUID, title: String) async throws -> Document {
        let body = try JSONEncoder().encode(CreateChildBody(title: title))
        return try await send(path: "documents/\(documentID.uuidString.lowercased())/children/", method: "POST", body: body)
    }
}
