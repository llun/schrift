import UIKit
import XCTest

@testable import Schrift

/// PR13a end to end on a real editor session: the slash menu's media items,
/// the inspector's prop commands, peers' media edits reaching the card, and
/// the upload pipeline's generation-checked commit (a fake upload; nothing
/// reaches a network).
@MainActor
final class NativeMediaTests: NativeEditingTestCase {
    private nonisolated static let origin = "https://example.test"

    private func seed(_ name: String) throws -> Data {
        let capture = try XCTUnwrap(BlockNoteMediaCaptures.edits.first { $0.name == name }, name)
        return try XCTUnwrap(Data(base64Encoded: capture.seed))
    }

    private func xml(_ harness: Harness) async -> String {
        await harness.session.replicaDoc { YXMLString.fragment($0) } ?? ""
    }

    private func props(_ harness: Harness, _ id: String) throws -> [ProjectedProp] {
        try XCTUnwrap(harness.session.surface.blocks.first { $0.id == id }).props
    }

    // MARK: - Slash menu and inspector commands

    /// "/image" in an empty paragraph makes it an empty image block in place
    /// (the web's `insertOrUpdateBlockForSlashMenu`), one command, and asks
    /// for its inspector.
    func testTheImageSlashItemMakesAnEmptyImageAndRequestsItsInspector() async throws {
        let harness = try await makeHarness(state: try seed("imageSlashEmpty"))
        addTeardownBlock { await harness.close() }
        XCTAssertTrue(harness.session.canType)
        setSelection(harness, NSRange(location: try location(harness.session, "q", 0), length: 0))
        for key in ["/", "i", "m"] { harness.view.insertText(key) }
        await harness.settle()
        XCTAssertNotNil(harness.input.slashMenuQuery)
        let item = try XCTUnwrap(NativeInputCoordinator.slashItems.first { $0.id == "mediaImage" })
        let applied = await harness.run { harness.input.applySlashItem(item) }
        XCTAssertTrue(applied)
        XCTAssertEqual(harness.input.requestedMedia, "q")
        XCTAssertEqual(harness.session.surface.blocks.map(\.node), ["paragraph", "image", "paragraph"])
        let capture = try XCTUnwrap(BlockNoteMediaCaptures.edits.first { $0.name == "imageSlashEmpty" })
        let written = await xml(harness)
        XCTAssertEqual(written, capture.xml)
        try await assertConsistent(harness, localCommands: 4)
    }

    /// From a paragraph with text the block goes after it; the last root
    /// block gets the web's trailing paragraph, and the caret goes there.
    func testTheFileSlashItemAfterTextAddsTheTrailingParagraph() async throws {
        let harness = try await makeHarness([paragraph("lead", "Notes"), paragraph("q", "Later")])
        addTeardownBlock { await harness.close() }
        setSelection(harness, NSRange(location: try location(harness.session, "q", 0), length: 0))
        for key in ["/", "f"] { harness.view.insertText(key) }
        await harness.settle()
        let item = try XCTUnwrap(NativeInputCoordinator.slashItems.first { $0.id == "mediaFile" })
        let applied = await harness.run { harness.input.applySlashItem(item) }
        XCTAssertTrue(applied)
        let blocks = harness.session.surface.blocks
        XCTAssertEqual(blocks.map(\.node), ["paragraph", "paragraph", "file", "paragraph"])
        XCTAssertEqual(blocks[1].runs.map(\.text).joined(), "Later", "the query went, the text stayed")
        XCTAssertEqual(harness.input.requestedMedia, blocks[2].id)
        XCTAssertTrue(blocks[3].runs.allSatisfy(\.text.isEmpty))
        XCTAssertEqual(harness.view.selectedRange.location, try location(harness.session, blocks[3].id, 0))
        try await assertConsistent(harness, localCommands: 3)
    }

