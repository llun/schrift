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
