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

/// Builds a single-file `multipart/form-data` body. Pure and deterministic for a
/// given boundary so tests can assert exact bytes. `fileName`/`contentType` are
/// app-supplied constants — never interpolate user-controlled data here, and
/// never derive the boundary from user data.
func multipartFormDataBody(
    boundary: String, fieldName: String, fileName: String, contentType: String, fileData: Data
) -> Data {
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

// MARK: - Endpoints

extension DocsAPIClient {
    /// Uploads a document attachment. The backend accepts exactly one multipart
    /// field, `file` — it sniffs the content type and derives the extension
    /// server-side, so the part's filename extension must match the real bytes
    /// (a mismatch stores the file under an `-unsafe` key that won't render
    /// inline). Returns the raw `file` string: a media-check path, not a URL.
    func uploadAttachment(documentID: UUID, fileName: String, contentType: String, data: Data) async throws -> String {
        let boundary = "schrift-" + UUID().uuidString
        let body = multipartFormDataBody(
            boundary: boundary, fieldName: "file", fileName: fileName, contentType: contentType, fileData: data)
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
    func checkMedia(path: String) async throws -> MediaCheckResponse {
        try await get(path)
    }
}
