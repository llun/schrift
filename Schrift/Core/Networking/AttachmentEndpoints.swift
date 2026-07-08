import Foundation

// MARK: - Models

/// Response of `POST documents/{id}/attachment-upload/`. `file` is a
/// server-relative **media-check path** (`/api/v1.0/documents/{id}/media-check/?key=…`),
/// NOT a media URL — poll it until the attachment is ready.
private struct AttachmentUploadResponse: Decodable {
    let file: String
}

/// Response of the media-check poll. `file` (present once `status == "ready"`)
/// is the server-relative media path (`/media/{key}`).
struct MediaCheckResponse: Decodable, Equatable, Sendable {
    let status: String
    let file: String?

    static let readyStatus = "ready"
}

// MARK: - Pure helpers

/// A token safe to interpolate into a multipart header (and, for `contentType`,
/// into a real HTTP header value): no quote, CR or LF to break out with.
///
/// Compares **unicode scalars**, not `Character`s: Swift treats `"\r\n"` as a
/// single extended grapheme cluster, so `character == "\r"` never matches a CRLF
/// — the exact sequence a header-injection payload uses.
func isSafeMultipartToken(_ token: String) -> Bool {
    !token.unicodeScalars.contains { $0 == "\"" || $0 == "\r" || $0 == "\n" }
}

/// Builds a single-file `multipart/form-data` body. Pure and deterministic for a
/// given boundary so tests can assert exact bytes. Never derive the boundary from
/// user or server data.
///
/// Returns nil if any interpolated token could break out of its header. The only
/// caller passes app constants (`photo.jpg`, `image/jpeg`), but the signature
/// invites a future caller to pass the picked asset's real filename — which is
/// user-controlled — so the guard lives here rather than in a comment.
func multipartFormDataBody(
    boundary: String, fieldName: String, fileName: String, contentType: String, fileData: Data
) -> Data? {
    guard isSafeMultipartToken(boundary), isSafeMultipartToken(fieldName), isSafeMultipartToken(fileName),
        isSafeMultipartToken(contentType)
    else { return nil }
    var body = Data()
    body.append(Data("--\(boundary)\r\n".utf8))
    body.append(Data("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\n".utf8))
    body.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
    body.append(fileData)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    return body
}

/// Extracts the storage key (`{doc-id}/attachments/{file-id}.{ext}`) from the
/// media-check path returned by the upload; `URLComponents` percent-decodes it.
func attachmentKey(fromMediaCheckPath path: String) -> String? {
    URLComponents(string: path)?.queryItems?.first(where: { $0.name == "key" })?.value
}

/// True for a **path-absolute reference** — the only shape of server-supplied
/// path we will turn into a request URL. `"/a/b"` yes; `"//evil.com/x"` (a
/// protocol-relative *authority*) and `"https://evil.com/x"` (a scheme) no,
/// because both escape the server origin when resolved against `baseURL`.
func isSameOriginPath(_ path: String) -> Bool {
    path.hasPrefix("/") && !path.hasPrefix("//") && URLComponents(string: path)?.scheme == nil
}

// MARK: - Endpoints

extension DocsAPIClient {
    /// Uploads a document attachment. The backend accepts exactly one multipart
    /// field, `file` — it sniffs the content type and derives the extension
    /// server-side, so the part's filename extension must match the real bytes
    /// (a mismatch stores the file under an `-unsafe` key that won't render
    /// inline). Returns the raw `file` string: a media-check path, not a URL.
    func uploadAttachment(documentID: UUID, fileName: String, contentType: String, data: Data) async throws -> String {
        let boundary = "schrift-" + UUID().uuidString
        guard
            let body = multipartFormDataBody(
                boundary: boundary, fieldName: "file", fileName: fileName, contentType: contentType, fileData: data)
        else { throw DocsAPIError.network("Invalid multipart metadata") }
        let response: AttachmentUploadResponse = try await send(
            path: "documents/\(documentID.uuidString.lowercased())/attachment-upload/",
            method: "POST", body: body,
            contentType: "multipart/form-data; boundary=\(boundary)")
        return response.file
    }

    /// Polls a media-check path exactly as the server returned it. That path is
    /// server-provided and already rooted (`/api/v1.0/…`), so — unlike every
    /// other endpoint here — it intentionally starts with `/` and resolves
    /// against the host root rather than re-prefixing the API base.
    ///
    /// This is the only endpoint whose path is **not** app-authored, so it must
    /// prove the server can't steer our HTTP client off-origin (`//evil.com/x`,
    /// `https://evil.com/x`). Keep that guard if this ever becomes a non-GET:
    /// `performRequest` would then send the CSRF token and `Origin` to that host.
    func checkMedia(path: String) async throws -> MediaCheckResponse {
        guard isSameOriginPath(path) else { throw DocsAPIError.network("Invalid media-check path") }
        return try await get(path)
    }
}
