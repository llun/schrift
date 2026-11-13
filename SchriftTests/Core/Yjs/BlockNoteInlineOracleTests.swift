import Foundation
import XCTest

@testable import Schrift

final class BlockNoteInlineOracleTests: XCTestCase {
    private static let testOrigin = "https://docs.example"

    func testAllInlineCapturesAreModeledAndMatchYProviderShadow() throws {
        let mentionOnlyShadow = Set([
            "interlinkDisabled",
            "interlinkEmptyDocId",
            "mentionBasic",
            "mentionUnicode",
            "mentionEmptyName",
            "mentionOnlyBlock",
            "mentionSearchDisabledAt",
            "mentionSearchDisabledSlash",
            "mentionSearchActive",
            "chipAtEnd",
        ])

        for fixture in BlockNoteInlineCaptures.fixtures {
            let doc = try decodeDoc(fixture.update)
            defer { doc.destroy() }

            XCTAssertEqual(YXMLString.fragment(doc), fixture.xml, "\(fixture.name): xml")

            let native = NativeBlockProjection.project(doc)
            XCTAssertTrue(native.isFullyRenderable, "\(fixture.name): renderable")
            if fixture.name == "chipsInCallout" {
                XCTAssertEqual(native.blocks.first?.block.fidelity, .lossy(reasons: ["prop:emoji"]))
            } else {
                XCTAssertTrue(native.isFullyModeled, "\(fixture.name): modeled")
            }
            for snapshot in native.blocks {
                for run in snapshot.block.runs where run.inlineObject != nil {
                    XCTAssertEqual(run.text, "\u{FFFC}", "\(fixture.name): 1-unit placeholder")
                    XCTAssertTrue(run.marks.isEmpty, "\(fixture.name): inline object carries no marks")
                }
            }

            let shadow = try XCTUnwrap(
                NativeBlockProjection.markdownShadow(doc, interlinkingOrigin: Self.testOrigin),
                "\(fixture.name): expected shadow with origin")
            XCTAssertEqual(
                canonicalMarkdown(shadow), canonicalMarkdown(fixture.markdown),
                "\(fixture.name): canonical shadow mismatch")
            if !["mentionOnlyBlock", "chipsInLists", "chipsInColumns"].contains(fixture.name) {
                XCTAssertEqual(shadow, fixture.markdown, "\(fixture.name): exact shadow mismatch")
            }

            let slashOriginShadow = NativeBlockProjection.markdownShadow(
                doc, interlinkingOrigin: Self.testOrigin + "/")
            XCTAssertEqual(slashOriginShadow, shadow, "\(fixture.name): trailing slash trimmed")

            let nilOriginShadow = NativeBlockProjection.markdownShadow(doc, interlinkingOrigin: nil)
            let emptyOriginShadow = NativeBlockProjection.markdownShadow(doc, interlinkingOrigin: "")
            let slashOnlyOriginShadow = NativeBlockProjection.markdownShadow(doc, interlinkingOrigin: "/")
            if mentionOnlyShadow.contains(fixture.name) {
                XCTAssertEqual(nilOriginShadow, shadow, "\(fixture.name): nil origin allowed without active interlink")
                XCTAssertEqual(emptyOriginShadow, shadow, "\(fixture.name): empty origin allowed")
                XCTAssertEqual(slashOnlyOriginShadow, shadow, "\(fixture.name): slash-only origin allowed")
            } else {
                XCTAssertNil(nilOriginShadow, "\(fixture.name): active interlink fails closed without origin")
                XCTAssertNil(emptyOriginShadow, "\(fixture.name): active interlink fails closed on empty origin")
                XCTAssertNil(slashOnlyOriginShadow, "\(fixture.name): active interlink fails closed on '/' origin")
            }
        }
    }

    func testClassicYBlockProjectionRemainsUnchanged() throws {
        let stillOpaqueNames = [
            "interlinkDisabled",
            "interlinkEmptyDocId",
            "interlinkComplexDocId",
            "mentionBasic",
            "mentionSearchActive",
        ]
        for name in stillOpaqueNames {
            let fixture = try XCTUnwrap(BlockNoteInlineCaptures.fixtures.first { $0.name == name })
            let doc = try decodeDoc(fixture.update)
            defer { doc.destroy() }
            let classic = YBlockProjection.project(doc, interlinkingOrigin: Self.testOrigin)
            XCTAssertFalse(classic.isFullyRenderable, "\(name): classic projection must stay opaque")
            XCTAssertNil(YBlockProjection.projectedMarkdown(classic), "\(name): classic markdown must stay nil")
        }

        let titled = try XCTUnwrap(BlockNoteInlineCaptures.fixtures.first { $0.name == "interlinkWithTitle" })
        let doc = try decodeDoc(titled.update)
        defer { doc.destroy() }
        XCTAssertFalse(
            YBlockProjection.project(doc, interlinkingOrigin: nil).isFullyRenderable,
            "classic projection refuses interlink without origin")

        let classic = YBlockProjection.project(doc, interlinkingOrigin: Self.testOrigin)
        XCTAssertTrue(classic.isFullyRenderable)
        XCTAssertNil(classic.blocks[1].runs[1].inlineObject, "classic projection does not emit inlineObject runs")
        XCTAssertEqual(classic.blocks[1].runs[1].text, "Roadmap")
    }

