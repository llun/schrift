import XCTest

@testable import Schrift

/// PR13a against real BlockNote 0.56 media blocks and Docs' server `pdf` and
/// `uploadLoader` specs (`BlockNoteMediaCaptures`, media.mjs): every
/// web-authored media block is familiar and modeled, its shadow is the
/// exporter's own Markdown, and the native writer's prop edits, upload
/// commits, replacements and slash insertions produce the web's XML and
/// Markdown. Anything the shadow could not spell is refused before a write.
final class BlockNoteMediaOracleTests: XCTestCase {
    private func doc(_ base64: String, clientID: UInt = 9) throws -> YDoc {
        let doc = YDoc(clientID: clientID, gc: false)
        try doc.applyUpdate(YUpdateDecoder.decode(try XCTUnwrap(Data(base64Encoded: base64))))
        return doc
    }

    /// The export writes an empty media block as an empty block (blank lines)
    /// and an empty paragraph likewise; the shadow drops both, as the classic
    /// shadow drops empty paragraphs, which `syncCanonicalMarkdown` reads as
    /// no change. Everything else is byte for byte.
    private static func isEmptyBlock(_ name: String) -> Bool {
        (name.hasSuffix("Empty") || name.hasSuffix("NameOnlyCaption") || name.contains("Slash"))
            && !name.hasPrefix("pdf")
    }

    /// Below the root, and with children, only the classic image line spells
    /// a media block (its own canonical shadow).
    private static let classicShapes: Set<String> = ["nestedImage", "imageWithChild"]

    /// The classic spelling of the lists around a media block writes `- `
    /// where the export writes `* ` (as at the root without media).
    private static let classicLists: Set<String> = ["listAroundImage"]

    private func assertShadow(
        _ doc: YDoc, _ markdown: String, _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let shadow = NativeBlockProjection.markdownShadow(doc)
        XCTAssertEqual(
            shadow.map(syncCanonicalMarkdown), syncCanonicalMarkdown(markdown), name, file: file, line: line)
        if !Self.isEmptyBlock(name), !Self.classicShapes.contains(name), !Self.classicLists.contains(name) {
            XCTAssertEqual(shadow, markdown, name, file: file, line: line)
        }
    }

    func testEveryFixtureIsModeledAndItsShadowIsTheExport() throws {
        for fixture in BlockNoteMediaCaptures.fixtures {
            let doc = try doc(fixture.update)
            defer { doc.destroy() }
            XCTAssertEqual(YXMLString.fragment(doc), fixture.xml, fixture.name)
            let native = NativeBlockProjection.project(doc)
            XCTAssertTrue(native.isFullyModeled, "\(fixture.name): the native projection models media")
            if fixture.name == "pdfJs" {
                // The server prints a non-http(s) pdf url as a span glued to
                // the next block: no shadow, so the document stays read-only.
                XCTAssertNil(NativeBlockProjection.markdownShadow(doc), fixture.name)
                continue
            }
            assertShadow(doc, fixture.markdown, fixture.name)
        }
    }

    /// The classic projection, its goldens and its shadow keep today's rules:
    /// only a default-props image is modeled there.
    func testTheClassicProjectionIsUnchanged() throws {
        for fixture in BlockNoteMediaCaptures.fixtures
        where fixture.name == "imageCaption" || fixture.name == "videoBasic" {
            let doc = try doc(fixture.update)
            defer { doc.destroy() }
            XCTAssertFalse(YBlockProjection.project(doc).isFullyModeled, fixture.name)
        }
    }

    private func command(_ engine: DocumentEngine, _ id: String, _ kind: NativeEditCommand.Kind) -> NativeEditCommand {
        NativeEditCommand(id: UUID(), baseRevision: engine.revision, blockID: id, kind: kind)
    }

    private func apply(_ engine: DocumentEngine, _ id: String, _ kind: NativeEditCommand.Kind) throws {
        _ = try engine.applyStructural(command(engine, id, kind), persist: { _ in })
    }

    private static let url = "https://docs.example/media/0b5d1c0e-7e4b-4c3b-9a35-5b8f3c9b8e11/attachments/"

    private static func mediaURL(_ node: String) -> String {
        switch node {
        case "file": url + "2a2b3c4d-0b1d-4a8e-9f8c-3d2e1f0a9b8c-unsafe.docx"
        case "image": url + "5f0f6a54-0b1d-4a8e-9f8c-3d2e1f0a9b8c.png"
        default: url + "1a2b3c4d-0b1d-4a8e-9f8c-3d2e1f0a9b8c.mp4"
        }
    }

