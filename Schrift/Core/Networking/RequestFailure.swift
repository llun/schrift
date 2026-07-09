import Foundation

/// A non-2xx API response, captured so the failure can be diagnosed from the device.
///
/// `DocsAPIError` deliberately flattens every failure into a handful of cases, and the
/// view models turn those into one friendly sentence. That leaves a misconfigured server
/// (Django answering 403 from its CSRF check) indistinguishable from a client bug (a 400,
/// or a decoding failure) for anyone holding a phone rather than a debugger.
///
/// Safety: this type must never grow a field for request or response headers, for cookies,
/// or for the CSRF token — those are the live session credential. The method, the path, the
/// status, and a bounded prefix of the response body are the only things it may carry, and
/// none of them are written to disk.
struct RequestFailure: Equatable, Sendable {
    /// Django's CSRF rejections are a single short sentence, but a misrouted request can
    /// answer with a whole HTML error page.
    static let maxBodyLength = 512

    let method: String
    let path: String
    let statusCode: Int
    /// A bounded prefix of the response body; nil when the body is empty.
    let bodyPrefix: String?

    init(method: String, path: String, statusCode: Int, body: Data) {
        self.method = method
        self.path = path
        self.statusCode = statusCode
        self.bodyPrefix = boundedBodyPrefix(body)
    }

    /// One line for the UI: the status, plus whatever the server said about it.
    var displayText: String {
        guard let reason = bodyPrefix.flatMap({ serverReason(fromBody: $0) }) else {
            return "HTTP \(statusCode)"
        }
        return "HTTP \(statusCode): \(reason)"
    }
}

/// Truncates before decoding: a large error page costs nothing to cut down first, and a cut
/// landing mid-scalar decodes to a replacement character rather than failing outright.
func boundedBodyPrefix(_ body: Data, limit: Int = RequestFailure.maxBodyLength) -> String? {
    guard !body.isEmpty else { return nil }
    return String(decoding: body.prefix(limit), as: UTF8.self)
}

/// Lifts DRF's `{"detail": "…"}` out of an error body — that is where Django's CSRF reason
/// ("CSRF Failed: CSRF token missing.") actually lives, since `SessionAuthentication`
/// raises `PermissionDenied` with it. Anything else (an HTML page, a bare string, or a body
/// the length cap truncated mid-JSON) falls back to the raw text.
func serverReason(fromBody body: String) -> String? {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let data = trimmed.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let detail = object["detail"] as? String
    else { return trimmed }
    return detail
}
