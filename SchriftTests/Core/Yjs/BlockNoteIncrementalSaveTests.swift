import XCTest

@testable import Schrift

/// The Docs 6 save's core: the update `BlockNoteIncrementalSave` builds must make the
/// server's own state read exactly like the editor's markdown when the server applies it
/// incrementally — leaving untouched blocks alone and sending nothing at all when nothing
/// changed. Verified at the document level, by applying the update to a replica of the
/// served state and projecting it (see `AGENTS.md`, "The Yjs CRDT core").
final class BlockNoteIncrementalSaveTests: XCTestCase {
    private let origin = "https://docs.example.test"

    private var baseProps: [(key: String, value: YAnyValue)] {
        [
            ("backgroundColor", .string("default")), ("textColor", .string("default")),
            ("textAlignment", .string("left")),
        ]
    }

    private func paragraph(_ text: String, id: String) -> BlockNoteBlock {
        BlockNoteBlock(node: "paragraph", props: baseProps, runs: [InlineRun(text)], id: id)
    }

    /// A served document built by the golden encoder, so it is exactly what yjs would hold.
    private func served(_ blocks: [BlockNoteBlock]) -> Data {
        BlockNoteYjs.encode(blocks, clientID: 1)
    }

    private func newBlocks(_ markdown: String) -> [BlockNoteBlock] {
        MarkdownYjs.blockNoteBlocks(from: markdown, serverOrigin: origin)
    }

    /// The server's state after it applies `update`, projected.
    private func project(
        _ state: Data, after update: Data?, interlinkingOrigin: String? = nil
    ) throws -> ProjectedDocument {
        let doc = YDoc(clientID: 999)
        defer { doc.destroy() }
        if !state.isEmpty { try doc.applyUpdate(try YUpdateDecoder.decode(state)) }
        if let update { try doc.applyUpdate(try YUpdateDecoder.decode(update)) }
        return YBlockProjection.project(doc, interlinkingOrigin: interlinkingOrigin)
    }

    /// Content equality with the markdown the editor saved: node and runs, block by block.
    private func assertReads(
        _ document: ProjectedDocument, like markdown: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let expected = newBlocks(markdown)
        XCTAssertEqual(document.blocks.map(\.node), expected.map(\.node), "nodes", file: file, line: line)
        XCTAssertEqual(document.blocks.map(\.runs), expected.map(\.runs), "runs", file: file, line: line)
    }

    private let idA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let idB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private let idC = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

    func testAnUnchangedDocumentNeedsNoUpdate() throws {
        let state = served([paragraph("One", id: idA), paragraph("Two", id: idB)])

        let update = try BlockNoteIncrementalSave.update(
            serverState: state, newBlocks: newBlocks("One\n\nTwo"), serverOrigin: origin)

        XCTAssertNil(update)
    }

    func testAnUnchangedDocumentWithHistoricalTombstonesNeedsNoUpdate() throws {
        let doc = YDoc(clientID: 7)
        defer { doc.destroy() }
        let original = paragraph("hello", id: idA)
        let shortened = paragraph("ho", id: idA)
        _ = try BlockNoteWrite.applyEdit(old: [], new: [original], to: doc)
        _ = try BlockNoteWrite.applyEdit(old: [original], new: [shortened], to: doc)
        XCTAssertFalse(YDeleteSet.from(store: doc.store).isEmpty)
        let state = try YStateEncoder.encodeStateAsUpdate(doc)
        XCTAssertNil(
            try BlockNoteIncrementalSave.update(serverState: state, newBlocks: [shortened], serverOrigin: origin))
    }

    func testAnEditLandsInPlaceAndUntouchedBlocksKeepTheirIDs() throws {
        let state = served([paragraph("One", id: idA), paragraph("Two", id: idB), paragraph("Three", id: idC)])
        let markdown = "One\n\nTwo, edited\n\nThree\n\nFour"

        let update = try XCTUnwrap(
            BlockNoteIncrementalSave.update(serverState: state, newBlocks: newBlocks(markdown), serverOrigin: origin))
        let after = try project(state, after: update)

        assertReads(after, like: markdown)
        XCTAssertEqual(Array(after.blocks.map(\.id).prefix(3)), [idA, idB, idC], "reconciled, not rebuilt")
    }