    private func string(_ key: String, _ value: String) -> ProjectedProp {
        ProjectedProp(key: key, value: .string(value))
    }

    /// The native writer against the web's own edits: the same XML, and the
    /// shadow the web's Markdown.
    func testMediaEditsMatchTheWebCaptures() throws {
        var covered: Set<String> = []
        func edited(_ name: String, _ body: (DocumentEngine) throws -> Void) throws {
            let capture = try XCTUnwrap(BlockNoteMediaCaptures.edits.first { $0.name == name }, name)
            covered.insert(name)
            let doc = try doc(capture.seed, clientID: 2)
            defer { doc.destroy() }
            let surface = HeadlessSurface()
            let engine = DocumentEngine(doc: doc, surface: surface)
            defer { engine.detach() }
            try body(engine)
            XCTAssertEqual(YXMLString.fragment(doc), capture.xml, name)
            assertShadow(doc, capture.markdown, name)
            XCTAssertFalse(engine.nativeWriteFailed, name)
            XCTAssertTrue(NativeBlockProjection.project(doc).isFullyModeled, name)
        }
        for node in ["image", "video", "audio", "file", "pdf"] {
            let url = Self.mediaURL(node)
            try edited("\(node)SetCaption") { try apply($0, "mx", .mediaProps([string("caption", "New caption")])) }
            try edited("\(node)ClearCaption") { try apply($0, "mx", .mediaProps([string("caption", "")])) }
            try edited("\(node)SetName") { try apply($0, "mx", .mediaProps([string("name", "renamed.bin")])) }
            try edited("\(node)Commit") {
                try apply(
                    $0, "mx",
                    .mediaProps(
                        [string("name", "up.bin"), string("url", url)],
                        expecting: MediaBlock.Slot(node: node, url: "")))
            }
            try edited("\(node)Replace") {
                try apply(
                    $0, "mx",
                    .mediaProps([
                        string("name", "new.bin"),
                        string("url", url.replacingOccurrences(of: "docs.example", with: "docs2.example")),
                    ]))
            }
            if node != "audio" && node != "file" {
                try edited("\(node)SetWidth") {
                    try apply($0, "mx", .mediaProps([ProjectedProp(key: "previewWidth", value: .int(400))]))
                }
                try edited("\(node)SetWidthFraction") {
                    try apply(
                        $0, "mx",
                        .mediaProps([ProjectedProp(key: "previewWidth", value: BlockNoteWriter.number(250.5))]))
                }
                try edited("\(node)SetAlign") { try apply($0, "mx", .mediaProps([string("textAlignment", "center")])) }
                try edited("\(node)HidePreview") {
                    try apply($0, "mx", .mediaProps([ProjectedProp(key: "showPreview", value: .bool(false))]))
                }
            }
            // The web's ids: the new block "1" after a paragraph with text.
            try edited("\(node)SlashEmpty") {
                try apply($0, "q", .insertMedia(node: node, ids: ["spare", "spare2"], removing: 0..<0))
            }
            try edited("\(node)SlashAfterText") {
                try apply($0, "lead", .insertMedia(node: node, ids: ["1", "spare"], removing: 0..<0))
            }
        }
        // The trailing paragraph: after the document's last root block, even from a column.
        try edited("imageSlashLastEmpty") {
            try apply($0, "q", .insertMedia(node: "image", ids: ["spare", "1"], removing: 0..<0))
        }
        try edited("imageSlashLastText") {
            try apply($0, "lead", .insertMedia(node: "image", ids: ["1", "2"], removing: 0..<0))
        }
        try edited("imageSlashBeforeDivider") {
            try apply($0, "q", .insertMedia(node: "image", ids: ["spare", "1"], removing: 0..<0))
        }
        try edited("imageSlashBeforeDividerLast") {
            try apply($0, "q", .insertMedia(node: "image", ids: ["spare", "1"], removing: 0..<0))
        }
        try edited("imageSlashInColumn") { engine in
            XCTAssertTrue(engine.openColumns("cl"))
            try apply(engine, "q", .insertMedia(node: "image", ids: ["spare", "1"], removing: 0..<0))
        }
        try edited("imageSlashInColumnLast") { engine in
            XCTAssertTrue(engine.openColumns("cl"))
            try apply(engine, "q", .insertMedia(node: "image", ids: ["spare", "1"], removing: 0..<0))
        }
        try edited("imageDelete") { try apply($0, "mx", .deleteBlock) }
        let refused: Set<String> = ["imageSlashNestedEmpty", "imageSlashWithChildren"]
        XCTAssertEqual(
            Set(BlockNoteMediaCaptures.edits.map(\.name)).subtracting(covered), refused,
            "every web edit is either matched or refused below")
    }

