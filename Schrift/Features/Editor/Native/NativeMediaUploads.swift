import Foundation
import Observation

/// The native editor's media uploads (PR13a, queued since PR13b): the
/// classic preparation (`preparedJPEGData`, `loadPickedAttachmentFile`)
/// feeding the coordinator's durable native queue.
///
/// The block exists before its upload (the slash menu inserts it empty, as the
/// web does); an upload records the block's **slot** (its kind and url) when
/// it starts and is queued at once, online or offline
/// (`DocumentSaveCoordinator.queueNativeAttachment`: bytes and record on disk
/// first). The coordinator uploads, checkpoints the URL and commits
/// `.mediaProps([name, url], expecting: slot)` through a headless lease of the
/// document's replica, so it lands whether this editor is still open or not,
/// and after a relaunch. A block deleted, retyped or filled meanwhile refuses
/// the commit and drops the record. The URL written is always the server's own
/// media URL for **this** document; nothing local, no placeholder and no picked
/// file name the server did not store ever reaches the replica. One upload per
/// block at a time. A local document (no server id) is refused with a notice.
@MainActor @Observable
final class NativeMediaUploads {
    /// Uploads to document `documentID`, answering the absolute media URL (or
    /// nil when the server gave none): `uploadAttachment` then
    /// `readyMediaURLString` (`DocsAPIClient.mediaUploader`).
    typealias Upload =
        @Sendable (_ documentID: UUID, _ fileName: String, _ contentType: String, _ data: Data)
        async throws -> String?

    enum Source: Sendable {
        /// A photo's original bytes; re-encoded as JPEG without metadata.
        case photo(@Sendable () async throws -> Data?)
        /// A picked file, sized and named by `loadPickedAttachmentFile`.
        case file(@Sendable () async throws -> PreparedAttachmentFile?)
    }

    /// The block whose bytes are being prepared, before they are queued.
    private(set) var preparing: String?
    /// The last failure, for the block it was for.
    private(set) var failure: (blockID: String, key: L10nKey)?
    /// The document's replica scope (its server id and account); nil for a
    /// document only this device knows, which cannot upload. Every record
    /// shown, retried or discarded is this account's (review X5).
    let scope: ReplicaScope?
    var documentID: UUID? { scope?.documentID }
    @ObservationIgnored private let queue: DocumentSaveCoordinator

    init(scope: ReplicaScope?, queue: DocumentSaveCoordinator) {
        self.scope = scope
        self.queue = queue
    }

    /// Block `blockID`'s queued upload (waiting, uploading or failed), if any.
    func record(_ blockID: String) -> PendingAttachment? {
        scope.flatMap { queue.nativeAttachment(scope: $0, blockID: blockID) }
    }

    /// The blocks of this document with an upload under way, and those whose upload failed.
    var uploadingBlocks: Set<String> { blocks(failed: false).union(preparing.map { [$0] } ?? []) }
    var failedBlocks: Set<String> { blocks(failed: true) }

    private func blocks(failed: Bool) -> Set<String> {
        guard let scope else { return [] }
        _ = queue.pendingAttachmentsVersion
        return Set(
            queue.nativeAttachments(scope: scope).filter { ($0.failedAt != nil) == failed }
                .compactMap(\.native?.blockID))
    }

    /// Whether an upload into `blockID` can start now (a server document, none under way for it).
    func canUpload(_ blockID: String) -> Bool { documentID != nil && preparing == nil && record(blockID) == nil }

    func clearFailure() { failure = nil }

    /// A failed upload goes again (its bytes are still queued).
    func retry(_ blockID: String) {
        guard let record = record(blockID) else { return }
        queue.retryPendingAttachment(localID: record.localID)
    }

    /// The queued upload and its bytes go; the block stays as it is.
    func discard(_ blockID: String) {
        guard let record = record(blockID) else { return }
        queue.discardPendingAttachment(localID: record.localID)
    }