    /// The server applies the update incrementally, so a deletion must arrive as a delete —
    /// re-sending the surviving blocks would duplicate them.
    func testADeletionRemovesOnlyThatBlock() throws {
        let state = served([paragraph("One", id: idA), paragraph("Two", id: idB), paragraph("Three", id: idC)])

        let update = try BlockNoteIncrementalSave.update(
            serverState: state, newBlocks: newBlocks("One\n\nThree"), serverOrigin: origin)
        let after = try project(state, after: update)

        assertReads(after, like: "One\n\nThree")
        XCTAssertEqual(after.blocks.map(\.id), [idA, idC])
    }

    func testAnEmptyServerDocumentReceivesTheWholeDocument() throws {
        let markdown = "# Title\n\nBody with **bold**"

        let update = try BlockNoteIncrementalSave.update(
            serverState: Data(), newBlocks: newBlocks(markdown), serverOrigin: origin)

        assertReads(try project(Data(), after: update), like: markdown)
    }

    /// A nested list is inserted as a nested `blockGroup` (the projection reads such a block
    /// as opaque "nested children" — which is exactly the evidence that the subtree is there).
    func testANestedListIsWrittenAsANestedGroup() throws {
        let state = served([paragraph("One", id: idA)])

        let update = try BlockNoteIncrementalSave.update(
            serverState: state, newBlocks: newBlocks("One\n\n- parent\n  - child"), serverOrigin: origin)
        let after = try project(state, after: update)

        XCTAssertEqual(after.blocks.count, 2)
        XCTAssertEqual(after.blocks[0].id, idA)
        XCTAssertEqual(after.blocks[1].fidelity, .opaque(reason: "nested children"))
    }

    /// A photo and a file nested under a checklist item go in as the item's nested group, the
    /// same way a nested list does.
    func testLeavesNestedUnderAListItemAreWrittenAsANestedGroup() throws {
        let state = served([paragraph("One", id: idA)])

        let update = try BlockNoteIncrementalSave.update(
            serverState: state, newBlocks: newBlocks("One\n\n" + nestedLeafMarkdown), serverOrigin: origin)
        let after = try project(state, after: update)

        XCTAssertEqual(after.blocks.count, 2)
        XCTAssertEqual(after.blocks[0].id, idA)
        XCTAssertEqual(after.blocks[1].fidelity, .opaque(reason: "nested children"))
    }

    /// The accepted residual without a recorded base: a list item with nested leaves projects
    /// opaque, so even an unchanged one is not anchored and is rebuilt on every save (resetting web-only media
    /// props such as an image's caption). The content still reads the same afterwards.
    func testAnUnchangedItemWithNestedLeavesIsRebuiltEachSave() throws {
        let stored = newBlocks(nestedLeafMarkdown)
        let state = served(stored)

        let update = try XCTUnwrap(
            BlockNoteIncrementalSave.update(
                serverState: state, newBlocks: newBlocks(nestedLeafMarkdown), serverOrigin: origin))
        let after = try project(state, after: update)

        XCTAssertEqual(after.blocks.count, 1)
        XCTAssertEqual(after.blocks[0].fidelity, .opaque(reason: "nested children"))
        XCTAssertNotEqual(after.blocks[0].id, stored[0].id, "rebuilt, not reconciled")
    }

    /// TestFlight 0.103.0: the user edits only the first paragraph while a co-author types in a
    /// nested bullet on the web. The save must leave that untouched list item where it is.
    /// Rebuilding it (delete + re-insert, the old behaviour) dropped the co-author's keystroke
    /// that landed between the save's GET and its PATCH ("Another bullet poin"), and a second
    /// rebuild of the same item from the same state left both copies.
    func testAnUntouchedNestedListItemIsLeftInPlaceForACoAuthorTypingInIt() throws {
        let base = "Intro\n\n- Bullet\n  - Another bullet poin\n\nEnd"
        let stored = newBlocks(base)
        let state = BlockNoteYjs.encode(stored, clientID: 1)

        // The save is computed from the GET...
        let update = try BlockNoteIncrementalSave.update(
            serverState: state, newBlocks: newBlocks("TEST\n\n- Bullet\n  - Another bullet poin\n\nEnd"),
            baseBlocks: stored, serverOrigin: origin)
        // ...while the co-author finishes the word before the PATCH lands.
        let peer = YDoc(clientID: 7)
        defer { peer.destroy() }
        try peer.applyUpdate(try YUpdateDecoder.decode(state))
        let keystroke = try BlockNoteWriter(doc: peer).replaceText(
            block: stored[1].children[0].id, range: NSRange(location: 19, length: 0), with: "t")

        let server = YDoc(clientID: 999)
        defer { server.destroy() }
        try server.applyUpdate(try YUpdateDecoder.decode(state))
        try server.applyUpdate(try YUpdateDecoder.decode(keystroke))
        if let update { try server.applyUpdate(try YUpdateDecoder.decode(update)) }

        let after = YBlockProjection.project(server)
        XCTAssertEqual(after.blocks.map(\.id), stored.map(\.id), "the list item kept its container")
        XCTAssertEqual(after.blocks[0].runs, [InlineRun("TEST")])
        XCTAssertEqual(
            text(of: try BlockNoteWriter(doc: server).find(stored[1].children[0].id).element), "Another bullet point")
    }