    /// The web makes a nested media block (a nested "/image") or gives one
    /// children (a "/image" on a paragraph with children); neither has a
    /// shadow, so the native slash item refuses both before any write.
    func testMediaInsertionBelowTheRootOrWithChildrenIsRefused() throws {
        for name in ["imageSlashNestedEmpty", "imageSlashWithChildren"] {
            let capture = try XCTUnwrap(BlockNoteMediaCaptures.edits.first { $0.name == name })
            let doc = try doc(capture.seed, clientID: 2)
            defer { doc.destroy() }
            let engine = DocumentEngine(doc: doc, surface: HeadlessSurface())
            defer { engine.detach() }
            let before = YXMLString.fragment(doc)
            let insert = command(engine, "q", .insertMedia(node: "image", ids: ["n1", "n2"], removing: 0..<0))
            XCTAssertFalse(engine.canApplyStructural(insert), name)
            do {
                _ = try engine.applyStructural(insert, persist: { _ in })
                XCTFail("\(name): applied")
            } catch DocumentEngineError.unsupportedNativeInput {
            } catch {
                XCTFail("\(name): \(error)")
            }
            XCTAssertEqual(YXMLString.fragment(doc), before, name)
        }
    }

    /// Values a native edit may not store, kinds that lack the prop, a peer's
    /// `uploadLoader`, and a commit whose slot changed: each refused, nothing
    /// written.
    func testInvalidMediaEditsAreRefusedBeforeAnyWrite() throws {
        let capture = try XCTUnwrap(BlockNoteMediaCaptures.edits.first { $0.name == "imageSetCaption" })
        let doc = try doc(capture.seed, clientID: 2)
        defer { doc.destroy() }
        let engine = DocumentEngine(doc: doc, surface: HeadlessSurface())
        defer { engine.detach() }
        let before = YXMLString.fragment(doc)
        let url = Self.mediaURL("image")
        let refused: [[ProjectedProp]] = [
            [string("url", "javascript:alert(1)")],
            [string("url", "file:///private/var/mobile/photo.jpg")],
            [string("url", "schrift-attachment://1234")],
            [string("url", "/media/relative.png")],
            [string("url", "https://exa mple.com/a.png")],
            [string("url", "https://user:pass@example.com/a.png")],
            [string("url", "https://example.com/" + String(repeating: "a", count: 3000))],
            [string("name", "two\nlines")],
            [string("caption", String(repeating: "c", count: 5000))],
            [ProjectedProp(key: "previewWidth", value: .int(0))],
            [ProjectedProp(key: "previewWidth", value: .string("400"))],
            [string("textAlignment", "middle")],
            [string("backgroundColor", "red")],
            [string("unknown", "x")],
            [string("name", "a"), string("name", "b")],
            [],
        ]
        for props in refused {
            let edit = command(engine, "mx", .mediaProps(props))
            XCTAssertFalse(engine.canApplyStructural(edit), "\(props)")
        }
        // A commit refuses a block whose url or kind is not the upload's slot.
        XCTAssertFalse(
            engine.canApplyStructural(
                command(
                    engine, "mx",
                    .mediaProps([string("url", url)], expecting: MediaBlock.Slot(node: "image", url: "")))))
        XCTAssertFalse(
            engine.canApplyStructural(
                command(
                    engine, "mx", .mediaProps([string("url", url)], expecting: MediaBlock.Slot(node: "video", url: url))
                )
            ))
        XCTAssertTrue(
            engine.canApplyStructural(
                command(
                    engine, "mx", .mediaProps([string("url", url)], expecting: MediaBlock.Slot(node: "image", url: url))
                )
            ))
        // Not a media block.
        XCTAssertFalse(engine.canApplyStructural(command(engine, "lead", .mediaProps([string("caption", "x")]))))
        XCTAssertEqual(YXMLString.fragment(doc), before)

        // Audio has no width or alignment; a file has no preview either.
        for (name, props) in [
            ("audioSetCaption", [ProjectedProp(key: "previewWidth", value: .int(300))]),
            ("audioSetCaption", [string("textAlignment", "center")]),
            ("fileSetCaption", [ProjectedProp(key: "showPreview", value: .bool(false))]),
        ] {
            let capture = try XCTUnwrap(BlockNoteMediaCaptures.edits.first { $0.name == name })
            let doc = try self.doc(capture.seed, clientID: 2)
            defer { doc.destroy() }
            let engine = DocumentEngine(doc: doc, surface: HeadlessSurface())
            defer { engine.detach() }
            XCTAssertFalse(engine.canApplyStructural(command(engine, "mx", .mediaProps(props))), "\(name) \(props)")
        }
    }

