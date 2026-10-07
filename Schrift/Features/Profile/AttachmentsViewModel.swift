import Foundation
import Observation

/// One document's attachments, as the Attachments screen lists them.
struct AttachmentLibraryGroup: Equatable, Identifiable {
    let documentID: UUID
    let title: String?
    let syncedAt: Date
    let attachments: [AttachmentDisplay]

    var id: UUID { documentID }
}

/// The attachments found in the cached documents, grouped by document, newest
/// sync first.
///
/// Docs has no endpoint that lists a user's attachments, so the cached markdown
/// is the only source this app has: the screen can only ever show documents
/// opened on this device. Classification goes through `parseEditorBlocks` with
/// the server origin — the same gate the editor's cards use — so a link the
/// editor would draw as plain text never appears here, and nothing listed can
/// name another host. A document linking one file twice lists it once.
func attachmentLibraryGroups(from contents: [CachedDocumentContent], serverOrigin: String) -> [AttachmentLibraryGroup] {
    contents
        .compactMap { content -> AttachmentLibraryGroup? in
            var seen = Set<String>()
            var attachments: [AttachmentDisplay] = []
            for block in parseEditorBlocks(content.markdown, serverOrigin: serverOrigin) {
                guard case .attachment(let name, let url) = block.kind,
                    let display = parseAttachmentLink("[\(name)](\(url))", serverOrigin: serverOrigin),
                    seen.insert(display.urlString).inserted
                else { continue }
                attachments.append(display)
            }
            guard !attachments.isEmpty else { return nil }
            return AttachmentLibraryGroup(
                documentID: content.documentID, title: content.title, syncedAt: content.syncedAt,
                attachments: attachments)
        }
        .sorted { $0.syncedAt > $1.syncedAt }
}

/// One row of the Attachments list: a document's header or one of its files.
///
/// The list is flattened into rows so every card is its own child of the lazy
/// stack. Ids are scoped by document, because one file linked from two
/// documents appears under both and a lazy stack needs every id unique.
enum AttachmentLibraryRow: Equatable, Identifiable {
    case header(documentID: UUID, title: String?, isFirst: Bool)
    case file(documentID: UUID, display: AttachmentDisplay)

    var id: String {
        switch self {
        case .header(let documentID, _, _):
            return "\(documentID.uuidString)#header"
        case .file(let documentID, let display):
            return "\(documentID.uuidString)#\(display.urlString)"
        }
    }
}

func attachmentLibraryRows(_ groups: [AttachmentLibraryGroup]) -> [AttachmentLibraryRow] {
    var rows: [AttachmentLibraryRow] = []
    for (index, group) in groups.enumerated() {
        rows.append(.header(documentID: group.documentID, title: group.title, isFirst: index == 0))
        rows += group.attachments.map { .file(documentID: group.documentID, display: $0) }
    }
    return rows
}

/// A group's header text, or nil to fall back to "Untitled". A blank title is
/// treated as absent, as `SubpageRow` does, so a header is never empty.
func attachmentGroupTitle(_ title: String?) -> String? {
    let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}

/// Lists the files attached to documents cached on this device. Read-only and
/// local: loading issues no request, and downloads happen in each card through
/// the shared `AttachmentLoader`, exactly as they do in the editor.
@MainActor
@Observable
final class AttachmentsViewModel {
    private(set) var groups: [AttachmentLibraryGroup] = []
    private(set) var rows: [AttachmentLibraryRow] = []
    /// False until the first `load()`, so the empty state never flashes before
    /// the cache has been read.
    private(set) var hasLoaded = false

    private let contentCache: DocumentContentCacheStore
    private let serverOrigin: String
    /// A document the user has deleted whose deletion is still queued keeps its
    /// content-cache entry until the deletion lands; it is withheld here, as
    /// every other list strikes or hides it.
    private let isPendingDelete: @MainActor (UUID) -> Bool

    init(
        contentCache: DocumentContentCacheStore = DocumentContentCacheStore(), serverOrigin: String,
        isPendingDelete: @escaping @MainActor (UUID) -> Bool = { _ in false }
    ) {
        self.contentCache = contentCache
        self.serverOrigin = serverOrigin
        self.isPendingDelete = isPendingDelete
    }

    func load() {
        let contents = contentCache.allContents().filter { !isPendingDelete($0.documentID) }
        groups = attachmentLibraryGroups(from: contents, serverOrigin: serverOrigin)
        rows = attachmentLibraryRows(groups)
        hasLoaded = true
    }
}
