import XCTest

@testable import Schrift

/// Parsing and serializing `BlockKind.attachment`.
///
/// The load-bearing property is at the bottom: an origin-aware parse and an
/// origin-less one must serialize to the **same markdown** for every input.
/// That is what lets `canonicalMarkdown`, `draftSyncDecision` and the whole save
/// coordinator go on calling `parseEditorBlocks` without an origin — and it is
/// why classification lives in `flushPending`'s single-line branch rather than
/// in `parseClassifiedLine`.
final class AttachmentBlockParsingTests: XCTestCase {
    private let serverOrigin = "https://docs.example.org"
    private let documentUUID = "11111111-1111-4111-8111-111111111111"
    private let fileUUID = "22222222-2222-4222-8222-222222222222"

    private func url(_ ext: String = "pdf", origin: String? = nil) -> String {
        "\(origin ?? serverOrigin)/media/\(documentUUID)/attachments/\(fileUUID).\(ext)"
    }

    private func parse(_ markdown: String, origin: String? = nil) -> [EditorBlock] {
        parseEditorBlocks(markdown, serverOrigin: origin ?? serverOrigin)
    }

    // MARK: - Classification

    func testAStandaloneAttachmentLinkBecomesAnAttachmentBlock() {
        let blocks = parse("[Q3 report.pdf](\(url()))")
        XCTAssertEqual(blocks.map(\.kind), [.attachment(name: "Q3 report.pdf", url: url())])
        XCTAssertEqual(blocks.first?.text, "", "an attachment is a leaf: no text")
    }

    func testTheURLIsPreservedByteForByte() {
        // extract_attachments() matches the embedded url exactly, so nothing may
        // re-normalize it.
        let shouted = "HTTPS://DOCS.Example.ORG/media/\(documentUUID)/attachments/\(fileUUID).pdf"
        guard case .attachment(_, let stored)? = parse("[f](\(shouted))").first?.kind else {
            return XCTFail("expected an attachment block")
        }
        XCTAssertEqual(stored, shouted)
    }

    func testWithoutAnOriginTheSameLineStaysAParagraph() {
        let markdown = "[Q3 report.pdf](\(url()))"
        XCTAssertEqual(parseEditorBlocks(markdown).map(\.kind), [.paragraph])
        XCTAssertEqual(parseEditorBlocks(markdown, serverOrigin: "").map(\.kind), [.paragraph])
    }