    /// The visible characters of an element's `xmlText` children.
    private func text(of element: YType) -> String {
        var result = ""
        var item = element.start
        while let current = item {
            if !current.deleted, case .type(let child) = current.content, child.typeRef == .xmlText {
                var piece = child.start
                while let run = piece {
                    if !run.deleted, case .string(let units) = run.content {
                        result += String(decoding: units, as: UTF16.self)
                    }
                    piece = run.right
                }
            }
            item = current.right
        }
        return result
    }

    /// Re-indenting keeps every word and must still be written: the nested item is untouched
    /// only when its whole subtree is.
    func testUnNestingAListItemIsWritten() throws {
        let base = "- Bullet\n  - Child"
        let stored = newBlocks(base)
        let state = BlockNoteYjs.encode(stored, clientID: 1)

        let update = try BlockNoteIncrementalSave.update(
            serverState: state, newBlocks: newBlocks("- Bullet\n- Child"), baseBlocks: stored, serverOrigin: origin)
        let after = try project(state, after: update)

        XCTAssertEqual(after.blocks.count, 2)
        XCTAssertTrue(after.blocks.allSatisfy { $0.fidelity == .modeled })
    }

    /// A tick keeps every word and the tree, and must still be written.
    func testTickingANestedChecklistItemIsWritten() throws {
        let base = "- [ ] Parent\n  - [ ] Child"
        let stored = newBlocks(base)
        let state = BlockNoteYjs.encode(stored, clientID: 1)

        let update = try BlockNoteIncrementalSave.update(
            serverState: state, newBlocks: newBlocks("- [ ] Parent\n  - [x] Child"), baseBlocks: stored,
            serverOrigin: origin)
        let after = try project(state, after: update)

        XCTAssertNotEqual(after.blocks.map(\.id), stored.map(\.id), "rebuilt from the markdown")
    }

    /// Two nested items with the same words and tree, told apart only by the tick: deleting the
    /// unchecked one must keep the checked one, not the first server item that reads alike.
    func testDeletingOneOfTwoItemsThatDifferOnlyInTheirTickKeepsTheOther() throws {
        let stored = newBlocks("- [ ] Task\n  - Child\n- [x] Task\n  - Child")
        XCTAssertEqual(stored.map(\.children.count), [1, 1])
        let state = BlockNoteYjs.encode(stored, clientID: 1)

        let update = try BlockNoteIncrementalSave.update(
            serverState: state, newBlocks: newBlocks("- [x] Task\n  - Child"), baseBlocks: stored,
            serverOrigin: origin)
        let after = try project(state, after: update)

        XCTAssertEqual(after.blocks.map(\.id), [stored[1].id], "the checked item is the one kept")
    }

    /// Two nested items whose words, tree and props match (one has a "!"): swapping them must be
    /// written, so the untouched one keeps its own container rather than its look-alike's.
    func testReorderingTwoLookAlikeNestedItemsIsWritten() throws {
        let stored = newBlocks("- Task\n  - Child\n- Task!\n  - Child")
        XCTAssertEqual(stored.map(\.children.count), [1, 1])
        let state = BlockNoteYjs.encode(stored, clientID: 1)

        let update = try BlockNoteIncrementalSave.update(
            serverState: state, newBlocks: newBlocks("- Task!\n  - Child\n- Task\n  - Child"), baseBlocks: stored,
            serverOrigin: origin)

        let server = YDoc(clientID: 999)
        defer { server.destroy() }
        try server.applyUpdate(try YUpdateDecoder.decode(state))
        if let update { try server.applyUpdate(try YUpdateDecoder.decode(update)) }
        let ids = YBlockProjection.project(server).blocks.map(\.id)
        let writer = BlockNoteWriter(doc: server)
        XCTAssertEqual(try ids.map { text(of: try writer.find($0).element) }, ["Task!", "Task"])
        XCTAssertEqual(ids.first, stored[1].id, "the untouched item kept its own container")
    }

