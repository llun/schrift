import UIKit
import XCTest

@testable import Schrift

/// PR06e: every block the native editor does not author yet is one
/// attachment character with a bounded, read-only preview. The S2 sizing fix
/// (paragraph min = max line height = attachment height = the view's
/// intrinsic size) holds before and after an image loads and across width and
/// Dynamic Type changes; only attachments near the viewport are realised; the
/// classic external-image rule (tap to load) holds; nothing writes Yjs.
@MainActor
final class NativeAttachmentLayoutTests: NativeEditingTestCase {
    private static let origin = "https://example.test"
    private var cleanup: [URL] = []

    override func tearDown() async throws {
        for url in cleanup { try? FileManager.default.removeItem(at: url) }
        cleanup = []
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// An XML subtree the block encoder cannot spell (a table, a column list).
    private indirect enum XNode {
        case element(String, [(String, YAnyValue)], [XNode])
        case text(String)
    }

    private func block(_ node: String, _ id: String, _ props: [(key: String, value: YAnyValue)] = [], text: String = "")
        -> BlockNoteBlock
    {
        BlockNoteBlock(node: node, props: props, runs: text.isEmpty ? [] : [InlineRun(text)], id: id)
    }

    private func image(_ id: String, url: String, caption: String = "", previewWidth: YAnyValue = .undefined)
        -> BlockNoteBlock
    {
        block(
            "image", id,
            [
                ("backgroundColor", .string("default")), ("caption", .string(caption)), ("name", .string("photo.png")),
                ("previewWidth", previewWidth), ("showPreview", .bool(true)), ("textAlignment", .string("left")),
                ("url", .string(url)),
            ])
    }

    private func media(_ node: String, _ id: String, name: String) -> BlockNoteBlock {
        block(
            node, id,
            [
                ("backgroundColor", .string("default")), ("caption", .string("")), ("name", .string(name)),
                ("url", .string("\(Self.origin)/media/\(name)")),
            ])
    }

    private func container(_ id: String, _ element: XNode) -> XNode {
        .element("blockContainer", [("id", .string(id))], [element])
    }

    private func table(_ rows: [[String]]) -> XNode {
        let cellProps: [(String, YAnyValue)] = [
            ("backgroundColor", .string("default")), ("colspan", .int(1)), ("rowspan", .int(1)),
            ("textAlignment", .string("left")), ("textColor", .string("default")),
        ]
        return .element(
            "table", [("textColor", .string("default"))],
            rows.enumerated().map { index, row in
                .element(
                    "tableRow", [],
                    row.map {
                        .element(
                            index == 0 ? "tableHeader" : "tableCell", cellProps,
                            [.element("tableParagraph", [], [.text($0)])])
                    })
            })
    }

    private func columns(_ id: String, _ columns: [[String]]) -> XNode {
        .element(
            "columnList", [("id", .string(id))],
            columns.enumerated().map { index, lines in
                .element(
                    "column", [("id", .string("\(id)-c\(index)")), ("width", .int(1))],
                    lines.enumerated().map { line, text in
                        container(
                            "\(id)-c\(index)-\(line)",
                            .element("paragraph", Self.paragraphProps.map { ($0.key, $0.value) }, [.text(text)]))
                    })
            })
    }

    /// `blocks`, then each node inserted into the root group after the block `after`.
    private func state(_ blocks: [BlockNoteBlock], inserting nodes: [(after: String, node: XNode)] = []) throws -> Data
    {
        let doc = YDoc(clientID: 2, gc: true)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(BlockNoteYjs.encode(blocks, clientID: Self.seedClientID)))
        let root = try XCTUnwrap(doc.share[BlockNoteYjs.fragmentField])
        guard case .type(let group)? = YBlockProjection.children(of: root, includeFormats: false).first?.content else {
            throw XCTSkip("no root group")
        }
        try doc.transact { tx in
            for (after, node) in nodes {
                let left = YBlockProjection.children(of: group, includeFormats: false).first { item in
                    guard case .type(let type) = item.content, case .any(let values)? = type.map["id"]?.content
                    else { return false }
                    return values.first == .string(after)
                }
                try insert(node, into: group, after: left, tx)
            }
        }
        return try YStateEncoder.encodeStateAsUpdate(doc)
    }

    @discardableResult
    private func insert(_ node: XNode, into parent: YType, after left: YItem?, _ tx: YTransaction) throws -> YItem? {
        switch node {
        case .element(let name, let attributes, let children):
            let type = YType(typeRef: .xmlElement(nodeName: name))
            let item = try YWrite.insertAfter(tx, into: parent, after: left, [.type(type)])
            var last: YItem?
            for child in children { last = try insert(child, into: type, after: last, tx) }
            for (key, value) in attributes { try YWrite.mapSet(tx, on: type, key: key, .any([value])) }
            return item
        case .text(let string):
            let text = YType(typeRef: .xmlText)
            let item = try YWrite.insertAfter(tx, into: parent, after: left, [.type(text)])
            if !string.isEmpty { try text.insert(0, string, nil) }
            return item
        }
    }

    /// One block of every family the native editor previews.
    private func everyFamily() throws -> Data {
        let rows = (0..<8).map { row in (0..<6).map { column in row == 0 ? "H\(column)" : "r\(row)c\(column)" } }
        return try state(
            [
                paragraph("intro", "Intro paragraph"),
                image("img", url: "\(Self.origin)/media/photo.png", caption: "A red flower"),
                media("video", "vid", name: "clip.mp4"),
                media("audio", "aud", name: "roar.mp3"),
                media("file", "fil", name: "notes.txt"),
                media("pdf", "doc", name: "paper.pdf"),
                block("mathBlock", "math", text: "\\int_0^1 x^2 \\, dx"),
                block("diagram", "diag", text: "graph TD\n  A --> B\n  B --> C\n  C --> D\n  D --> E\n  E --> F"),
                block("customWidget", "widget", text: "Custom content"),
                paragraph("outro", "Outro paragraph"),
            ],
            inserting: [
                (after: "fil", node: container("tbl", table(rows))),
                (after: "tbl", node: columns("cols", [["Left one", "Left two"], ["Right one"]])),
            ])
    }