    /// A nested paragraph keeps its "/query": the slash item is refused (a
    /// media block below the root has no shadow) and nothing is written.
    func testTheSlashItemIsRefusedInANestedParagraph() async throws {
        let parent = BlockNoteBlock(
            node: "bulletListItem", props: paragraph("x", "").props, runs: [InlineRun("Parent")], id: "parent",
            children: [paragraph("q", "")])
        let harness = try await makeHarness([parent, paragraph("tail", "After")])
        addTeardownBlock { await harness.close() }
        setSelection(harness, NSRange(location: try location(harness.session, "q", 0), length: 0))
        for key in ["/", "i"] { harness.view.insertText(key) }
        await harness.settle()
        let item = try XCTUnwrap(NativeInputCoordinator.slashItems.first { $0.id == "mediaImage" })
        _ = await harness.run { harness.input.applySlashItem(item) }
        await harness.settle()
        XCTAssertEqual(harness.session.surface.blocks.map(\.node), ["bulletListItem", "paragraph", "paragraph"])
        let written = await xml(harness)
        XCTAssertFalse(written.contains("<image"))
        try await assertConsistent(harness, localCommands: 2)
    }

    /// Each inspector change is one command; the card's preview follows it,
    /// and an unchanged value writes nothing.
    func testInspectorPropsAreOneCommandEachAndTheCardFollows() async throws {
        let harness = try await makeHarness(state: try seed("imageSetCaption"))
        addTeardownBlock { await harness.close() }
        let caption = ProjectedProp(key: "caption", value: .string("A harbour at dawn"))
        let applied = await harness.run { harness.input.setMediaProps("mx", [caption]) }
        XCTAssertTrue(applied)
        let card = try XCTUnwrap(harness.session.surface.blocks.first { $0.id == "mx" })
        guard case .image(_, let alt, _)? = card.preview else { return XCTFail("\(String(describing: card.preview))") }
        XCTAssertEqual(alt, "A harbour at dawn")
        let width = ProjectedProp(key: "previewWidth", value: .int(320))
        _ = await harness.run { harness.input.setMediaProps("mx", [width]) }
        XCTAssertEqual(MediaBlock.number(try props(harness, "mx").last { $0.key == "previewWidth" }?.value), 320)
        // Unchanged: nothing posted, nothing journaled.
        XCTAssertTrue(harness.input.setMediaProps("mx", [width]))
        _ = await harness.run { harness.input.deleteMedia("mx") }
        XCTAssertNil(harness.session.surface.blocks.first { $0.id == "mx" })
        try await assertConsistent(harness, localCommands: 3)
    }

