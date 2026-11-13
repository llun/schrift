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
    /// The payload is a `safeErrorSummary` (never a raw `DecodingError` description, which embeds
    /// the server's values); the save-failure alert quotes it.
    case decoding(String)
    case server(statusCode: Int)
}

/// How the native write gate reads a `documents/{id}/` answer (PR13b review R1), shared by the
/// editor open (`NativeEditorOpen.serverAbility`) and the headless media gate
/// (`DocumentSaveCoordinator.nativeMayWrite`).
///
/// Only the server's own answer about the document is evidence: a 403, an API 404, and a decoded
/// body that says `abilities.update == false` or names another document. Everything else — a
/// missing route (an HTML 404 from a proxy during a rollout), an unreadable body, a timeout, a
/// 408, a 5xx, offline, an expired session — is **no answer**: the row and any earlier answer
/// stand, and nothing is remembered as a denial.
enum DocumentAbilityAnswer: Equatable {
    case writer
    case reader
    case noAnswer

    /// `true` writer, `false` reader, nil no answer.
    var writer: Bool? {
        switch self {
        case .writer: return true
        case .reader: return false
        case .noAnswer: return nil
        }
    }

    /// The decoded answer for `documentID`: another document's answer says nothing about this
    /// one, so it is a denial (review Z3).
    static func classify(_ document: Document, asked documentID: UUID) -> DocumentAbilityAnswer {
        guard document.id == documentID else { return .reader }
        return document.abilities.update ? .writer : .reader
    }

    /// A failed fetch: only a 403 and an API 404 are the server's answer about the document.
    static func classify(_ error: Error) -> DocumentAbilityAnswer {
        guard let error = error as? DocsAPIError else { return .noAnswer }
        switch error {
        case .forbidden, .notFound: return .reader
        case .sessionExpired, .routeNotFound, .rateLimited, .network, .decoding, .server: return .noAnswer
        }
    }
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
