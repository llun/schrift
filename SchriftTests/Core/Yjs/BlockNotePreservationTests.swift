import XCTest

@testable import Schrift

/// The Docs 6 save must leave a server block the markdown cannot spell (a table, a callout, a
/// toggle, a video, a coloured paragraph, a page break) exactly as it is when the user did not
/// touch it, and still write everything the user did change. Verified at the document level,
/// like `BlockNoteIncrementalSaveTests`: apply the update to a replica of the served state
/// and project the result.
final class BlockNotePreservationTests: XCTestCase {
    private let origin = "https://docs.example.test"

    private let idA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let idB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private let idC = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    private let idD = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"

    private let baseProps: [(key: String, value: YAnyValue)] = [
        ("backgroundColor", .string("default")), ("textColor", .string("default")),
        ("textAlignment", .string("left")),
    ]

    private func paragraph(_ text: String, id: String) -> BlockNoteBlock {
        BlockNoteBlock(node: "paragraph", props: baseProps, runs: [InlineRun(text)], id: id)
    }

    /// A served document built by the golden encoder, so it is exactly what yjs would hold.
    /// The encoder writes any node name, which is how the web's own nodes are stood in for.
    private func served(_ blocks: [BlockNoteBlock]) -> Data {
        BlockNoteYjs.encode(blocks, clientID: 1)
    }

    private func save(_ state: Data, _ markdown: String) throws -> Data? {
        try BlockNoteIncrementalSave.update(
            serverState: state, newBlocks: MarkdownYjs.blockNoteBlocks(from: markdown, serverOrigin: origin),
            serverOrigin: origin)
    }

    private func project(_ state: Data, after update: Data?) throws -> ProjectedDocument {
        let doc = YDoc(clientID: 999)
        defer { doc.destroy() }
        try doc.applyUpdate(try YUpdateDecoder.decode(state))
        if let update { try doc.applyUpdate(try YUpdateDecoder.decode(update)) }
        return YBlockProjection.project(doc)
    }

    private func prop(_ key: String, of block: ProjectedBlock) -> YAnyValue? {
        block.props.first { $0.key == key }?.value
    }

    // MARK: - Tables

    /// The web's table reaches the editor as pipe lines, which come back as three plain
    /// paragraphs. Untouched, it must stay the table.
    private var table: BlockNoteBlock {
        BlockNoteBlock(node: "table", props: [], runs: [InlineRun("Page What it covers Architecture How")], id: idB)
    }
    private let tableMarkdown = "| Page | What it covers |\n| --- | --- |\n| Architecture | How |"

    func testAnUntouchedTableSurvivesAnEditElsewhere() throws {
        let state = served([paragraph("Intro", id: idA), table, paragraph("Outro", id: idC)])

        let update = try save(state, "Intro, edited\n\n\(tableMarkdown)\n\nOutro")
        let after = try project(state, after: update)

        XCTAssertEqual(after.blocks.map(\.id), [idA, idB, idC])
        XCTAssertEqual(after.blocks[1].node, "table")
        XCTAssertEqual(after.blocks[0].runs, [InlineRun("Intro, edited")])
    }

    func testAnUntouchedTableAloneNeedsNoUpdate() throws {
        let state = served([paragraph("Intro", id: idA), table])

        XCTAssertNil(try save(state, "Intro\n\n\(tableMarkdown)"))
    }

    /// Changed in the app, its words no longer match: it is written from the markdown, as
    /// before — the user's edit wins.
    func testAnEditedTableIsWrittenFromTheMarkdown() throws {
        let state = served([paragraph("Intro", id: idA), table])

        let update = try save(state, "Intro\n\n| Page | What it covers |\n| --- | --- |\n| Features | How |")
        let after = try project(state, after: update)

        XCTAssertFalse(after.blocks.contains { $0.node == "table" })
        XCTAssertEqual(after.blocks.first?.id, idA)
    }

    func testADeletedTableIsRemoved() throws {
        let state = served([paragraph("Intro", id: idA), table, paragraph("Outro", id: idC)])

        let after = try project(state, after: try save(state, "Intro\n\nOutro"))

        XCTAssertEqual(after.blocks.map(\.id), [idA, idC])
    }

    // MARK: - Callouts, toggles, media

    func testAnUntouchedCalloutStaysACallout() throws {
        let callout = BlockNoteBlock(
            node: "callout", props: [("emoji", .string("💡"))], runs: [InlineRun("Remember this")], id: idB)
        let state = served([paragraph("Intro", id: idA), callout])

        let after = try project(state, after: try save(state, "Intro, edited\n\n💡 Remember this"))

        XCTAssertEqual(after.blocks.map(\.node), ["paragraph", "callout"])
        XCTAssertEqual(after.blocks[1].id, idB)
    }

    /// A toggle with a child: the export flattens it to sibling paragraphs.
    func testAnUntouchedToggleKeepsItsChildren() throws {
        var toggle = BlockNoteBlock(node: "toggleListItem", props: baseProps, runs: [InlineRun("Parent")], id: idB)
        toggle.children = [paragraph("Child", id: idC)]
        let state = served([paragraph("Intro", id: idA), toggle])

        let after = try project(state, after: try save(state, "Intro, edited\n\nParent\n\nChild"))

        XCTAssertEqual(after.blocks.map(\.id), [idA, idB])
        XCTAssertEqual(after.blocks[1].fidelity, .opaque(reason: "nested children"))
    }