    /// A pasted media block (an untrusted payload, review S2) must hold only
    /// what a native edit could write: a script, data or non-web url, an
    /// unbounded name, a width out of range or a pdf the shadow cannot spell
    /// is refused before any write; a well-formed one pastes.
    func testPastedMediaIsValidatedLikeANativeEdit() throws {
        let capture = try XCTUnwrap(BlockNoteMediaCaptures.edits.first { $0.name == "imageSetCaption" })
        let doc = try doc(capture.seed, clientID: 2)
        defer { doc.destroy() }
        let engine = DocumentEngine(doc: doc, surface: HeadlessSurface())
        defer { engine.detach() }
        func payload(_ node: String, _ overrides: [String: YAnyValue]) throws -> Data {
            let props = (MediaBlock.schemas[node] ?? []).map { (key: $0.key, value: overrides[$0.key] ?? $0.value) }
            return try BlockNoteSubtreePayload.encode([
                .element("blockContainer", [("id", .string("pasted"))], [.element(node, props, [])])
            ])
        }
        let refused: [(String, [String: YAnyValue])] = [
            ("image", ["url": .string("javascript:alert(1)")]),
            ("image", ["url": .string("data:image/png;base64,AAAA")]),
            ("file", ["url": .string("/media/relative.bin")]),
            ("pdf", ["url": .string("ftp://files.example/a.pdf")]),
            ("image", ["name": .string(String(repeating: "n", count: MediaBlock.maxName + 1))]),
            ("video", ["caption": .string("two\nlines")]),
            ("image", ["previewWidth": BlockNoteWriter.number(1e20)]),
            ("image", ["textAlignment": .string("middle")]),
            ("image", ["url": .int(3)]),
        ]
        let before = YXMLString.fragment(doc)
        for (node, overrides) in refused {
            XCTAssertFalse(
                engine.canApplyStructural(
                    command(engine, "lead", .insertSubtrees(payload: try payload(node, overrides)))),
                "\(node) \(overrides)")
        }
        XCTAssertEqual(YXMLString.fragment(doc), before)
        try apply(
            engine, "lead",
            .insertSubtrees(
                payload: try payload("image", ["url": .string(Self.mediaURL("image")), "name": .string("a")])))
        XCTAssertTrue(YXMLString.fragment(doc).contains("name=\"a\""))
        XCTAssertNotNil(NativeBlockProjection.markdownShadow(doc))
    }

    /// A pasted pdf whose url the export would not spell (a percent-encoded
    /// host, review V2) is refused, as is the same url typed natively: a block
    /// without a shadow would make every save fail.
    func testAPdfUrlWithoutAShadowIsNeverWritten() throws {
        let capture = try XCTUnwrap(BlockNoteMediaCaptures.edits.first { $0.name == "pdfSetCaption" })
        let doc = try doc(capture.seed, clientID: 2)
        defer { doc.destroy() }
        let engine = DocumentEngine(doc: doc, surface: HeadlessSurface())
        defer { engine.detach() }
        let url = "https://%65xample.com/a.pdf"
        XCTAssertTrue(MediaBlock.isAuthoredURL(url), "the url check alone passes it")
        let props = (MediaBlock.schemas["pdf"] ?? []).map {
            (key: $0.key, value: $0.key == "url" ? .string(url) : $0.value)
        }
        let payload = try BlockNoteSubtreePayload.encode([
            .element("blockContainer", [("id", .string("pasted"))], [.element("pdf", props, [])])
        ])
        XCTAssertFalse(engine.canApplyStructural(command(engine, "lead", .insertSubtrees(payload: payload))))
        XCTAssertFalse(engine.canApplyStructural(command(engine, "mx", .mediaProps([string("url", url)]))))
        XCTAssertNotNil(NativeBlockProjection.markdownShadow(doc))
    }

