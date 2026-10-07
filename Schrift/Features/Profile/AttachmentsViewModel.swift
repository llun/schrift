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

/// Lists the files attached to documents cached on this device. Read-only and
/// local: loading issues no request, and downloads happen in each card through
/// the shared `AttachmentLoader`, exactly as they do in the editor.
@MainActor
@Observable
final class AttachmentsViewModel {
    private(set) var groups: [AttachmentLibraryGroup] = []
    /// False until the first `load()`, so the empty state never flashes before
    /// the cache has been read.
    private(set) var hasLoaded = false

    private let contentCache: DocumentContentCacheStore
    private let serverOrigin: String

    init(contentCache: DocumentContentCacheStore = DocumentContentCacheStore(), serverOrigin: String) {
        self.contentCache = contentCache
        self.serverOrigin = serverOrigin
    }

    func load() {
        groups = attachmentLibraryGroups(from: contentCache.allContents(), serverOrigin: serverOrigin)
        hasLoaded = true
    }
}
