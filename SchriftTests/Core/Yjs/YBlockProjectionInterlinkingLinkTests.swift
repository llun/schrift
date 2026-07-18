import XCTest

@testable import Schrift

/// Golden fixtures for the web editor's `interlinkingLinkInline` custom inline
/// node (B5 Task 5) — captured from real **yjs@13.6.31**, not hand-built:
/// `y-provider`'s `InterlinkingLinkInline.ts` is a `content: 'none'` inline
/// leaf whose propSchema is `docId`/`disabled`/`trigger`/`title`, and its href
/// is never stored on the wire — the web client computes
/// `${instanceOrigin}/docs/${docId}/` at export time.
///
/// The fixture was captured (session-local node oracle, never committed) by
/// building the `document-store → blockGroup → blockContainer → paragraph`
/// structure by hand, the same way `BlockNoteDocument.swift`/`BlockNoteYjs.encode`
/// does, then inserting a `Y.XmlElement('interlinkingLinkInline')` — with
/// `docId`/`title`/`disabled`/`trigger` attributes set via `setAttribute` — as
/// an inline child of the paragraph **between two `Y.XmlText` runs**:
/// `paragraph.insert(0, [textBefore, linkNode, textAfter])`. Decoding the
/// resulting update bytes into a fresh `Y.Doc` and walking
/// `paragraph.toArray()` confirmed the ACTUAL wire shape: the interlinking
/// node is its own `Y.XmlElement`, a **sibling** in the same children list as
/// the surrounding `Y.XmlText` runs — never nested inside one `xmlText`'s own
/// item list — with `linkNode.length === 0` (no text children of its own) and
/// its four attributes as ordinary single-value map entries, exactly like any
/// other content element's props. That confirmed shape is exactly what
/// `YBlockProjection.foldInline` reads.
///
/// Regeneration (yjs@13.6.31, Node v24): in a scratch dir with `yjs@13.6.31`
/// installed —
/// ```js
/// import * as Y from "yjs";
/// const doc = new Y.Doc();
/// doc.clientID = 1;
/// doc.gc = false;
/// const fragment = doc.getXmlFragment("document-store");
/// const blockGroup = new Y.XmlElement("blockGroup");
/// fragment.insert(0, [blockGroup]);
/// const blockContainer = new Y.XmlElement("blockContainer");
/// blockGroup.insert(0, [blockContainer]);
/// blockContainer.setAttribute("id", "11111111-1111-4111-8111-111111111111");
/// const paragraph = new Y.XmlElement("paragraph");
/// blockContainer.insert(0, [paragraph]);
/// paragraph.setAttribute("backgroundColor", "default");
/// paragraph.setAttribute("textColor", "default");
/// paragraph.setAttribute("textAlignment", "left");
/// const textBefore = new Y.XmlText("before ");
/// const linkNode = new Y.XmlElement("interlinkingLinkInline");
/// linkNode.setAttribute("docId", "22222222-2222-4222-8222-222222222222");
/// linkNode.setAttribute("title", "My Page");
/// linkNode.setAttribute("disabled", false);  // true for the disabled fixture
/// linkNode.setAttribute("trigger", "/");
/// const textAfter = new Y.XmlText(" after");
/// paragraph.insert(0, [textBefore, linkNode, textAfter]);
/// console.log(Buffer.from(Y.encodeStateAsUpdate(doc)).toString("hex"));
/// ```
final class YBlockProjectionInterlinkingLinkTests: XCTestCase {

    // MARK: - Fixtures

    /// `disabled: false`. Container id `11111111-1111-4111-8111-111111111111`;
    /// link node `docId: "22222222-2222-4222-8222-222222222222"`, `title: "My Page"`.
    private let withOriginHex =
        "0110010007010e646f63756d656e742d73746f7265030a626c6f636b47726f757007000100030e626c6f636b436f6e7461696e65722800010102696401772431313131313131312d313131312d343131312d383131312d313131313131313131313131070001010309706172616772617068280001030f6261636b67726f756e64436f6c6f7201770764656661756c74280001030974657874436f6c6f7201770764656661756c74280001030d74657874416c69676e6d656e740177046c656674070001030604000107076265666f7265208701070316696e7465726c696e6b696e674c696e6b496e6c696e652800010f05646f63496401772432323232323232322d323232322d343232322d383232322d3232323232323232323232322800010f057469746c650177074d7920506167652800010f0864697361626c656401792800010f07747269676765720177012f87010f06040001140620616674657200"

