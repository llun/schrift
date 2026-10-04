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

/// Docs 5.7.0 renamed the favorites action; compare numeric release components rather
/// than strings (5.10 is newer than 5.7). Tagged, prerelease, and build-suffixed versions
/// use the same API as their core release. Unknown versions require a route probe.
func favoriteDocumentsPath(serverVersion: String?) -> String? {
    guard let version = serverVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
        version.range(
            of: #"^v?[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"#,
            options: .regularExpression) != nil
    else { return nil }
    let core = version.drop(while: { $0 == "v" }).prefix(while: { $0 != "-" && $0 != "+" })
    let components = core.split(separator: ".").compactMap { Int($0) }
    guard components.count == 3 else { return nil }
    let usesNewRoute = components[0] > 5 || (components[0] == 5 && components[1] >= 7)
    return usesNewRoute ? "documents/favorites/" : "documents/favorite_list/"
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
        let path: String
        if let favoriteListPath {
            path = favoriteListPath
        } else {
            let config: ServerConfig?
            do {
                config = try await serverConfig()
            } catch DocsAPIError.sessionExpired {
                // The shared client has already raised reauthentication. Never hide a 401
                // behind compatibility probing, even though config is normally public.
                throw DocsAPIError.sessionExpired
            } catch {
                // Older/custom deployments may not expose config. Its availability must
                // not prevent a favorites read; a 404 below can identify the other route.
                config = nil
            }
            path = favoriteDocumentsPath(serverVersion: config?.version) ?? "documents/favorite_list/"
        }

        let page: PaginatedResponse<Document>
        do {
            page = try await get(path)
        } catch let error as DocsAPIError where error == .notFound || error == .routeNotFound {
            // A collection GET has no document to delete. DRF may resolve an unregistered
            // action as a detail lookup and return a JSON 404, so both 404 forms qualify.
            // One alternate GET supports unknown releases and deployments with backports;
            // auth, permission, rate-limit, transport, decoding, and 5xx errors propagate.
            favoriteListPath = nil
            let alternate = path == "documents/favorites/" ? "documents/favorite_list/" : "documents/favorites/"
            page = try await get(alternate)
            favoriteListPath = alternate
            return page
        }
        favoriteListPath = path
        return page
    }

    func searchDocuments(query: String) async throws -> PaginatedResponse<Document> {
        try await get(documentsSearchPath(query: query))
    }

    func setFavorite(documentID: UUID, isFavorite: Bool) async throws {
        let path = "documents/\(documentID.uuidString.lowercased())/favorite/"
        try await sendVoid(path: path, method: isFavorite ? "POST" : "DELETE", body: nil)
    }
}
