import Foundation
import Observation

/// The native editor's media uploads (PR13a): the classic pipeline
/// (`preparedJPEGData`, `loadPickedAttachmentFile`, `uploadAttachment` and the
/// bounded media-check poll) feeding a generation-checked commit.
///
/// The block exists before its upload (the slash menu inserts it empty, as the
/// web does); the upload records the block's **slot** (its kind and url) when
/// it starts, and the URL is committed with `.mediaProps([name, url],
/// expecting: slot)` through the same editor session's input. A block deleted,
/// retyped or filled meanwhile refuses the commit; a session that closed (Done,
/// sign-out, another account) drops it, never retargeting another session. The
/// URL written is always the server's own media URL for **this** document
/// (`parseAttachmentLink` + the document id); nothing local, no placeholder and
/// no picked file name the server did not store ever reaches the replica.
/// One upload at a time per document. Offline and local documents are refused
/// with a notice: the native offline queue is PR13b.
@MainActor @Observable
final class NativeMediaUploads {
    /// Uploads to document `documentID`, answering the absolute media URL (or
    /// nil when the server gave none). The app's: `uploadAttachment` then
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

    /// The block an upload is running for, if any.
    private(set) var uploading: String?
    /// The last failure, for the block it was for.
    private(set) var failure: (blockID: String, key: L10nKey)?
    /// The server's id for the document; nil for one only this device knows.
    let documentID: UUID?
    let serverOrigin: String
    @ObservationIgnored var isOffline: () -> Bool
    @ObservationIgnored private let upload: Upload
    @ObservationIgnored private weak var session: NativeEditorSession?
    /// How long a commit waits for the input to be free, a step at a time.
    @ObservationIgnored var commitAttempts = 50
    @ObservationIgnored var commitInterval: Duration = .milliseconds(100)

    init(
        session: NativeEditorSession, documentID: UUID?, serverOrigin: String, isOffline: @escaping () -> Bool,
        upload: @escaping Upload
    ) {
        self.session = session
        self.documentID = documentID
        self.serverOrigin = serverOrigin
        self.isOffline = isOffline
        self.upload = upload
    }

    /// Whether an upload can start now (one at a time, online, a server document).
    var canUpload: Bool { uploading == nil && documentID != nil && !isOffline() }

    func clearFailure() { failure = nil }

    /// Starts uploading `source` into media block `blockID`, whose slot is
    /// `slot` now. Nil (and a failure notice) when it cannot start.
    @discardableResult
    func start(_ source: Source, into blockID: String, slot: MediaBlock.Slot) -> Task<Void, Never>? {
        failure = nil
        guard uploading == nil else { return nil }
        guard let documentID, !isOffline() else {
            failure = (blockID, .native_editor_media_upload_offline)
            return nil
        }
        uploading = blockID
        return Task { [weak self] in
            await self?.run(source, into: blockID, slot: slot, documentID: documentID)
        }
    }

    private func run(_ source: Source, into blockID: String, slot: MediaBlock.Slot, documentID: UUID) async {
        defer { uploading = nil }
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
                (fileName, contentType, data) = (file.fileName, file.contentType, file.data)
            }
        } catch AttachmentImportError.tooLarge {
            return fail(blockID, .editor_error_file_too_large)
        } catch {
            return fail(blockID, .native_editor_media_upload_failed)
        }
        let url: String
        do {
            guard let answered = try await upload(documentID, fileName, contentType, data) else {
                return fail(blockID, .native_editor_media_upload_failed)
            }
            url = answered
        } catch {
            return fail(blockID, .native_editor_media_upload_failed)
        }
        // Only this server's media URL for this very document is written.
        guard let display = parseAttachmentLink("[file](\(url))", serverOrigin: serverOrigin),
            display.documentUUID.lowercased() == documentID.uuidString.lowercased(),
            MediaBlock.isAuthoredURL(url)
        else { return fail(blockID, .native_editor_media_upload_failed) }
        await commit(
            blockID,
            props: [
                ProjectedProp(key: "name", value: .string(fileName)), ProjectedProp(key: "url", value: .string(url)),
            ],
            slot: slot)
    }

    /// Posts the commit through the same session's input once it is free
    /// (a composition or another command in flight); a session that closed
    /// meanwhile drops it.
    private func commit(_ blockID: String, props: [ProjectedProp], slot: MediaBlock.Slot) async {
        for attempt in 0..<commitAttempts {
            guard let session, !session.isClosed, let input = session.input else { break }
            if input.setMediaProps(blockID, props, expecting: slot) { return }
            if attempt + 1 < commitAttempts { try? await Task.sleep(for: commitInterval) }
        }
        fail(blockID, .native_editor_media_upload_dropped)
    }

    private func fail(_ blockID: String, _ key: L10nKey) {
        failure = (blockID, key)
    }
}

extension DocsAPIClient {
    /// The native editor's upload (PR13a): the classic attachment upload and
    /// its bounded media-check poll, answering the URL to embed.
    nonisolated func mediaUploader(maxAttempts: Int = 5, retryInterval: Duration = .seconds(1))
        -> NativeMediaUploads.Upload
    {
        { [self] documentID, fileName, contentType, data in
            let path = try await uploadAttachment(
                documentID: documentID, fileName: fileName, contentType: contentType, data: data)
            return await readyMediaURLString(
                fromMediaCheckPath: path, maxAttempts: maxAttempts, retryInterval: retryInterval)
        }
    }
}