    /// The server swapped two nested items that differ only in a "!", and the user deleted
    /// "Task!" locally. Words alone place the server's "Task!" at the base's "Task", so the save
    /// kept "Task!" and deleted "Task"; the exact text must tell them apart.
    func testDeletingOneOfTwoLookAlikeItemsTheServerSwappedKeepsTheOneLeft() throws {
        let stored = newBlocks("- Task\n  - Child\n- Task!\n  - Child")
        XCTAssertEqual(stored.map(\.children.count), [1, 1])
        let state = BlockNoteYjs.encode([stored[1], stored[0]], clientID: 1)

        let update = try BlockNoteIncrementalSave.update(
            serverState: state, newBlocks: newBlocks("- Task\n  - Child"), baseBlocks: stored, serverOrigin: origin)

        let server = YDoc(clientID: 999)
        defer { server.destroy() }
        try server.applyUpdate(try YUpdateDecoder.decode(state))
        if let update { try server.applyUpdate(try YUpdateDecoder.decode(update)) }
        let ids = YBlockProjection.project(server).blocks.map(\.id)
        let writer = BlockNoteWriter(doc: server)
        XCTAssertEqual(try ids.map { text(of: try writer.find($0).element) }, ["Task"], "not the server's Task!")
    }

    /// The web underlined "Chi" of an untouched nested item. Scrubbing the unknown mark leaves
    /// "Chi" + "ld", which must still read like the markdown's one "Child" run.
    func testAnUntouchedNestedItemWithAnUnknownMarkIsLeftInPlace() throws {
        try assertUntouchedNestedItemKept(
            serverChildRuns: [InlineRun("Chi", marks: [(key: "underline", valueJSON: "true")]), InlineRun("ld")])
    }

    /// The server's nested item ends in blanks, which the markdown's list parser strips.
    func testAnUntouchedNestedItemWithTrailingBlanksIsLeftInPlace() throws {
        try assertUntouchedNestedItemKept(serverChildRuns: [InlineRun("Child \t")])
    }

    /// The server's "- Parent / - Child" holds `serverChildRuns` as the child's text; the user
    /// edits only the paragraph above, so the list item and its child keep their containers.
    private func assertUntouchedNestedItemKept(
        serverChildRuns: [InlineRun], file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let stored = newBlocks("Intro\n\n- Parent\n  - Child")
        var serverBlocks = stored
        serverBlocks[1].children[0].runs = serverChildRuns
        let state = BlockNoteYjs.encode(serverBlocks, clientID: 1)

        let update = try BlockNoteIncrementalSave.update(
            serverState: state, newBlocks: newBlocks("TEST\n\n- Parent\n  - Child"), baseBlocks: stored,
            serverOrigin: origin)

        let server = YDoc(clientID: 999)
        defer { server.destroy() }
        try server.applyUpdate(try YUpdateDecoder.decode(state))
        if let update { try server.applyUpdate(try YUpdateDecoder.decode(update)) }
        let after = YBlockProjection.project(server)
        XCTAssertEqual(
            after.blocks.map(\.id), stored.map(\.id), "the list item kept its container", file: file, line: line)
        XCTAssertEqual(after.blocks.first?.runs, [InlineRun("TEST")], file: file, line: line)
        let child = try BlockNoteWriter(doc: server).find(stored[1].children[0].id).element
        XCTAssertEqual(
            text(of: child), serverChildRuns.map(\.text).joined(), "the child kept its own text", file: file, line: line
        )
    }

    private var nestedLeafMarkdown: String {
        let media = "\(origin)/media/11111111-1111-4111-8111-111111111111/attachments/"
        return "- [ ] Task\n  ![photo.jpg](\(media)22222222-2222-4222-8222-222222222222.jpg)\n"
            + "  [report.pdf](\(media)33333333-3333-4333-8333-333333333333.pdf)\n"
    }