    func testAnUntouchedVideoIsNotTurnedIntoAnImage() throws {
        let url = "https://docs.example.test/media/clip.mp4"
        let video = BlockNoteBlock(
            node: "video", props: [("url", .string(url)), ("name", .string("clip"))], runs: [], id: idB)
        let state = served([paragraph("Intro", id: idA), video])

        let after = try project(state, after: try save(state, "Intro, edited\n\n![clip](\(url))"))

        XCTAssertEqual(after.blocks.map(\.node), ["paragraph", "video"])
        XCTAssertEqual(after.blocks[1].id, idB)
    }

    // MARK: - Blocks the export never spells

    func testAPageBreakTheEditorNeverSawIsKeptInPlace() throws {
        let pageBreak = BlockNoteBlock(node: "pageBreak", props: [], runs: [], id: idB)
        let state = served([paragraph("One", id: idA), pageBreak, paragraph("Two", id: idC)])

        let after = try project(state, after: try save(state, "One\n\nTwo, edited"))

        XCTAssertEqual(after.blocks.map(\.id), [idA, idB, idC])
        XCTAssertEqual(after.blocks[2].runs, [InlineRun("Two, edited")])
    }

    // MARK: - Props the markdown cannot carry

    func testAnUntouchedColouredParagraphKeepsItsColour() throws {
        let red = BlockNoteBlock(
            node: "paragraph",
            props: [
                ("backgroundColor", .string("default")), ("textColor", .string("red")),
                ("textAlignment", .string("center")),
            ],
            runs: [InlineRun("Warning")], id: idB)
        let state = served([paragraph("Intro", id: idA), red])

        let after = try project(state, after: try save(state, "Intro, edited\n\nWarning"))

        XCTAssertEqual(after.blocks[1].id, idB)
        XCTAssertEqual(prop("textColor", of: after.blocks[1]), .string("red"))
        XCTAssertEqual(prop("textAlignment", of: after.blocks[1]), .string("center"))
    }

    /// A tick is a change the markdown carries, so it must be written even though the item's
    /// colour is not: the user's change wins over preservation.
    func testTickingAColouredChecklistItemIsWritten() throws {
        let item = BlockNoteBlock(
            node: "checkListItem",
            props: [
                ("backgroundColor", .string("default")), ("textColor", .string("red")),
                ("textAlignment", .string("left")), ("checked", .bool(false)),
            ],
            runs: [InlineRun("Task")], id: idB)
        let state = served([paragraph("Intro", id: idA), item])

        let after = try project(state, after: try save(state, "Intro\n\n- [x] Task"))

        XCTAssertEqual(after.blocks.count, 2)
        XCTAssertEqual(prop("checked", of: after.blocks[1]), .bool(true))
    }

    /// The same words under a different heading level are an edit, not a shadow.
    func testChangingAToggleableHeadingsLevelIsWritten() throws {
        let heading = BlockNoteBlock(
            node: "heading", props: baseProps + [("level", .int(2)), ("isToggleable", .bool(true))],
            runs: [InlineRun("Section")], id: idB)
        let state = served([paragraph("Intro", id: idA), heading])

        let unchanged = try project(state, after: try save(state, "Intro, edited\n\n## Section"))
        XCTAssertEqual(unchanged.blocks[1].id, idB)
        XCTAssertEqual(prop("isToggleable", of: unchanged.blocks[1]), .bool(true))

        let changed = try project(state, after: try save(state, "Intro\n\n### Section"))
        XCTAssertEqual(prop("level", of: changed.blocks[1]), .int(3))
    }

    // MARK: - Pieces

    func testWordsIgnoreMarkdownSyntaxLinkTargetsAndHTML() {
        XCTAssertEqual(BlockNotePreservation.signatureTokens("| **Page** | What it |"), ["Page", "What", "it"])
        XCTAssertEqual(
            BlockNotePreservation.signatureTokens("💡 Remember [this](https://a.example/x)"), ["Remember", "this"])
        XCTAssertEqual(
            BlockNotePreservation.signatureTokens("<figure><figcaption>Cap</figcaption></figure>"), ["Cap"])
        XCTAssertEqual(BlockNotePreservation.signatureTokens("| --- | :-: |"), [])
    }

    func testAMediaBlockIsFoundByItsURL() {
        let url = "https://a.example/v.mp4"
        let image = BlockNoteBlock(node: "image", props: [("url", .string(url))], runs: [], id: "x")
        let html = BlockNoteBlock(
            node: "paragraph", props: [], runs: [InlineRun("<audio src=\"\(url)\"></audio>")], id: "y")
        let other = BlockNoteBlock(node: "image", props: [("url", .string(url + "2"))], runs: [], id: "z")
        XCTAssertTrue(BlockNotePreservation.references(image, url: url))
        XCTAssertTrue(BlockNotePreservation.references(html, url: url))
        XCTAssertFalse(BlockNotePreservation.references(other, url: url))
    }
}
