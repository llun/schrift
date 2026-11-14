import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest
import zlib

@testable import Schrift

/// PR13b2 Step 4: `NativeMediaDropPaste`, `NativeMediaDropController` (`UIDropInteraction`
/// + `UITextDropDelegate` + drop indicator), clipboard precedence, size/type/count limits,
/// root & column surface routing, EXIF GPS stripping, PR13b durable queue routing, and
/// gating across reader, local unsaved doc, table cell, and source editor surfaces.
@MainActor
final class NativeMediaDropPasteTests: NativeEditingTestCase {
    private nonisolated static let origin = "https://docs.example"
    private nonisolated static let owner = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    private nonisolated static let mediaPath =
        "/media/11111111-2222-4333-8444-555555555555/attachments/66666666-7777-4888-8999-aaaaaaaaaaaa.jpg"

    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows {
            window.endEditing(true)
            window.isHidden = true
        }
        windows = []
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func privatePasteboard() -> UIPasteboard {
        let name = UIPasteboard.Name("test.drop-paste.\(UUID().uuidString)")
        let pb = UIPasteboard(name: name, create: true)!
        addTeardownBlock { UIPasteboard.remove(withName: name) }
        return pb
    }

    private func tempDir(_ label: String = "tmp") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeMediaDropPasteTests-\(label)-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeReaderSession(_ blocks: [BlockNoteBlock]) async throws -> NativeEditorSession {
        let dir = try tempDir("reader")
        let scope = ReplicaScope(
            serverOrigin: "https://example.test", ownerUserID: UUID(), org: "docs", documentID: UUID())
        let store = ReplicaStore(directory: dir)
        let state = BlockNoteYjs.encode(blocks, clientID: Self.seedClientID)
        _ = try store.create(for: scope, checkpoint: state)
        let restored = try await NativeEditorSession.restore(store: store, scope: scope)
        let session = try XCTUnwrap(restored)
        addTeardownBlock { await session.close().value }
        return session
    }