    /// Our items must never reuse a client id the document already holds — that would mint
    /// duplicate `(client, clock)` pairs, which is silent corruption on the server.
    func testTheUpdateNeverReusesAClientIDTheDocumentAlreadyHolds() throws {
        let state = served([paragraph("One", id: idA)])

        let update = try XCTUnwrap(
            BlockNoteIncrementalSave.update(
                serverState: state, newBlocks: newBlocks("One\n\nTwo"), serverOrigin: origin, clientID: 1))

        XCTAssertFalse(try YUpdateDecoder.decode(update).blocks.contains { $0.client == 1 })
    }

    func testMalformedServerBytesAreRefused() {
        assertSaveRefused(.malformedServerState) {
            try BlockNoteIncrementalSave.update(
                serverState: Data([0x05, 0xff]), newBlocks: self.newBlocks("x"), serverOrigin: self.origin)
        }
    }

    /// A root that is not a single `blockGroup` cannot be mapped to blocks by position.
    func testANonCanonicalRootIsRefused() throws {
        let doc = YDoc(clientID: 5)
        defer { doc.destroy() }
        try doc.transact(local: true) { tx in
            let root = doc.get(BlockNoteYjs.fragmentField)
            let stray = YType(typeRef: .xmlElement(nodeName: "paragraph"))
            try YWrite.insertAfter(tx, into: root, after: nil, [.type(stray)])
        }
        let state = try YStateEncoder.encodeStateAsUpdate(doc)

        assertSaveRefused(.nonCanonicalDocument) {
            try BlockNoteIncrementalSave.update(
                serverState: state, newBlocks: self.newBlocks("x"), serverOrigin: self.origin)
        }
    }

    // MARK: - The web's document-link node

    /// Captured from yjs (`YBlockProjectionInterlinkingLinkTests`): a paragraph holding
    /// "before ", an `interlinkingLinkInline` to doc 2222… titled "My Page", and " after".
    private let interlinkingHex =
        "0110010007010e646f63756d656e742d73746f7265030a626c6f636b47726f757007000100030e626c6f636b436f6e7461696e65722800010102696401772431313131313131312d313131312d343131312d383131312d313131313131313131313131070001010309706172616772617068280001030f6261636b67726f756e64436f6c6f7201770764656661756c74280001030974657874436f6c6f7201770764656661756c74280001030d74657874416c69676e6d656e740177046c656674070001030604000107076265666f7265208701070316696e7465726c696e6b696e674c696e6b496e6c696e652800010f05646f63496401772432323232323232322d323232322d343232322d383232322d3232323232323232323232322800010f057469746c650177074d7920506167652800010f0864697361626c656401792800010f07747269676765720177012f87010f06040001140620616674657200"

    /// The server's markdown export spells the node as a plain link. Saving that markdown
    /// back unchanged must leave the node alone rather than flattening it into a link.
    func testAnUntouchedDocumentLinkNodeIsLeftAlone() throws {
        let markdown = "before [My Page](https://docs.example.test/docs/22222222-2222-4222-8222-222222222222/) after"

        let update = try BlockNoteIncrementalSave.update(
            serverState: Data(hex: interlinkingHex), newBlocks: newBlocks(markdown), serverOrigin: origin)

        XCTAssertNil(update)
    }

    /// Changed, the block is rewritten from the markdown (never text-reconciled across the
    /// node), exactly as the classic save would write it.
    func testAnEditedDocumentLinkBlockIsRewrittenFromTheMarkdown() throws {
        let state = Data(hex: interlinkingHex)
        let markdown = "before [My Page](https://docs.example.test/docs/22222222-2222-4222-8222-222222222222/) later"

        let update = try BlockNoteIncrementalSave.update(
            serverState: state, newBlocks: newBlocks(markdown), serverOrigin: origin)

        assertReads(try project(state, after: update, interlinkingOrigin: origin), like: markdown)
    }

    private func assertSaveRefused(
        _ expected: BlockNoteIncrementalSaveError, file: StaticString = #filePath, line: UInt = #line,
        _ body: () throws -> Data?
    ) {
        do {
            _ = try body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as BlockNoteIncrementalSaveError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}