    func testOffOriginAndOrdinaryLinksStayParagraphs() {
        XCTAssertEqual(parse("[x](\(url(origin: "https://files.example")))").map(\.kind), [.paragraph])
        XCTAssertEqual(parse("[Docs](https://docs.example.org/docs/\(documentUUID)/)").map(\.kind), [.paragraph])
        XCTAssertEqual(parse("Just prose.").map(\.kind), [.paragraph])
    }

    func testAnImageLineIsStillAnImage() {
        XCTAssertEqual(parse("![alt](\(url("png")))").map(\.kind), [.image(alt: "alt", url: url("png"))])
    }

    /// The adjacency contract: with no blank line between, the parser makes one
    /// `.unknown` block, and it must stay that way under both parses or the
    /// identity below breaks.
    func testAnAttachmentLineAdjacentToProseStaysOneUnknownBlock() {
        let markdown = "Attached:\n[f](\(url()))"
        XCTAssertEqual(parse(markdown).map(\.kind), [.unknown])
        XCTAssertEqual(parseEditorBlocks(markdown).map(\.kind), [.unknown])
    }

    func testAnAttachmentAmongOtherBlocksClassifiesOnlyItself() {
        let blocks = parse("# Title\n\nIntro\n\n[f](\(url()))\n\n- item")
        XCTAssertEqual(
            blocks.map(\.kind),
            [.heading(level: 1), .paragraph, .attachment(name: "f", url: url()), .bulletItem])
    }

    // MARK: - Serialization

    func testAnAttachmentSerializesBackToItsLink() {
        let block = EditorBlock(kind: .attachment(name: "Q3 report.pdf", url: url()))
        XCTAssertEqual(serializeBlock(block, numberedIndex: 1), "[Q3 report.pdf](\(url()))")
    }

    func testAnAttachmentRoundTripsThroughParseAndSerialize() {
        let markdown = "[Q3 report.pdf](\(url()))\n"
        XCTAssertEqual(serializeMarkdown(parse(markdown)), markdown)
    }

    func testAnAttachmentIsSeparatedLikeAParagraphNotLikeAColumnZeroBlock() {
        // It joins its neighbours exactly as the paragraph it was classified
        // from would, which is what keeps the two parses' output identical.
        let markdown = "Intro\n\n[f](\(url()))\n\nOutro\n"
        XCTAssertEqual(serializeMarkdown(parse(markdown)), markdown)
    }

    func testAnEmptyLabelSurvivesTheRoundTrip() {
        let markdown = "[](\(url()))\n"
        XCTAssertEqual(serializeMarkdown(parse(markdown)), markdown)
    }

    func testAnAttachmentIsNotDroppedAsAnEmptyParagraph() {
        // Its `text` is empty, so the serializer's empty-paragraph filter must
        // not mistake it for one.
        XCTAssertEqual(
            serializeMarkdown([EditorBlock(kind: .attachment(name: "f", url: url()))]), "[f](\(url()))\n")
    }

    // MARK: - The identity that licenses leaving the save pipeline alone

    /// For **every** input, classifying attachments must not change the
    /// serialized document. If this ever fails, `canonicalMarkdown`,
    /// `draftSyncDecision`, `markdownSurvivesRoundTrip` and the save
    /// coordinator's comparisons — all of which parse without an origin — can no
    /// longer be trusted to agree with what the editor holds, and a conflict
    /// would be raised (or missed) on a difference that isn't real.
    func testAttachmentClassificationNeverChangesSerializedMarkdown() {
        let corpus = [
            "[f](\(url()))",
            "[](\(url()))",
            "Intro\n\n[f](\(url()))\n\nOutro",
            "Attached:\n[f](\(url()))",
            "[f](\(url()))\n[g](\(url("docx")))",
            "- [f](\(url()))",
            "> [f](\(url()))",
            "# [f](\(url()))",
            "    [f](\(url()))",
            "[f](\(url())) and more",
            "![a](\(url("png")))",
            "```\n[f](\(url()))\n```",
            "| [f](\(url())) |",
            "Plain prose with no links at all.",
            "",
            "\n\n",
        ]
        for markdown in corpus {
            XCTAssertEqual(
                serializeMarkdown(parseEditorBlocks(markdown, serverOrigin: serverOrigin)),
                serializeMarkdown(parseEditorBlocks(markdown)),
                "classification changed the serialized document for: \(markdown.debugDescription)")
        }
    }

    /// The same property stated the other way: the *canonical* form the sync
    /// machinery compares on is origin-insensitive.
    func testCanonicalMarkdownIsUnaffectedByClassification() {
        let markdown = "Intro\n\n[f](\(url()))\n\nOutro"
        let classified = serializeMarkdown(parseEditorBlocks(markdown, serverOrigin: serverOrigin))
        let plain = serializeMarkdown(parseEditorBlocks(markdown))
        XCTAssertEqual(classified, plain)
        XCTAssertTrue(markdownSurvivesRoundTrip(markdown, serverOrigin: serverOrigin))
        XCTAssertTrue(markdownSurvivesRoundTrip(markdown))
    }

    // MARK: - Leaf semantics

    func testAnAttachmentNeverRendersInlineMarkdown() {
        XCTAssertFalse(rendersInlineMarkdown(.attachment(name: "f", url: url())))
    }

    func testTwoAttachmentsDifferingOnlyInNameAreNotEqual() {
        XCTAssertNotEqual(
            BlockKind.attachment(name: "a", url: url()), BlockKind.attachment(name: "b", url: url()))
    }
}