    @discardableResult
    private func host(_ view: NativeTextView, width: CGFloat = 390, height: CGFloat = 2_400) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        return window
    }

    private func attachment(_ session: NativeEditorSession, _ id: String) throws -> NativeBlockAttachment {
        let entry = try XCTUnwrap(session.surface.rangeIndex.entry(for: id))
        return try XCTUnwrap(
            session.textView.textStorage.attribute(.attachment, at: entry.range.location, effectiveRange: nil)
                as? NativeBlockAttachment, "\(id) is an attachment")
    }

    private func realized(_ session: NativeEditorSession, _ id: String) -> NativeAttachmentView? {
        session.textView.blockControls.visibleAttachmentViews.first { $0.content.blockID == id }
    }

    /// The laid-out fragment holding the block's attachment, in text-view coordinates.
    private func fragmentFrame(_ session: NativeEditorSession, _ id: String) throws -> CGRect {
        let view = session.textView
        let entry = try XCTUnwrap(session.surface.rangeIndex.entry(for: id))
        let layout = try XCTUnwrap(view.textLayoutManager)
        let content = try XCTUnwrap(layout.textContentManager)
        let location = try XCTUnwrap(content.location(content.documentRange.location, offsetBy: entry.range.location))
        let fragment = try XCTUnwrap(layout.textLayoutFragment(for: location))
        return fragment.layoutFragmentFrame.offsetBy(dx: view.textContainerInset.left, dy: view.textContainerInset.top)
    }

    private final class FetchLog {
        var urls: [URL] = []
    }

    @MainActor
    private final class FetchGate {
        var started = false
        var continuation: CheckedContinuation<Data, Error>?
    }

    /// A loader whose transport is this closure: no request leaves the test.
    private func loader(
        _ log: FetchLog, data: Data = testPNGData(width: 400, height: 200),
        decodedCache: NSCache<NSURL, UIImage>? = nil,
        fetch: (@MainActor @Sendable (URL) async throws -> Data)? = nil
    ) -> ImageLoader {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cleanup.append(directory)
        nonisolated(unsafe) let log = log
        return ImageLoader(
            scopeProvider: { ImageCacheScope(serverOrigin: Self.origin, sessionID: "native-attachments") },
            cache: ImageCacheStore(directory: directory),
            decodedCache: decodedCache,
            fetch: { url, _ in
                log.urls.append(url)
                if let fetch { return try await fetch(url) }
                return data
            }, cookieProvider: { _ in [] })
    }

    /// Every attachment in storage: its paragraph's line height is its
    /// height, and a realised view's intrinsic size is its bounds' size.
    private func assertS2Consistent(
        _ session: NativeEditorSession, file: StaticString = #filePath, line: UInt = #line
    ) {
        let storage = session.textView.textStorage
        var count = 0
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? NativeBlockAttachment else { return }
            count += 1
            let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let content = attachment.content
            XCTAssertEqual(style?.minimumLineHeight, content.lineHeight, file: file, line: line)
            XCTAssertEqual(style?.maximumLineHeight, content.lineHeight, file: file, line: line)
            XCTAssertEqual(content.lineHeight, content.size.height + content.descent, file: file, line: line)
            XCTAssertEqual(
                attachment.bounds, .zero, "bounds would make TextKit draw a file icon", file: file, line: line)
            if let view = realized(session, content.blockID) {
                XCTAssertEqual(view.intrinsicContentSize, content.size, file: file, line: line)
                XCTAssertEqual(
                    view.bounds.size, content.size, "TextKit sized the view as reported", file: file, line: line)
                XCTAssertEqual(view.content, content, "a stale view would mis-size", file: file, line: line)
            }
        }
        XCTAssertGreaterThan(count, 0, file: file, line: line)
        let fresh = AttributedDocumentProjection.attributedString(
            blocks: session.surface.blocks, traits: session.surface.traits, labels: session.surface.labels,
            geometry: session.surface.attachmentGeometry)
        XCTAssertTrue(storage.isEqual(to: fresh), "storage equals the projection", file: file, line: line)
    }

    private func journalCount(_ harness: Harness) throws -> Int {
        try XCTUnwrap(harness.store.restore(for: harness.scope)).manifest.journal.count
    }

    // MARK: - Every family

    func testEveryFamilyRendersABoundedReadOnlyPreview() async throws {
        let harness = try await makeHarness(state: everyFamily())
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let window = host(harness.view)
        defer { window.isHidden = true }

        func preview(_ id: String) throws -> NativeBlockPreview { try attachment(session, id).content.preview }
        XCTAssertEqual(
            try preview("img"), .image(url: "\(Self.origin)/media/photo.png", alt: "A red flower", previewWidth: nil))
        XCTAssertEqual(
            try preview("vid"),
            .video(url: "\(Self.origin)/media/clip.mp4", label: "clip.mp4", previewWidth: nil))
        XCTAssertEqual(try preview("aud"), .file(node: "audio", name: "roar.mp3", url: "\(Self.origin)/media/roar.mp3"))
        XCTAssertEqual(
            try preview("fil"), .file(node: "file", name: "notes.txt", url: "\(Self.origin)/media/notes.txt"))
        XCTAssertEqual(try preview("doc"), .file(node: "pdf", name: "paper.pdf", url: "\(Self.origin)/media/paper.pdf"))
        guard case .table(let cells, let rows, let columns) = try preview("tbl") else {
            return XCTFail("the table previews as a table")
        }
        XCTAssertEqual(rows, 8)
        XCTAssertEqual(columns, 6)
        XCTAssertEqual(cells.count, NativeBlockPreview.Limits.maxRows, "rows are bounded")
        XCTAssertTrue(cells.allSatisfy { $0.count == NativeBlockPreview.Limits.maxColumns }, "columns are bounded")
        XCTAssertEqual(cells[0], ["H0", "H1", "H2", "H3"])
        XCTAssertEqual(cells[1], ["r1c0", "r1c1", "r1c2", "r1c3"])
        XCTAssertEqual(
            try preview("cols"),
            .columns(
                [
                    [.init(node: "paragraph", text: "Left one"), .init(node: "paragraph", text: "Left two")],
                    [.init(node: "paragraph", text: "Right one")],
                ], columnCount: 2))
        XCTAssertEqual(try preview("math"), .source(node: "mathBlock", lines: ["\\int_0^1 x^2 \\, dx"], lineCount: 1))
        XCTAssertEqual(
            try preview("diag"),
            .source(node: "diagram", lines: ["graph TD", "  A --> B", "  B --> C", "  C --> D"], lineCount: 6),
            "source summaries are bounded")
        XCTAssertEqual(try preview("widget"), .preserved(node: "customWidget", summary: "Custom content"))

        // One attachment character per preview block, read-only and realised as our view.
        for id in ["img", "vid", "aud", "fil", "doc", "tbl", "cols", "math", "diag", "widget"] {
            let entry = try XCTUnwrap(session.surface.rangeIndex.entry(for: id))
            XCTAssertEqual(entry.range.length, 2, "\(id): the attachment and its separator")
            XCTAssertEqual(
                (harness.view.textStorage.string as NSString).substring(with: entry.textRange),
                AttributedDocumentProjection.attachmentCharacter)
            let view = try XCTUnwrap(realized(session, id), "\(id) is realised as a preview view, not a file icon")
            XCTAssertEqual(view.bounds.size, try attachment(session, id).content.size, id)
            XCTAssertLessThanOrEqual(view.bounds.height, NativeAttachmentLayout.maxImageHeight, id)
        }
        // The table shows its bounded grid and the "… more" row.
        let tableView = try XCTUnwrap(realized(session, "tbl"))
        let texts = labels(in: tableView)
        XCTAssertTrue(texts.contains("H0"))
        XCTAssertTrue(texts.contains("r5c3"))
        XCTAssertFalse(texts.contains("r6c0"), "rows past the bound are not shown")
        XCTAssertFalse(texts.contains("H4"), "columns past the bound are not shown")
        XCTAssertTrue(texts.contains("… more"))
        assertS2Consistent(session)
        try await assertConsistent(harness, localCommands: 0)
    }

    private func labels(in view: UIView) -> [String] {
        var result: [String] = []
        var queue = view.subviews
        while let next = queue.popLast() {
            if let label = next as? UILabel, let text = label.text { result.append(text) }
            queue += next.subviews
        }
        return result
    }

    /// A range command that touches a preview is refused before any write.
    func testRangeCommandsAcrossAPreviewAreStillRefused() async throws {
        let harness = try await makeHarness(state: everyFamily())
        addTeardownBlock { await harness.close() }
        try select(harness, from: ("intro", 2), to: ("vid", 0))
        let replaced = await harness.run { harness.input.replace(range: harness.view.selectedRange, with: "x") }
        XCTAssertFalse(replaced)
        XCTAssertEqual(harness.input.noticeKey, .native_editor_range_unavailable)
        XCTAssertTrue(harness.log.commands.isEmpty)
        XCTAssertEqual(try journalCount(harness), 0)
    }

    // MARK: - S2 sizing

    /// The line is exactly the attachment: the fragment's first line is the
    /// attachment's height, the view sits inside its fragment (no overlap with
    /// the paragraph above), and the view's intrinsic size is its bounds.
    func testAttachmentLineHeightBoundsAndViewAgree() async throws {
        let harness = try await makeHarness(state: everyFamily())
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let window = host(harness.view)
        defer { window.isHidden = true }
        assertS2Consistent(session)
        for id in ["img", "vid", "tbl", "cols", "diag", "widget"] {
            let attachment = try attachment(session, id)
            let frame = try fragmentFrame(session, id)
            let view = try XCTUnwrap(realized(session, id))
            let rect = view.convert(view.bounds, to: harness.view)
            let lineHeight = attachment.content.lineHeight
            XCTAssertGreaterThanOrEqual(rect.minY, frame.minY - 0.5, "\(id) does not overlap the block above")
            XCTAssertLessThanOrEqual(rect.maxY, frame.minY + lineHeight + 0.5, "\(id) stays inside its line")
            XCTAssertEqual(
                frame.height, lineHeight + DocsSpacing.spaceSM, accuracy: 0.5,
                "\(id): the line is the paragraph style's height, plus the paragraph spacing")
        }
        if let contentStorage = harness.view.textLayoutManager?.textContentManager as? NSTextContentStorage {
            for id in ["img", "tbl", "cols", "outro"] {
                let range = try XCTUnwrap(session.surface.rangeIndex.entry(for: id)).range
                XCTAssertNil(
                    harness.view.blockControls.textContentStorage(contentStorage, textParagraphWith: range),
                    "\(id) is not a document-ending placeholder")
            }
        }
    }

    /// An image download refreshes its card's height immediately to the decoded
    /// aspect ratio (S2-consistent), shifts blocks below without moving
    /// `contentOffset`, writes zero Yjs/journal entries, never enters a reload
    /// loop, and keeps updating cleanly across width changes.
    func testImageLoadRefreshesHeightImmediatelyAndAppliesAcrossWidths() async throws {
        let harness = try await makeHarness(state: everyFamily())
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let log = FetchLog()
        harness.view.blockControls.images = loader(log)
        harness.view.blockControls.serverOrigin = Self.origin
        let window = host(harness.view, height: 900)
        defer { window.isHidden = true }

        let before = try attachment(session, "img")
        XCTAssertEqual(before.content.size.height, NativeAttachmentLayout.placeholderImageHeight, "no ratio known yet")
        let view = try XCTUnwrap(realized(session, "img"))
        let below = try fragmentFrame(session, "vid")
        let offset = harness.view.contentOffset
        await view.loadTask?.value
        harness.view.layoutIfNeeded()

        let usable = session.surface.attachmentGeometry.usableWidth
        let expectedHeight = ceil(usable / 2)
        XCTAssertEqual(log.urls, [URL(string: "\(Self.origin)/media/photo.png")!], "same origin loads on render")
        let refreshedAttachment = try attachment(session, "img")
        XCTAssertEqual(refreshedAttachment.content.size.width, usable)
        XCTAssertEqual(refreshedAttachment.content.size.height, expectedHeight)
        let refreshedView = try XCTUnwrap(realized(session, "img"))
        XCTAssertNotNil(refreshedView.imageView?.image)
        XCTAssertEqual(refreshedView.intrinsicContentSize, refreshedAttachment.content.size)
        XCTAssertEqual(refreshedView.bounds.size, refreshedAttachment.content.size)
        XCTAssertNil(refreshedView.loadTask, "no second fetch after restyle")
        XCTAssertEqual(log.urls.count, 1, "no reload loop")
        XCTAssertEqual(
            try fragmentFrame(session, "vid").minY - below.minY,
            expectedHeight - NativeAttachmentLayout.placeholderImageHeight,
            accuracy: 0.5,
            "the block below shifts by the exact height delta")
        XCTAssertEqual(harness.view.contentOffset, offset, "visible card expands in place")
        assertS2Consistent(session)

        // Rotation / split view: the cached ratio (2:1) sizes the new width too.
        harness.view.frame.size.width = 320
        harness.view.layoutIfNeeded()
        let usable320 =
            320 - harness.view.textContainerInset.left - harness.view.textContainerInset.right
            - 2 * harness.view.textContainer.lineFragmentPadding
        XCTAssertEqual(session.surface.attachmentGeometry.width, usable320.rounded(.down))
        let after = try attachment(session, "img")
        XCTAssertEqual(after.content.size.width, usable320.rounded(.down))
        XCTAssertEqual(after.content.size.height, ceil(usable320.rounded(.down) / 2))
        XCTAssertEqual(log.urls.count, 1, "width change reuses cache without refetch")
        assertS2Consistent(session)
        try await assertConsistent(harness, localCommands: 0)
        XCTAssertEqual(try journalCount(harness), 0)
    }

    /// `previewWidth` caps the image box; the ratio gives its height.
    func testPreviewWidthAndRatioGiveTheHeight() throws {
        let block = BlockSnapshot(
            id: "i", node: "image", props: [], runs: [],
            preview: .image(url: "https://example.test/a.png", alt: "", previewWidth: 200))
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        var geometry = NativeAttachmentGeometry(width: 350)
        let placeholder = AttributedDocumentProjection.attachment(
            for: block, traits: traits, labels: NativeEditorLabels(), geometry: geometry)
        XCTAssertEqual(placeholder.content.size.height, NativeAttachmentLayout.placeholderImageHeight)
        geometry.aspectRatios["https://example.test/a.png"] = 4.0 / 3.0
        let sized = AttributedDocumentProjection.attachment(
            for: block, traits: traits, labels: NativeEditorLabels(), geometry: geometry)
        XCTAssertEqual(sized.content.size.height, 150, "200 wide at 4:3")
        geometry.aspectRatios["https://example.test/a.png"] = 0.01
        let tall = AttributedDocumentProjection.attachment(
            for: block, traits: traits, labels: NativeEditorLabels(), geometry: geometry)
        XCTAssertEqual(tall.content.size.height, NativeAttachmentLayout.maxImageHeight, "bounded")
    }

    /// Dynamic Type restyles every card to its new size, consistently.
    func testDynamicTypeKeepsBoundsAndLineHeightsConsistent() async throws {
        let harness = try await makeHarness(state: everyFamily())
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let window = host(harness.view)
        defer { window.isHidden = true }
        let small = try attachment(session, "aud").content.size.height
        session.surface.updatePresentation(
            traits: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraLarge),
            labels: session.surface.labels)
        harness.view.layoutIfNeeded()
        XCTAssertGreaterThan(try attachment(session, "aud").content.size.height, small)
        assertS2Consistent(session)
        try await assertConsistent(harness, localCommands: 0)
    }

    // MARK: - Privacy

    /// The classic rule: an external image issues no request until the
    /// reader taps "External image · tap to load".
    func testExternalImageWaitsForATap() async throws {
        let url = "https://elsewhere.example/cat.png"
        let harness = try await makeHarness([paragraph("p", "Before"), image("ext", url: url, caption: "A cat")])
        addTeardownBlock { await harness.close() }
        let log = FetchLog()
        harness.view.blockControls.images = loader(log)
        harness.view.blockControls.serverOrigin = Self.origin
        let window = host(harness.view)
        defer { window.isHidden = true }
        let view = try XCTUnwrap(realized(harness.session, "ext"))
        await view.loadTask?.value

        XCTAssertTrue(log.urls.isEmpty, "no request to an external host before consent")
        let button = try XCTUnwrap(view.loadButton)
        XCTAssertEqual(button.configuration?.title, "External image · tap to load")
        XCTAssertEqual(view.accessibilityLabel, "Image: A cat")
        XCTAssertEqual(view.accessibilityValue, "External image from elsewhere.example. Tap to load.")
        XCTAssertTrue(view.accessibilityTraits.contains(.button))
        let size = view.intrinsicContentSize

        button.sendActions(for: .primaryActionTriggered)
        await view.loadTask?.value
        harness.view.layoutIfNeeded()
        XCTAssertEqual(log.urls, [URL(string: url)!], "one request, after the tap")
        let refreshed = try XCTUnwrap(realized(harness.session, "ext"))
        XCTAssertNotNil(refreshed.imageView?.image)
        XCTAssertNil(refreshed.loadButton)
        XCTAssertTrue(harness.view.blockControls.isExternalMediaApproved(url))
        let expectedHeight = ceil(harness.session.surface.attachmentGeometry.usableWidth / 2)
        XCTAssertNotEqual(size.height, expectedHeight)
        XCTAssertEqual(refreshed.intrinsicContentSize.height, expectedHeight)
        XCTAssertEqual(try attachment(harness.session, "ext").content.size.height, expectedHeight)
        XCTAssertEqual(log.urls.count, 1, "no reload loop after restyle")
        assertS2Consistent(harness.session)
        try await assertConsistent(harness, localCommands: 0)
        XCTAssertEqual(try journalCount(harness), 0)
    }

    /// Consented external URLs survive attachment restyles and `NSCache` eviction
    /// in the same view session, and clear when `serverOrigin` or `images` changes.
    func testExternalImageConsentSurvivesCacheEvictionAndClearsOnSessionChange() async throws {
        let url = "https://elsewhere.example/cat.png"
        let harness = try await makeHarness([paragraph("p", "Before"), image("ext", url: url, caption: "A cat")])
        addTeardownBlock { await harness.close() }
        let log = FetchLog()
        let decodedCache = NSCache<NSURL, UIImage>()
        harness.view.blockControls.images = loader(log, decodedCache: decodedCache)
        harness.view.blockControls.serverOrigin = Self.origin
        let window = host(harness.view)
        defer { window.isHidden = true }
        let initial = try XCTUnwrap(realized(harness.session, "ext"))
        await initial.loadTask?.value
        let button = try XCTUnwrap(initial.loadButton)
        button.sendActions(for: .primaryActionTriggered)
        await initial.loadTask?.value
        harness.view.layoutIfNeeded()
        XCTAssertEqual(log.urls.count, 1)

        // Evict decoded bitmap and force a new view via width change: stays approved, hits disk cache.
        decodedCache.removeAllObjects()
        harness.view.frame.size.width = 320
        harness.view.layoutIfNeeded()
        let remounted = try XCTUnwrap(realized(harness.session, "ext"))
        await remounted.loadTask?.value
        harness.view.layoutIfNeeded()
        XCTAssertTrue(harness.view.blockControls.isExternalMediaApproved(url))
        XCTAssertNil(remounted.loadButton)
        XCTAssertNotNil(remounted.imageView?.image)
        XCTAssertEqual(log.urls.count, 1, "disk cache satisfies re-decode without network")

        // Changing serverOrigin or loader clears retained consent.
        harness.view.blockControls.serverOrigin = "https://other.example"
        XCTAssertFalse(harness.view.blockControls.isExternalMediaApproved(url))
    }

    /// While IME composition holds storage (`holdsComposition == true`), an image
    /// load defers height restyling until composition ends, never cancelling marked text.
    func testImageLoadDefersHeightRefreshDuringIMEComposition() async throws {
        let url = "\(Self.origin)/media/ime.png"
        let harness = try await makeHarness([paragraph("p", "Hi"), image("img", url: url)])
        addTeardownBlock { await harness.close() }
        let log = FetchLog()
        let gate = FetchGate()
        harness.view.blockControls.images = loader(log) { _ in
            gate.started = true
            return try await withCheckedThrowingContinuation { continuation in
                gate.continuation = continuation
            }
        }
        harness.view.blockControls.serverOrigin = Self.origin
        let window = host(harness.view)
        defer { window.isHidden = true }
        await waitUntil { gate.started }

        // Begin IME composition in the paragraph before the image finishes decoding.
        harness.view.selectedRange = NSRange(location: 2, length: 0)
        harness.view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertNotNil(harness.view.markedTextRange)

        gate.continuation?.resume(returning: testPNGData(width: 400, height: 200))
        let view = try XCTUnwrap(realized(harness.session, "img"))
        await view.loadTask?.value
        harness.view.layoutIfNeeded()

        XCTAssertNotNil(harness.view.markedTextRange, "image decode must not cancel marked text")
        XCTAssertNil(harness.session.surface.attachmentGeometry.aspectRatios[url])
        var composingAttachment: NativeBlockAttachment?
        harness.view.textStorage.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: harness.view.textStorage.length)
        ) { value, _, stop in
            if let found = value as? NativeBlockAttachment, found.content.blockID == "img" {
                composingAttachment = found
                stop.pointee = true
            }
        }
        XCTAssertEqual(
            composingAttachment?.content.size.height,
            NativeAttachmentLayout.placeholderImageHeight,
            "storage restyle stays deferred while composing")

        // Commit composition: deferred height refresh runs right after composition releases.
        harness.view.unmarkText()
        await harness.settle()
        harness.view.layoutIfNeeded()
        let expectedHeight = ceil(harness.session.surface.attachmentGeometry.usableWidth / 2)
        XCTAssertEqual(try attachment(harness.session, "img").content.size.height, expectedHeight)
        XCTAssertEqual(try block(harness.session, "p").runs.map(\.text).joined(), "Hiか")
        assertS2Consistent(harness.session)
        try await assertConsistent(harness, localCommands: 1)
    }

    /// An off-screen image strictly above the visible viewport compensates
    /// `contentOffset.y` by `(newLineHeight - oldLineHeight)` so visible reading
    /// content stays anchored in place.
    func testAboveViewportImageLoadCompensatesScrollOffset() async throws {
        var docBlocks: [BlockNoteBlock] = [image("imgTop", url: "\(Self.origin)/media/top.png")]
        for index in 0..<30 {
            docBlocks.append(paragraph("p\(index)", "Paragraph \(index) with enough text for stable layout"))
        }
        let harness = try await makeHarness(docBlocks)
        addTeardownBlock { await harness.close() }
        let log = FetchLog()
        let gate = FetchGate()
        harness.view.blockControls.images = loader(log) { _ in
            gate.started = true
            return try await withCheckedThrowingContinuation { continuation in
                gate.continuation = continuation
            }
        }
        harness.view.blockControls.serverOrigin = Self.origin
        let window = host(harness.view, height: 400)
        defer { window.isHidden = true }
        await waitUntil { gate.started }

        let oldAttachment = try attachment(harness.session, "imgTop")
        let topView = try XCTUnwrap(realized(harness.session, "imgTop"))

        // Scroll down so imgTop lies strictly above the viewport while p6 is visible inside it.
        harness.view.contentOffset = CGPoint(x: 0, y: 240)
        harness.view.layoutIfNeeded()
        let anchorID = "p6"
        let anchorBefore = try fragmentFrame(harness.session, anchorID)
        let screenYBefore = anchorBefore.minY - harness.view.contentOffset.y
        let offsetBefore = harness.view.contentOffset.y

        // Tall portrait image (200x400 -> ratio 0.5 -> height capped at maxImageHeight = 640).
        gate.continuation?.resume(returning: testPNGData(width: 200, height: 400))
        await topView.loadTask?.value
        harness.view.layoutIfNeeded()

        let newAttachment = try attachment(harness.session, "imgTop")
        let expectedDelta = newAttachment.content.lineHeight - oldAttachment.content.lineHeight
        XCTAssertGreaterThan(expectedDelta, 100)
        let anchorAfter = try fragmentFrame(harness.session, anchorID)
        let imgFragAfter = try fragmentFrame(harness.session, "imgTop")
        let screenYAfter = anchorAfter.minY - harness.view.contentOffset.y
        XCTAssertEqual(
            harness.view.contentOffset.y, offsetBefore + expectedDelta, accuracy: 0.5,
            "imgFragAfter=\(imgFragAfter) anchorBefore=\(anchorBefore) anchorAfter=\(anchorAfter) oldLH=\(oldAttachment.content.lineHeight) newLH=\(newAttachment.content.lineHeight) contentSize=\(harness.view.contentSize)"
        )
        XCTAssertEqual(screenYAfter, screenYBefore, accuracy: 0.5, "visible content stayed anchored")
        assertS2Consistent(harness.session)
        try await assertConsistent(harness, localCommands: 0)
        XCTAssertEqual(try journalCount(harness), 0)
    }

    /// Multiple images finishing in the same session refresh accurately, never
    /// loop, and pre-cached ratios apply on `.insert` / `.replaceBlock` first frame.
    func testMultipleImageLoadsAndPreCachedPatchApplyFirstFrameHeight() async throws {
        let urlA = "\(Self.origin)/media/a.png"
        let urlB = "\(Self.origin)/media/b.png"
        let harness = try await makeHarness([
            paragraph("intro", "Start"),
            image("imgA", url: urlA),
            image("imgB", url: urlB),
        ])
        addTeardownBlock { await harness.close() }
        let log = FetchLog()
        let imgLoader = loader(log, data: testPNGData(width: 400, height: 200))
        harness.view.blockControls.images = imgLoader
        harness.view.blockControls.serverOrigin = Self.origin
        let window = host(harness.view, height: 900)
        defer { window.isHidden = true }

        let viewA = try XCTUnwrap(realized(harness.session, "imgA"))
        let viewB = try XCTUnwrap(realized(harness.session, "imgB"))
        await viewA.loadTask?.value
        await viewB.loadTask?.value
        harness.view.layoutIfNeeded()

        let usable = harness.session.surface.attachmentGeometry.usableWidth
        let expectedHeight = ceil(usable / 2)
        XCTAssertEqual(try attachment(harness.session, "imgA").content.size.height, expectedHeight)
        XCTAssertEqual(try attachment(harness.session, "imgB").content.size.height, expectedHeight)
        XCTAssertEqual(Set(log.urls).count, 2)
        XCTAssertEqual(log.urls.count, 2, "each image fetched exactly once")
        assertS2Consistent(harness.session)

        // Pre-cached URL inserted or replaced via surface patch renders at its true height on the first frame.
        let inserted = BlockSnapshot(
            id: "imgC", node: "image", props: [], runs: [],
            preview: .image(url: urlA, alt: "", previewWidth: nil))
        harness.session.surface.applyPatch(
            BlockPatch([.insert(after: "imgB", blocks: [inserted])], origin: .other))
        XCTAssertEqual(try attachment(harness.session, "imgC").content.size.height, expectedHeight)
        let placeholderD = BlockSnapshot(id: "imgD", node: "paragraph", props: [], runs: [])
        harness.session.surface.applyPatch(
            BlockPatch([.insert(after: "imgC", blocks: [placeholderD])], origin: .other))
        let replacedD = BlockSnapshot(
            id: "imgD", node: "image", props: [], runs: [],
            preview: .image(url: urlB, alt: "", previewWidth: nil))
        harness.session.surface.applyPatch(
            BlockPatch([.replaceBlock(blockID: "imgD", block: replacedD)], origin: .other))
        XCTAssertEqual(try attachment(harness.session, "imgD").content.size.height, expectedHeight)
        XCTAssertEqual(try journalCount(harness), 0)
    }

    /// An image loading inside a column editor refreshes its card height and
    /// propagates the updated height to `ColumnTextContainer.contentSize`.
    func testImageLoadInsideColumnPropagatesHeightToColumnContainer() async throws {
        let stateData = try state(
            [paragraph("lead", "Lead")],
            inserting: [
                (
                    after: "lead",
                    node: .element(
                        "columnList", [("id", .string("cl"))],
                        [
                            .element(
                                "column", [("id", .string("c1")), ("width", .int(1))],
                                [
                                    container(
                                        "c1-p",
                                        .element(
                                            "paragraph", Self.paragraphProps.map { ($0.key, $0.value) },
                                            [.text("Column text")])),
                                    container(
                                        "c1-img",
                                        .element(
                                            "image",
                                            [
                                                ("backgroundColor", .string("default")), ("caption", .string("")),
                                                ("name", .string("col.png")), ("showPreview", .bool(true)),
                                                ("textAlignment", .string("left")),
                                                ("url", .string("\(Self.origin)/media/col.png")),
                                            ], [])),
                                ]),
                            .element(
                                "column", [("id", .string("c2")), ("width", .int(1))],
                                [
                                    container(
                                        "c2-p",
                                        .element(
                                            "paragraph", Self.paragraphProps.map { ($0.key, $0.value) },
                                            [.text("Right")]))
                                ]),
                        ])
                )
            ])
        let harness = try await makeHarness(state: stateData)
        addTeardownBlock { await harness.close() }
        let model = ColumnEditorModel(document: harness.session, groupID: "cl")
        addTeardownBlock { model.close() }
        await model.load()
        XCTAssertEqual(model.columns.count, 2)
        let column = model.columns[0]

        let log = FetchLog()
        let gate = FetchGate()
        column.textView.blockControls.images = loader(log) { _ in
            gate.started = true
            return try await withCheckedThrowingContinuation { continuation in
                gate.continuation = continuation
            }
        }
        column.textView.blockControls.serverOrigin = Self.origin

        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.traitOverrides.horizontalSizeClass = .compact
        let containerView = ColumnTextContainer(frame: window.bounds)
        window.addSubview(containerView)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        containerView.show(
            model.columns.map(\.textView), widths: model.group?.columns.map { $0.width ?? 1 } ?? [], active: 0)
        for _ in 0..<3 { containerView.layoutIfNeeded() }

        await waitUntil { gate.started }
        let initialAttachment = try attachment(column, "c1-img")
        let imgFrameBefore = try fragmentFrame(column, "c1-img")
        XCTAssertEqual(initialAttachment.content.size.height, NativeAttachmentLayout.placeholderImageHeight)
        let columnHeightBefore = column.textView.contentSize.height
        let containerHeightBefore = containerView.contentSize.height
        let view = try XCTUnwrap(realized(column, "c1-img"))

        // Tall 200x400 image expands card height from 160 to 640 (or box / 0.5).
        gate.continuation?.resume(returning: testPNGData(width: 200, height: 400))
        await view.loadTask?.value
        for _ in 0..<3 {
            column.textView.layoutIfNeeded()
            containerView.layoutIfNeeded()
        }

        let updatedAttachment = try attachment(column, "c1-img")
        let expectedHeight = min(
            NativeAttachmentLayout.maxImageHeight,
            ceil(column.surface.attachmentGeometry.usableWidth / 0.5))
        XCTAssertEqual(updatedAttachment.content.size.height, expectedHeight)
        let delta = updatedAttachment.content.lineHeight - initialAttachment.content.lineHeight
        let imgFrameAfter = try fragmentFrame(column, "c1-img")
        XCTAssertGreaterThan(delta, 100)
        XCTAssertEqual(
            column.textView.contentSize.height, columnHeightBefore + delta, accuracy: 1,
            "before=\(columnHeightBefore) containerBefore=\(containerHeightBefore) imgFrameBefore=\(imgFrameBefore) imgFrameAfter=\(imgFrameAfter) attSize=\(updatedAttachment.content.size) bounds=\(column.textView.bounds) tcSize=\(column.textView.textContainer.size) c2=\(model.columns[1].textView.contentSize) storage=\(String(reflecting: column.textView.textStorage.string)) blocks=\(column.surface.blocks.map(\.id))"
        )
        XCTAssertEqual(containerView.contentSize.height, containerHeightBefore + delta, accuracy: 1)
        assertS2Consistent(column)
        try await assertConsistent(harness, localCommands: 0)
        XCTAssertEqual(try journalCount(harness), 0)
    }

    /// A root document ending in a placeholder (no trailing paragraph) must not
    /// inherit the attachment's `lineHeight` on TextKit 2's trailing empty line.
    func testRootEndingInPlaceholderDoesNotDoubleTrailingLineHeight() async throws {
        let harness = try await makeHarness([
            paragraph("lead", "Lead"),
            image("img", url: "\(Self.origin)/media/end.png"),
        ])
        addTeardownBlock { await harness.close() }
        let log = FetchLog()
        let gate = FetchGate()
        harness.view.blockControls.images = loader(log) { _ in
            gate.started = true
            return try await withCheckedThrowingContinuation { continuation in
                gate.continuation = continuation
            }
        }
        harness.view.blockControls.serverOrigin = Self.origin
        let window = host(harness.view, height: 900)
        defer { window.isHidden = true }
        await waitUntil { gate.started }

        let initialAttachment = try attachment(harness.session, "img")
        let heightBefore = harness.view.contentSize.height
        let frameBefore = try fragmentFrame(harness.session, "img")
        XCTAssertLessThan(
            frameBefore.height, initialAttachment.content.lineHeight * 1.5,
            "trailing empty line must not inherit attachment lineHeight even before image load")
        if let contentStorage = harness.view.textLayoutManager?.textContentManager as? NSTextContentStorage {
            let leadRange = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "lead")).range
            let imgRange = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "img")).range
            XCTAssertNil(harness.view.blockControls.textContentStorage(contentStorage, textParagraphWith: leadRange))
            XCTAssertNotNil(harness.view.blockControls.textContentStorage(contentStorage, textParagraphWith: imgRange))
        }
        let view = try XCTUnwrap(realized(harness.session, "img"))

        gate.continuation?.resume(returning: testPNGData(width: 200, height: 400))
        await view.loadTask?.value
        harness.view.layoutIfNeeded()

        let updatedAttachment = try attachment(harness.session, "img")
        let frameAfter = try fragmentFrame(harness.session, "img")
        let delta = updatedAttachment.content.lineHeight - initialAttachment.content.lineHeight
        XCTAssertGreaterThan(delta, 100)
        XCTAssertEqual(frameAfter.height - frameBefore.height, delta, accuracy: 1)
        XCTAssertEqual(
            harness.view.contentSize.height, heightBefore + delta, accuracy: 1,
            "before=\(heightBefore) after=\(harness.view.contentSize.height) delta=\(delta) frameBefore=\(frameBefore) frameAfter=\(frameAfter)"
        )
        assertS2Consistent(harness.session)
        try await assertConsistent(harness, localCommands: 0)
    }

    /// `MarkdownImageView.matchesSession`: a loader of another server's
    /// session (a stale one after a server or account switch) neither shows
    /// its cached image nor requests one, and a tap-to-load does nothing.
    func testALoaderOfAnotherSessionShowsAndRequestsNothing() async throws {
        let url = "\(Self.origin)/media/photo.png"
        let harness = try await makeHarness([
            image("img", url: url), image("ext", url: "https://elsewhere.example/a.png"),
        ])
        addTeardownBlock { await harness.close() }
        let log = FetchLog()
        let images = loader(log)
        // The image is already decoded and cached in that loader's session.
        _ = await images.loadIfNeeded(URL(string: url)!)
        XCTAssertEqual(log.urls.count, 1)
        harness.view.blockControls.images = images
        harness.view.blockControls.serverOrigin = "https://other.example"
        let window = host(harness.view)
        defer { window.isHidden = true }
        for id in ["img", "ext"] {
            let view = try XCTUnwrap(realized(harness.session, id))
            XCTAssertNil(view.loadTask, "\(id): no load is started")
            view.approveAndLoad()
            await view.loadTask?.value
            XCTAssertNil(view.imageView?.image, "\(id): no cached image is shown")
            XCTAssertNil(view.loadButton)
            XCTAssertEqual(view.imageStatus?.text, "Image available when online")
        }
        XCTAssertEqual(log.urls.count, 1, "no request under another session")
        XCTAssertNil(harness.session.surface.aspectRatio?(url), "nor its remembered ratio")
    }

    /// A theme change keeps a loaded image's card clear.
    func testThemeChangeKeepsALoadedImageClear() async throws {
        let harness = try await makeHarness([image("img", url: "\(Self.origin)/media/photo.png")])
        addTeardownBlock { await harness.close() }
        harness.view.blockControls.images = loader(FetchLog())
        harness.view.blockControls.serverOrigin = Self.origin
        let window = host(harness.view)
        defer { window.isHidden = true }
        let view = try XCTUnwrap(realized(harness.session, "img"))
        await view.loadTask?.value
        XCTAssertNotNil(view.imageView?.image)
        harness.view.blockControls.invalidateChrome()
        XCTAssertEqual(view.backgroundColor, .clear)
    }

    /// Offline, an uncached image issues no request and says so.
    func testOfflineImageIssuesNoRequest() async throws {
        let harness = try await makeHarness([image("img", url: "\(Self.origin)/media/photo.png")])
        addTeardownBlock { await harness.close() }
        let log = FetchLog()
        harness.view.blockControls.images = loader(log)
        harness.view.blockControls.serverOrigin = Self.origin
        harness.view.blockControls.isOffline = true
        let window = host(harness.view)
        defer { window.isHidden = true }
        let view = try XCTUnwrap(realized(harness.session, "img"))
        await view.loadTask?.value
        XCTAssertTrue(log.urls.isEmpty)
        XCTAssertEqual(view.imageStatus?.text, "Image available when online")
        XCTAssertEqual(view.accessibilityValue, "Image available when online")
    }

    /// No loader (a host without one): a placeholder, never a request.
    func testWithoutALoaderTheImageStaysAPlaceholder() async throws {
        let harness = try await makeHarness([image("img", url: "\(Self.origin)/media/photo.png")])
        addTeardownBlock { await harness.close() }
        let window = host(harness.view)
        defer { window.isHidden = true }
        let view = try XCTUnwrap(realized(harness.session, "img"))
        XCTAssertNil(view.loadTask)
        XCTAssertNil(view.imageView?.image)
    }

    // MARK: - Bounded realisation and no writes

    /// 5,000 mixed blocks with 200 previews: only the ones around the
    /// viewport are realised, at the top and after scrolling, and opening and
    /// scrolling write nothing.
    func testOnlyVisibleAttachmentsAreRealisedAt5000Blocks() async throws {
        var blocks: [BlockNoteBlock] = []
        var tables: [(after: String, node: XNode)] = []
        for index in 0..<4_800 {
            blocks.append(paragraph("p\(index)", "Paragraph \(index) with some words to wrap across the line."))
            guard index % 24 == 0 else { continue }
            switch index / 24 % 4 {
            case 0: blocks.append(image("img\(index)", url: "\(Self.origin)/media/\(index).png"))
            case 1: blocks.append(media("video", "vid\(index)", name: "\(index).mp4"))
            case 2: blocks.append(block("mathBlock", "math\(index)", text: "x^\(index)"))
            default:
                tables.append((after: "p\(index)", node: container("tbl\(index)", table([["a", "b"], ["c", "d"]]))))
            }
        }
        let harness = try await makeHarness(state: state(blocks, inserting: tables))
        addTeardownBlock { await harness.close() }
        let session = harness.session
        XCTAssertEqual(session.surface.blocks.count, 5_000)
        XCTAssertEqual(session.surface.blocks.filter(AttributedDocumentProjection.isPlaceholder).count, 200)
        let log = FetchLog()
        harness.view.blockControls.images = loader(log)
        harness.view.blockControls.serverOrigin = Self.origin
        let window = host(harness.view, height: 844)
        defer { window.isHidden = true }
        let controls = harness.view.blockControls!
        XCTAssertGreaterThan(controls.attachmentViewLoads, 0)
        XCTAssertLessThanOrEqual(controls.attachmentViewLoads, 12, "only the viewport's previews at the top")

        for fraction in [0.25, 0.5, 0.75, 0.999] {
            let target = (harness.view.contentSize.height - harness.view.bounds.height) * fraction
            harness.view.contentOffset = CGPoint(x: 0, y: target)
            harness.view.layoutIfNeeded()
            XCTAssertLessThanOrEqual(controls.visibleAttachmentViews.count, 12, "bounded at \(fraction)")
        }
        XCTAssertLessThanOrEqual(controls.attachmentViewLoads, 60, "never the 200 of the document")
        XCTAssertLessThanOrEqual(log.urls.count, 15, "only realised images load")
        XCTAssertTrue(harness.log.commands.isEmpty)
        XCTAssertEqual(try journalCount(harness), 0, "opening and scrolling write nothing")
        let failed = await harness.engine { $0.nativeWriteFailed }
        XCTAssertEqual(failed, false)
    }

    /// A peer's edit inside a table reaches the preview (one `.replaceBlock`).
    func testPeerTableEditRefreshesThePreview() async throws {
        let checkpoint = try state(
            [paragraph("intro", "Intro")], inserting: [(after: "intro", node: container("tbl", table([["A"], ["b"]])))])
        let harness = try await makeHarness(state: checkpoint)
        addTeardownBlock { await harness.close() }
        let peer = YDoc(clientID: 77, gc: true)
        defer { peer.destroy() }
        try peer.applyUpdate(YUpdateDecoder.decode(checkpoint))
        let root = try XCTUnwrap(peer.share[BlockNoteYjs.fragmentField])
        var text: YType?
        func find(_ type: YType) {
            for item in YBlockProjection.children(of: type, includeFormats: false) {
                guard case .type(let child) = item.content else { continue }
                if child.typeRef == .xmlText, YBlockProjection.textRuns(child)?.map(\.text).joined() == "b" {
                    text = child
                }
                find(child)
            }
        }
        find(root)
        try XCTUnwrap(text).insert(1, "eta", nil)
        try await harness.session.integrateServerState(YStateEncoder.encodeStateAsUpdate(peer))
        guard case .table(let cells, _, _) = try attachment(harness.session, "tbl").content.preview else {
            return XCTFail("still a table")
        }
        XCTAssertEqual(cells, [["A"], ["beta"]])
        XCTAssertTrue(harness.log.commands.isEmpty, "a peer's edit is not a local command")
    }

    // MARK: - VoiceOver

    func testVoiceOverLabels() async throws {
        let harness = try await makeHarness(state: everyFamily())
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let window = host(harness.view)
        defer { window.isHidden = true }
        let expected = [
            "img": "Image: A red flower", "vid": "Video: clip.mp4", "aud": "Audio: roar.mp3",
            "fil": "File: notes.txt", "doc": "PDF: paper.pdf", "tbl": "Table, 8 by 6", "cols": "Columns, 2",
            "math": "Math source", "diag": "Diagram source", "widget": "customWidget (preserved, not editable yet)",
        ]
        for (id, label) in expected {
            XCTAssertEqual(try attachment(session, id).content.label, label)
            let view = try XCTUnwrap(realized(session, id))
            XCTAssertTrue(view.isAccessibilityElement)
            XCTAssertEqual(view.accessibilityLabel, label)
        }
        let value = try XCTUnwrap(harness.view.accessibilityValue)
        XCTAssertFalse(value.contains(AttributedDocumentProjection.attachmentCharacter))
        XCTAssertTrue(value.contains("Intro paragraph\nImage: A red flower\nVideo: clip.mp4"))
        XCTAssertTrue(value.contains("Table, 8 by 6\nColumns, 2\n"))

        // Localized: the label follows the editor's labels.
        let french = Strings_fr.table
        var labels = session.surface.labels
        labels.table = french[.native_editor_table]!
        session.surface.updatePresentation(traits: session.surface.traits, labels: labels)
        XCTAssertEqual(try attachment(session, "tbl").content.label, "Tableau, 8 sur 6")
    }

    // MARK: - Real capture

    /// The real test document (`.review/state.bin`, git-ignored): tables,
    /// media, math, columns and a diagram. Every block renders, scrolling end
    /// to end, without a crash.
    func testRealCaptureRendersEveryBlock() async throws {
        let review = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".review")
        guard let state = try? Data(contentsOf: review.appendingPathComponent("state.bin")) else {
            throw XCTSkip("no .review capture")
        }
        let session = try await NativeEditorSession.seed(state: state)
        addTeardownBlock { await session.close().value }
        let view = session.textView
        let window = host(view, height: 844)
        defer { window.isHidden = true }
        var seen: Set<String> = []
        var offset: CGFloat = 0
        repeat {
            view.contentOffset = CGPoint(x: 0, y: offset)
            view.layoutIfNeeded()
            seen.formUnion(view.blockControls.visibleAttachmentViews.map(\.content.blockID))
            offset += 400
        } while offset < view.contentSize.height
        let previews = session.surface.blocks.filter(AttributedDocumentProjection.isPlaceholder)
        XCTAssertFalse(previews.isEmpty)
        XCTAssertEqual(Set(previews.map(\.id)), seen, "every preview block was realised")
        func preview(_ node: String) -> NativeBlockPreview? { previews.first { $0.node == node }?.preview }
        XCTAssertEqual(
            preview("table"),
            .table(
                cells: [["Name", "Role", "Status"], ["Ada", "Engineer", "Active"], ["Grace", "Admiral", "Retired"]],
                rowCount: 3, columnCount: 3))
        XCTAssertEqual(
            preview("columnList"),
            .columns(
                [
                    [.init(node: "paragraph", text: "Left column text")],
                    [.init(node: "paragraph", text: "Right column text"), .init(node: "image", text: "")],
                ], columnCount: 2))
        XCTAssertEqual(
            preview("diagram"), .source(node: "diagram", lines: ["graph TD", "    A[Start] --> B[Stop]"], lineCount: 2))
        XCTAssertEqual(
            preview("video"),
            .video(
                url: "https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4",
                label: "flower.mp4",
                previewWidth: nil))
        let value = view.accessibilityValue ?? ""
        XCTAssertTrue(value.contains("Table, 3 by 3"))
        XCTAssertTrue(value.contains("Video: flower.mp4"))
        XCTAssertTrue(value.contains("Math"))
    }
}
