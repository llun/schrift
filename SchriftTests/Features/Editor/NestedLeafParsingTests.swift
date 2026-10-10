import XCTest

@testable import Schrift

/// Images, attachments and link lines nested under a list item (`parseNestedLeaf`,
/// `serializeMarkdown`'s nested-leaf branch).
///
/// The app writes a nested leaf tightly at its parent's content column; the
/// server's markdown export flattens it to a column-zero line after a blank one.
/// The first must read back nested and the second must keep reading flat — and
/// whether a line nests must never depend on the server origin, only what kind
/// of block it becomes.
final class NestedLeafParsingTests: XCTestCase {
    private let origin = "https://docs.example.test"
    private let media = "https://docs.example.test/media/11111111-1111-4111-8111-111111111111/attachments/"
    private var image: String { media + "22222222-2222-4222-8222-222222222222.jpg" }
    private var pdf: String { media + "33333333-3333-4333-8333-333333333333.pdf" }

    private func assertParses(
        _ markdown: String, origin: String = "", _ expected: [EditorBlock], file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let parsed = parseEditorBlocks(markdown, serverOrigin: origin)
        XCTAssertTrue(
            blocksContentEqual(parsed, expected),
            "Parsed \(parsed.map { "\($0.kind)@\($0.indent): \"\($0.text)\"" })",
            file: file, line: line)
    }

    private func task(_ text: String, checked: Bool = false, _ indent: Int = 0) -> EditorBlock {
        EditorBlock(kind: .checklistItem(checked: checked), text: text, indent: indent)
    }

    private var appSpelling: String {
        "- [ ] Task\n  ![photo.jpg](\(image))\n  [report.pdf](\(pdf))\n- [ ] Next\n"
    }

    // MARK: - Classification

    func testTheAppSpellingNestsAnImageAndAnAttachmentUnderTheItem() {
        assertParses(
            appSpelling, origin: origin,
            [
                task("Task"),
                EditorBlock(kind: .image(alt: "photo.jpg", url: image), indent: 1),
                EditorBlock(kind: .attachment(name: "report.pdf", url: pdf), indent: 1),
                task("Next"),
            ])
    }

    /// Without an origin the link line is a paragraph carrying the link — nested
    /// all the same. Structure is decided by shape alone.
    func testWithoutAnOriginTheLinkLineNestsAsAParagraph() {
        assertParses(
            appSpelling,
            [
                task("Task"),
                EditorBlock(kind: .image(alt: "photo.jpg", url: image), indent: 1),
                EditorBlock(kind: .paragraph, text: "[report.pdf](\(pdf))", indent: 1),
                task("Next"),
            ])
    }

    func testAnOffOriginLinkNestsAsAParagraph() {
        assertParses(
            "- a\n  [site](https://example.com/x)", origin: origin,
            [
                EditorBlock(kind: .bulletItem, text: "a"),
                EditorBlock(kind: .paragraph, text: "[site](https://example.com/x)", indent: 1),
            ])
    }

    func testALeafAndANestedItemAfterItAreSiblings() {
        assertParses(
            "- a\n  ![p](\(image))\n  - b\n- c",
            [
                EditorBlock(kind: .bulletItem, text: "a"),
                EditorBlock(kind: .image(alt: "p", url: image), indent: 1),
                EditorBlock(kind: .bulletItem, text: "b", indent: 1),
                EditorBlock(kind: .bulletItem, text: "c"),
            ])
    }

    func testALeafNestsUnderWhicheverOpenItemsColumnItSitsAt() {
        assertParses(
            "- a\n  - b\n    ![deep](\(image))\n  ![shallow](\(image))",
            [
                EditorBlock(kind: .bulletItem, text: "a"),
                EditorBlock(kind: .bulletItem, text: "b", indent: 1),
                EditorBlock(kind: .image(alt: "deep", url: image), indent: 2),
                EditorBlock(kind: .image(alt: "shallow", url: image), indent: 1),
            ])
    }

    func testANumberedItemsLeafSitsAtItsThreeColumnContentColumn() {
        let markdown = "1. a\n   ![p](\(image))\n2. b\n"
        let blocks = parseEditorBlocks(markdown)
        XCTAssertTrue(
            blocksContentEqual(
                blocks,
                [
                    EditorBlock(kind: .numberedItem, text: "a"),
                    EditorBlock(kind: .image(alt: "p", url: image), indent: 1),
                    EditorBlock(kind: .numberedItem, text: "b"),
                ]))
        // A photo under item 1 does not restart the count for item 2.
        XCTAssertEqual(numberedIndex(of: 2, in: blocks), 2)
        XCTAssertEqual(serializeMarkdown(blocks), markdown)
    }

    // MARK: - What stays as it was

    /// The server's export flattens a nested leaf: a blank line, then column zero.
    /// That shape must keep parsing flat.
    func testTheServersFlattenedExportStaysFlat() {
        let export = "* [ ] Task\n\n![photo.jpg](\(image))\n\n[report.pdf](\(pdf))\n\n* [ ] Next\n"
        let blocks = parseEditorBlocks(export, serverOrigin: origin)
        XCTAssertEqual(
            blocks.map(\.kind),
            [
                .checklistItem(checked: false), .image(alt: "photo.jpg", url: image),
                .attachment(name: "report.pdf", url: pdf), .checklistItem(checked: false),
            ])
        XCTAssertEqual(blocks.map(\.indent), [0, 0, 0, 0])
    }

    func testOnlyTheExactContentColumnNests() {
        for spaces in [1, 3, 4] {
            let line = String(repeating: " ", count: spaces) + "![p](\(image))"
            assertParses(
                "- a\n" + line,
                [EditorBlock(kind: .bulletItem, text: "a"), EditorBlock(kind: .unknown, text: line)])
        }
    }

    func testATabBlankLineOrProseAboveKeepsTheLineVerbatim() {
        assertParses(
            "- a\n\t![p](\(image))",
            [EditorBlock(kind: .bulletItem, text: "a"), EditorBlock(kind: .unknown, text: "\t![p](\(image))")])
        assertParses(
            "- a\n\n  ![p](\(image))",
            [EditorBlock(kind: .bulletItem, text: "a"), EditorBlock(kind: .unknown, text: "  ![p](\(image))")])
        assertParses(
            "Intro\n  ![p](\(image))", [EditorBlock(kind: .unknown, text: "Intro\n  ![p](\(image))")])
    }

    /// A line that could be a lazy continuation of the leaf's line — indented or
    /// column-zero prose — makes the whole run verbatim, exactly as before nested
    /// leaves existed. A leaf is never classified while a sibling after it is not.
    func testALazyContinuationKeepsTheWholeRunVerbatim() {
        assertParses(
            "- a\n  ![p](\(image))\n  more text",
            [
                EditorBlock(kind: .bulletItem, text: "a"),
                EditorBlock(kind: .unknown, text: "  ![p](\(image))\n  more text"),
            ])
        assertParses(
            "- a\n  ![p](\(image))\nlazy",
            [EditorBlock(kind: .bulletItem, text: "a"), EditorBlock(kind: .unknown, text: "  ![p](\(image))\nlazy")])
        assertParses(
            "- a\n  ![p](\(image))\n  [r](\(pdf))\n  prose",
            [
                EditorBlock(kind: .bulletItem, text: "a"),
                EditorBlock(kind: .unknown, text: "  ![p](\(image))\n  [r](\(pdf))\n  prose"),
            ])
    }

    func testALinkWithTrailingProseIsNotALeaf() {
        assertParses(
            "- a\n  [r](\(pdf)) and more",
            [
                EditorBlock(kind: .bulletItem, text: "a"),
                EditorBlock(kind: .unknown, text: "  [r](\(pdf)) and more"),
            ])
    }

    func testALeafDeeperThanTheMaximumStaysVerbatim() {
        var markdown = "- l0"
        for depth in 1...maxListIndent {
            markdown += "\n" + String(repeating: " ", count: depth * 2) + "- l\(depth)"
        }
        // The deepest item's content column would nest the leaf one level too deep.
        let tooDeep = String(repeating: " ", count: maxListIndent * 2 + 2) + "![p](\(image))"
        let parsed = parseEditorBlocks(markdown + "\n" + tooDeep)
        XCTAssertEqual(parsed.last?.kind, .unknown)
        XCTAssertEqual(parsed.last?.text, tooDeep)

        // One level shallower is exactly the maximum, and nests.
        let deepest = String(repeating: " ", count: maxListIndent * 2) + "![p](\(image))"
        let atMaximum = parseEditorBlocks(markdown + "\n" + deepest)
        XCTAssertEqual(atMaximum.last?.kind, .image(alt: "p", url: image))
        XCTAssertEqual(atMaximum.last?.indent, maxListIndent)
    }

    // MARK: - Serialization and the round trip

    func testTheAppSpellingIsAFixedPointOfTheRoundTrip() {
        for serverOrigin in ["", origin] {
            let once = serializeMarkdown(parseEditorBlocks(appSpelling, serverOrigin: serverOrigin))
            XCTAssertEqual(once, appSpelling)
            XCTAssertTrue(markdownSurvivesRoundTrip(appSpelling, serverOrigin: serverOrigin))
        }
    }

    func testANestedLeafIsWrittenAtItsParentsContentColumn() {
        let blocks = [
            EditorBlock(kind: .bulletItem, text: "a"),
            EditorBlock(kind: .numberedItem, text: "b", indent: 1),
            EditorBlock(kind: .image(alt: "p", url: image), indent: 2),
            EditorBlock(kind: .attachment(name: "r", url: pdf), indent: 1),
            EditorBlock(kind: .bulletItem, text: "c"),
        ]
        let markdown = serializeMarkdown(blocks)
        XCTAssertEqual(markdown, "- a\n  1. b\n     ![p](\(image))\n  [r](\(pdf))\n- c\n")
        XCTAssertEqual(parseEditorBlocks(markdown, serverOrigin: origin).map(\.indent), [0, 1, 2, 1, 0])
    }

    /// Anything that is not a list line after a nested leaf is separated by a
    /// blank line, or it would read back as a lazy continuation of the leaf.
    func testWhatFollowsANestedLeafAtTheTopLevelGetsABlankLine() {
        let blocks = [
            task("Task"),
            EditorBlock(kind: .image(alt: "p", url: image), indent: 1),
            EditorBlock(kind: .paragraph, text: "After"),
            EditorBlock(kind: .image(alt: "flat", url: image)),
        ]
        let markdown = serializeMarkdown(blocks)
        XCTAssertEqual(markdown, "- [ ] Task\n  ![p](\(image))\n\nAfter\n\n![flat](\(image))\n")
        XCTAssertTrue(blocksContentEqual(parseEditorBlocks(markdown), blocks))
    }

    func testAnIndentedVerbatimLeafSurvivesTheRoundTripGate() {
        XCTAssertTrue(markdownSurvivesRoundTrip("- a\n   ![p](\(image))"))
        XCTAssertTrue(markdownSurvivesRoundTrip("Intro\n  [r](\(pdf))"))
        XCTAssertTrue(markdownSurvivesRoundTrip("- a\n  ![p](\(image))\n  more text"))
    }

    // MARK: - Queued photos

    private var placeholderID: UUID { UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")! }

    /// A queued photo nested under an item is held, and both the rewriter and the
    /// remover find it — held-but-not-rewritable is a permanent save wedge.
    func testANestedQueuedPhotoIsHeldRewrittenAndRemovable() {
        let placeholder = pendingAttachmentPlaceholderURL(for: placeholderID)
        let source = "- [ ] Task\n  ![](\(placeholder))\n- [ ] Next"
        XCTAssertEqual(parseEditorBlocks(source)[1].indent, 1)
        XCTAssertTrue(markdownReferencesPendingAttachment(source))
        XCTAssertTrue(markdownReferencesPendingAttachment(source, localID: placeholderID))

        let rewritten = markdownRewritingPendingAttachment(source, localID: placeholderID, resolvedURL: image)
        XCTAssertEqual(rewritten, "- [ ] Task\n  ![](\(image))\n- [ ] Next")
        XCTAssertFalse(markdownReferencesPendingAttachment(rewritten))

        XCTAssertEqual(
            markdownRemovingPendingAttachment(source, localID: placeholderID), "- [ ] Task\n- [ ] Next")
    }
}