    /// A web image whose url is an IRI (a non-ASCII path or host, stored
    /// verbatim on the web) cuts and pastes back: the paste stores it
    /// percent-encoded and punycoded (review V3); whitespace, userinfo and
    /// other schemes stay refused.
    func testAWebImageWithAnIRIPastesBackCanonicalised() throws {
        let capture = try XCTUnwrap(BlockNoteMediaCaptures.edits.first { $0.name == "imageSetCaption" })
        let doc = try doc(capture.seed, clientID: 2)
        defer { doc.destroy() }
        let engine = DocumentEngine(doc: doc, surface: HeadlessSurface())
        defer { engine.detach() }
        func payload(_ url: String) throws -> Data {
            let props = (MediaBlock.schemas["image"] ?? []).map {
                (key: $0.key, value: $0.key == "url" ? .string(url) : $0.value)
            }
            return try BlockNoteSubtreePayload.encode([
                .element("blockContainer", [("id", .string("pasted"))], [.element("image", props, [])])
            ])
        }
        try apply(engine, "lead", .insertSubtrees(payload: try payload("https://images.example/été.png")))
        try apply(engine, "lead", .insertSubtrees(payload: try payload("https://exämple.com/a.png")))
        let xml = YXMLString.fragment(doc)
        XCTAssertTrue(xml.contains("url=\"https://images.example/%C3%A9t%C3%A9.png\""), xml)
        XCTAssertTrue(xml.contains("url=\"https://xn--exmple-cua.com/a.png\""), xml)
        XCTAssertNotNil(NativeBlockProjection.markdownShadow(doc))
        for url in ["https://images.example/a b.png", "https://user@evil.example/a.png", "javascript:alert(1)"] {
            XCTAssertFalse(
                engine.canApplyStructural(command(engine, "lead", .insertSubtrees(payload: try payload(url)))), url)
        }
    }

    /// Only RFC 3986 characters are stored (review S5): Foundation's parser
    /// must not be the one deciding what a raw string means, so non-ASCII,
    /// quotes, angle brackets, spaces and a bare `%` are refused before it.
    func testAuthoredURLsAreRFC3986() {
        for url in [
            "https://exämple.com/a", "https://example.com/a\"b", "https://example.com/<a>", "https://example.com/a b",
            "https://example.com/%zz", "https://example.com/%", "https://example.com/é", "https://example.com/a{b}",
        ] {
            XCTAssertFalse(MediaBlock.isAuthoredURL(url), url)
        }
        for url in [
            "https://example.com/a%20b.png?x=1&y=(2)", "http://xn--exmple-cua.com/a", "https://h.example:8443/p",
        ] {
            XCTAssertTrue(MediaBlock.isAuthoredURL(url), url)
        }
    }

    /// A peer's upload in progress is shown and preserved: modeled (the
    /// document types), spelled as nothing (as the server exports it), and
    /// never a target of a native prop edit.
    func testAPeersUploadLoaderIsPreservedAndNeverEdited() throws {
        let fixture = try XCTUnwrap(BlockNoteMediaCaptures.fixtures.first { $0.name == "uploadLoader" })
        let doc = try doc(fixture.update)
        defer { doc.destroy() }
        let engine = DocumentEngine(doc: doc, surface: HeadlessSurface())
        defer { engine.detach() }
        XCTAssertFalse(engine.canApplyStructural(command(engine, "mx", .mediaProps([string("name", "mine.png")]))))
        XCTAssertFalse(
            engine.canApplyStructural(command(engine, "mx", .mediaProps([string("url", Self.mediaURL("image"))]))))
        let card = try XCTUnwrap(NativeBlockProjection.project(doc).blocks.first { $0.id == "mx" })
        XCTAssertEqual(card.preview, .file(node: "uploadLoader", name: "x.png", url: ""))
        XCTAssertEqual(NativeBlockProjection.markdownShadow(doc), "Before\n\nAfter\n")
    }

