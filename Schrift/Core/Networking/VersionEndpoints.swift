import Foundation

/// One entry in a document's version history, as returned by
/// `GET documents/{id}/versions/`. Read-only: the app never PATCHes a version
/// back onto the document (see F4 — deferred). `id` is the server's opaque
/// version identifier, not a UUID.
struct DocumentVersion: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let lastModified: Date
    var isCurrent: Bool

    init(id: String, lastModified: Date, isCurrent: Bool) {
        self.id = id
        self.lastModified = lastModified
        self.isCurrent = isCurrent
    }
}

// The decoder lives in an extension so the memberwise initializer above survives
// (mirrors `Document.swift`). `JSONDecoder.docsAPI` converts snake_case to
// camelCase, so the wire keys `version_id` / `last_modified` / `is_current`
// arrive as `versionId` / `lastModified` / `isCurrent`.
extension DocumentVersion {
    private enum Keys: String, CodingKey {
        case versionId, lastModified, isCurrent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decode(String.self, forKey: .versionId)
        lastModified = try container.decode(Date.self, forKey: .lastModified)
        // Defensive default, mirroring `Document.isFavorite`: a server that omits
        // the flag (e.g. the only version) should not fail decoding.
        isCurrent = try container.decodeIfPresent(Bool.self, forKey: .isCurrent) ?? false
    }
}

private struct DocumentVersionsResponse: Decodable {
    let versions: [DocumentVersion]
}

extension DocsAPIClient {
    func documentVersions(documentID: UUID) async throws -> [DocumentVersion] {
        let response: DocumentVersionsResponse = try await get(
            "documents/\(documentID.uuidString.lowercased())/versions/")
        return response.versions
    }
}