    /// A peer's caption change reaches the card: a prop change on a preview
    /// block is a whole-block patch (before PR13a it was a `.props` patch the
    /// card never showed).
    func testAPeersMediaPropChangeRefreshesTheCard() async throws {
        let state = try seed("imageSetCaption")
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }
        let peer = YDoc(clientID: 77, gc: true)
        defer { peer.destroy() }
        try peer.applyUpdate(YUpdateDecoder.decode(state))
        let before = YStateEncoder.encodeStateVector(peer)
        let engine = DocumentEngine(doc: peer, surface: HeadlessSurface())
        _ = try engine.applyStructural(
            NativeEditCommand(
                id: UUID(), baseRevision: engine.revision, blockID: "mx",
                kind: .mediaProps([ProjectedProp(key: "caption", value: .string("From a peer"))])), persist: { _ in })
        engine.detach()
        let vector = try YUpdateDecoder.decodeStateVector(before)
        let update = try YStateEncoder.encodeStateAsUpdate(
            peer, since: Dictionary(vector.map { ($0.client, $0.clock) }, uniquingKeysWith: { $1 }))
        try await harness.session.integrateServerState(update)
        await harness.settle()
        let card = try XCTUnwrap(harness.session.surface.blocks.first { $0.id == "mx" })
        guard case .image(_, let alt, _)? = card.preview else { return XCTFail("\(String(describing: card.preview))") }
        XCTAssertEqual(alt, "From a peer")
        try await assertConsistent(harness, localCommands: 0)
    }

    // MARK: - Uploads

    private nonisolated static func mediaURL(_ documentID: UUID, origin: String = origin) -> String {
        "\(origin)/media/\(documentID.uuidString.lowercased())/attachments/6f0f6a54-0b1d-4a8e-9f8c-3d2e1f0a9b8c.png"
    }

    /// The uploads over `harness`, answering `answer` once `gate` (if any) opens.
    private func uploads(
        _ harness: Harness, gate: Latch? = nil, offline: Bool = false,
        answer: @escaping @Sendable (UUID) -> String?
    ) -> (NativeMediaUploads, Locked<[(UUID, String, String, Int)]>) {
        let calls = Locked<[(UUID, String, String, Int)]>([])
        let uploads = NativeMediaUploads(
            documentID: harness.scope.documentID, serverOrigin: Self.origin,
            isOffline: { offline },
            upload: { documentID, name, type, data in
                calls.update { $0.append((documentID, name, type, data.count)) }
                if let gate { await gate.passing() }
                return answer(documentID)
            })
        uploads.commitInterval = .milliseconds(10)
        return (uploads, calls)
    }

    private nonisolated static let file = PreparedAttachmentFile(
        fileName: "harbour.png", contentType: "image/png", data: Data(repeating: 7, count: 64))

    private var slot: MediaBlock.Slot { MediaBlock.Slot(node: "image", url: "") }

    /// An upload into an empty image block commits the server's URL and the
    /// file's name as one command, to the session's own document.
    func testAnUploadCommitsTheServersURLIntoItsBlock() async throws {
        let harness = try await makeHarness(state: try seed("imageCommit"))
        addTeardownBlock { await harness.close() }
        let (uploads, calls) = uploads(harness) { Self.mediaURL($0) }
        let task = try XCTUnwrap(uploads.start(.file { Self.file }, into: "mx", slot: slot, in: harness.session))
        XCTAssertEqual(uploads.uploading, "mx")
        await task.value
        await harness.settle()
        XCTAssertNil(uploads.uploading)
        XCTAssertNil(uploads.failure)
        XCTAssertEqual(calls.value.map(\.0), [harness.scope.documentID])
        XCTAssertEqual(calls.value.map(\.1), ["harbour.png"])
        let stored = try props(harness, "mx")
        XCTAssertEqual(MediaBlock.string("url", in: stored), Self.mediaURL(harness.scope.documentID))
        XCTAssertEqual(MediaBlock.string("name", in: stored), "harbour.png")
        try await assertConsistent(harness, localCommands: 1)
    }

    /// A photo is re-encoded as a JPEG before it leaves (metadata stripped).
    func testAPhotoUploadsAsAJPEG() async throws {
        let harness = try await makeHarness(state: try seed("imageCommit"))
        addTeardownBlock { await harness.close() }
        let (uploads, calls) = uploads(harness) { Self.mediaURL($0) }
        let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        await uploads.start(.photo { png }, into: "mx", slot: slot, in: harness.session)?.value
        XCTAssertEqual(calls.value.map(\.1), ["photo.jpg"])
        XCTAssertEqual(calls.value.map(\.2), ["image/jpeg"])
        await harness.settle()
        XCTAssertEqual(MediaBlock.string("name", in: try props(harness, "mx")), "photo.jpg")
    }

    /// A URL that is not this server's media URL for this document (another
    /// document's, another origin's, a local path) is never written.
    func testOnlyThisDocumentsMediaURLIsWritten() async throws {
        let harness = try await makeHarness(state: try seed("imageCommit"))
        addTeardownBlock { await harness.close() }
        for answer in [
            Self.mediaURL(UUID()), Self.mediaURL(harness.scope.documentID, origin: "https://elsewhere.test"),
            "file:///private/var/mobile/photo.jpg", "\(Self.origin)/media/x.png",
        ] {
            let (uploads, _) = uploads(harness) { _ in answer }
            await uploads.start(.file { Self.file }, into: "mx", slot: slot, in: harness.session)?.value
            XCTAssertEqual(uploads.failure?.key, .native_editor_media_upload_failed, answer)
        }
        await harness.settle()
        XCTAssertEqual(MediaBlock.string("url", in: try props(harness, "mx")), "")
        try await assertConsistent(harness, localCommands: 0)
    }

    /// The block is deleted, or filled, while its upload runs: the commit's
    /// slot no longer matches and nothing is written over it.
    func testACommitIsRefusedWhenItsBlockChangedDuringTheUpload() async throws {
        for change in ["delete", "fill"] {
            let harness = try await makeHarness(state: try seed("imageCommit"))
            let gate = Latch()
            let (uploads, _) = uploads(harness, gate: gate) { Self.mediaURL($0) }
            let task = try XCTUnwrap(uploads.start(.file { Self.file }, into: "mx", slot: slot, in: harness.session))
            let other = "https://other.example/picture.png"
            if change == "delete" {
                _ = await harness.run { harness.input.deleteMedia("mx") }
            } else {
                _ = await harness.run {
                    harness.input.setMediaProps("mx", [ProjectedProp(key: "url", value: .string(other))])
                }
            }
            gate.open()
            await task.value
            await harness.settle()
            if change == "delete" {
                XCTAssertNil(harness.session.surface.blocks.first { $0.id == "mx" }, change)
            } else {
                XCTAssertEqual(MediaBlock.string("url", in: try props(harness, "mx")), other, change)
            }
            let written = await xml(harness)
            XCTAssertFalse(written.contains("6f0f6a54"), change)
            // A deleted block drops the commit before posting; a filled one is refused by the engine.
            if change == "delete" {
                XCTAssertEqual(uploads.failure?.key, .native_editor_media_upload_dropped, change)
            } else {
                XCTAssertEqual(harness.input.noticeKey, .native_editor_media_upload_dropped, change)
            }
            try await assertConsistent(harness, localCommands: 1)
            await harness.close()
        }
    }

    /// Offline, or a document only this device knows, refuses before any
    /// upload; and one upload runs at a time.
    func testOfflineLocalAndConcurrentUploadsAreRefused() async throws {
        let harness = try await makeHarness(state: try seed("imageCommit"))
        addTeardownBlock { await harness.close() }
        let (offline, offlineCalls) = uploads(harness, offline: true) { Self.mediaURL($0) }
        XCTAssertNil(offline.start(.file { Self.file }, into: "mx", slot: slot, in: harness.session))
        XCTAssertEqual(offline.failure?.key, .native_editor_media_upload_offline)
        XCTAssertFalse(offline.canUpload)
        let local = NativeMediaUploads(
            documentID: nil, serverOrigin: Self.origin, isOffline: { false },
            upload: { _, _, _, _ in nil })
        XCTAssertNil(local.start(.file { Self.file }, into: "mx", slot: slot, in: harness.session))
        let gate = Latch()
        let (busy, busyCalls) = uploads(harness, gate: gate) { Self.mediaURL($0) }
        let first = try XCTUnwrap(busy.start(.file { Self.file }, into: "mx", slot: slot, in: harness.session))
        XCTAssertFalse(busy.canUpload)
        XCTAssertNil(busy.start(.file { Self.file }, into: "mx", slot: slot, in: harness.session))
        gate.open()
        await first.value
        XCTAssertEqual(offlineCalls.value.count, 0)
        XCTAssertEqual(busyCalls.value.count, 1)
    }

    /// The editor closes (Done, sign-out) while the upload runs: the commit is
    /// dropped, never posted to another session, and nothing crashes.
    func testAnUploadFinishingAfterTheEditorClosedIsDropped() async throws {
        let harness = try await makeHarness(state: try seed("imageCommit"))
        let gate = Latch()
        let (uploads, _) = uploads(harness, gate: gate) { Self.mediaURL($0) }
        let task = try XCTUnwrap(uploads.start(.file { Self.file }, into: "mx", slot: slot, in: harness.session))
        await harness.session.close().value
        gate.open()
        await task.value
        XCTAssertEqual(uploads.failure?.key, .native_editor_media_upload_dropped)
        let restored = try XCTUnwrap(harness.store.restore(for: harness.scope))
        XCTAssertTrue(restored.manifest.journal.isEmpty)
        await harness.close()
    }

    /// A file too large for the picker's limit fails with its own notice.
    func testATooLargeFileFailsWithItsOwnNotice() async throws {
        let harness = try await makeHarness(state: try seed("imageCommit"))
        addTeardownBlock { await harness.close() }
        let (uploads, calls) = uploads(harness) { Self.mediaURL($0) }
        await uploads.start(
            .file { throw AttachmentImportError.tooLarge }, into: "mx", slot: slot, in: harness.session)?.value
        XCTAssertEqual(uploads.failure?.key, .editor_error_file_too_large)
        XCTAssertTrue(calls.value.isEmpty)
    }
}
