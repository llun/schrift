import Foundation

/// A creation action's one-time editing intent. Reference identity keeps consumption shared
/// with the navigation route if SwiftUI recreates the screen; it is never persisted or inferred
/// from an empty body, a default title, or a pending-create id.
@MainActor
final class NewDocumentEntryIntent: Hashable {
    nonisolated private let id = UUID()
    private var isPending = true

    func consume() -> Bool {
        guard isPending else { return false }
        isPending = false
        return true
    }

    nonisolated static func == (lhs: NewDocumentEntryIntent, rhs: NewDocumentEntryIntent) -> Bool {
        lhs.id == rhs.id
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Ordinary opens carry no intent. Only a successful creation action mints one, for both
/// compact navigation stacks and the regular-width selected detail.
struct DocumentEditorRoute: Hashable {
    let document: Document
    let entryIntent: NewDocumentEntryIntent?

    init(document: Document) {
        self.document = document
        self.entryIntent = nil
    }

    @MainActor
    init(createdDocument: Document) {
        self.document = createdDocument
        self.entryIntent = NewDocumentEntryIntent()
    }
}
