import Foundation

enum DocsAPIError: Error, Equatable {
    case sessionExpired
    case forbidden
    case notFound
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
            return .notFound
        case 429:
            let retryAfter = headers["Retry-After"].flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retryAfter)
        default:
            return .server(statusCode: statusCode)
        }
    }
}