    private func waitForCondition(
        seconds: TimeInterval = 3.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "timed out waiting for condition", file: file, line: line)
    }

    private func makeUploadEnv(
        for harness: Harness,
        online: Bool = true,
        onUploadBody: (@Sendable (Data) -> Void)? = nil
    ) throws -> (
        uploads: NativeMediaUploads,
        coordinator: DocumentSaveCoordinator,
        registry: NativeSessionRegistry,
        attachments: PendingAttachmentStore,
        log: RequestRecorder
    ) {
        let scopeOrigin = harness.scope.serverOrigin
        let scopeOwner = harness.scope.ownerUserID
        let dir = try tempDir("uploads")
        let suite = "NativeMediaDropPaste.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        SignedInUserStore(userDefaults: defaults).remember(scopeOwner)

        var abilities = DocumentAbilities()
        abilities.update = true
        let doc = Document(
            id: harness.scope.documentID, title: "Doc", excerpt: nil, abilities: abilities,
            linkReach: .restricted, linkRole: .reader, isFavorite: false, depth: 1, numchild: 0,
            path: "0001", createdAt: Date(), updatedAt: Date(), userRole: nil, creator: nil)
        DocumentCacheStore(userDefaults: defaults).saveRecentDocuments([doc], fetchedFor: scopeOwner)

        let attachments = PendingAttachmentStore(
            userDefaults: defaults, directory: dir.appendingPathComponent("bytes"))
        let requestLog = RequestRecorder()
        let docIDLower = harness.scope.documentID.uuidString.lowercased()

        MockURLProtocol.stubHandler = { request in
            requestLog.record(request)
            if request.httpMethod == "POST",
                request.url?.absoluteString.contains("attachment-upload") == true,
                let body = bodyData(from: request)
            {
                onUploadBody?(body)
            }
            if !online {
                return .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
            }
            let url = request.url?.absoluteString ?? ""
            switch request.httpMethod {
            case "POST" where url.contains("attachment-upload"):
                return .init(
                    statusCode: 201, headers: [:],
                    body: Data(#"{"file": "/api/v1.0/documents/x/media-check/?key=k.jpg"}"#.utf8), error: nil)
            case "GET" where url.contains("media-check"):
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data(#"{"status": "ready", "file": "\#(scopeOrigin + Self.mediaPath)"}"#.utf8), error: nil)
            case "GET" where url.hasSuffix("documents/\(docIDLower)/"):
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data(#"{"id": "\#(docIDLower)", "abilities": {"update": true}}"#.utf8), error: nil)
            default:
                return .init(statusCode: 404, headers: [:], body: Data(), error: nil)
            }
        }

        let client = DocsAPIClient(
            baseURL: URL(string: scopeOrigin + "/api/v1.0/")!,
            session: MockURLProtocol.makeSession(),
            cookieProvider: { [] })
        let coordinator = DocumentSaveCoordinator(
            client: client,
            draftStore: PendingDraftStore(userDefaults: defaults),
            replicaStore: harness.store,
            contentCache: DocumentContentCacheStore(directory: dir.appendingPathComponent("cache")),
            createStore: PendingDocumentCreateStore(userDefaults: defaults),
            attachmentStore: attachments,
            listCache: DocumentCacheStore(userDefaults: defaults),
            childrenCache: DocumentChildrenCacheStore(userDefaults: defaults),
            serverOrigin: scopeOrigin,
            mediaCheckMaxAttempts: 1,
            mediaCheckRetryInterval: .milliseconds(1),
            backgroundTasks: .noop)
        let registry = NativeSessionRegistry()
        coordinator.nativeSessions = registry
        coordinator.nativeEditorEnabled = { true }
        coordinator.nativeCommitAttempts = 3
        coordinator.nativeCommitInterval = .milliseconds(10)

        let uploads = NativeMediaUploads(scope: harness.scope, queue: coordinator)
        harness.input.mediaUploads = uploads

        addTeardownBlock {
            MockURLProtocol.reset()
            await registry.closeAll().value
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return (uploads, coordinator, registry, attachments, requestLog)
    }

    private func hostInWindow(_ view: UIView, width: CGFloat = 390, height: CGFloat = 700) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.frame = window.bounds
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.layoutIfNeeded()
        windows.append(window)
        return window
    }

    private func makeJPEGWithGPS(width: Int = 32, height: Int = 24) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let image = renderer.image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
        let metadata: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 37.7749,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.4194,
                kCGImagePropertyGPSLongitudeRef: "W",
            ]
        ]
        CGImageDestinationAddImage(dest, cgImage, metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func makePNGData() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12))
        let image = renderer.image { ctx in
            UIColor.systemOrange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
        return try XCTUnwrap(image.pngData())
    }

    @MainActor
    private final class StubDropSession: NSObject, @preconcurrency UIDropSession {
        var localDragSession: (any UIDragSession)?
        var progressIndicatorStyle: UIDropSessionProgressIndicatorStyle = .default
        var items: [UIDragItem]
        var allowsMoveOperation = true
        var isRestrictedToDraggingApplication = false
        nonisolated let progress = Progress()
        var point: CGPoint

        init(items: [UIDragItem], location: CGPoint = .zero, localDragSession: (any UIDragSession)? = nil) {
            self.items = items
            self.point = location
            self.localDragSession = localDragSession
            super.init()
        }

        func location(in view: UIView) -> CGPoint { point }

        func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool {
            items.contains { item in
                typeIdentifiers.contains { item.itemProvider.hasItemConformingToTypeIdentifier($0) }
            }
        }

        func canLoadObjects(ofClass aClass: any NSItemProviderReading.Type) -> Bool {
            items.contains { $0.itemProvider.canLoadObject(ofClass: aClass) }
        }

        func loadObjects(
            ofClass aClass: any NSItemProviderReading.Type,
            completion: @escaping ([any NSItemProviderReading]) -> Void
        ) -> Progress {
            completion([])
            return progress
        }
    }

    private func dataProvider(_ type: UTType, data: Data, name: String? = nil) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = name
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    // MARK: - 1. UTType -> MediaBlock Node Classification

    func testProviderClassificationAcrossAllMediaAndTextTypes() throws {
        let png = dataProvider(.png, data: Data([0x89, 0x50]), name: "shot.png")
        let heic = dataProvider(.heic, data: Data([0x00, 0x01]), name: "photo.heic")
        let jpeg = dataProvider(.jpeg, data: Data([0xFF, 0xD8]), name: "pic.jpg")
        let svg = dataProvider(.svg, data: Data("<svg/>".utf8), name: "vector.svg")
        let mp4 = dataProvider(.mpeg4Movie, data: Data([0x00, 0x00]), name: "clip.mp4")
        let mov = dataProvider(.quickTimeMovie, data: Data([0x00, 0x00]), name: "movie.mov")
        let mp3 = dataProvider(.mp3, data: Data([0x49, 0x44]), name: "song.mp3")
        let pdf = dataProvider(.pdf, data: Data("%PDF-1.4".utf8), name: "doc.pdf")
        let zip = dataProvider(.zip, data: Data([0x50, 0x4B]), name: "bundle.zip")

        XCTAssertEqual(NativeMediaDropPaste.classifyDropProvider(png), .media(node: "image", isImage: true))
        XCTAssertEqual(NativeMediaDropPaste.classifyDropProvider(heic), .media(node: "image", isImage: true))
        XCTAssertEqual(NativeMediaDropPaste.classifyDropProvider(jpeg), .media(node: "image", isImage: true))
        XCTAssertEqual(NativeMediaDropPaste.classifyDropProvider(svg), .file)
        XCTAssertEqual(NativeMediaDropPaste.classifyDropProvider(mp4), .media(node: "video", isImage: false))
        XCTAssertEqual(NativeMediaDropPaste.classifyDropProvider(mov), .media(node: "video", isImage: false))
        XCTAssertEqual(NativeMediaDropPaste.classifyDropProvider(mp3), .media(node: "audio", isImage: false))
        XCTAssertEqual(NativeMediaDropPaste.classifyDropProvider(pdf), .media(node: "pdf", isImage: false))
        XCTAssertEqual(NativeMediaDropPaste.classifyDropProvider(zip), .file)

        // TXT file on disk via NSItemProvider(contentsOf:) vs bare dragged plain text.
        let txtDir = try tempDir("txt")
        let txtURL = txtDir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: txtURL)
        let txtFileProvider = try XCTUnwrap(NSItemProvider(contentsOf: txtURL))
        XCTAssertEqual(NativeMediaDropPaste.classifyDropProvider(txtFileProvider), .file)

        let plainDragProvider = NSItemProvider(object: "just words" as NSString)
        XCTAssertEqual(NativeMediaDropPaste.classifyDropProvider(plainDragProvider), .ignore)

        // Bare folder and external web URL are never treated as media files.
        let folderProvider = dataProvider(.folder, data: Data(), name: "MyFolder")
        XCTAssertEqual(NativeMediaDropPaste.classifyDropProvider(folderProvider), .ignore)

        let urlProvider = NSItemProvider(object: URL(string: "https://example.test/article")! as NSURL)
        XCTAssertEqual(NativeMediaDropPaste.classifyDropProvider(urlProvider), .ignore)
    }

    // MARK: - 2. Clipboard Precedence

    func testClipboardTextPrecedenceNeverUploadsFallbackImageOrURL() async throws {
        let harness = try await makeHarness([paragraph("p1", "")])
        addTeardownBlock { await harness.close() }
        let env = try makeUploadEnv(for: harness)
        let pb = privatePasteboard()
        harness.input.pasteboard = pb
        let png = try makePNGData()

        // 1. Rich HTML + plain text + fallback PNG snapshot -> pastes text, 0 uploads.
        pb.setItems([
            [
                UTType.html.identifier: Data("<p>Rich text</p>".utf8),
                UTType.utf8PlainText.identifier: "Copied rich text",
                UTType.png.identifier: png,
            ]
        ])
        if case .textOrPayload = NativeMediaDropPaste.classifyPasteboard(pb) {
        } else {
            return XCTFail("HTML + fallback PNG must choose text/payload")
        }
        let richApplied = await harness.run { harness.input.pasteFromPasteboard() }
        XCTAssertTrue(richApplied)
        XCTAssertEqual(harness.session.surface.blocks.map(\.node), ["paragraph"])
        XCTAssertEqual(harness.session.surface.blocks[0].visibleText, "Copied rich text")
        XCTAssertTrue(env.attachments.allAttachments().isEmpty)

        // 2. HTML + fallback PNG without plain-text representation -> must NOT upload PNG as image.
        pb.setItems([
            [
                UTType.html.identifier: Data("<p>Only HTML</p>".utf8),
                UTType.png.identifier: png,
            ]
        ])
        if case .textOrPayload = NativeMediaDropPaste.classifyPasteboard(pb) {
        } else {
            return XCTFail("HTML + PNG without fileURL must not classify as image upload")
        }
        _ = harness.input.pasteFromPasteboard()
        await harness.settle()
        XCTAssertTrue(harness.session.surface.blocks.allSatisfy { $0.node == "paragraph" })
        XCTAssertTrue(env.attachments.allAttachments().isEmpty)

        // 3. Plain external web URL -> stays text paste, never uploads a file.
        pb.setItems([
            [
                UTType.url.identifier: URL(string: "https://external.example/path")! as NSURL,
                UTType.utf8PlainText.identifier: "https://external.example/path",
            ]
        ])
        if case .textOrPayload = NativeMediaDropPaste.classifyPasteboard(pb) {
        } else {
            return XCTFail("Plain URL must prefer text/payload over file upload")
        }
        let urlApplied = await harness.run { harness.input.pasteFromPasteboard() }
        XCTAssertTrue(urlApplied)
        XCTAssertTrue(harness.session.surface.blocks.allSatisfy { $0.node == "paragraph" })
        XCTAssertTrue(env.attachments.allAttachments().isEmpty)

        // 4. Files.app file copy (`public.file-url` + `public.plain-text` + filename) -> routes as "file".
        let fileDir = try tempDir("pb-file")
        let noteURL = fileDir.appendingPathComponent("notes.txt")
        try Data("from files".utf8).write(to: noteURL)
        pb.setItems([
            [
                UTType.fileURL.identifier: noteURL.dataRepresentation,
                UTType.plainText.identifier: Data("from files".utf8),
                UTType.utf8PlainText.identifier: "notes.txt",
            ]
        ])
        if case .media(let items) = NativeMediaDropPaste.classifyPasteboard(pb) {
            XCTAssertEqual(items.map(\.kind), [.file])
        } else {
            return XCTFail("Files.app file-url + filename must classify as file media")
        }
        _ = await harness.run { harness.input.pasteFromPasteboard() }
        await waitForCondition { !env.attachments.allAttachments().isEmpty }
        XCTAssertTrue(harness.session.surface.blocks.contains { $0.node == "file" })

        // 5. Direct UIImage on pasteboard -> classifies as "image".
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        pb.image = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        if case .media(let items) = NativeMediaDropPaste.classifyPasteboard(pb) {
            XCTAssertEqual(items.map(\.kind), [.media(node: "image", isImage: true)])
        } else {
            return XCTFail("UIImage on pasteboard must classify as image")
        }
    }

    // MARK: - 3. canPerformAction Gating Across Surfaces (Private Pasteboard Only)

    func testCanPerformActionPasteGatingAcrossSurfaces() async throws {
        let pb = privatePasteboard()
        let png = try makePNGData()
        let pasteAction = #selector(UIResponderStandardEditActions.paste(_:))

        // Editable root surface: empty -> false; PNG -> true.
        let harness = try await makeHarness([paragraph("p1", "Hello")])
        addTeardownBlock { await harness.close() }
        harness.input.pasteboard = pb
        pb.items = []
        XCTAssertFalse(harness.view.canPerformAction(pasteAction, withSender: nil))

        pb.setItems([[UTType.png.identifier: png]])
        XCTAssertTrue(harness.view.canPerformAction(pasteAction, withSender: nil))

        // Reader (non-editable root): PNG -> false.
        let reader = try await makeReaderSession([paragraph("p1", "Readonly")])
        XCTAssertFalse(reader.textView.isEditable)
        XCTAssertFalse(reader.textView.canPerformAction(pasteAction, withSender: nil))

        // Table cell coordinator (`tableMove` / `tableKey` set): PNG -> false, plain string -> true.
        harness.input.tableMove = { _ in false }
        harness.input.tableKey = { _ in false }
        XCTAssertFalse(harness.view.canPerformAction(pasteAction, withSender: nil))
        pb.setItems([[UTType.utf8PlainText.identifier: "cell text"]])
        XCTAssertTrue(harness.view.canPerformAction(pasteAction, withSender: nil))
        harness.input.tableMove = nil
        harness.input.tableKey = nil

        // Source editor (`.mathBlock`): PNG -> false, plain string -> true.
        let mathHarness = try await makeHarness([paragraph("p1", "")])
        addTeardownBlock { await mathHarness.close() }
        setSelection(mathHarness, NSRange(location: 0, length: 0))
        mathHarness.view.insertText("/math")
        await mathHarness.settle()
        let mathItem = try XCTUnwrap(NativeInputCoordinator.slashItems.first { $0.id == "mathBlock" })
        _ = await mathHarness.run { mathHarness.input.applySlashItem(mathItem) }
        let req = try XCTUnwrap(mathHarness.input.requestedSource)
        let sourceVC = NativeSourceEditorViewController(document: mathHarness.session, request: req)
        _ = hostInWindow(sourceVC.view)
        for _ in 0..<200 where sourceVC.sourceSession == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let sourceSession = try XCTUnwrap(sourceVC.sourceSession)
        sourceSession.input?.pasteboard = pb
        pb.setItems([[UTType.png.identifier: png]])
        XCTAssertFalse(sourceSession.textView.canPerformAction(pasteAction, withSender: nil))
        let sourceCanDrop = sourceSession.input?.canAcceptMediaDrop ?? true
        XCTAssertFalse(sourceCanDrop)
        pb.setItems([[UTType.utf8PlainText.identifier: "x^2"]])
        XCTAssertTrue(sourceSession.textView.canPerformAction(pasteAction, withSender: nil))
    }

    // MARK: - 4. Paste Placement (Empty Paragraph, Prose, Selection, Nested Child)

    func testPastePlacementInEmptyParagraphProseSelectionAndNestedList() async throws {
        let nested = BlockNoteBlock(
            node: "bulletListItem", props: paragraph("b", "").props, runs: [InlineRun("Root bullet")], id: "rootBullet",
            children: [paragraph("child", "Nested line")])
        let harness = try await makeHarness([
            paragraph("empty", ""),
            paragraph("prose", "Keep this prose"),
            nested,
        ])
        addTeardownBlock { await harness.close() }
        _ = try makeUploadEnv(for: harness, online: false)
        let pb = privatePasteboard()
        harness.input.pasteboard = pb
        let png = try makePNGData()
        pb.setItems([[UTType.png.identifier: png]])

        // 1. Pasting into empty paragraph replaces "empty" in place.
        let emptyLoc = try location(harness.session, "empty", 0)
        setSelection(harness, NSRange(location: emptyLoc, length: 0))
        let replacedEmpty = await harness.run { harness.input.pasteFromPasteboard() }
        XCTAssertTrue(replacedEmpty)
        XCTAssertEqual(harness.session.surface.blocks[0].id, "empty")
        XCTAssertEqual(harness.session.surface.blocks[0].node, "image")

        // 2. Pasting with non-collapsed selection inside prose inserts AFTER prose without deleting prose.
        let proseLoc = try location(harness.session, "prose", 0)
        setSelection(harness, NSRange(location: proseLoc, length: 4))
        let pastedAfterProse = await harness.run { harness.input.pasteFromPasteboard() }
        XCTAssertTrue(pastedAfterProse)
        let afterProseIDs = harness.session.surface.blocks.map(\.id)
        let proseIndex = try XCTUnwrap(afterProseIDs.firstIndex(of: "prose"))
        XCTAssertEqual(harness.session.surface.blocks[proseIndex].visibleText, "Keep this prose")
        XCTAssertEqual(harness.session.surface.blocks[proseIndex + 1].node, "image")

        // 3. Pasting inside nested child ("child", depth 1) walks up and inserts AFTER "rootBullet" at depth 0.
        let childLoc = try location(harness.session, "child", 2)
        setSelection(harness, NSRange(location: childLoc, length: 0))
        let pastedAfterNested = await harness.run { harness.input.pasteFromPasteboard() }
        XCTAssertTrue(pastedAfterNested)
        let blocks = harness.session.surface.blocks
        let nestedIdx = try XCTUnwrap(blocks.firstIndex { $0.id == "child" })
        XCTAssertEqual(blocks[nestedIdx + 1].node, "image")
        XCTAssertEqual(blocks[nestedIdx + 1].depth, 0)
    }

    // MARK: - 5. Drop Hit-Testing & Indicator Chrome

    func testDropHitTestingTopHalfBottomHalfEmptyParagraphAndIndicatorChrome() async throws {
        let nested = BlockNoteBlock(
            node: "bulletListItem", props: paragraph("b", "").props, runs: [InlineRun("Parent list")], id: "listRoot",
            children: [paragraph("listChild", "Nested child text")])
        let harness = try await makeHarness([
            paragraph("emptyTop", ""),
            paragraph("midProse", "Middle paragraph with enough words to span lines nicely on narrow canvas"),
            nested,
        ])
        addTeardownBlock { await harness.close() }
        _ = try makeUploadEnv(for: harness, online: false)
        _ = hostInWindow(harness.view)
        harness.view.layoutIfNeeded()

        let dropController = try XCTUnwrap(harness.view.mediaDropController)
        let inset = harness.view.textContainerInset
        let layoutManager = try XCTUnwrap(harness.view.textLayoutManager)
        let contentManager = try XCTUnwrap(layoutManager.textContentManager)
        let docStart = contentManager.documentRange.location

        func frame(of blockID: String) throws -> CGRect {
            let entry = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: blockID))
            let loc = try XCTUnwrap(contentManager.location(docStart, offsetBy: entry.range.location))
            let frag = try XCTUnwrap(layoutManager.textLayoutFragment(for: loc))
            return frag.layoutFragmentFrame
        }

        let emptyFrame = try frame(of: "emptyTop")
        let proseFrame = try frame(of: "midProse")
        let listChildFrame = try frame(of: "listChild")
        let xMid: CGFloat = 100

        // Empty paragraph -> `.replace`
        let emptyHit = dropController.hitTestDrop(
            at: CGPoint(x: xMid, y: inset.top + emptyFrame.midY))
        XCTAssertEqual(emptyHit?.target, .replace(blockID: "emptyTop"))

        // Prose top half -> `.before`, bottom half -> `.after`.
        let topPoint = CGPoint(x: xMid, y: inset.top + proseFrame.minY + 2)
        let bottomPoint = CGPoint(x: xMid, y: inset.top + proseFrame.maxY - 2)
        let topHit = dropController.hitTestDrop(at: topPoint)
        let bottomHit = dropController.hitTestDrop(at: bottomPoint)
        if case .before(let id, _)? = topHit?.target {
            XCTAssertEqual(id, "midProse")
        } else {
            return XCTFail("expected .before for top half, got \(String(describing: topHit))")
        }
        if case .after(let id, _)? = bottomHit?.target {
            XCTAssertEqual(id, "midProse")
        } else {
            return XCTFail("expected .after for bottom half, got \(String(describing: bottomHit))")
        }

        // Below all fragments -> `.after(listRoot)`.
        let belowAllHit = dropController.hitTestDrop(
            at: CGPoint(x: xMid, y: inset.top + listChildFrame.maxY + 40))
        if case .after(let id, _)? = belowAllHit?.target {
            XCTAssertEqual(id, "listRoot")
        } else {
            return XCTFail("expected .after(listRoot) below all fragments, got \(String(describing: belowAllHit))")
        }

        // Nested child resolves to enclosing root block ("listRoot") spanning parent+child.
        let childBottomPoint = CGPoint(x: xMid, y: inset.top + listChildFrame.maxY - 2)
        let nestedHit = dropController.hitTestDrop(at: childBottomPoint)
        if case .after(let id, _)? = nestedHit?.target {
            XCTAssertEqual(id, "listRoot")
        } else {
            return XCTFail("expected .after(listRoot), got \(String(describing: nestedHit))")
        }

        // `sessionDidUpdate` shows indicator and returns `.copy`; `sessionDidExit` hides indicator.
        let interaction = try XCTUnwrap(harness.view.interactions.compactMap { $0 as? UIDropInteraction }.first)
        let png = try makePNGData()
        let dropSession = StubDropSession(
            items: [UIDragItem(itemProvider: dataProvider(.png, data: png))], location: topPoint)
        XCTAssertTrue(dropController.dropInteraction(interaction, canHandle: dropSession))
        let proposal = dropController.dropInteraction(interaction, sessionDidUpdate: dropSession)
        XCTAssertEqual(proposal.operation, UIDropOperation.copy)
        XCTAssertTrue(dropController.isShowingDropIndicator)

        dropController.dropInteraction(interaction, sessionDidExit: dropSession)
        XCTAssertFalse(dropController.isShowingDropIndicator)
    }

    // MARK: - 6. End-to-End Drop + EXIF GPS Stripping + PR13b Queue

    func testPerformDropEndToEndEXIFGPSStrippingAndPR13bQueue() async throws {
        let harness = try await makeHarness([paragraph("p1", "Lead"), paragraph("p2", "Tail")])
        addTeardownBlock { await harness.close() }
        let uploadedData = Locked<Data?>(nil)
        let env = try makeUploadEnv(for: harness, online: true) { body in
            uploadedData.value = body
        }
        _ = hostInWindow(harness.view)

        let gpsJPEG = try makeJPEGWithGPS()
        let sourceSource = try XCTUnwrap(CGImageSourceCreateWithData(gpsJPEG as CFData, nil))
        let sourceProps = CGImageSourceCopyPropertiesAtIndex(sourceSource, 0, nil) as? [CFString: Any]
        XCTAssertNotNil(sourceProps?[kCGImagePropertyGPSDictionary], "test fixture has GPS EXIF")

        let interaction = try XCTUnwrap(harness.view.interactions.compactMap { $0 as? UIDropInteraction }.first)
        let dropController = try XCTUnwrap(harness.view.mediaDropController)
        let dropSession = StubDropSession(
            items: [UIDragItem(itemProvider: dataProvider(.jpeg, data: gpsJPEG, name: "gps.jpg"))],
            location: CGPoint(x: 80, y: 120))

        _ = dropController.dropInteraction(interaction, sessionDidUpdate: dropSession)
        dropController.dropInteraction(interaction, performDrop: dropSession)

        await waitForCondition {
            harness.session.surface.blocks.contains { $0.node == "image" } && uploadedData.value != nil
        }

        let imageBlock = try XCTUnwrap(harness.session.surface.blocks.first { $0.node == "image" })
        XCTAssertEqual(imageBlock.depth, 0)
        XCTAssertGreaterThanOrEqual(env.log.count(ofMethod: "POST", urlContaining: "attachment-upload"), 1)

        // Verify EXIF GPS dictionary was stripped before upload bytes ever left.
        let body = try XCTUnwrap(uploadedData.value)
        let startMarker = Data([0xFF, 0xD8, 0xFF])
        let endMarker = Data([0xFF, 0xD9])
        let startRange = try XCTUnwrap(body.range(of: startMarker))
        let endRange = try XCTUnwrap(body.range(of: endMarker, options: .backwards))
        let jpegSlice = body[startRange.lowerBound..<endRange.upperBound]
        let uploadedSource = try XCTUnwrap(CGImageSourceCreateWithData(jpegSlice as CFData, nil))
        let uploadedProps = CGImageSourceCopyPropertiesAtIndex(uploadedSource, 0, nil) as? [CFString: Any]
        XCTAssertNil(uploadedProps?[kCGImagePropertyGPSDictionary], "GPS EXIF metadata must be stripped")
    }

    // MARK: - 7. Column Drop Activation & Queue Forwarding

    func testColumnDropActivatesTargetColumnAndQueuesUpload() async throws {
        let capture = try XCTUnwrap(BlockNoteColumnCaptures.fixtures.first { $0.name == "two" })
        let seed = try XCTUnwrap(Data(base64Encoded: capture.update))
        let harness = try await makeHarness(state: seed)
        addTeardownBlock { await harness.close() }
        let env = try makeUploadEnv(for: harness, online: false)

        let model = ColumnEditorModel(document: harness.session, groupID: "cl")
        addTeardownBlock { model.close() }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let loc = LocalizationStore(userDefaults: defaults)
        loc.language = .english
        let screen = ColumnEditorScreen(model: model, serverOrigin: Self.origin, uploads: env.uploads).environment(loc)
        let vc = UIHostingController(rootView: screen)
        _ = hostInWindow(vc.view)

        await waitForCondition { model.isLoaded && model.columns.count == 2 }
        XCTAssertTrue(model.activeSession === model.columns[0])

        let col2 = model.columns[1]
        let col2Controller = try XCTUnwrap(col2.textView.mediaDropController)
        let col2Interaction = try XCTUnwrap(col2.textView.interactions.compactMap { $0 as? UIDropInteraction }.first)
        let pdfBytes = Data("%PDF-1.4 column drop".utf8)
        let dropSession = StubDropSession(
            items: [UIDragItem(itemProvider: dataProvider(.pdf, data: pdfBytes, name: "col.pdf"))],
            location: CGPoint(x: 40, y: 20))

        let proposal = col2Controller.dropInteraction(col2Interaction, sessionDidUpdate: dropSession)
        XCTAssertEqual(proposal.operation, UIDropOperation.copy)
        col2Controller.dropInteraction(col2Interaction, performDrop: dropSession)

        await waitForCondition {
            model.activeSession === col2
                && col2.surface.blocks.contains { $0.node == "pdf" }
                && !env.attachments.allAttachments().isEmpty
        }

        XCTAssertTrue(model.activeSession === col2, "drop onto inactive column activates target column")
        XCTAssertTrue(col2.surface.blocks.contains { $0.node == "pdf" && $0.depth == 0 })
        let queued = try XCTUnwrap(env.attachments.allAttachments().first)
        XCTAssertEqual(queued.native?.slot.node, "pdf")
        XCTAssertEqual(queued.native?.fileName, "col.pdf")
    }

    // MARK: - 8. >50 MB File Limit

    func testOversizeFileRefusedBeforeQueueingBytes() async throws {
        // 1. Direct staging check with sparse >50 MB file on disk (uses zero real data blocks).
        let dir = try tempDir("oversize")
        let hugeURL = dir.appendingPathComponent("huge.bin")
        FileManager.default.createFile(atPath: hugeURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: hugeURL)
        try handle.truncate(atOffset: UInt64(attachmentImportByteLimit + 1))
        try handle.close()

        let provider = try XCTUnwrap(NSItemProvider(contentsOf: hugeURL))
        let stagingRoot = dir.appendingPathComponent("staging", isDirectory: true)
        let batch = NativeMediaDropPaste.stage(
            providers: [(provider, .file)], stagingRoot: stagingRoot, byteLimit: attachmentImportByteLimit)
        let staged = await batch.waitAll()
        XCTAssertEqual(staged.count, 1)
        XCTAssertTrue(staged[0].exceededByteLimit)
        XCTAssertNil(staged[0].stagingURL, "oversize file must never be copied into staging")

        // 2. End-to-end drop: `uploads.failure` surfaces `.editor_error_file_too_large` and leaves queue empty.
        let harness = try await makeHarness([paragraph("p1", "Lead")])
        addTeardownBlock { await harness.close() }
        let env = try makeUploadEnv(for: harness, online: true)
        _ = hostInWindow(harness.view)

        let interaction = try XCTUnwrap(harness.view.interactions.compactMap { $0 as? UIDropInteraction }.first)
        let dropController = try XCTUnwrap(harness.view.mediaDropController)
        let dropSession = StubDropSession(
            items: [UIDragItem(itemProvider: provider)], location: CGPoint(x: 40, y: 20))
        dropController.dropInteraction(interaction, performDrop: dropSession)

        await waitForCondition { env.uploads.failure?.key == .editor_error_file_too_large }
        XCTAssertEqual(env.uploads.failure?.key, .editor_error_file_too_large)
        XCTAssertTrue(
            env.attachments.allAttachments().isEmpty, "oversize item must never enqueue into PendingAttachmentStore")
    }

    // MARK: - 9. >10 Items Limit (Zero Yjs Writes)

    func testOverTenItemsRefusedBeforeAnyYjsOrQueueWrite() async throws {
        let harness = try await makeHarness([paragraph("p1", "Only block")])
        addTeardownBlock { await harness.close() }
        let env = try makeUploadEnv(for: harness, online: false)
        _ = hostInWindow(harness.view)

        let png = try makePNGData()
        let elevenDragItems = (0..<11).map { i in
            UIDragItem(itemProvider: dataProvider(.png, data: png, name: "img\(i).png"))
        }

        // Drop 11 items -> refused before any Yjs or queue write.
        let dropController = try XCTUnwrap(harness.view.mediaDropController)
        let interaction = try XCTUnwrap(harness.view.interactions.compactMap { $0 as? UIDropInteraction }.first)
        let dropSession = StubDropSession(items: elevenDragItems, location: CGPoint(x: 40, y: 20))
        _ = dropController.dropInteraction(interaction, sessionDidUpdate: dropSession)
        dropController.dropInteraction(interaction, performDrop: dropSession)
        await harness.settle()

        XCTAssertEqual(harness.input.noticeKey, .native_editor_media_drop_limit)
        XCTAssertEqual(harness.session.surface.blocks.map(\.id), ["p1"])
        XCTAssertTrue(env.attachments.allAttachments().isEmpty)

        // Paste 11 items via private pasteboard -> refused before any Yjs or queue write.
        let pb = privatePasteboard()
        harness.input.pasteboard = pb
        pb.setItems((0..<11).map { _ in [UTType.png.identifier: png] })
        XCTAssertFalse(harness.input.pasteFromPasteboard())
        await harness.settle()

        XCTAssertEqual(harness.input.noticeKey, .native_editor_media_drop_limit)
        XCTAssertEqual(harness.session.surface.blocks.map(\.id), ["p1"])
        XCTAssertTrue(env.attachments.allAttachments().isEmpty)
    }

    // MARK: - 10. Offline vs. Local Unsaved / Reader / Table / Source

    func testOfflineQueuesWaitingWhileLocalUnsavedReaderTableAndSourceRefuse() async throws {
        let png = try makePNGData()
        let dragItems = [UIDragItem(itemProvider: dataProvider(.png, data: png, name: "offline.png"))]

        // 1. Offline server doc -> accepts drop, queues into PendingAttachmentStore.
        let offlineHarness = try await makeHarness([paragraph("p1", "")])
        addTeardownBlock { await offlineHarness.close() }
        let offlineEnv = try makeUploadEnv(for: offlineHarness, online: false)
        _ = hostInWindow(offlineHarness.view)

        let offlineDrop = try XCTUnwrap(offlineHarness.view.mediaDropController)
        let offlineInteraction = try XCTUnwrap(
            offlineHarness.view.interactions.compactMap { $0 as? UIDropInteraction }.first)
        let offlineSession = StubDropSession(items: dragItems, location: CGPoint(x: 40, y: 20))
        let offlineProposal = offlineDrop.dropInteraction(offlineInteraction, sessionDidUpdate: offlineSession)
        XCTAssertEqual(offlineProposal.operation, UIDropOperation.copy)
        offlineDrop.dropInteraction(offlineInteraction, performDrop: offlineSession)

        await waitForCondition {
            offlineHarness.session.surface.blocks.contains { $0.node == "image" }
                && !offlineEnv.attachments.allAttachments().isEmpty
        }
        XCTAssertEqual(offlineEnv.attachments.allAttachments().count, 1)

        // 2. Local unsaved document (`uploads.scope == nil`) -> drop `.forbidden`, paste refuses with offline notice.
        let localHarness = try await makeHarness([paragraph("p1", "")])
        addTeardownBlock { await localHarness.close() }
        let localDir = try tempDir("local-doc")
        let localSuite = "LocalDoc.\(UUID().uuidString)"
        let localDefaults = try XCTUnwrap(UserDefaults(suiteName: localSuite))
        addTeardownBlock { UserDefaults(suiteName: localSuite)?.removePersistentDomain(forName: localSuite) }
        let localCoordinator = DocumentSaveCoordinator(
            client: DocsAPIClient(
                baseURL: URL(string: Self.origin + "/api/v1.0/")!, session: MockURLProtocol.makeSession(),
                cookieProvider: { [] }),
            draftStore: PendingDraftStore(userDefaults: localDefaults),
            replicaStore: ReplicaStore(directory: localDir.appendingPathComponent("replicas")),
            contentCache: DocumentContentCacheStore(directory: localDir.appendingPathComponent("cache")),
            createStore: PendingDocumentCreateStore(userDefaults: localDefaults),
            attachmentStore: PendingAttachmentStore(
                userDefaults: localDefaults, directory: localDir.appendingPathComponent("bytes")),
            listCache: DocumentCacheStore(userDefaults: localDefaults),
            childrenCache: DocumentChildrenCacheStore(userDefaults: localDefaults),
            serverOrigin: Self.origin,
            backgroundTasks: .noop)
        localHarness.input.mediaUploads = NativeMediaUploads(scope: nil, queue: localCoordinator)
        _ = hostInWindow(localHarness.view)

        let localDrop = try XCTUnwrap(localHarness.view.mediaDropController)
        let localInteraction = try XCTUnwrap(
            localHarness.view.interactions.compactMap { $0 as? UIDropInteraction }.first)
        XCTAssertEqual(
            localDrop.dropInteraction(localInteraction, sessionDidUpdate: StubDropSession(items: dragItems)).operation,
            UIDropOperation.forbidden)
        XCTAssertFalse(localDrop.isShowingDropIndicator)

        let pb = privatePasteboard()
        localHarness.input.pasteboard = pb
        pb.setItems([[UTType.png.identifier: png]])
        XCTAssertFalse(localHarness.input.pasteFromPasteboard())
        await localHarness.settle()
        XCTAssertEqual(localHarness.input.noticeKey, .native_editor_media_upload_offline)
        XCTAssertEqual(localHarness.session.surface.blocks.map(\.node), ["paragraph"])

        // 3. Reader (`!isEditable`), table cell, and source editor all return `.forbidden` for media drop.
        let reader = try await makeReaderSession([paragraph("p1", "Locked")])
        _ = hostInWindow(reader.textView)
        let readerDrop = try XCTUnwrap(reader.textView.mediaDropController)
        let readerInteraction = try XCTUnwrap(
            reader.textView.interactions.compactMap { $0 as? UIDropInteraction }.first)
        let readerProposal = readerDrop.dropInteraction(
            readerInteraction, sessionDidUpdate: StubDropSession(items: dragItems))
        XCTAssertEqual(readerProposal.operation, UIDropOperation.forbidden)

        offlineHarness.input.tableMove = { _ in false }
        let tableProposal = offlineDrop.dropInteraction(
            offlineInteraction, sessionDidUpdate: StubDropSession(items: dragItems))
        XCTAssertEqual(tableProposal.operation, UIDropOperation.forbidden)
        offlineHarness.input.tableMove = nil
    }

    // MARK: - 11. Security Findings S1, S4, S5, S6 / C1 / C7

    func testS1StageRefusesSymlinksAppContainerAndBundleURLsAndPrefersLoadFileRepresentation() async throws {
        let dir = try tempDir("s1")
        let stagingRoot = dir.appendingPathComponent("staging", isDirectory: true)

        // 1. Relative symlink to Library/Preferences via NSItemProvider(contentsOf:) / file-url.
        let relSymlink = dir.appendingPathComponent("notes.txt")
        try FileManager.default.createSymbolicLink(
            atPath: relSymlink.path, withDestinationPath: "../../../../Library/Preferences/dev.llun.Schrift.plist")
        let relSymlinkProvider = NSItemProvider(object: relSymlink as NSURL)

        // 2. Symlink to a real regular file in tempDir.
        let realTemp = dir.appendingPathComponent("real.txt")
        try Data("hello".utf8).write(to: realTemp)
        let validSymlink = dir.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(at: validSymlink, withDestinationURL: realTemp)
        let validSymlinkProvider = NSItemProvider(object: validSymlink as NSURL)

        // 3. Direct file inside Library/Caches, Documents, and App Bundle via public.file-url.
        let cachesDir = try XCTUnwrap(
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        try FileManager.default.createDirectory(at: cachesDir, withIntermediateDirectories: true)
        let librarySecret = cachesDir.appendingPathComponent("s1-lib-\(UUID().uuidString).txt")
        try Data("secret-library".utf8).write(to: librarySecret)
        addTeardownBlock { try? FileManager.default.removeItem(at: librarySecret) }
        let libraryProvider = NSItemProvider(object: librarySecret as NSURL)

        let docsDir = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
        let docsSecret = docsDir.appendingPathComponent("s1-doc-\(UUID().uuidString).txt")
        try Data("secret-docs".utf8).write(to: docsSecret)
        addTeardownBlock { try? FileManager.default.removeItem(at: docsSecret) }
        let docsProvider = NSItemProvider(object: docsSecret as NSURL)

        let bundleFile = Bundle.main.bundleURL.appendingPathComponent("Info.plist")
        let bundleProvider = NSItemProvider(object: bundleFile as NSURL)

        let forbiddenBatch = NativeMediaDropPaste.stage(
            providers: [
                (relSymlinkProvider, .file),
                (validSymlinkProvider, .file),
                (libraryProvider, .file),
                (docsProvider, .file),
                (bundleProvider, .file),
            ],
            stagingRoot: stagingRoot)
        let forbiddenStaged = await forbiddenBatch.waitAll()
        for (idx, item) in forbiddenStaged.enumerated() {
            XCTAssertNil(item.stagingURL, "forbidden item \(idx) must not stage")
            XCTAssertFalse(item.exceededByteLimit, "forbidden item \(idx) must not report oversize")
        }

        // 4. Provider with BOTH loadFileRepresentation and loadObject(ofClass: URL.self):
        //    must prefer the system-brokered file representation over the raw file URL.
        let brokeredFile = dir.appendingPathComponent("brokered.txt")
        try Data("brokered-safe".utf8).write(to: brokeredFile)
        let dualProvider = NSItemProvider()
        dualProvider.suggestedName = "brokered.txt"
        dualProvider.registerFileRepresentation(
            forTypeIdentifier: UTType.plainText.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            completion(brokeredFile, false, nil)
            return nil
        }
        dualProvider.registerObject(librarySecret as NSURL, visibility: .all)

        let dualBatch = NativeMediaDropPaste.stage(
            providers: [(dualProvider, .file)], stagingRoot: stagingRoot)
        let dualStaged = await dualBatch.waitAll()
        let stagedURL = try XCTUnwrap(dualStaged.first?.stagingURL)
        XCTAssertEqual(try Data(contentsOf: stagedURL), Data("brokered-safe".utf8))
    }

    func testS4CopiedRichTextFlatRTFDWebArchiveAndTaggedPlainTextNeverUpload() async throws {
        let harness = try await makeHarness([paragraph("p1", "")])
        addTeardownBlock { await harness.close() }
        let env = try makeUploadEnv(for: harness)
        let pb = privatePasteboard()
        harness.input.pasteboard = pb
        let png = try makePNGData()

        // 1. com.apple.flat-rtfd + fallback PNG snapshot -> textOrPayload, 0 uploads.
        pb.setItems([
            [
                UTType.flatRTFD.identifier: Data("rtfd-bytes".utf8),
                UTType.png.identifier: png,
            ]
        ])
        if case .textOrPayload = NativeMediaDropPaste.classifyPasteboard(pb) {
        } else {
            return XCTFail("flatRTFD + PNG must classify as text/payload")
        }
        _ = harness.input.pasteFromPasteboard()
        await harness.settle()
        XCTAssertTrue(harness.session.surface.blocks.allSatisfy { $0.node == "paragraph" })
        XCTAssertTrue(env.attachments.allAttachments().isEmpty)

        // 2. com.apple.webarchive + fallback PNG snapshot -> textOrPayload, 0 uploads.
        pb.setItems([
            [
                UTType.webArchive.identifier: Data("webarchive-bytes".utf8),
                UTType.png.identifier: png,
            ]
        ])
        if case .textOrPayload = NativeMediaDropPaste.classifyPasteboard(pb) {
        } else {
            return XCTFail("webArchive + PNG must classify as text/payload")
        }
        _ = harness.input.pasteFromPasteboard()
        await harness.settle()
        XCTAssertTrue(harness.session.surface.blocks.allSatisfy { $0.node == "paragraph" })
        XCTAssertTrue(env.attachments.allAttachments().isEmpty)

        // 3. Plain text + custom public.data/plist metadata + PNG preview -> pastes text, 0 uploads.
        pb.setItems([
            [
                UTType.utf8PlainText.identifier: "Copied snippet",
                UTType.propertyList.identifier: Data("plist-meta".utf8),
                UTType.png.identifier: png,
            ]
        ])
        if case .textOrPayload = NativeMediaDropPaste.classifyPasteboard(pb) {
        } else {
            return XCTFail("plainText + metadata flavors without fileURL must classify as text/payload")
        }
        let applied = await harness.run { harness.input.pasteFromPasteboard() }
        XCTAssertTrue(applied)
        XCTAssertEqual(harness.session.surface.blocks.map(\.node), ["paragraph"])
        XCTAssertEqual(harness.session.surface.blocks[0].visibleText, "Copied snippet")
        XCTAssertTrue(env.attachments.allAttachments().isEmpty)
    }

    func testS5UnderClaimedImageProviderAndOpaqueFileImageStripEXIFAndBlockBomb() async throws {
        let gpsJPEG = try makeJPEGWithGPS()

        // 1. Provider claiming only public.data with suggestedName "IMG_1234.JPG" classifies as image.
        let namedDataProvider = dataProvider(.data, data: gpsJPEG, name: "IMG_1234.JPG")
        XCTAssertEqual(
            NativeMediaDropPaste.classifyDropProvider(namedDataProvider),
            .media(node: "image", isImage: true))

        // 2. Opaque .file drop (no image UTType AND non-image extension ".bin") containing GPS JPEG:
        //    NativeMediaUploads.prepare sniffs raster image bytes and strips GPS EXIF before queueing.
        let harness = try await makeHarness([paragraph("p1", "Lead")])
        addTeardownBlock { await harness.close() }
        let uploadedData = Locked<Data?>(nil)
        let env = try makeUploadEnv(for: harness, online: true) { body in
            uploadedData.value = body
        }
        _ = hostInWindow(harness.view)

        let opaqueProvider = dataProvider(.data, data: gpsJPEG, name: "opaque.bin")
        XCTAssertEqual(NativeMediaDropPaste.classifyDropProvider(opaqueProvider), .file)

        let interaction = try XCTUnwrap(harness.view.interactions.compactMap { $0 as? UIDropInteraction }.first)
        let dropController = try XCTUnwrap(harness.view.mediaDropController)
        let dropSession = StubDropSession(
            items: [UIDragItem(itemProvider: opaqueProvider)],
            location: CGPoint(x: 80, y: 120))
        _ = dropController.dropInteraction(interaction, sessionDidUpdate: dropSession)
        dropController.dropInteraction(interaction, performDrop: dropSession)

        await waitForCondition { uploadedData.value != nil }
        let body = try XCTUnwrap(uploadedData.value)
        let startMarker = Data([0xFF, 0xD8, 0xFF])
        let endMarker = Data([0xFF, 0xD9])
        let startRange = try XCTUnwrap(body.range(of: startMarker))
        let endRange = try XCTUnwrap(body.range(of: endMarker, options: .backwards))
        let jpegSlice = body[startRange.lowerBound..<endRange.upperBound]
        let uploadedSource = try XCTUnwrap(CGImageSourceCreateWithData(jpegSlice as CFData, nil))
        let uploadedProps = CGImageSourceCopyPropertiesAtIndex(uploadedSource, 0, nil) as? [CFString: Any]
        XCTAssertNil(uploadedProps?[kCGImagePropertyGPSDictionary], "GPS EXIF metadata must be stripped even on .file")

        // 3. Opaque .file drop containing a >100 MP decompression bomb fails instead of uploading raw bytes.
        let bombPNG = makeMinimal1BitPNG(width: 10_001, height: 10_001)
        let bombProvider = dataProvider(.data, data: bombPNG, name: "bomb.bin")
        let bombSession = StubDropSession(
            items: [UIDragItem(itemProvider: bombProvider)],
            location: CGPoint(x: 80, y: 120))
        _ = dropController.dropInteraction(interaction, sessionDidUpdate: bombSession)
        dropController.dropInteraction(interaction, performDrop: bombSession)

        await waitForCondition { env.uploads.failure?.key == .native_editor_media_upload_failed }
        XCTAssertEqual(env.uploads.failure?.key, .native_editor_media_upload_failed)
    }

    func testS6C1C7StagedFilesCleanedUpOnEveryExitPath() async throws {
        NativeMediaDropPaste.removeStagingRoot()
        addTeardownBlock { NativeMediaDropPaste.removeStagingRoot() }
        let stagingRoot = NativeMediaDropPaste.stagingRootDirectory()

        func stagedContents() -> [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)) ?? []
        }

        let png = try makePNGData()

        // 1. Barrier unsettled -> detach() cleans up staged files and batch directory.
        let detachHarness = try await makeHarness([paragraph("p1", "Lead")])
        addTeardownBlock { await detachHarness.close() }
        _ = try makeUploadEnv(for: detachHarness, online: false)
        _ = hostInWindow(detachHarness.view)
        let detachDrop = try XCTUnwrap(detachHarness.view.mediaDropController)
        let detachInteraction = try XCTUnwrap(
            detachHarness.view.interactions.compactMap { $0 as? UIDropInteraction }.first)
        let detachSession = StubDropSession(
            items: [UIDragItem(itemProvider: dataProvider(.png, data: png, name: "detach.png"))],
            location: CGPoint(x: 80, y: 80))
        _ = detachDrop.dropInteraction(detachInteraction, sessionDidUpdate: detachSession)
        detachDrop.dropInteraction(detachInteraction, performDrop: detachSession)
        XCTAssertFalse(stagedContents().isEmpty, "staging directory must exist immediately after drop")
        detachHarness.input.detach()
        await waitForCondition { stagedContents().isEmpty }

        // 2. Barrier unsettled -> stopAfterStorageFailure() cleans up staged files and batch directory.
        let failHarness = try await makeHarness([paragraph("p1", "Lead")])
        addTeardownBlock { await failHarness.close() }
        _ = try makeUploadEnv(for: failHarness, online: false)
        _ = hostInWindow(failHarness.view)
        let failDrop = try XCTUnwrap(failHarness.view.mediaDropController)
        let failInteraction = try XCTUnwrap(
            failHarness.view.interactions.compactMap { $0 as? UIDropInteraction }.first)
        let failSession = StubDropSession(
            items: [UIDragItem(itemProvider: dataProvider(.png, data: png, name: "fail.png"))],
            location: CGPoint(x: 80, y: 80))
        _ = failDrop.dropInteraction(failInteraction, sessionDidUpdate: failSession)
        failDrop.dropInteraction(failInteraction, performDrop: failSession)
        XCTAssertFalse(stagedContents().isEmpty)
        failHarness.input.stopAfterStorageFailure()
        await waitForCondition { stagedContents().isEmpty }

        // 3. Normal drop success cleans up BOTH staged file AND empty batch UUID directory.
        let okHarness = try await makeHarness([paragraph("p1", "Lead")])
        addTeardownBlock { await okHarness.close() }
        let okEnv = try makeUploadEnv(for: okHarness, online: false)
        _ = hostInWindow(okHarness.view)
        let okDrop = try XCTUnwrap(okHarness.view.mediaDropController)
        let okInteraction = try XCTUnwrap(
            okHarness.view.interactions.compactMap { $0 as? UIDropInteraction }.first)
        let okSession = StubDropSession(
            items: [UIDragItem(itemProvider: dataProvider(.png, data: png, name: "ok.png"))],
            location: CGPoint(x: 80, y: 80))
        _ = okDrop.dropInteraction(okInteraction, sessionDidUpdate: okSession)
        okDrop.dropInteraction(okInteraction, performDrop: okSession)
        await waitForCondition { !okEnv.attachments.allAttachments().isEmpty && stagedContents().isEmpty }
        XCTAssertTrue(stagedContents().isEmpty, "empty batch UUID directory must be removed after upload queue")

        // 4. C7: NativeMediaUploads.start returning nil (!canUpload) cleans up staged file immediately.
        let dir = try tempDir("c7")
        let stagedFile = dir.appendingPathComponent("orphan.png")
        try png.write(to: stagedFile)
        let cleanedUp = Locked(false)
        let localUploads = NativeMediaUploads(scope: nil, queue: okEnv.coordinator)
        let nilTask = localUploads.start(
            .photo { png }, into: "p1", slot: MediaBlock.Slot(node: "image", url: ""),
            in: okHarness.session, onCleanup: { cleanedUp.value = true })
        XCTAssertNil(nilTask)
        XCTAssertTrue(cleanedUp.value, "onCleanup must run when uploads.start returns nil")

        // 5. removeStagingRoot() wipes any leftover staging directory (used on launch & sign-out).
        let leftoverDir = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: leftoverDir, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: leftoverDir.appendingPathComponent("stale.txt"))
        XCTAssertFalse(stagedContents().isEmpty)
        NativeMediaDropPaste.removeStagingRoot()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingRoot.path))
    }

    private func makeMinimal1BitPNG(width: Int, height: Int) -> Data {
        func appendChunk(_ type: String, body: Data, to out: inout Data) {
            var lengthBE = UInt32(body.count).bigEndian
            out.append(Data(bytes: &lengthBE, count: 4))
            var typeAndBody = Data(type.utf8)
            typeAndBody.append(body)
            out.append(typeAndBody)
            let crc = typeAndBody.withUnsafeBytes { ptr in
                crc32(0, ptr.bindMemory(to: Bytef.self).baseAddress, uInt(ptr.count))
            }
            var crcBE = UInt32(crc).bigEndian
            out.append(Data(bytes: &crcBE, count: 4))
        }

        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = Data()
        var wBE = UInt32(width).bigEndian
        var hBE = UInt32(height).bigEndian
        ihdr.append(Data(bytes: &wBE, count: 4))
        ihdr.append(Data(bytes: &hBE, count: 4))
        ihdr.append(contentsOf: [1, 0, 0, 0, 0])
        appendChunk("IHDR", body: ihdr, to: &png)

        let rowBytes = 1 + (width + 7) / 8
        let raw = Data(count: rowBytes * height)
        var destLen = compressBound(uLong(raw.count))
        var compressed = Data(count: Int(destLen))
        let status = raw.withUnsafeBytes { srcPtr in
            compressed.withUnsafeMutableBytes { dstPtr in
                compress2(
                    dstPtr.bindMemory(to: Bytef.self).baseAddress,
                    &destLen,
                    srcPtr.bindMemory(to: Bytef.self).baseAddress,
                    uLong(raw.count),
                    Z_BEST_SPEED)
            }
        }
        XCTAssertEqual(status, Z_OK)
        compressed.count = Int(destLen)
        appendChunk("IDAT", body: compressed, to: &png)
        appendChunk("IEND", body: Data(), to: &png)
        return png
    }
}
