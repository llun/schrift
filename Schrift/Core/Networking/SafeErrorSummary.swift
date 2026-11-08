import Foundation

/// A short description of an error that is safe to show on a device and to quote in a bug report.
///
/// `String(describing:)` is not: `DecodingError` descriptions embed the server's own value
/// (`ISO8601 date, got <string>`), `NSError` ones embed the failing URL, and a `DocsAPIError`'s
/// payload may be either. This reports only what the code can vouch for: the error's type, its
/// case (never the case's payload, except the numeric ones below), and for a `DecodingError` the
/// kind and the coding path. It never carries document content, a header, a cookie or a token,
/// and path components shaped like ids are elided the way `RequestFailure.displayPath` does.
func safeErrorSummary(_ error: Error) -> String {
    switch error {
    case let decoding as DecodingError:
        return "\(decodingKind(decoding)) at \(codingPathText(decoding.safeContext.codingPath))"
    case DocsAPIError.server(let statusCode):
        return "DocsAPIError.server(\(statusCode))"
    case DocsAPIError.decoding(let summary):
        // Built from `safeErrorSummary` (or a fixed phrase) wherever it is thrown; bounded anyway.
        return "DocsAPIError.decoding: \(summary.prefix(200))"
    case let url as URLError:
        return "URLError(\(url.code.rawValue))"
    default:
        let mirror = Mirror(reflecting: error)
        guard mirror.displayStyle == .enum else { return String(describing: type(of: error)) }
        // An enum's first child is its case with the payload; a payload-less case has none.
        let name = mirror.children.first?.label ?? String(describing: error)
        return "\(type(of: error)).\(name)"
    }
}

private func decodingKind(_ error: DecodingError) -> String {
    switch error {
    case .typeMismatch(let type, _): return "typeMismatch(\(type))"
    case .valueNotFound(let type, _): return "valueNotFound(\(type))"
    case .keyNotFound(let key, _): return "keyNotFound(\(keyText(key)))"
    case .dataCorrupted: return "dataCorrupted"
    @unknown default: return "DecodingError"
    }
}

extension DecodingError {
    fileprivate var safeContext: Context {
        switch self {
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .keyNotFound(_, let context),
            .dataCorrupted(let context):
            return context
        @unknown default: return Context(codingPath: [], debugDescription: "")
        }
    }
}

private func codingPathText(_ path: [CodingKey]) -> String {
    guard !path.isEmpty else { return "(root)" }
    return path.prefix(12).map { key in
        if let index = key.intValue { return "[\(index)]" }
        return keyText(key)
    }.joined(separator: " › ")
}

private func keyText(_ key: CodingKey) -> String {
    UUID(uuidString: key.stringValue) == nil ? String(key.stringValue.prefix(40)) : "…"
}
