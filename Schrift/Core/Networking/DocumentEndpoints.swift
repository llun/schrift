import Foundation

func documentsListPath(
    isFavorite: Bool? = nil,
    isCreatorMe: Bool? = nil,
    title: String? = nil,
    ordering: String? = nil,
    page: Int? = nil,
    pageSize: Int? = nil
) -> String {
    var items: [URLQueryItem] = []
    if let isFavorite { items.append(URLQueryItem(name: "is_favorite", value: isFavorite ? "true" : "false")) }
    if let isCreatorMe { items.append(URLQueryItem(name: "is_creator_me", value: isCreatorMe ? "true" : "false")) }
    if let title { items.append(URLQueryItem(name: "title", value: title)) }
    if let ordering { items.append(URLQueryItem(name: "ordering", value: ordering)) }
    if let page { items.append(URLQueryItem(name: "page", value: String(page))) }
    if let pageSize { items.append(URLQueryItem(name: "page_size", value: String(pageSize))) }
    return "documents/" + queryStringSuffix(items)
}

func documentsSearchPath(query: String) -> String {
    "documents/search/" + queryStringSuffix([URLQueryItem(name: "q", value: query)])
}

private func queryStringSuffix(_ items: [URLQueryItem]) -> String {
    guard !items.isEmpty else { return "" }
    var components = URLComponents()
    components.queryItems = items
    return "?" + (components.percentEncodedQuery ?? "")
}

extension DocsAPIClient {
    func listDocuments(
        isFavorite: Bool? = nil,
        isCreatorMe: Bool? = nil,
        title: String? = nil,
        ordering: String? = nil,
        page: Int? = nil,
        pageSize: Int? = nil
    ) async throws -> PaginatedResponse<Document> {
        try await get(
            documentsListPath(
                isFavorite: isFavorite,
                isCreatorMe: isCreatorMe,
                title: title,
                ordering: ordering,
                page: page,
                pageSize: pageSize
            ))
    }

    /// A single document's metadata. Resolves a `/docs/<uuid>/` link tapped in document
    /// content into the `Document` the app navigates to. The response carries no `content`
    /// — the pushed editor reads the body through its own content route — so this is a
    /// cheap lookup rather than a second copy of the document.
    func document(documentID: UUID) async throws -> Document {
        try await get("documents/\(documentID.uuidString.lowercased())/")
    }

    func favoriteDocuments() async throws -> PaginatedResponse<Document> {
        try await get("documents/favorite_list/")
    }

    func searchDocuments(query: String) async throws -> PaginatedResponse<Document> {
        try await get(documentsSearchPath(query: query))
    }

    func setFavorite(documentID: UUID, isFavorite: Bool) async throws {
        let path = "documents/\(documentID.uuidString.lowercased())/favorite/"
        try await sendVoid(path: path, method: isFavorite ? "POST" : "DELETE", body: nil)
    }
}
