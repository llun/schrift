import XCTest

@testable import Schrift

/// The Docs 6 save must leave a server block the markdown cannot spell (a table, a callout, a
/// toggle, a video, a coloured paragraph, a page break) exactly as it is when the user did not
/// touch it, and still write everything the user did change. Verified at the document level,
/// like `BlockNoteIncrementalSaveTests`: apply the update to a replica of the served state
/// and project the result.
///
/// Each save passes `base`, the markdown the server's export gave the editor before the edit
/// (the draft's baseline in the app), which is what says which blocks the user left alone.
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

    private func blocks(_ markdown: String) -> [BlockNoteBlock] {
        MarkdownYjs.blockNoteBlocks(from: markdown, serverOrigin: origin)
    }

    private func save(_ state: Data, _ markdown: String, base: String?) throws -> Data? {
        try BlockNoteIncrementalSave.update(
            serverState: state, newBlocks: blocks(markdown), baseBlocks: base.map(blocks), serverOrigin: origin)
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
        BlockNoteBlock(node: "table", props: [], runs: [InlineRun("Page What it covers Architecture -5")], id: idB)
    }
    private let tableMarkdown = "| Page | What it covers |\n| --- | --- |\n| Architecture | -5 |"

    func testAnUntouchedTableSurvivesAnEditElsewhere() throws {
        let state = served([paragraph("Intro", id: idA), table, paragraph("Outro", id: idC)])
        let base = "Intro\n\n\(tableMarkdown)\n\nOutro"

        let update = try save(state, "Intro, edited\n\n\(tableMarkdown)\n\nOutro", base: base)
        let after = try project(state, after: update)

        XCTAssertEqual(after.blocks.map(\.id), [idA, idB, idC])
        XCTAssertEqual(after.blocks[1].node, "table")
        XCTAssertEqual(after.blocks[0].runs, [InlineRun("Intro, edited")])
    }

    func testAnUntouchedTableAloneNeedsNoUpdate() throws {
        let state = served([paragraph("Intro", id: idA), table])
        let markdown = "Intro\n\n\(tableMarkdown)"

        XCTAssertNil(try save(state, markdown, base: markdown))
    }

    /// Changed in the app, it is written from the markdown, as before — the user's edit wins.
    func testAnEditedTableIsWrittenFromTheMarkdown() throws {
        let state = served([paragraph("Intro", id: idA), table])

        let update = try save(
            state, "Intro\n\n| Page | What it covers |\n| --- | --- |\n| Features | -5 |",
            base: "Intro\n\n\(tableMarkdown)")
        let after = try project(state, after: update)

        XCTAssertFalse(after.blocks.contains { $0.node == "table" })
        XCTAssertEqual(after.blocks.first?.id, idA)
    }

    /// An edit the words cannot see — a sign, a bold word — is still an edit.
    func testAPunctuationOrFormattingOnlyEditIsWritten() throws {
        let state = served([paragraph("Intro", id: idA), table])
        let base = "Intro\n\n\(tableMarkdown)"

        for edited in [
            "| Page | What it covers |\n| --- | --- |\n| Architecture | 5 |",
            "| Page | What it covers |\n| --- | --- |\n| **Architecture** | -5 |",
        ] {
            let after = try project(state, after: try save(state, "Intro\n\n\(edited)", base: base))
            XCTAssertFalse(after.blocks.contains { $0.node == "table" }, edited)
        }
    }

    func testADeletedTableIsRemoved() throws {
        let state = served([paragraph("Intro", id: idA), table, paragraph("Outro", id: idC)])

        let after = try project(
            state, after: try save(state, "Intro\n\nOutro", base: "Intro\n\n\(tableMarkdown)\n\nOutro"))

        XCTAssertEqual(after.blocks.map(\.id), [idA, idC])
    }

    /// Without a base nothing can be shown to be untouched, so no shadow is matched.
    /// A row the user deleted must not be made up from the next block's words: the shadow
    /// has to have been one run in the base.
    func testATableThatLostARowDoesNotBorrowTheNextBlocksWords() throws {
        let twoRows = BlockNoteBlock(node: "table", props: [], runs: [InlineRun("A B")], id: idB)
        let callout = BlockNoteBlock(
            node: "callout", props: [("emoji", .string("💡"))], runs: [InlineRun("B")], id: idC)
        let state = served([twoRows, callout])

        let after = try project(
            state, after: try save(state, "| A |\n| --- |\n\n💡 B", base: "| A |\n| --- |\n| B |\n\n💡 B"))

        XCTAssertFalse(after.blocks.contains { $0.node == "table" })
        XCTAssertEqual(after.blocks.last?.id, idC)
        XCTAssertEqual(after.blocks.last?.node, "callout")
    }

    /// A save whose baseline is the user's own body (a "keep mine" with no server copy to
    /// carry) passes no base, so nothing the user wrote can read as untouched.
    func testALocalBaselineIsNoBase() {
        XCTAssertNil(DraftBaseline(serverUpdatedAt: nil, markdown: "Mine", markdownIsLocal: true).serverMarkdown)
        XCTAssertEqual(DraftBaseline(serverUpdatedAt: nil, markdown: "Server").serverMarkdown, "Server")
    }

    func testWithoutABaseNoShadowIsMatched() throws {
        let state = served([paragraph("Intro", id: idA), table])

        let after = try project(state, after: try save(state, "Intro, edited\n\n\(tableMarkdown)", base: nil))

        XCTAssertFalse(after.blocks.contains { $0.node == "table" })
    }

    // MARK: - Callouts, toggles, media

    func testAnUntouchedCalloutStaysACallout() throws {
        let callout = BlockNoteBlock(
            node: "callout", props: [("emoji", .string("💡"))], runs: [InlineRun("Remember this")], id: idB)
        let state = served([paragraph("Intro", id: idA), callout])

        let update = try save(state, "Intro, edited\n\n💡 Remember this", base: "Intro\n\n💡 Remember this")
        let after = try project(state, after: update)

        XCTAssertEqual(after.blocks.map(\.node), ["paragraph", "callout"])
        XCTAssertEqual(after.blocks[1].id, idB)
    }

    func testACalloutTurnedIntoAHeadingIsWritten() throws {
        let callout = BlockNoteBlock(
            node: "callout", props: [("emoji", .string("💡"))], runs: [InlineRun("Remember this")], id: idB)
        let state = served([paragraph("Intro", id: idA), callout])

        let after = try project(
            state, after: try save(state, "Intro\n\n## Remember this", base: "Intro\n\n💡 Remember this"))

        XCTAssertEqual(after.blocks.map(\.node), ["paragraph", "heading"])
    }

    /// A toggle with a child: the export flattens it to sibling blocks.
    private var toggle: BlockNoteBlock {
        var toggle = BlockNoteBlock(node: "toggleListItem", props: baseProps, runs: [InlineRun("Parent")], id: idB)
        toggle.children = [
            BlockNoteBlock(
                node: "checkListItem", props: baseProps + [("checked", .bool(false))], runs: [InlineRun("Child")],
                id: idC)
        ]
        return toggle
    }
    private let toggleMarkdown = "Parent\n\n- [ ] Child"

    func testAnUntouchedToggleKeepsItsChildren() throws {
        let state = served([paragraph("Intro", id: idA), toggle])

        let update = try save(state, "Intro, edited\n\n\(toggleMarkdown)", base: "Intro\n\n\(toggleMarkdown)")
        let after = try project(state, after: update)

        XCTAssertEqual(after.blocks.map(\.id), [idA, idB])
        XCTAssertEqual(after.blocks[1].fidelity, .opaque(reason: "nested children"))
    }

    /// Ticking the toggle's nested checklist item keeps every word, and must still be written.
    func testATickInsideAToggleIsWritten() throws {
        let state = served([paragraph("Intro", id: idA), toggle])

        let after = try project(
            state, after: try save(state, "Intro\n\nParent\n\n- [x] Child", base: "Intro\n\n\(toggleMarkdown)"))

        XCTAssertFalse(after.blocks.contains { $0.id == idB })
        XCTAssertEqual(after.blocks.last.flatMap { prop("checked", of: $0) }, .bool(true))
    }

    /// A photo the user put between the toggle's flattened lines is theirs, never part of the
    /// shadow.
    func testABlockInsertedInsideAShadowIsNotSwallowed() throws {
        let state = served([paragraph("Intro", id: idA), toggle])
        let photo = "![](https://docs.example.test/media/p.png)"

        let after = try project(
            state,
            after: try save(state, "Intro\n\nParent\n\n\(photo)\n\n- [ ] Child", base: "Intro\n\n\(toggleMarkdown)"))

        XCTAssertTrue(after.blocks.contains { $0.node == "image" })
    }

    private let videoURL = "https://docs.example.test/media/clip.mp4"
    private var video: BlockNoteBlock {
        BlockNoteBlock(
            node: "video", props: [("url", .string(videoURL)), ("name", .string("clip"))], runs: [], id: idB)
    }

    func testAnUntouchedVideoIsNotTurnedIntoAnImage() throws {
        let state = served([paragraph("Intro", id: idA), video])
        let line = "![clip](\(videoURL))"

        let after = try project(state, after: try save(state, "Intro, edited\n\n\(line)", base: "Intro\n\n\(line)"))

        XCTAssertEqual(after.blocks.map(\.node), ["paragraph", "video"])
        XCTAssertEqual(after.blocks[1].id, idB)
    }

    /// Deleting the video while a paragraph links to it: the paragraph is not the video's
    /// shadow, so the video goes and the paragraph stays.
    func testAParagraphLinkingAMediaURLIsNotItsShadow() throws {
        let link = "See [clip](\(videoURL))"
        let state = served([paragraph("Intro", id: idA), video, paragraph("Outro", id: idC)])

        let update = try save(
            state, "Intro\n\n\(link)\n\nOutro", base: "Intro\n\n![clip](\(videoURL))\n\n\(link)\n\nOutro")
        let after = try project(state, after: update)

        XCTAssertFalse(after.blocks.contains { $0.node == "video" })
        XCTAssertEqual(after.blocks.map(\.node), ["paragraph", "paragraph", "paragraph"])
    }

    // MARK: - Blocks the export never spells

    private var pageBreak: BlockNoteBlock { BlockNoteBlock(node: "pageBreak", props: [], runs: [], id: idB) }

    func testAPageBreakTheEditorNeverSawIsKeptInPlace() throws {
        let state = served([paragraph("One", id: idA), pageBreak, paragraph("Two", id: idC)])

        let after = try project(state, after: try save(state, "One\n\nTwo, edited", base: "One\n\nTwo"))

        XCTAssertEqual(after.blocks.map(\.id), [idA, idB, idC])
        XCTAssertEqual(after.blocks[2].runs, [InlineRun("Two, edited")])
    }

    /// Editing the block *before* it must not move the page break above that block.
    func testEditingTheBlockBeforeAPageBreakKeepsItsPlace() throws {
        let state = served([paragraph("One", id: idA), pageBreak, paragraph("Two", id: idC)])

        let after = try project(state, after: try save(state, "One, edited\n\nTwo", base: "One\n\nTwo"))

        XCTAssertEqual(after.blocks.map(\.id), [idA, idB, idC])
        XCTAssertEqual(after.blocks[0].runs, [InlineRun("One, edited")])
    }

    func testAPageBreakIsKeptEvenWithoutABase() throws {
        let state = served([paragraph("One", id: idA), pageBreak, paragraph("Two", id: idC)])

        let after = try project(state, after: try save(state, "One\n\nTwo, edited", base: nil))

        XCTAssertEqual(after.blocks.map(\.id), [idA, idB, idC])
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

        let after = try project(
            state, after: try save(state, "Intro, edited\n\nWarning", base: "Intro\n\nWarning"))

        XCTAssertEqual(after.blocks[1].id, idB)
        XCTAssertEqual(prop("textColor", of: after.blocks[1]), .string("red"))
        XCTAssertEqual(prop("textAlignment", of: after.blocks[1]), .string("center"))
    }

    /// A plain duplicate of a coloured paragraph's words must not anchor onto its shadow and
    /// leave the coloured one with nothing to match.
    func testAPlainDuplicateCannotTakeAColouredParagraphsShadow() throws {
        let red = BlockNoteBlock(
            node: "paragraph", props: [("backgroundColor", .string("red"))], runs: [InlineRun("Warning")], id: idA)
        let state = served([red, paragraph("Warning", id: idB), paragraph("Note", id: idC)])

        let after = try project(
            state,
            after: try save(state, "Warning\n\nWarning\n\nNote, edited", base: "Warning\n\nWarning\n\nNote"))

        XCTAssertEqual(after.blocks.map(\.id), [idA, idB, idC])
        XCTAssertEqual(prop("backgroundColor", of: after.blocks[0]), .string("red"))
        XCTAssertEqual(after.blocks[2].runs, [InlineRun("Note, edited")])
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

        let after = try project(state, after: try save(state, "Intro\n\n- [x] Task", base: "Intro\n\n- [ ] Task"))

        XCTAssertEqual(after.blocks.count, 2)
        XCTAssertEqual(prop("checked", of: after.blocks[1]), .bool(true))
    }

    func testChangingAToggleableHeadingsLevelIsWritten() throws {
        let heading = BlockNoteBlock(
            node: "heading", props: baseProps + [("level", .int(2)), ("isToggleable", .bool(true))],
            runs: [InlineRun("Section")], id: idB)
        let state = served([paragraph("Intro", id: idA), heading])
        let base = "Intro\n\n## Section"

        let unchanged = try project(state, after: try save(state, "Intro, edited\n\n## Section", base: base))
        XCTAssertEqual(unchanged.blocks[1].id, idB)
        XCTAssertEqual(prop("isToggleable", of: unchanged.blocks[1]), .bool(true))

        let changed = try project(state, after: try save(state, "Intro\n\n### Section", base: base))
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

    func testOnlyATrueMediaShadowMatchesItsURL() {
        let url = "https://a.example/v.mp4"
        let link = #"{"href":"https://a.example/v.mp4"}"#
        let image = BlockNoteBlock(node: "image", props: [("url", .string(url))], runs: [], id: "x")
        let html = BlockNoteBlock(
            node: "paragraph", props: [], runs: [InlineRun("<audio src=\"\(url)\"></audio>")], id: "y")
        let bareLink = BlockNoteBlock(
            node: "paragraph", props: [], runs: [InlineRun("clip", marks: [(key: "link", valueJSON: link)])], id: "z")
        let mention = BlockNoteBlock(
            node: "paragraph", props: [],
            runs: [InlineRun("See "), InlineRun("clip", marks: [(key: "link", valueJSON: link)])], id: "w")
        let other = BlockNoteBlock(node: "image", props: [("url", .string(url + "2"))], runs: [], id: "v")
        XCTAssertTrue(BlockNotePreservation.isMediaShadow(image, url: url))
        XCTAssertTrue(BlockNotePreservation.isMediaShadow(html, url: url))
        XCTAssertTrue(BlockNotePreservation.isMediaShadow(bareLink, url: url))
        XCTAssertFalse(BlockNotePreservation.isMediaShadow(mention, url: url))
        XCTAssertFalse(BlockNotePreservation.isMediaShadow(other, url: url))
    }

    func testUntouchedIsTheLongestCommonSubsequenceWithTheBase() {
        let base = blocks("One\n\nTwo\n\nThree")
        let new = blocks("One\n\nTwo, edited\n\nThree\n\nFour")
        XCTAssertEqual(BlockNotePreservation.untouched(base: base, new: new), [0: 0, 2: 2])
    }
}