    /// Same shape, `disabled: true`.
    private let disabledHex =
        "0110010007010e646f63756d656e742d73746f7265030a626c6f636b47726f757007000100030e626c6f636b436f6e7461696e65722800010102696401772431313131313131312d313131312d343131312d383131312d313131313131313131313131070001010309706172616772617068280001030f6261636b67726f756e64436f6c6f7201770764656661756c74280001030974657874436f6c6f7201770764656661756c74280001030d74657874416c69676e6d656e740177046c656674070001030604000107076265666f7265208701070316696e7465726c696e6b696e674c696e6b496e6c696e652800010f05646f63496401772432323232323232322d323232322d343232322d383232322d3232323232323232323232322800010f057469746c650177074d7920506167652800010f0864697361626c656401782800010f07747269676765720177012f87010f06040001140620616674657200"

    private let interlinkingOrigin = "https://docs.example.test"
    private let expectedHref = "https://docs.example.test/docs/22222222-2222-4222-8222-222222222222/"

    private func doc(fromHex hex: String) throws -> YDoc {
        let doc = YDoc(clientID: 99)
        try doc.applyUpdate(try YUpdateDecoder.decode(Data(hex: hex)))
        return doc
    }

    // MARK: - Test 1: with an origin, the node projects as a modeled link run

    func testInterlinkingLinkWithOriginProjectsAsModeledLink() throws {
        let replica = try doc(fromHex: withOriginHex)
        let projected = YBlockProjection.project(replica, interlinkingOrigin: interlinkingOrigin)
        replica.destroy()

        XCTAssertEqual(projected.blocks.count, 1)
        let block = projected.blocks[0]
        XCTAssertEqual(block.id, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(block.node, "paragraph")
        XCTAssertEqual(block.fidelity, .modeled, "expected .modeled, got \(block.fidelity)")
        XCTAssertTrue(projected.isFullyRenderable)
        XCTAssertTrue(projected.isFullyModeled)

        XCTAssertEqual(
            block.runs,
            [
                InlineRun("before "),
                InlineRun("My Page", marks: [(key: "link", valueJSON: #"{"href":"\#(expectedHref)"}"#)]),
                InlineRun(" after"),
            ])
    }

    // MARK: - Test 2: without an origin, the block is opaque

    func testInterlinkingLinkWithoutOriginIsOpaque() throws {
        let replica = try doc(fromHex: withOriginHex)
        let projected = YBlockProjection.project(replica)  // nil origin (the default)
        replica.destroy()

        XCTAssertEqual(projected.blocks.count, 1)
        let block = projected.blocks[0]
        XCTAssertEqual(block.id, "11111111-1111-4111-8111-111111111111", "id stays legible even when opaque")
        guard case .opaque(let reason) = block.fidelity else {
            XCTFail("expected .opaque, got \(block.fidelity)")
            return
        }
        XCTAssertEqual(reason, "interlinkingLink")
        XCTAssertFalse(projected.isFullyRenderable)
        XCTAssertFalse(projected.isFullyModeled)
    }

    // MARK: - Test 3: disabled, even with an origin, is opaque

    func testDisabledInterlinkingLinkIsOpaque() throws {
        let replica = try doc(fromHex: disabledHex)
        let projected = YBlockProjection.project(replica, interlinkingOrigin: interlinkingOrigin)
        replica.destroy()

        XCTAssertEqual(projected.blocks.count, 1)
        guard case .opaque(let reason) = projected.blocks[0].fidelity else {
            XCTFail("expected .opaque, got \(projected.blocks[0].fidelity)")
            return
        }
        XCTAssertEqual(reason, "interlinkingLink")
        XCTAssertFalse(projected.isFullyRenderable)
    }

    // MARK: - Test 4: the with-origin markdown round-trips

    func testInterlinkingLinkWithOriginMarkdownRoundTrips() throws {
        let replica = try doc(fromHex: withOriginHex)
        let projected = YBlockProjection.project(replica, interlinkingOrigin: interlinkingOrigin)
        replica.destroy()

        guard let markdown = YBlockProjection.projectedMarkdown(projected) else {
            XCTFail("expected the modeled interlinking-link block to render as markdown")
            return
        }
        XCTAssertTrue(
            markdown.contains("[My Page](\(expectedHref))"),
            "expected a real markdown link in: \(markdown.debugDescription)")

        // Re-parsing the rendered markdown must produce a paragraph whose runs
        // are equivalent to the original projected runs — the same
        // self-verification `projectedMarkdown` already performs internally,
        // asserted here directly against `InlineMarkdown.parse`.
        let reparsedBlocks = parseEditorBlocks(markdown)
        XCTAssertEqual(reparsedBlocks.count, 1)
        XCTAssertEqual(reparsedBlocks[0].kind, .paragraph)
        let reparsedRuns = InlineMarkdown.parse(reparsedBlocks[0].text)
        XCTAssertEqual(reparsedRuns, projected.blocks[0].runs)
    }
}