    /// Prepares `source` and queues it for media block `blockID` of
    /// `session`'s surface (the document's, or a column's), whose slot is
    /// `slot` now. Nil (and a failure notice) when it cannot start.
    @discardableResult
    func start(_ source: Source, into blockID: String, slot: MediaBlock.Slot, in session: NativeEditorSession)
        -> Task<Void, Never>?
    {
        failure = nil
        guard let scope, session.scope == scope else {
            failure = (blockID, .native_editor_media_upload_offline)
            return nil
        }
        guard canUpload(blockID) else { return nil }
        preparing = blockID
        // Never retained across the preparation: a closed editor is gone, not kept alive.
        let target = WeakSession(session: session)
        return Task { [weak self] in
            await self?.prepare(source, into: blockID, slot: slot, scope: scope, target: target)
        }
    }

    private func prepare(
        _ source: Source, into blockID: String, slot: MediaBlock.Slot, scope: ReplicaScope, target: WeakSession
    ) async {
        defer { preparing = nil }
        let fileName: String
        let contentType: String
        let data: Data
        do {
            switch source {
            case .photo(let load):
                guard let original = try await load() else { return }
                // Off the main actor: decoding a 48 MP HEIC must not freeze the editor.
                guard
                    let jpeg = await Task.detached(
                        priority: .userInitiated, operation: { preparedJPEGData(from: original) }
                    ).value
                else { return fail(blockID, .native_editor_media_upload_failed) }
                (fileName, contentType, data) = ("photo.jpg", "image/jpeg", jpeg)
            case .file(let load):
                guard let file = try await load() else { return }
                if slot.node == "image" {
                    // An image block's file is re-encoded like a photo: its
                    // EXIF (GPS included) never leaves the device.
                    guard
                        let jpeg = await Task.detached(
                            priority: .userInitiated, operation: { preparedJPEGData(from: file.data) }
                        ).value
                    else { return fail(blockID, .native_editor_media_upload_failed) }
                    let stem = (file.fileName as NSString).deletingPathExtension
                    (fileName, contentType, data) = ((stem.isEmpty ? "photo" : stem) + ".jpg", "image/jpeg", jpeg)
                } else {
                    (fileName, contentType, data) = (file.fileName, file.contentType, file.data)
                }
            }
        } catch AttachmentImportError.tooLarge {
            return fail(blockID, .editor_error_file_too_large)
        } catch {
            return fail(blockID, .native_editor_media_upload_failed)
        }
        // Preparation awaited: the editor that started this may have closed
        // (Done, a sign-out or another account's reopen). Nothing is queued then.
        guard target.session.map({ !$0.isClosed }) == true else {
            return fail(blockID, .native_editor_media_upload_dropped)
        }
        let queued = queue.queueNativeAttachment(
            scope: scope,
            target: NativeMediaTarget(
                org: scope.org, blockID: blockID, slot: slot, fileName: fileName, contentType: contentType),
            data: data)
        if queued == nil { fail(blockID, .native_editor_media_upload_failed) }
    }

    private struct WeakSession {
        weak var session: NativeEditorSession?
    }

    private func fail(_ blockID: String, _ key: L10nKey) {
        failure = (blockID, key)
    }
}

extension DocsAPIClient {
    /// The native editor's upload (PR13a): the classic attachment upload and
    /// its bounded media-check poll, answering the URL to embed.
    /// `isCurrent` binds the upload to the sign-in generation it started in
    /// (`SignInGenerationClock.isCurrent`), checked when the request is built.
    nonisolated func mediaUploader(
        maxAttempts: Int = 5, retryInterval: Duration = .seconds(1), isCurrent: (@Sendable () -> Bool)? = nil
    ) -> NativeMediaUploads.Upload {
        { [self] documentID, fileName, contentType, data in
            let path = try await uploadAttachment(
                documentID: documentID, fileName: fileName, contentType: contentType, data: data,
                isCurrent: isCurrent)
            return await readyMediaURLString(
                fromMediaCheckPath: path, maxAttempts: maxAttempts, retryInterval: retryInterval)
        }
    }
}
