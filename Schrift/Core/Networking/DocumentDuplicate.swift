import Foundation

struct DuplicatedDocument: Codable, Equatable, Sendable {
    let id: UUID
}

private struct DuplicateRequest: Encodable {
    let withAccesses: Bool
    let withDescendants: Bool

    enum CodingKeys: String, CodingKey {
        case withAccesses = "with_accesses"
        case withDescendants = "with_descendants"
    }
}

extension DocsAPIClient {
    func duplicateDocument(documentID: UUID, withAccesses: Bool = false, withDescendants: Bool = false) async throws
        -> UUID
    {
        let body = try JSONEncoder().encode(
            DuplicateRequest(withAccesses: withAccesses, withDescendants: withDescendants))
        let result: DuplicatedDocument = try await send(
            path: "documents/\(documentID.uuidString.lowercased())/duplicate/", method: "POST", body: body)
        return result.id
    }
}
