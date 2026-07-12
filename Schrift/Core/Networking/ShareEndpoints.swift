import Foundation

private struct AccessCreateRequest: Encodable {
    let userId: String
    let role: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case role
    }
}

private struct RoleUpdateRequest: Encodable {
    let role: String
}

private struct InvitationCreateRequest: Encodable {
    let email: String
    let role: String
}

private struct LinkConfigurationRequest: Encodable {
    let linkReach: String
    let linkRole: String?

    enum CodingKeys: String, CodingKey {
        case linkReach = "link_reach"
        case linkRole = "link_role"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(linkReach, forKey: .linkReach)
        if let linkRole {
            try container.encode(linkRole, forKey: .linkRole)
        } else {
            try container.encodeNil(forKey: .linkRole)
        }
    }
}

func userSearchPath(query: String, excludingDocumentID: UUID) -> String {
    var components = URLComponents()
    components.queryItems = [
        URLQueryItem(name: "q", value: query),
        URLQueryItem(name: "document_id", value: excludingDocumentID.uuidString.lowercased()),
    ]
    return "users/?" + (components.percentEncodedQuery ?? "")
}

extension DocsAPIClient {
    /// The accesses endpoint's `list` action is **not** paginated: the backend
    /// overrides it to build the ancestor-aware access list by hand and returns a
    /// bare JSON array (`[…]`), not a `{count, results}` envelope. Decoding it as a
    /// `PaginatedResponse` fails on every call — which is why the Share sheet
    /// reported "Couldn't load members" for every document and the Shared tab's
    /// row enrichment silently no-op'd. Decode the bare array directly, like
    /// `searchUsers`. (Invitations *are* paginated — see `listInvitations`.)
    func listAccesses(documentID: UUID) async throws -> [DocumentAccess] {
        try await get("documents/\(documentID.uuidString.lowercased())/accesses/")
    }

    func createAccess(documentID: UUID, userID: UUID, role: DocumentRole) async throws -> DocumentAccess {
        let body = try JSONEncoder().encode(
            AccessCreateRequest(userId: userID.uuidString.lowercased(), role: role.rawValue))
        return try await send(
            path: "documents/\(documentID.uuidString.lowercased())/accesses/", method: "POST", body: body)
    }

    func updateAccess(documentID: UUID, accessID: UUID, role: DocumentRole) async throws -> DocumentAccess {
        let body = try JSONEncoder().encode(RoleUpdateRequest(role: role.rawValue))
        return try await send(
            path: "documents/\(documentID.uuidString.lowercased())/accesses/\(accessID.uuidString.lowercased())/",
            method: "PATCH", body: body)
    }

    func deleteAccess(documentID: UUID, accessID: UUID) async throws {
        try await sendVoid(
            path: "documents/\(documentID.uuidString.lowercased())/accesses/\(accessID.uuidString.lowercased())/",
            method: "DELETE", body: nil)
    }

    func listInvitations(documentID: UUID) async throws -> PaginatedResponse<Invitation> {
        try await get("documents/\(documentID.uuidString.lowercased())/invitations/")
    }

    func createInvitation(documentID: UUID, email: String, role: DocumentRole) async throws -> Invitation {
        let body = try JSONEncoder().encode(InvitationCreateRequest(email: email, role: role.rawValue))
        return try await send(
            path: "documents/\(documentID.uuidString.lowercased())/invitations/", method: "POST", body: body)
    }

    func deleteInvitation(documentID: UUID, invitationID: UUID) async throws {
        try await sendVoid(
            path:
                "documents/\(documentID.uuidString.lowercased())/invitations/\(invitationID.uuidString.lowercased())/",
            method: "DELETE", body: nil)
    }

    func setLinkConfiguration(documentID: UUID, linkReach: LinkReach, linkRole: LinkRole?) async throws
        -> LinkConfiguration
    {
        let body = try JSONEncoder().encode(
            LinkConfigurationRequest(linkReach: linkReach.rawValue, linkRole: linkRole?.rawValue))
        return try await send(
            path: "documents/\(documentID.uuidString.lowercased())/link-configuration/", method: "PUT", body: body)
    }

    func searchUsers(query: String, excludingDocumentID: UUID) async throws -> [UserSearchResult] {
        try await get(userSearchPath(query: query, excludingDocumentID: excludingDocumentID))
    }
}
