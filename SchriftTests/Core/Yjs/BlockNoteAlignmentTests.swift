import XCTest

@testable import Schrift

/// `BlockNoteAlignment.align` decides which server blocks the Docs 6 save leaves untouched,
/// which it reconciles in place, and which it removes or inserts. Each case pins one rule.
final class BlockNoteAlignmentTests: XCTestCase {
    private var baseProps: [(key: String, value: YAnyValue)] {
        [
            ("backgroundColor", .string("default")), ("textColor", .string("default")),
            ("textAlignment", .string("left")),
        ]
    }

    private func old(
        _ text: String, id: String, node: String = "paragraph", fidelity: ProjectionFidelity = .modeled,
        extraProps: [ProjectedProp] = []
    ) -> ProjectedBlock {
        let props = baseProps.map { ProjectedProp(key: $0.key, value: $0.value) } + extraProps
        return ProjectedBlock(
            id: id, node: node, props: props.sorted { $0.key < $1.key }, runs: text.isEmpty ? [] : [InlineRun(text)],
            fidelity: fidelity)
    }

    private func new(_ text: String, node: String = "paragraph") -> BlockNoteBlock {
        BlockNoteBlock(
            node: node, props: baseProps, runs: text.isEmpty ? [] : [InlineRun(text)],
            id: UUID().uuidString.lowercased())
    }

    func testAnUnchangedDocumentKeepsEveryID() {
        let server = [old("a", id: "A"), old("b", id: "B"), old("c", id: "C")]

        let aligned = BlockNoteAlignment.align(old: server, new: [new("a"), new("b"), new("c")])

        XCTAssertEqual(aligned.map(\.id), ["A", "B", "C"])
    }

    func testABlockInsertedInTheMiddleKeepsItsFreshIDAndTheNeighboursKeepTheirs() {
        let server = [old("a", id: "A"), old("c", id: "C")]
        let inserted = new("b")

        let aligned = BlockNoteAlignment.align(old: server, new: [new("a"), inserted, new("c")])

        XCTAssertEqual(aligned.map(\.id), ["A", inserted.id, "C"])
    }

    /// An edited block between two anchors is paired positionally, so `applyEdit` reconciles
    /// its text in place instead of deleting and re-inserting it.
    func testAnEditedBlockReusesTheServerID() {
        let server = [old("a", id: "A"), old("b", id: "B"), old("c", id: "C")]

        let aligned = BlockNoteAlignment.align(old: server, new: [new("a"), new("b changed"), new("c")])

        XCTAssertEqual(aligned.map(\.id), ["A", "B", "C"])
        XCTAssertEqual(aligned[1].runs, [InlineRun("b changed")], "the content is the new block's")
    }

    func testADeletedBlockIsLeftUnmatched() {
        let server = [old("a", id: "A"), old("b", id: "B"), old("c", id: "C")]

        let aligned = BlockNoteAlignment.align(old: server, new: [new("a"), new("c")])

        XCTAssertEqual(aligned.map(\.id), ["A", "C"])
    }

    func testAKindChangeIsPairedSoTheContainerSurvives() {
        let server = [old("a", id: "A"), old("item", id: "B"), old("c", id: "C")]

        let aligned = BlockNoteAlignment.align(
            old: server, new: [new("a"), new("item", node: "bulletListItem"), new("c")])

        XCTAssertEqual(aligned.map(\.id), ["A", "B", "C"])
        XCTAssertEqual(aligned[1].node, "bulletListItem")
    }

    /// A lossy block the user left alone is anchored — and so left untouched with every prop
    /// the editor does not model — while a changed lossy block is never reconciled (its runs
    /// are scrubbed, so a text diff over them could corrupt it).
    func testALossyBlockIsAnchoredWhenUnchangedAndNeverPairedWhenChanged() {
        let colored = ProjectedProp(key: "zColor", value: .string("red"))
        let lossy = ProjectionFidelity.lossy(reasons: ["unknownProp:zColor"])
        let server = [old("a", id: "A"), old("b", id: "B", fidelity: lossy, extraProps: [colored]), old("c", id: "C")]

        let untouched = BlockNoteAlignment.align(old: server, new: [new("a"), new("b"), new("c")])
        let edited = new("b edited")
        let changed = BlockNoteAlignment.align(old: server, new: [new("a"), edited, new("c")])

        XCTAssertEqual(untouched.map(\.id), ["A", "B", "C"])
        XCTAssertEqual(changed.map(\.id), ["A", edited.id, "C"])
    }

    /// An opaque block has no reliable content to compare or reconcile, except an unknown node
    /// whose props and runs were read in full (the web's `file` attachment block).
    func testOpaqueBlocksMatchOnlyWhenTheirContentWasFullyRead() {
        let fileProps = [
            ProjectedProp(key: "backgroundColor", value: .string("default")),
            ProjectedProp(key: "caption", value: .string("")),
            ProjectedProp(key: "name", value: .string("a.pdf")),
            ProjectedProp(key: "url", value: .string("https://docs.example.org/media/x.pdf")),
        ]
        let server = [
            ProjectedBlock(
                id: "F", node: "file", props: fileProps, runs: [], fidelity: .opaque(reason: "unknownNode:file")),
            old("", id: "L", fidelity: .opaque(reason: "interlinkingLink")),
        ]
        let file = BlockNoteBlock(
            node: "file",
            props: [
                ("backgroundColor", .string("default")), ("name", .string("a.pdf")),
                ("url", .string("https://docs.example.org/media/x.pdf")), ("caption", .string("")),
            ],
            runs: [], id: "fresh-file")
        let emptyParagraph = new("")

        let aligned = BlockNoteAlignment.align(old: server, new: [file, emptyParagraph])

        XCTAssertEqual(aligned.map(\.id), ["F", emptyParagraph.id], "an opaque paragraph's empty runs prove nothing")
    }

    /// The differ only reconciles a flat block; a new block with children is always inserted.
    func testABlockWithChildrenIsNeverMatched() {
        let server = [old("a", id: "A"), old("item", id: "B", node: "bulletListItem")]
        var parent = new("item", node: "bulletListItem")
        parent.children = [new("child", node: "bulletListItem")]

        let aligned = BlockNoteAlignment.align(old: server, new: [new("a"), parent])

        XCTAssertEqual(aligned.map(\.id), ["A", parent.id])
    }

    /// Two equal blocks in a row must anchor one-to-one, never both to the same server block.
    func testRepeatedContentAnchorsInOrder() {
        let server = [old("x", id: "X1"), old("y", id: "Y"), old("x", id: "X2")]

        let aligned = BlockNoteAlignment.align(old: server, new: [new("x"), new("x")])

        XCTAssertEqual(aligned.map(\.id), ["X1", "X2"])
    }

    func testEveryMatchIsAscendingInBothCoordinates() {
        let server = [old("a", id: "A"), old("b", id: "B"), old("c", id: "C"), old("d", id: "D")]
        let blocks = [new("d"), new("b"), new("q"), new("a")]

        let pairs = BlockNoteAlignment.matches(old: server, new: blocks)

        XCTAssertEqual(pairs.map(\.old), pairs.map(\.old).sorted())
        XCTAssertEqual(pairs.map(\.new), pairs.map(\.new).sorted())
        XCTAssertEqual(Set(pairs.map(\.old)).count, pairs.count)
    }
}