    func testTablesWithInlineObjectsReadAsFamiliarAndNonSimple() throws {
        for name in ["chipsInTable", "tablePipeInTitle"] {
            let fixture = try XCTUnwrap(BlockNoteInlineCaptures.fixtures.first { $0.name == name })
            let doc = try decodeDoc(fixture.update)
            defer { doc.destroy() }
            let grid = try XCTUnwrap(TableGrid.tables(in: doc)["tbl"])
            XCTAssertEqual(grid.familiarity, .familiar, name)
            XCTAssertFalse(grid.rows[0][0].paragraphs[0].isSimpleText, "\(name): interlink cell")
            XCTAssertFalse(grid.rows[0][1].paragraphs[0].isSimpleText, "\(name): single mention cell")
            XCTAssertNil(
                NativeExportMarkdown.table(grid, interlinkingOrigin: nil),
                "\(name): table with active interlink fails closed without origin")
        }
    }

    func testInvalidAndUnsupportedInlineShapesFailClosed() throws {
        // Code block containing an inline object is opaque with no shadow.
        do {
            let doc = YDoc(clientID: 1, gc: true)
            defer { doc.destroy() }
            try populateBlock(doc, node: "codeBlock", props: ["language": .string("swift")]) { element, tx in
                let mention = YType(typeRef: .xmlElement(nodeName: "userMentionInline"))
                try YWrite.insertAfter(tx, into: element, after: nil, [.type(mention)])
            }
            let projected = NativeBlockProjection.project(doc)
            XCTAssertEqual(projected.blocks.first?.block.fidelity, .opaque(reason: "marked code"))
            XCTAssertNil(NativeBlockProjection.markdownShadow(doc, interlinkingOrigin: Self.testOrigin))
        }

        // Inline leaf element with child content is opaque with no shadow.
        do {
            let doc = YDoc(clientID: 1, gc: true)
            defer { doc.destroy() }
            try populateBlock(doc, node: "paragraph") { element, tx in
                let interlink = YType(typeRef: .xmlElement(nodeName: "interlinkingLinkInline"))
                try YWrite.insertAfter(tx, into: element, after: nil, [.type(interlink)])
                try YWrite.mapSet(
                    tx, on: interlink, key: "docId", .any([.string("11111111-1111-4111-8111-111111111111")]))
                try YWrite.mapSet(tx, on: interlink, key: "disabled", .any([.bool(false)]))
                let illegalChild = YType(typeRef: .xmlText)
                try YWrite.insertAfter(tx, into: interlink, after: nil, [.type(illegalChild)])
            }
            XCTAssertTrue(NativeBlockProjection.project(doc).blocks[0].block.fidelity.isOpaque)
            XCTAssertNil(NativeBlockProjection.markdownShadow(doc, interlinkingOrigin: Self.testOrigin))
        }

        // Wrong schema scalar types reject familiarity.
        do {
            let badProps: [(String, String, YAnyValue)] = [
                ("interlinkingLinkInline", "docId", .int(42)),
                ("interlinkingLinkInline", "disabled", .string("false")),
                ("userMentionInline", "userId", .bool(true)),
                ("userMentionInline", "fullName", .int(7)),
                ("mentionSearchInline", "disabled", .int(0)),
                ("mentionSearchInline", "trigger", .int(1)),
            ]
            for (node, key, value) in badProps {
                let doc = YDoc(clientID: 1, gc: true)
                defer { doc.destroy() }
                try populateBlock(doc, node: "paragraph") { element, tx in
                    let chip = YType(typeRef: .xmlElement(nodeName: node))
                    try YWrite.insertAfter(tx, into: element, after: nil, [.type(chip)])
                    try YWrite.mapSet(tx, on: chip, key: key, .any([value]))
                }
                XCTAssertTrue(NativeBlockProjection.project(doc).blocks[0].block.fidelity.isOpaque, "\(node).\(key)")
                XCTAssertNil(NativeBlockProjection.markdownShadow(doc, interlinkingOrigin: Self.testOrigin))
            }
        }

        // Unknown inline node (`math`) remains opaque until PR14.
        do {
            let doc = YDoc(clientID: 1, gc: true)
            defer { doc.destroy() }
            try populateBlock(doc, node: "paragraph") { element, tx in
                let math = YType(typeRef: .xmlElement(nodeName: "math"))
                try YWrite.insertAfter(tx, into: element, after: nil, [.type(math)])
            }
            XCTAssertEqual(
                NativeBlockProjection.project(doc).blocks[0].block.fidelity, .opaque(reason: "non-text inline content"))
            XCTAssertNil(NativeBlockProjection.markdownShadow(doc, interlinkingOrigin: Self.testOrigin))
        }

        // Unknown extra attributes are ignored during projection and preserved in Yjs.
        do {
            let doc = YDoc(clientID: 1, gc: true)
            defer { doc.destroy() }
            try populateBlock(doc, node: "paragraph") { element, tx in
                let mention = YType(typeRef: .xmlElement(nodeName: "userMentionInline"))
                try YWrite.insertAfter(tx, into: element, after: nil, [.type(mention)])
                try YWrite.mapSet(tx, on: mention, key: "userId", .any([.string("u-1")]))
                try YWrite.mapSet(tx, on: mention, key: "fullName", .any([.string("Ada")]))
                try YWrite.mapSet(tx, on: mention, key: "extraTag", .any([.string("keep-me")]))
            }
            let projected = NativeBlockProjection.project(doc)
            XCTAssertTrue(projected.isFullyModeled)
            XCTAssertEqual(projected.blocks[0].block.runs.first?.inlineObject, .mention(userID: "u-1", fullName: "Ada"))
            XCTAssertTrue(YXMLString.fragment(doc).contains(#"extraTag="keep-me""#))
        }
    }

    func testEncodeURIComponentVisibleTextAndURLParser() {
        XCTAssertEqual(
            NativeInlineObject.encodeURIComponent("AZaz09-_.!~*'()"), "AZaz09-_.!~*'()")
        XCTAssertEqual(
            NativeInlineObject.encodeURIComponent("doc a/b?c#d café"), "doc%20a%2Fb%3Fc%23d%20caf%C3%A9")
        XCTAssertNil(NativeInlineObject.encodeURIComponent(utf16: [0xD800]))
        XCTAssertNil(NativeInlineObject.encodeURIComponent(utf16: [0xDC00]))
        XCTAssertEqual(NativeInlineObject.encodeURIComponent(utf16: [0xD83D, 0xDE80]), "%F0%9F%9A%80")

        let titled = NativeInlineObject.interlink(
            docID: "11111111-1111-4111-8111-111111111111", blockID: nil, title: "Spec", disabled: false, trigger: "/")
        XCTAssertEqual(titled.visibleText, "Spec")

        let untitled = NativeInlineObject.interlink(
            docID: "11111111-1111-4111-8111-111111111111", blockID: nil, title: nil, disabled: false, trigger: "/")
        XCTAssertEqual(untitled.visibleText, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(untitled.visibleText { _ in "Cached Title" }, "Cached Title")

        let disabledUntitled = NativeInlineObject.interlink(
            docID: "11111111-1111-4111-8111-111111111111", blockID: nil, title: "", disabled: true, trigger: "/")
        XCTAssertEqual(
            disabledUntitled.visibleText { _ in "Should Not Resolve" }, "11111111-1111-4111-8111-111111111111")

        XCTAssertEqual(NativeInlineObject.mention(userID: "u-1", fullName: "Ada").visibleText, "@Ada")
        XCTAssertEqual(NativeInlineObject.mention(userID: "u-1", fullName: "").visibleText, "@u-1")
        XCTAssertEqual(NativeInlineObject.mention(userID: "", fullName: "").visibleText, "@?")
        XCTAssertEqual(NativeInlineObject.mentionSearch(disabled: true, trigger: "/").visibleText, "/")
        XCTAssertEqual(NativeInlineObject.mentionSearch(disabled: true, trigger: "").visibleText, "@")

        XCTAssertEqual(
            NativeInlineObject.interlink(
                fromURLString: "https://DOCS.EXAMPLE/docs/11111111-1111-4111-8111-111111111111/#sec-1",
                serverOrigin: "https://docs.example/"),
            .interlink(
                docID: "11111111-1111-4111-8111-111111111111", blockID: "sec-1", title: nil, disabled: false,
                trigger: "/"))
        XCTAssertNil(
            NativeInlineObject.interlink(
                fromURLString: "https://other.example/docs/11111111-1111-4111-8111-111111111111/",
                serverOrigin: "https://docs.example"))
        XCTAssertNil(
            NativeInlineObject.interlink(
                fromURLString: "https://user:pass@docs.example/docs/11111111-1111-4111-8111-111111111111/",
                serverOrigin: "https://docs.example"))
        XCTAssertNil(
            NativeInlineObject.interlink(
                fromURLString: "https://docs.example/docs/11111111-1111-4111-8111-111111111111/?x=1",
                serverOrigin: "https://docs.example"))
        XCTAssertNil(
            NativeInlineObject.interlink(
                fromURLString: "https://docs.example/docs/not-a-uuid/",
                serverOrigin: "https://docs.example"))
        XCTAssertNil(
            NativeInlineObject.interlink(
                fromURLString:
                    "https://docs.example/docs/11111111-1111-4111-8111-111111111111/#"
                    + String(repeating: "a", count: 257),
                serverOrigin: "https://docs.example"))
    }

    @MainActor
    func testInterlinkingOriginThreadingThroughSessionsAndSaveAdapter() async throws {
        let interlink = try XCTUnwrap(BlockNoteInlineCaptures.fixtures.first { $0.name == "interlinkBasic" })
        let mention = try XCTUnwrap(BlockNoteInlineCaptures.fixtures.first { $0.name == "mentionBasic" })
        let interlinkData = try XCTUnwrap(Data(base64Encoded: interlink.update))
        let mentionData = try XCTUnwrap(Data(base64Encoded: mention.update))

        let inspectedNoOrigin = try await NativeEditorSession.inspect(state: interlinkData, interlinkingOrigin: nil)
        XCTAssertFalse(inspectedNoOrigin.canType, "inspect without origin keeps active interlink read-only")
        await inspectedNoOrigin.close().value

        let inspectedWithOrigin = try await NativeEditorSession.inspect(
            state: interlinkData, interlinkingOrigin: Self.testOrigin)
        XCTAssertTrue(inspectedWithOrigin.canType, "inspect with origin allows typing")
        await inspectedWithOrigin.close().value

        let seededNoOrigin = try await NativeEditorSession.seed(
            state: interlinkData, clientID: 2, interlinkingOrigin: nil)
        XCTAssertFalse(seededNoOrigin.canType)
        await seededNoOrigin.close().value

        let seededWithOrigin = try await NativeEditorSession.seed(
            state: interlinkData, clientID: 2, interlinkingOrigin: Self.testOrigin)
        XCTAssertTrue(seededWithOrigin.canType)
        await seededWithOrigin.close().value

        let mentionNoOrigin = try await NativeEditorSession.inspect(state: mentionData, interlinkingOrigin: nil)
        XCTAssertTrue(mentionNoOrigin.canType, "mention-only document needs no interlinkingOrigin")
        await mentionNoOrigin.close().value

        // Owned save adapter derives interlinkingOrigin from scope.serverOrigin.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReplicaStore(directory: directory)
        let scope = ReplicaScope(
            serverOrigin: Self.testOrigin, ownerUserID: UUID(), org: "org-1", documentID: UUID())
        let manifest = try store.create(for: scope, checkpoint: interlinkData)
        let adapter = ReplicaSaveAdapter(store: store, scope: scope)
        let prepared = try adapter.prepare()
        XCTAssertEqual(prepared.request.reference.generation, manifest.generation)
        XCTAssertEqual(prepared.markdown, interlink.markdown)
    }

    @MainActor
    func testCapturedStateBinIsModeledWhenPresent() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let stateURL = root.appendingPathComponent(".review/state.bin")
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            throw XCTSkip("optional .review/state.bin capture not present")
        }
        let data = try Data(contentsOf: stateURL)
        let doc = YDoc(clientID: 1, gc: true)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(data), origin: .remote)
        let projected = NativeBlockProjection.project(doc)
        let interlinkBlocks = projected.blocks.filter { snapshot in
            snapshot.block.runs.contains { run in
                if case .interlink? = run.inlineObject { return true }
                return false
            }
        }
        XCTAssertFalse(interlinkBlocks.isEmpty, "state.bin must contain at least one interlink block")
        for snapshot in interlinkBlocks {
            XCTAssertEqual(snapshot.block.fidelity, .modeled, "\(snapshot.id): interlink block must be modeled")
        }
        XCTAssertFalse(projected.isFullyModeled, "math/diagram blocks stay opaque until PR14")
        XCTAssertNil(NativeBlockProjection.markdownShadow(doc, interlinkingOrigin: Self.testOrigin))

        let inspected = try await NativeEditorSession.inspect(state: data, interlinkingOrigin: Self.testOrigin)
        XCTAssertFalse(inspected.canType, "whole document with opaque math/diagram stays canType == false")
        await inspected.close().value
    }

