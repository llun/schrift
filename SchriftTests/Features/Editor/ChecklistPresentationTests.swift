import SwiftUI
import UIKit
import XCTest

@testable import Schrift

@MainActor
final class ChecklistPresentationTests: XCTestCase {
    /// Exercises the real representable's update/delegate path, rather than
    /// restyling a detached text view directly.
    func testCompletedItemKeepsStrikeAndCaretThroughTypingFormattingAndModeChanges() async throws {
        let model = makeViewModel(blocks: [])
        let body = try JSONSerialization.data(withJSONObject: [
            "id": model.documentID.uuidString, "title": "Checklist",
            "content": "- [ ] Ship **bold** and *italic* with ~~strike~~",
            "created_at": "2026-10-05T06:00:00Z", "updated_at": "2026-10-05T06:00:00Z",
        ])
        MockURLProtocol.stubHandler = { request in
            .init(
                statusCode: 200, headers: [:],
                body: request.url!.path.contains("formatted-content")
                    ? body : Data("{\"count\":0,\"results\":[]}".utf8),
                error: nil)
        }
        await model.load()
        XCTAssertTrue(model.canStartEditing)
        let id = try XCTUnwrap(model.blocks.first?.id)
        model.startEditing(focusing: id)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        let host = UIHostingController(
            rootView: ChecklistSurface(model: model)
                .environment(LocalizationStore())
                .environment(AttachmentLoader.inert())
                .environment(ImageLoader.inert())
                .environment(\.dynamicTypeSize, .large))
        window.rootViewController = host
        window.makeKeyAndVisible()
        await waitUntil { self.textViews(in: host.view).first?.isFirstResponder == true }
        let editor = try XCTUnwrap(textViews(in: host.view).first)
        let selection = editor.selectedRange
        model.toggleChecklist(blockID: id)
        await waitUntil { editor.textStorage.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) != nil }
        XCTAssertTrue(textViews(in: host.view).first === editor)
        XCTAssertEqual(editor.selectedRange, selection)
        XCTAssertTrue(editor.isFirstResponder)
        assertStrike(editor, checked: true)
        editor.insertText("!")
        await waitUntil { model.blocks.first?.text.hasSuffix("!") == true }
        assertStrike(editor, checked: true)
        XCTAssertEqual(editor.selectedRange, NSRange(location: (editor.text as NSString).length, length: 0))
        XCTAssertEqual(editor.typingAttributes[.strikethroughStyle] as? Int, NSUnderlineStyle.single.rawValue)
        let boldRange = (editor.text as NSString).range(of: "bold")
        let italicRange = (editor.text as NSString).range(of: "italic")
        XCTAssertTrue(
            (editor.textStorage.attribute(.font, at: boldRange.location, effectiveRange: nil) as? UIFont)?
                .fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        XCTAssertTrue(
            (editor.textStorage.attribute(.font, at: italicRange.location, effectiveRange: nil) as? UIFont)?
                .fontDescriptor.symbolicTraits.contains(.traitItalic) == true)
        editor.selectedRange = (editor.text as NSString).range(of: "Ship")
        await waitUntil { model.selection == editor.selectedRange }
        model.applyInlineMarker("`")
        await waitUntil { editor.text.hasPrefix("`Ship`") }
        assertStrike(editor, checked: true)
        XCTAssertTrue(textViews(in: host.view).first === editor)
        XCTAssertTrue(editor.isFirstResponder)
        let readingBefore = model.blocks
        model.finishEditing()
        await waitUntil { self.textViews(in: host.view).isEmpty }
        XCTAssertEqual(model.blocks, readingBefore)
        XCTAssertTrue(model.rawMarkdown.hasPrefix("- [x] `Ship`"))
        model.startEditing()
        await waitUntil { !self.textViews(in: host.view).isEmpty }
        let reopened = try XCTUnwrap(textViews(in: host.view).first)
        XCTAssertTrue(reopened.becomeFirstResponder())
        assertStrike(reopened, checked: true)
        XCTAssertEqual(model.blocks.first?.id, id)
        let reopenedSelection = reopened.selectedRange
        model.toggleChecklist(blockID: id)
        await waitUntil { reopened.textStorage.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) == nil }
        // Explicit inline strike survives a block toggle while the unmarked
        // parts lose their completed-item strike.
        assertStrike(reopened, checked: false)
        XCTAssertTrue(textViews(in: host.view).first === reopened)
        XCTAssertTrue(reopened.isFirstResponder)
        XCTAssertEqual(reopened.selectedRange, reopenedSelection)
        reopened.selectedRange = NSRange(location: (reopened.text as NSString).length, length: 0)
        reopened.insertText("?")
        await waitUntil { model.blocks.first?.text.hasSuffix("!?") == true }
        assertStrike(reopened, checked: false)
    }

    private func assertStrike(
        _ editor: EditorUITextView, checked: Bool, file: StaticString = #filePath, line: UInt = #line
    ) {
        for offset in 0..<(editor.text as NSString).length {
            let value = editor.textStorage.attribute(.strikethroughStyle, at: offset, effectiveRange: nil) as? Int
            let inlineStrike = InlineMarkdown.layout(of: editor.text).spans.contains {
                $0.marks.contains(.strike) && NSLocationInRange(offset, $0.range)
            }
            XCTAssertEqual(
                value, checked || inlineStrike ? NSUnderlineStyle.single.rawValue : nil,
                "source offset \(offset)", file: file, line: line)
        }
    }

    private func textViews(in view: UIView) -> [EditorUITextView] {
        (view as? EditorUITextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
    }

    func testRenderedFirstLineAlignment() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        var uncheckedPixels: [String: Pixels] = [:]
        for size in [DynamicTypeSize.large, .accessibility3] {
            for checked in [false, true] {
                for wrapped in [false, true] {
                    let text = wrapped ? Array(repeating: "HHHH", count: 12).joined(separator: " ") : "HHHH"
                    let block = EditorBlock(kind: .checklistItem(checked: checked), text: text)
                    let model = makeViewModel(blocks: [block])
                    for editing in [false, true] {
                        let row =
                            editing
                            ? AnyView(
                                BlockEditorRow(
                                    viewModel: model, block: block, index: 0,
                                    serverOrigin: "https://docs.example.org", isOffline: true))
                            : AnyView(
                                MarkdownBlockView(
                                    block: block, serverOrigin: "https://docs.example.org",
                                    onToggleChecklist: { model.toggleChecklist(blockID: block.id) },
                                    onTapText: { model.startEditing(focusing: block.id) }))
                        let host = ChecklistRenderHost(
                            rootView:
                                row
                                .environment(LocalizationStore())
                                .environment(AttachmentLoader.inert())
                                .environment(ImageLoader.inert())
                                .environment(\.dynamicTypeSize, size)
                                .environment(\.colorScheme, .light)
                                .frame(width: 300, alignment: .topLeading)
                                .padding(20)
                                .background(Color.white))
                        host.safeAreaRegions = []
                        let fitted = host.sizeThatFits(in: CGSize(width: 340, height: 2000))
                        window.frame = CGRect(origin: .zero, size: fitted)
                        window.rootViewController = host
                        window.makeKeyAndVisible()
                        host.view.frame = window.bounds
                        host.view.layoutIfNeeded()
                        await waitUntil { host.didAppear }
                        host.view.layoutIfNeeded()
                        let image = UIGraphicsImageRenderer(size: fitted).image { _ in
                            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                        }
                        let glyphWidth = UIHostingController(
                            rootView:
                                MaterialSymbol(.check_box, size: EditorBlockMetrics.checkboxSize)
                                .environment(\.dynamicTypeSize, size)
                        ).sizeThatFits(in: CGSize(width: 300, height: 300)).width
                        let pixels = try Pixels(image)
                        let glyph = try XCTUnwrap(pixels.inkRows(fromX: 20, toX: 20 + glyphWidth).first)
                        let lines = pixels.inkRows(
                            fromX: 20 + glyphWidth + EditorBlockMetrics.adornmentSpacing,
                            toX: 320)
                        let firstLine = try XCTUnwrap(lines.first)
                        let name = "\(size)-\(checked)-\(wrapped)-\(editing ? "editing" : "reading")"
                        let key = "\(size)-\(wrapped)-\(editing)"
                        let textStart = 20 + glyphWidth + EditorBlockMetrics.adornmentSpacing
                        if checked {
                            let open = try XCTUnwrap(uncheckedPixels[key])
                            XCTAssertGreaterThan(
                                pixels.inkCount(fromX: textStart), open.inkCount(fromX: textStart),
                                "\(name): completed text must visibly gain a strike on the real surface")
                        } else {
                            uncheckedPixels[key] = pixels
                        }
                        print(
                            "CHECKLIST \(name) glyph=\(glyph) firstLine=\(firstLine) delta=\(glyph.midY - firstLine.midY) lines=\(lines.count)"
                        )
                        let attachment = XCTAttachment(image: image)
                        attachment.name = name
                        attachment.lifetime = .keepAlways
                        add(attachment)
                        let textFont =
                            editing
                            ? blockTextStyling(for: block, dynamicTypeSize: size).font
                            : UIFont.preferredFont(
                                forTextStyle: .body,
                                compatibleWith: UITraitCollection(
                                    preferredContentSizeCategory: uiContentSizeCategory(for: size)))
                        // A blurred first line can disappear from inkRows altogether,
                        // making the second line look like a misaligned first line.
                        if editing {
                            let editor = try XCTUnwrap(textViews(in: host.view).first)
                            let layout = editor.layoutManager
                            layout.ensureLayout(for: editor.textContainer)
                            var laidOutLines = 0
                            layout.enumerateLineFragments(
                                forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)
                            ) { _, _, _, _, _ in laidOutLines += 1 }
                            XCTAssertEqual(lines.count, laidOutLines, "\(name): every laid-out line must be visible")
                        }
                        for (index, line) in lines.enumerated() {
                            XCTAssertEqual(
                                line.maxY - line.minY + 1 / pixels.scale,
                                textFont.capHeight, accuracy: 1,
                                "\(name): capital glyphs on line \(index) must remain fully visible, without edge blur")
                        }
                        XCTAssertEqual(lines.count > 1, wrapped)
                        XCTAssertEqual(
                            glyph.midY, firstLine.midY, accuracy: 1,
                            "\(name): checkbox must center on the first line's capital glyphs")
                    }
                }
            }
        }
    }

    private struct InkRows {
        let minY: CGFloat
        let maxY: CGFloat
        var midY: CGFloat { (minY + maxY) / 2 }
    }

    private struct Pixels {
        let bytes: [UInt8]
        let width: Int
        let height: Int
        let scale: CGFloat

        init(_ image: UIImage) throws {
            let cgImage = try XCTUnwrap(image.cgImage)
            let pixelWidth = cgImage.width
            let pixelHeight = cgImage.height
            width = pixelWidth
            height = pixelHeight
            scale = image.scale
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            try buffer.withUnsafeMutableBytes { pointer in
                let context = try XCTUnwrap(
                    CGContext(
                        data: pointer.baseAddress, width: pixelWidth, height: pixelHeight,
                        bitsPerComponent: 8, bytesPerRow: pixelWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            }
            bytes = buffer
        }

        func inkCount(fromX: CGFloat) -> Int {
            let left = max(0, Int(ceil(fromX * scale)))
            return (0..<height).reduce(0) { count, y in
                count
                    + (left..<width).filter { x in
                        let offset = (y * width + x) * 4
                        return min(bytes[offset], bytes[offset + 1], bytes[offset + 2]) < 200
                    }.count
            }
        }

        func inkRows(fromX: CGFloat, toX: CGFloat) -> [InkRows] {
            let left = max(0, Int(ceil(fromX * scale)))
            let right = min(width, Int(floor(toX * scale)))
            var result: [InkRows] = []
            var start: Int?
            for y in 0..<height {
                let occupied = (left..<right).contains { x in
                    let offset = (y * width + x) * 4
                    return min(bytes[offset], bytes[offset + 1], bytes[offset + 2]) < 200
                }
                if occupied, start == nil { start = y }
                if !occupied, let first = start {
                    result.append(InkRows(minY: CGFloat(first) / scale, maxY: CGFloat(y - 1) / scale))
                    start = nil
                }
            }
            if let first = start {
                result.append(InkRows(minY: CGFloat(first) / scale, maxY: CGFloat(height - 1) / scale))
            }
            return result
        }
    }

    private func makeViewModel(blocks: [EditorBlock]) -> EditorViewModel {
        let suite = "ChecklistPresentationTests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        addTeardownBlock { store.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let contentCache = DocumentContentCacheStore(directory: directory)
        let childrenCache = DocumentChildrenCacheStore(userDefaults: store)
        let client = DocsAPIClient(
            baseURL: URL(string: "https://docs.example.org/api/v1.0/")!,
            session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let coordinator = DocumentSaveCoordinator(
            client: client,
            draftStore: PendingDraftStore(userDefaults: store), contentCache: contentCache,
            createStore: PendingDocumentCreateStore(userDefaults: store),
            deleteStore: PendingDocumentDeleteStore(userDefaults: store),
            attachmentStore: PendingAttachmentStore(userDefaults: store, directory: directory),
            listCache: DocumentCacheStore(userDefaults: store), childrenCache: childrenCache,
            serverOrigin: "https://docs.example.org", backgroundTasks: .noop)
        let model = EditorViewModel(
            client: client, documentID: UUID(), title: "Checklist",
            saveCoordinator: coordinator, signedInUser: SignedInUserStore(userDefaults: store),
            contentCache: contentCache, childrenCache: childrenCache)
        model.blocks = blocks
        return model
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }
}

private struct ChecklistSurface: View {
    @Bindable var model: EditorViewModel
    private let scrollAnchor = EditorScrollAnchorStore()

    var body: some View {
        if model.isEditing {
            BlockEditorView(
                viewModel: model, serverOrigin: "https://docs.example.org", isOffline: true,
                scrollAnchor: scrollAnchor
            ) { EmptyView() }
        } else {
            VStack(alignment: .leading, spacing: EditorBlockMetrics.blockSpacing) {
                ForEach(model.blocks) { block in
                    MarkdownBlockView(
                        block: block, serverOrigin: "https://docs.example.org",
                        onToggleChecklist: { model.toggleChecklist(blockID: block.id) },
                        onTapText: { model.startEditing(focusing: block.id) })
                }
            }
        }
    }
}

@MainActor
private final class ChecklistRenderHost<Content: View>: UIHostingController<Content> {
    var didAppear = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        didAppear = true
    }
}
