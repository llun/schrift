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

    func testCapturedStateBinIsModeledWhenPresent() throws {
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
        XCTAssertTrue(projected.isFullyModeled)
        XCTAssertNotNil(NativeBlockProjection.markdownShadow(doc, interlinkingOrigin: Self.testOrigin))
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
