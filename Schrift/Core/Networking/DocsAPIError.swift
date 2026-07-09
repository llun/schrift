import Foundation

enum DocsAPIError: Error, Equatable {
    case sessionExpired
    case forbidden
    case notFound
    /// A 404 for the **route**, not the object: Django serves a plain HTML page when no view
    /// is registered for the path (and a reverse proxy does the same when it swallows one).
    /// Deliberately *not* `.notFound`, which every caller reads as "this document was
    /// deleted" — a missing route is not evidence about any document.
    case routeNotFound
    case rateLimited(retryAfter: TimeInterval?)
    case network(String)
    case decoding(String)
    case server(statusCode: Int)
}

enum DocsAPIErrorMapper {
    static func map(statusCode: Int, headers: [String: String]) -> DocsAPIError {
        switch statusCode {
        case 401:
            return .sessionExpired
        case 403:
            return .forbidden
        case 404:
            // DRF answers a missing *object* with JSON (`{"detail": "Not found."}`); Django
            // answers a missing *route* with its HTML 404 page. Only positive evidence of
            // HTML downgrades to `.routeNotFound` — an empty or unlabelled 404 stays
            // `.notFound`, because the delete and cache-purge paths key off it and must not
            // silently stop firing.
            return isHTML(headers) ? .routeNotFound : .notFound
        case 429:
            let retryAfter = headers["Retry-After"].flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retryAfter)
        default:
            return .server(statusCode: statusCode)
        }
    }

    /// HTTP header names are case-insensitive, and `HTTPURLResponse` does not normalize them.
    private static func isHTML(_ headers: [String: String]) -> Bool {
        headers
            .first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?
            .value.lowercased().contains("html") ?? false
    }
}
