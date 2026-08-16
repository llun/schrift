import Foundation

/// Where a moved document lands relative to the target, in django-treebeard's own vocabulary.
///
/// The backend validates these against `MoveNodePositionChoices`, so the raw values are the
/// wire strings rather than anything the app is free to spell its own way. Only two are used
/// today — see `DocumentActions.move` — but the set is the server's, and narrowing it here
/// would just move the next caller's decision into a different file.
enum DocumentMovePosition: String, Sendable {
    case firstChild = "first-child"
    case lastChild = "last-child"
    case firstSibling = "first-sibling"
    case lastSibling = "last-sibling"
    case left
    case right
}

extension DocsAPIClient {
    /// The move request body.
    ///
    /// `targetDocumentId` is a **String**, not a `UUID`: `UUID`'s own `Codable` conformance
    /// emits the uppercase form, and the backend wants lowercase everywhere — the same rule
    /// every path in this layer follows. Encoding goes through a bare `JSONEncoder` with no key
    /// strategy, so the snake_case mapping has to be spelled out.
    struct MoveDocumentBody: Encodable {
        let targetDocumentId: String
        let position: String

        enum CodingKeys: String, CodingKey {
            case targetDocumentId = "target_document_id"
            case position
        }
    }

    /// Move a document — and, server-side, its whole subtree in one atomic transaction — to a
    /// new place in the tree.
    ///
    /// `position` decides what `targetDocumentID` means: a child position files the document
    /// *under* the target, a sibling position files it *beside* it, which is the only way to
    /// promote a document to the top level (there is no "no parent" target — a root is named
    /// instead, and every root is a sibling of every other).
    ///
    /// The response is a `{"message": …}` acknowledgement with nothing worth decoding, so this
    /// goes through `sendVoid`. Every rejection — no permission on the target, a target that
    /// does not exist, a move into the document's own descendant — is a **400**, so it arrives
    /// as `DocsAPIError.server(statusCode: 400)` rather than as a `.forbidden`/`.notFound` a
    /// caller could branch on.
    func moveDocument(
        documentID: UUID, targetDocumentID: UUID, position: DocumentMovePosition
    ) async throws {
        let body = try JSONEncoder().encode(
            MoveDocumentBody(
                targetDocumentId: targetDocumentID.uuidString.lowercased(),
                position: position.rawValue))
        try await sendVoid(
            path: "documents/\(documentID.uuidString.lowercased())/move/", method: "POST", body: body)
    }
}