    // MARK: - Step 3: BlockNoteWriter coalescing, DocumentEngine, Selection & Awareness

    func testAllWebInlineEditsMatchXMLAndShadowWhenPerformedNatively() throws {
        var covered: Set<String> = []
        let interlink = NativeInlineObject.interlink(
            docID: "11111111-1111-4111-8111-111111111111", blockID: nil, title: nil, disabled: false, trigger: "/")

        func runEdit(
            _ name: String, allowCanonicalMarkdownFallback: Bool = false,
            perform: (DocumentEngine, HeadlessSurface) throws -> Void
        ) throws {
            let capture = try XCTUnwrap(BlockNoteInlineCaptures.edits.first { $0.name == name }, "missing \(name)")
            covered.insert(name)
            let doc = try decodeDoc(capture.seed)
            defer { doc.destroy() }
            let surface = HeadlessSurface()
            let engine = DocumentEngine(doc: doc, surface: surface)
            defer { engine.detach() }

            do {
                try perform(engine, surface)
            } catch {
                XCTFail("\(name): failed with \(error)")
                return
            }

            XCTAssertEqual(YXMLString.fragment(doc), capture.xml, "\(name): xml mismatch")
            let shadow = try XCTUnwrap(
                NativeBlockProjection.markdownShadow(doc, interlinkingOrigin: Self.testOrigin),
                "\(name): expected shadow")
            if allowCanonicalMarkdownFallback {
                XCTAssertEqual(
                    syncCanonicalMarkdown(shadow), syncCanonicalMarkdown(capture.markdown),
                    "\(name): syncCanonicalMarkdown mismatch")
            } else if shadow != capture.markdown {
                XCTAssertEqual(
                    syncCanonicalMarkdown(shadow), syncCanonicalMarkdown(capture.markdown),
                    "\(name): syncCanonicalMarkdown mismatch")
            }
        }

        func replace(
            _ engine: DocumentEngine, _ blockID: String, _ range: Range<Int>, _ text: String, marks: [TextMark]? = nil
        )
            throws
        {
            let cmd = NativeEditCommand(
                id: UUID(), baseRevision: engine.revision, blockID: blockID, range: range, replacement: text,
                marks: marks)
            try engine.replaceText(cmd) { _ in }
        }

        func apply(_ engine: DocumentEngine, _ blockID: String, _ kind: NativeEditCommand.Kind) throws -> EditorPosition
        {
            let cmd = NativeEditCommand(id: UUID(), baseRevision: engine.revision, blockID: blockID, kind: kind)
            return try engine.applyStructural(cmd) { _ in }
        }

        try runEdit("typeBeforeChipAtStart") { engine, _ in
            try replace(engine, "p", 0..<0, "hi ")
            XCTAssertEqual(engine.nativeSnapshot(for: "p")?.runs.first?.text, "hi ")
        }
        try runEdit("typeAfterChipAtEnd") { engine, _ in
            try replace(engine, "p", 1..<1, " end")
        }
        try runEdit("typeLeftOfMiddleChip") { engine, _ in
            try replace(engine, "p", 2..<2, "X")
        }
        try runEdit("typeRightOfMiddleChip") { engine, _ in
            try replace(engine, "p", 3..<3, "Y")
        }
        try runEdit("typeBetweenAdjacentChips") { engine, _ in
            try replace(engine, "p", 1..<1, "mid")
        }
        try runEdit("typeAfterChipDoesNotInheritBold") { engine, _ in
            try replace(engine, "p", 5..<5, "tail", marks: [])
        }
        try runEdit("deleteMiddleChip") { engine, _ in
            try replace(engine, "p", 7..<8, "")
        }
        try runEdit("deleteMiddleChipMarked") { engine, _ in
            try replace(engine, "p", 4..<5, "")
        }
        try runEdit("deleteLeadAndChip") { engine, _ in
            try replace(engine, "p", 0..<4, "")
        }
        try runEdit("deleteChipAndTail") { engine, _ in
            try replace(engine, "p", 3..<7, "")
        }
        try runEdit("deleteOnlyChip", allowCanonicalMarkdownFallback: true) { engine, _ in
            try replace(engine, "p", 0..<1, "")
        }
        try runEdit("deleteTextBetweenTwoChips", allowCanonicalMarkdownFallback: true) { engine, _ in
            try replace(engine, "p", 1..<2, "")
        }
        try runEdit("deleteFirstOfTwoChips") { engine, _ in
            try replace(engine, "p", 0..<1, "")
        }
        try runEdit("deleteZombieSearch") { engine, _ in
            try replace(engine, "p", 3..<4, "")
        }
        try runEdit("replaceAcrossChip") { engine, _ in
            try replace(engine, "p", 1..<4, "X")
        }
        try runEdit("boldAcrossChip") { engine, _ in
            _ = try apply(
                engine, "p",
                .marks(
                    NativeMarkCommand(
                        startOffset: 0, endBlockID: "p", endOffset: 14,
                        attributes: [TextMark(key: "bold", valueJSON: "{}")])))
        }
        try runEdit("linkAcrossChip") { engine, _ in
            _ = try apply(
                engine, "p",
                .marks(
                    NativeMarkCommand(
                        startOffset: 0, endBlockID: "p", endOffset: 14,
                        attributes: [TextMark(key: "link", valueJSON: #"{"href":"https://example.com"}"#)])))
        }
        try runEdit("clearBoldAcrossChip") { engine, _ in
            _ = try apply(
                engine, "p",
                .marks(
                    NativeMarkCommand(
                        startOffset: 0, endBlockID: "p", endOffset: 14,
                        attributes: [TextMark(key: "bold", valueJSON: "null")])))
        }
        try runEdit("splitBeforeChip") { engine, _ in
            let caret = try apply(engine, "p", .split(offset: 7, newID: "1", open: []))
            XCTAssertEqual(caret, EditorPosition(blockID: "1", offset: 0, assoc: -1))
        }
        try runEdit("splitAfterChip") { engine, _ in
            let caret = try apply(engine, "p", .split(offset: 8, newID: "1", open: []))
            XCTAssertEqual(caret, EditorPosition(blockID: "1", offset: 0, assoc: -1))
        }
        try runEdit("splitBetweenChips", allowCanonicalMarkdownFallback: true) { engine, _ in
            let caret = try apply(engine, "p", .split(offset: 1, newID: "1", open: []))
            XCTAssertEqual(caret, EditorPosition(blockID: "1", offset: 0, assoc: -1))
        }
        try runEdit("joinParagraphWithChipIntoChipParagraph") { engine, _ in
            let caret = try apply(engine, "p2", .join)
            XCTAssertEqual(caret, EditorPosition(blockID: "p1", offset: 3, assoc: -1))
        }
        try runEdit("turnChipParagraphIntoHeading") { engine, _ in
            _ = try apply(
                engine, "p",
                .blockType(
                    node: "heading", props: [ProjectedProp(key: "level", value: .int(2))], removing: 0..<0))
        }
        try runEdit("sinkBulletWithChip") { engine, _ in
            _ = try apply(engine, "b2", .indent)
        }
        try runEdit("liftBulletWithChip") { engine, _ in
            _ = try apply(engine, "b2", .outdent)
        }
        try runEdit("deleteChipInTableCell") { engine, _ in
            XCTAssertTrue(engine.openTable("tbl"))
            let cells = try XCTUnwrap(engine.tableParagraphs("tbl"))
            XCTAssertGreaterThan(cells.count, 0)
            try replace(engine, cells[0].id, 2..<3, "")
        }
        try runEdit("insertInterlinkInMiddle") { engine, _ in
            let caret = try apply(engine, "p", .insertInlineObject(interlink, replacing: 6..<6))
            XCTAssertEqual(caret, EditorPosition(blockID: "p", offset: 7, assoc: -1))
        }
        try runEdit("insertInterlinkAtStart") { engine, _ in
            let caret = try apply(engine, "p", .insertInlineObject(interlink, replacing: 0..<0))
            XCTAssertEqual(caret, EditorPosition(blockID: "p", offset: 1, assoc: -1))
        }
        try runEdit("insertInterlinkAtEnd") { engine, _ in
            let caret = try apply(engine, "p", .insertInlineObject(interlink, replacing: 6..<6))
            XCTAssertEqual(caret, EditorPosition(blockID: "p", offset: 7, assoc: -1))
        }
        try runEdit("insertInterlinkInEmptyParagraph") { engine, _ in
            let caret = try apply(engine, "p", .insertInlineObject(interlink, replacing: 0..<0))
            XCTAssertEqual(caret, EditorPosition(blockID: "p", offset: 1, assoc: -1))
        }
        try runEdit("insertInterlinkWithBlockId") { engine, _ in
            let withBlockID = NativeInlineObject.interlink(
                docID: "11111111-1111-4111-8111-111111111111", blockID: "sec-1", title: nil, disabled: false,
                trigger: "/")
            let caret = try apply(engine, "p", .insertInlineObject(withBlockID, replacing: 4..<4))
            XCTAssertEqual(caret, EditorPosition(blockID: "p", offset: 5, assoc: -1))
        }

        XCTAssertEqual(Set(BlockNoteInlineCaptures.edits.map(\.name)), covered, "every web edit must be covered")
    }

    func testSelectionAndPeerPlaceAtEveryChipBoundary() throws {
        // Adjacent chips: [mention, interlink] -> length 2; plus prefix/suffix on peers.
        let adjacent = try XCTUnwrap(BlockNoteInlineCaptures.fixtures.first { $0.name == "twoAdjacentChips" })
        let doc = try decodeDoc(adjacent.update)
        defer { doc.destroy() }
        let engine = DocumentEngine(doc: doc, surface: HeadlessSurface())
        defer { engine.detach() }

        for offset in 0...2 {
            let pos = EditorPosition(blockID: "p", offset: offset, assoc: offset == 1 ? -1 : 0)
            try engine.setSelection(EditorSelection(anchor: pos, head: pos))
            XCTAssertEqual(try engine.currentSelection()?.head.offset, offset)
            let relJSON = try XCTUnwrap(engine.awarenessPosition(pos))
            XCTAssertEqual(
                engine.peerPlace(relJSON), .text(EditorPosition(blockID: "p", offset: offset, assoc: pos.assoc)))
        }

        // Capture carets on both sides of the boundary between two chips, then peer inserts "mid".
        let beforeBoundary = EditorPosition(blockID: "p", offset: 1, assoc: -1)
        let afterBoundary = EditorPosition(blockID: "p", offset: 1, assoc: 0)
        let beforePeerJSON = try XCTUnwrap(engine.awarenessPosition(beforeBoundary))
        let afterPeerJSON = try XCTUnwrap(engine.awarenessPosition(afterBoundary))

        let edit = try XCTUnwrap(BlockNoteInlineCaptures.edits.first { $0.name == "typeBetweenAdjacentChips" })
        let peerDoc = try decodeDoc(edit.seed)
        defer { peerDoc.destroy() }
        // Replicate "mid" insert from a remote peer transaction.
        let midUpdate = try XCTUnwrap(Data(base64Encoded: edit.update))
        try engine.durablyIntegrateRemote(
            update: midUpdate,
            apply: { try doc.applyUpdate(YUpdateDecoder.decode(midUpdate), origin: .remote) },
            persist: { _ in })

        XCTAssertEqual(engine.peerPlace(beforePeerJSON), .text(EditorPosition(blockID: "p", offset: 1, assoc: -1)))
        XCTAssertEqual(engine.peerPlace(afterPeerJSON), .text(EditorPosition(blockID: "p", offset: 4, assoc: 0)))

        // Middle-chip XmlText boundary positions ("before " + chip + " after").
        for offset in 0...5 {
            let pos = EditorPosition(blockID: "p", offset: offset, assoc: -1)
            try engine.setSelection(EditorSelection(anchor: pos, head: pos))
            XCTAssertEqual(try engine.currentSelection()?.head, pos)
            let json = try XCTUnwrap(engine.awarenessPosition(pos))
            XCTAssertEqual(engine.peerPlace(json), .text(pos))
        }
    }

    func testPasteInlineRangeMoveDuplicateAndRefusals() throws {
        let doc = YDoc(clientID: 1, gc: true)
        defer { doc.destroy() }
        let interlink = NativeInlineObject.interlink(
            docID: "11111111-1111-4111-8111-111111111111", blockID: nil, title: nil, disabled: false, trigger: "/")
        let mention = NativeInlineObject.mention(userID: "user-1", fullName: "Ada")
        try populateBlock(doc, node: "paragraph") { element, tx in
            let t = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: element, after: nil, [.type(t)])
            try t.insert(0, "hello world", nil)
        }
        let codeDoc = YDoc(clientID: 2, gc: true)
        defer { codeDoc.destroy() }
        try populateBlock(codeDoc, node: "codeBlock", props: ["language": .string("swift")]) { element, tx in
            let t = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: element, after: nil, [.type(t)])
            try t.insert(0, "let x = 1", nil)
        }

        // Code block refuses insertInlineObject cleanly without mutating XML.
        let codeEngine = DocumentEngine(doc: codeDoc, surface: HeadlessSurface())
        defer { codeEngine.detach() }
        let codeBefore = YXMLString.fragment(codeDoc)
        let codeInsert = NativeEditCommand(
            id: UUID(), baseRevision: codeEngine.revision, blockID: "b1",
            kind: .insertInlineObject(interlink, replacing: 4..<4))
        XCTAssertFalse(codeEngine.canApplyStructural(codeInsert))
        do {
            _ = try codeEngine.applyStructural(codeInsert) { _ in }
            XCTFail("codeBlock must refuse insertInlineObject")
        } catch DocumentEngineError.unsupportedNativeInput {
        }
        XCTAssertEqual(YXMLString.fragment(codeDoc), codeBefore)

        // pasteInline into codeBlock degrades chips to plain text.
        let slicePayload = try BlockNoteInlinePayload.encode([
            [
                .text([.run(InlineRun("hi "))]),
                .element(
                    "userMentionInline", [("userId", .string("u1")), ("fullName", .string("Ada"))], []),
                .text([.run(InlineRun(" "))]),
                .element(
                    "interlinkingLinkInline",
                    [
                        ("docId", .string("11111111-1111-4111-8111-111111111111")),
                        ("blockId", .string("")),
                        ("disabled", .bool(false)),
                        ("trigger", .string("/")),
                    ], []),
            ]
        ])
        let pasteCode = NativeEditCommand(
            id: UUID(), baseRevision: codeEngine.revision, blockID: "b1",
            kind: .pasteInline(
                payload: slicePayload,
                range: NativeRangeCommand(
                    startOffset: 9, endBlockID: "b1", endOffset: 9, replacement: "", newBlockIDs: [])))
        let codeCaret = try codeEngine.applyStructural(pasteCode) { _ in }
        XCTAssertEqual(
            codeCaret,
            EditorPosition(
                blockID: "b1", offset: 9 + "hi @Ada 11111111-1111-4111-8111-111111111111".utf16.count, assoc: -1))
        XCTAssertEqual(
            codeEngine.nativeSnapshot(for: "b1")?.runs.first?.text,
            "let x = 1hi @Ada 11111111-1111-4111-8111-111111111111")

        // Malformed inline props refuse edits and keep block non-projectable.
        let badDoc = YDoc(clientID: 3, gc: true)
        defer { badDoc.destroy() }
        try populateBlock(badDoc, node: "paragraph") { element, tx in
            let chip = YType(typeRef: .xmlElement(nodeName: "interlinkingLinkInline"))
            try YWrite.insertAfter(tx, into: element, after: nil, [.type(chip)])
            try YWrite.mapSet(tx, on: chip, key: "docId", .any([.string("11111111-1111-4111-8111-111111111111")]))
            try YWrite.mapSet(tx, on: chip, key: "disabled", .any([.int(1)]))
        }
        let badEngine = DocumentEngine(doc: badDoc, surface: HeadlessSurface())
        defer { badEngine.detach() }
        XCTAssertTrue(badEngine.nativeSnapshot(for: "b1")?.isOpaque == true)
        XCTAssertFalse(
            badEngine.canApplyStructural(
                NativeEditCommand(
                    id: UUID(), baseRevision: badEngine.revision, blockID: "b1",
                    kind: .insertInlineObject(mention, replacing: 0..<0))))

        // Paste inline slice + duplicate + moveDown + cross-block range on chip paragraphs.
        let engine = DocumentEngine(doc: doc, surface: HeadlessSurface())
        defer { engine.detach() }
        let pasteCaret = try engine.applyStructural(
            NativeEditCommand(
                id: UUID(), baseRevision: engine.revision, blockID: "b1",
                kind: .pasteInline(
                    payload: slicePayload,
                    range: NativeRangeCommand(
                        startOffset: 6, endBlockID: "b1", endOffset: 11, replacement: "", newBlockIDs: [])))
        ) { _ in }
        XCTAssertEqual(pasteCaret, EditorPosition(blockID: "b1", offset: 12, assoc: -1))
        XCTAssertTrue(engine.nativeSnapshot(for: "b1")?.runs.contains { $0.inlineObject != nil } == true)

        let dupCaret = try engine.applyStructural(
            NativeEditCommand(
                id: UUID(), baseRevision: engine.revision, blockID: "b1", kind: .duplicate(newIDs: ["b2"]))
        ) { _ in }
        XCTAssertEqual(dupCaret.blockID, "b1")
        _ = try engine.applyStructural(
            NativeEditCommand(id: UUID(), baseRevision: engine.revision, blockID: "b1", kind: .moveDown)
        ) { _ in }
        let mergedCaret = try engine.applyStructural(
            NativeEditCommand(
                id: UUID(), baseRevision: engine.revision, blockID: "b2",
                kind: .range(
                    NativeRangeCommand(
                        startOffset: 3, endBlockID: "b1", endOffset: 6, replacement: "!", newBlockIDs: [])))
        ) { _ in }
        XCTAssertEqual(mergedCaret, EditorPosition(blockID: "b2", offset: 4, assoc: -1))
    }

    func testCollaborativeUndoRedoWithChipEditsAndPeerUpdates() throws {
        let seed = try XCTUnwrap(BlockNoteInlineCaptures.edits.first { $0.name == "typeLeftOfMiddleChip" })
        let localDoc = try decodeDoc(seed.seed)
        defer { localDoc.destroy() }
        localDoc.clientID = 10

        let engine = DocumentEngine(doc: localDoc, surface: HeadlessSurface())
        defer { engine.detach() }
        let history = ReplicaHistory(doc: localDoc, engine: engine)
        defer { history.destroy() }

        let beforeXML = YXMLString.fragment(localDoc)
        try engine.setSelection(
            EditorSelection(
                anchor: EditorPosition(blockID: "p", offset: 2, assoc: -1),
                head: EditorPosition(blockID: "p", offset: 2, assoc: -1)))
        let delCmd = NativeEditCommand(
            id: UUID(), baseRevision: engine.revision, blockID: "p", range: 2..<3, replacement: "")
        try engine.replaceText(delCmd) { _ in }
        history.stopCapturing()

        // Peer concurrently edits at the start of the coalesced paragraph.
        let peerDoc = YDoc(clientID: 20, gc: true)
        defer { peerDoc.destroy() }
        let seedBytes = try XCTUnwrap(Data(base64Encoded: seed.seed))
        try peerDoc.applyUpdate(YUpdateDecoder.decode(seedBytes), origin: .remote)
        let peerWriter = BlockNoteWriter(doc: peerDoc)
        let peerUpdate = try peerWriter.replaceText(block: "p", range: NSRange(location: 0, length: 0), with: "hi ")
        try engine.durablyIntegrateRemote(
            update: peerUpdate,
            apply: { try localDoc.applyUpdate(YUpdateDecoder.decode(peerUpdate), origin: .remote) },
            persist: { _ in })

        XCTAssertTrue(history.canUndo)
        let undone = try engine.applyHistoryStep(
            NativeEditCommand(id: UUID(), baseRevision: engine.revision, blockID: "", kind: .undo),
            step: { try history.step(undo: true) },
            persist: { _ in })
        XCTAssertTrue(undone)
        let afterUndoXML = YXMLString.fragment(localDoc)
        XCTAssertTrue(afterUndoXML.contains("hi ab<interlinkinglinkinline"), "undo restores chip and keeps peer edit")
        XCTAssertNotEqual(afterUndoXML, beforeXML)

        let redone = try engine.applyHistoryStep(
            NativeEditCommand(id: UUID(), baseRevision: engine.revision, blockID: "", kind: .redo),
            step: { try history.step(undo: false) },
            persist: { _ in })
        XCTAssertTrue(redone)
        XCTAssertEqual(
            YXMLString.fragment(localDoc),
            #"<blockgroup><blockcontainer id="p"><paragraph backgroundColor="default" textAlignment="left" textColor="default">hi abcd</paragraph></blockcontainer></blockgroup>"#
        )
    }

    // MARK: - Helpers

    private func decodeDoc(_ base64: String) throws -> YDoc {
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        let doc = YDoc(clientID: 1, gc: true)
        try doc.applyUpdate(YUpdateDecoder.decode(data), origin: .remote)
        return doc
    }

    private func populateBlock(
        _ doc: YDoc, node: String, props: [String: YAnyValue] = [:],
        content: (YType, YTransaction) throws -> Void
    ) throws {
        try doc.transact { tx in
            let root = doc.get(BlockNoteYjs.fragmentField)
            let group = YType(typeRef: .xmlElement(nodeName: "blockGroup"))
            let container = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            let element = YType(typeRef: .xmlElement(nodeName: node))
            try YWrite.insertAfter(tx, into: root, after: nil, [.type(group)])
            try YWrite.insertAfter(tx, into: group, after: nil, [.type(container)])
            try YWrite.mapSet(tx, on: container, key: "id", .any([.string("b1")]))
            try YWrite.insertAfter(tx, into: container, after: nil, [.type(element)])
            for (k, v) in props { try YWrite.mapSet(tx, on: element, key: k, .any([v])) }
            try content(element, tx)
        }
    }
}