    /// An unknown prop on a media block (a newer web client's) is preserved by
    /// a native edit; the projection still models the block.
    func testAnUnknownPropSurvivesANativeEdit() throws {
        let capture = try XCTUnwrap(BlockNoteMediaCaptures.edits.first { $0.name == "imageSetCaption" })
        let doc = try doc(capture.seed, clientID: 2)
        defer { doc.destroy() }
        let writer = BlockNoteWriter(doc: doc)
        let group = try XCTUnwrap(
            doc.share[BlockNoteYjs.fragmentField].flatMap { writer.children($0).first }.flatMap { item -> YType? in
                if case .type(let type) = item.content { return type }
                return nil
            })
        let container = try XCTUnwrap(
            writer.children(group).compactMap { item -> YType? in
                guard case .type(let type) = item.content, BlockIndex.blockID(of: type) == "mx" else { return nil }
                return type
            }.first)
        let element = try XCTUnwrap(
            writer.children(container).first.flatMap { item -> YType? in
                if case .type(let type) = item.content { return type }
                return nil
            })
        try writer.transaction { tx in
            try YWrite.mapSet(tx, on: element, key: "futureProp", .any([.string("kept")]))
        }
        let engine = DocumentEngine(doc: doc, surface: HeadlessSurface())
        defer { engine.detach() }
        XCTAssertTrue(NativeBlockProjection.project(doc).isFullyModeled)
        try apply(engine, "mx", .mediaProps([string("caption", "New caption")]))
        XCTAssertTrue(YXMLString.fragment(doc).contains("futureProp=\"kept\""))
        XCTAssertTrue(YXMLString.fragment(doc).contains("caption=\"New caption\""))
    }

    /// A captioned image below the root has no confirmed export spelling: no
    /// shadow (the classic line would drop the caption), so the document stays
    /// read-only rather than saving a wrong shadow.
    func testANestedCaptionedImageHasNoShadow() throws {
        let fixture = try XCTUnwrap(BlockNoteMediaCaptures.fixtures.first { $0.name == "nestedImage" })
        let doc = try doc(fixture.update)
        defer { doc.destroy() }
        XCTAssertNotNil(NativeBlockProjection.markdownShadow(doc), "a plain nested image keeps the classic line")
        let writer = BlockNoteWriter(doc: doc)
        var stack: [YType] = doc.share[BlockNoteYjs.fragmentField].map { [$0] } ?? []
        var image: YType?
        while let type = stack.popLast(), image == nil {
            for item in writer.children(type) {
                guard case .type(let child) = item.content else { continue }
                if child.typeRef == .xmlElement(nodeName: "image") { image = child }
                stack.append(child)
            }
        }
        let element = try XCTUnwrap(image)
        try writer.transaction { tx in try YWrite.mapSet(tx, on: element, key: "caption", .any([.string("cap")])) }
        XCTAssertTrue(NativeBlockProjection.project(doc).isFullyModeled)
        XCTAssertNil(NativeBlockProjection.markdownShadow(doc))
    }

    /// A media block stays a root block without children (its shadow): Tab
    /// neither nests one nor nests a block under one, and a move never takes
    /// one below the root.
    func testMediaStaysARootBlock() throws {
        let capture = try XCTUnwrap(BlockNoteMediaCaptures.edits.first { $0.name == "imageSetCaption" })
        let doc = try doc(capture.seed, clientID: 2)
        defer { doc.destroy() }
        let engine = DocumentEngine(doc: doc, surface: HeadlessSurface())
        defer { engine.detach() }
        XCTAssertFalse(engine.canApplyStructural(command(engine, "mx", .indent)), "a media block under a paragraph")
        XCTAssertFalse(engine.canApplyStructural(command(engine, "tail", .indent)), "a paragraph under a media block")
        XCTAssertTrue(engine.canApplyStructural(command(engine, "mx", .moveUp)), "moves among root blocks")
    }

    /// The real test document (`.review/state.bin`, git-ignored) when present:
    /// its media (image in a column, video, audio, file, pdf) are modeled now,
    /// but its interlink, inline math, math block and diagram keep it
    /// read-only (13c, PR14), its media preserved.
    func testTheRealCaptureMediaAreModeledAndTheDocumentStaysReadOnly() throws {
        let review = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".review")
        guard let state = try? Data(contentsOf: review.appendingPathComponent("state.bin")) else {
            throw XCTSkip("no .review capture")
        }
        let doc = YDoc(clientID: 9, gc: false)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(state))
        let native = NativeBlockProjection.project(doc)
        for node in ["video", "audio", "file", "pdf"] {
            let block = try XCTUnwrap(native.blocks.first { $0.block.node == node }, node)
            XCTAssertEqual(block.block.fidelity, .modeled, node)
        }
        XCTAssertEqual(native.blocks.first { $0.block.node == "columnList" }?.block.fidelity, .modeled)
        XCTAssertFalse(native.isFullyModeled)
        XCTAssertNil(NativeBlockProjection.markdownShadow(doc))
    }
}
