import Foundation

func multipartFormData(boundary: String, fieldName: String, filename: String, contentType: String, content: Data) -> Data {
    var body = Data()
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
    body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
    body.append(content)
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
    return body
}

extension DocsAPIClient {
    func createDocumentFromMarkdown(title: String, markdown: String) async throws -> Document {
        let boundary = "Boundary-\(UUID().uuidString)"
        let body = multipartFormData(
            boundary: boundary,
            fieldName: "file",
            filename: "\(title).md",
            contentType: "text/markdown",
            content: markdown.data(using: .utf8) ?? Data()
        )
        return try await send(
            path: "documents/",
            method: "POST",
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
    }

    func rawContent(documentID: UUID) async throws -> Data {
        try await getRawData("documents/\(documentID.uuidString.lowercased())/content/")
    }

    func setContent(documentID: UUID, rawContent: Data) async throws {
        let body = try JSONEncoder().encode(["content": rawContent.base64EncodedString()])
        try await sendVoid(path: "documents/\(documentID.uuidString.lowercased())/content/", method: "PATCH", body: body)
    }

    func deleteDocument(documentID: UUID) async throws {
        try await sendVoid(path: "documents/\(documentID.uuidString.lowercased())/", method: "DELETE", body: nil)
    }

    func saveDocumentContent(documentID: UUID, title: String, markdown: String) async throws {
        let tempDocument = try await createDocumentFromMarkdown(title: title, markdown: markdown)
        do {
            let raw = try await rawContent(documentID: tempDocument.id)
            try await setContent(documentID: documentID, rawContent: raw)
        } catch {
            try? await deleteDocument(documentID: tempDocument.id)
            throw error
        }
        try? await deleteDocument(documentID: tempDocument.id)
    }
}
