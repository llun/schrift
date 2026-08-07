import XCTest

@testable import Schrift

final class MarkdownParserTests: XCTestCase {
    private func assertParses(
        _ markdown: String,
        _ expected: [EditorBlock],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let parsed = parseEditorBlocks(markdown)
        XCTAssertTrue(
            blocksContentEqual(parsed, expected),
            "Parsed \(parsed.map { "\($0.kind): \"\($0.text)\"" }) but expected \(expected.map { "\($0.kind): \"\($0.text)\"" })",
            file: file,
            line: line
        )
    }

    // MARK: - Ported from the original line-based parser

    func testParsesParagraph() {
        assertParses("Hello world", [EditorBlock(kind: .paragraph, text: "Hello world")])
    }

    func testParsesHeadingLevels() {
        assertParses("# Title", [EditorBlock(kind: .heading(level: 1), text: "Title")])
        assertParses("## Subtitle", [EditorBlock(kind: .heading(level: 2), text: "Subtitle")])
        assertParses("###### Deep", [EditorBlock(kind: .heading(level: 6), text: "Deep")])
    }

    func testHeadingRequiresSpaceAfterHashes() {
        assertParses("#NoSpace", [EditorBlock(kind: .paragraph, text: "#NoSpace")])
    }

    func testParsesBulletItemsWithDashOrAsterisk() {
        assertParses("- Item one", [EditorBlock(kind: .bulletItem, text: "Item one")])
        assertParses("* Item two", [EditorBlock(kind: .bulletItem, text: "Item two")])
    }

    func testParsesUncheckedChecklistItem() {
        assertParses("- [ ] Task", [EditorBlock(kind: .checklistItem(checked: false), text: "Task")])
    }

    func testParsesCheckedChecklistItemLowercaseAndUppercase() {
        assertParses("- [x] Done", [EditorBlock(kind: .checklistItem(checked: true), text: "Done")])
        assertParses("- [X] Done", [EditorBlock(kind: .checklistItem(checked: true), text: "Done")])
    }

    func testChecklistIsDistinguishedFromPlainBullet() {
        assertParses(
            "- [ ] Task\n- Not a checklist item",
            [
                EditorBlock(kind: .checklistItem(checked: false), text: "Task"),
                EditorBlock(kind: .bulletItem, text: "Not a checklist item"),
            ])
    }

    func testParsesQuote() {
        assertParses("> Quoted text", [EditorBlock(kind: .quote, text: "Quoted text")])
    }

    func testQuotePreservesLeadingWhitespaceBeyondTheMarkerSpace() {
        // ">     code" is indented code inside a blockquote — the marker eats
        // exactly one space; the rest is significant content.
        assertParses(">     let x = 1", [EditorBlock(kind: .quote, text: "    let x = 1")])
        XCTAssertTrue(
            blocksContentEqual(
                parseEditorBlocks(serializeMarkdown([EditorBlock(kind: .quote, text: "  indented")])),
                [EditorBlock(kind: .quote, text: "  indented")]
            ))
    }

    func testParsesMultipleBlocksInOrder() {
        let markdown = """
            # Heading

            A paragraph.

            - Bullet one
            - [ ] Checklist item
            > A quote
            """
        assertParses(
            markdown,
            [
                EditorBlock(kind: .heading(level: 1), text: "Heading"),
                EditorBlock(kind: .paragraph, text: "A paragraph."),
                EditorBlock(kind: .bulletItem, text: "Bullet one"),
                EditorBlock(kind: .checklistItem(checked: false), text: "Checklist item"),
                EditorBlock(kind: .quote, text: "A quote"),
            ])
    }

    func testEmptyLinesAreSkipped() {
        assertParses(
            "\n\nHello\n\n\nWorld\n",
            [
                EditorBlock(kind: .paragraph, text: "Hello"),
                EditorBlock(kind: .paragraph, text: "World"),
            ])
    }

    func testEmptyStringProducesNoBlocks() {
        assertParses("", [])
    }

    // MARK: - Ordered lists

    func testParsesNumberedItemsWithDotOrParenMarkers() {
        assertParses("1. First", [EditorBlock(kind: .numberedItem, text: "First")])
        assertParses("2) Second", [EditorBlock(kind: .numberedItem, text: "Second")])
        assertParses("42. Forty-second", [EditorBlock(kind: .numberedItem, text: "Forty-second")])
    }

    func testNumberedItemRequiresSpaceAfterMarker() {
        assertParses("1.First", [EditorBlock(kind: .paragraph, text: "1.First")])
    }

    // MARK: - Code fences

    func testParsesCodeFenceWithLanguage() {
        assertParses(
            "```swift\nlet answer = 42\n```",
            [
                EditorBlock(kind: .codeBlock(language: "swift"), text: "let answer = 42")
            ])
    }

    func testParsesCodeFenceWithoutLanguage() {
        assertParses(
            "```\nplain code\n```",
            [
                EditorBlock(kind: .codeBlock(language: ""), text: "plain code")
            ])
    }

    func testCodeFencePreservesBlankLinesAndIndentation() {
        assertParses(
            "```\nline one\n\n    indented\n```",
            [
                EditorBlock(kind: .codeBlock(language: ""), text: "line one\n\n    indented")
            ])
    }

    func testUnclosedCodeFenceKeepsRemainingContent() {
        assertParses(
            "```\nno closing fence\nstill code",
            [
                EditorBlock(kind: .codeBlock(language: ""), text: "no closing fence\nstill code")
            ])
    }

    func testLongerFenceContainsTripleBacktickContent() {
        assertParses(
            "````\n```\ninner fence\n```\n````",
            [
                EditorBlock(kind: .codeBlock(language: ""), text: "```\ninner fence\n```")
            ])
    }

    // MARK: - Dividers

    func testParsesDividers() {
        assertParses("---", [EditorBlock(kind: .divider)])
        assertParses("***", [EditorBlock(kind: .divider)])
        assertParses("___", [EditorBlock(kind: .divider)])
        assertParses("-----", [EditorBlock(kind: .divider)])
    }

    func testTwoDashesAreNotADivider() {
        assertParses("--", [EditorBlock(kind: .paragraph, text: "--")])
    }

    // MARK: - Unknown passthrough

    func testIndentedListLineIsPreservedVerbatimAsUnknown() {
        assertParses("  - nested item", [EditorBlock(kind: .unknown, text: "  - nested item")])
    }

    func testTableLinesGroupIntoOneUnknownBlock() {
        let table = "| Name | Role |\n| --- | --- |\n| Ana | Dev |"
        assertParses(table, [EditorBlock(kind: .unknown, text: table)])
    }

    // MARK: - Standalone images

    func testStandaloneImageLineBecomesImageBlock() {
        assertParses(
            "![diagram](https://example.com/d.png)",
            [EditorBlock(kind: .image(alt: "diagram", url: "https://example.com/d.png"))])
    }

    func testImageWithEmptyAltBecomesImageBlock() {
        assertParses(
            "![](https://example.com/d.png)",
            [EditorBlock(kind: .image(alt: "", url: "https://example.com/d.png"))])
    }

    func testImageWithRelativeURLStaysUnknown() {
        assertParses("![x](/media/a.png)", [EditorBlock(kind: .unknown, text: "![x](/media/a.png)")])
    }

    func testImageWithNonHTTPSchemeStaysUnknown() {
        assertParses(
            "![x](javascript:alert(1))",
            [EditorBlock(kind: .unknown, text: "![x](javascript:alert(1))")])
        assertParses(
            "![x](file:///etc/passwd)",
            [EditorBlock(kind: .unknown, text: "![x](file:///etc/passwd)")])
    }

    func testImageWithEmptyURLStaysUnknown() {
        // "![alt]()" is also the tightest index-arithmetic case: the url slice is
        // an empty range sitting exactly on the closing paren.
        assertParses("![alt]()", [EditorBlock(kind: .unknown, text: "![alt]()")])
    }

    func testImageURLContainingBracketStaysUnknown() {
        // The alt/url split takes the *first* "](", so a "]" inside the url means
        // the split was ambiguous. Same corruption class as an unbalanced ")".
        assertParses(
            "![a](https://e.com/x](y)",
            [EditorBlock(kind: .unknown, text: "![a](https://e.com/x](y)")])
    }

    func testLegitimateAttachmentURLsAreNotRejectedByTheGuards() {
        // Guard against false negatives: percent-encoding, a query with balanced
        // parens, and the Django backend's real attachment url shape.
        assertParses(
            "![a](https://e.com/a%20b.png)",
            [EditorBlock(kind: .image(alt: "a", url: "https://e.com/a%20b.png"))])
        assertParses(
            "![a](https://e.com/a.png?x=(1))",
            [EditorBlock(kind: .image(alt: "a", url: "https://e.com/a.png?x=(1)"))])
        assertParses(
            "![a](HTTPS://e.com/a.png)",
            [EditorBlock(kind: .image(alt: "a", url: "HTTPS://e.com/a.png"))])
    }

    func testImageWithTrailingTextStaysUnknown() {
        assertParses(
            "![x](https://e.com/a.png) tail",
            [EditorBlock(kind: .unknown, text: "![x](https://e.com/a.png) tail")])
    }

    func testIndentedImageStaysUnknown() {
        assertParses(
            "  ![x](https://e.com/a.png)",
            [EditorBlock(kind: .unknown, text: "  ![x](https://e.com/a.png)")])
    }

    func testImageAltWithBracketStaysUnknown() {
        assertParses(
            "![a]b](https://e.com/a.png)",
            [EditorBlock(kind: .unknown, text: "![a]b](https://e.com/a.png)")])
    }

    func testImageAltWithSpacesAndParenthesesBecomesImageBlock() {
        // A downloaded-file name like "photo (1).png" is a common real alt.
        assertParses(
            "![photo (1).png](https://docs.example.com/a.png)",
            [EditorBlock(kind: .image(alt: "photo (1).png", url: "https://docs.example.com/a.png"))])
    }

    func testImageURLWithBalancedParenthesesBecomesImageBlock() {
        assertParses(
            "![a](https://e.com/x(1).png)",
            [EditorBlock(kind: .image(alt: "a", url: "https://e.com/x(1).png"))])
    }

    func testImageURLWithUnbalancedParenthesesStaysUnknown() {
        // CommonMark ends the destination at the first unbalanced ")", leaving
        // "(y)" as literal text. Our column-zero classifier takes the *last* ")",
        // so without a balance check this would save a mangled url and silently
        // drop the trailing "(y)". Anything ambiguous must stay verbatim.
        assertParses(
            "![a](https://e.com/x.png)(y)",
            [EditorBlock(kind: .unknown, text: "![a](https://e.com/x.png)(y)")])
    }

    func testImageURLWithWhitespaceStaysUnknown() {
        assertParses(
            "![a](https://e.com/a b.png)",
            [EditorBlock(kind: .unknown, text: "![a](https://e.com/a b.png)")])
    }

    func testImageInsideProseRunSplitsTheRun() {
        // Classifying the image line flushes the pending prose run, so a
        // web-authored image between two prose lines becomes its own block
        // instead of being swallowed into one verbatim `.unknown` run.
        assertParses(
            "line one\n![img](https://e.com/a.png)\nline two",
            [
                EditorBlock(kind: .paragraph, text: "line one"),
                EditorBlock(kind: .image(alt: "img", url: "https://e.com/a.png")),
                EditorBlock(kind: .paragraph, text: "line two"),
            ])
    }

    func testHTMLLineBecomesUnknown() {
        assertParses("<div>widget</div>", [EditorBlock(kind: .unknown, text: "<div>widget</div>")])
    }

    func testMultiLineParagraphRunBecomesOneUnknownBlock() {
        assertParses("line one\nline two", [EditorBlock(kind: .unknown, text: "line one\nline two")])
    }

    func testUnknownRunEndsAtClassifiedLine() {
        assertParses(
            "  indented\n- bullet",
            [
                EditorBlock(kind: .unknown, text: "  indented"),
                EditorBlock(kind: .bulletItem, text: "bullet"),
            ])
    }

    func testNestedListUnderBulletIsPreserved() {
        assertParses(
            "- top\n  - nested\n  - nested two",
            [
                EditorBlock(kind: .bulletItem, text: "top"),
                EditorBlock(kind: .unknown, text: "  - nested\n  - nested two"),
            ])
    }

    func testCRLFLineEndingsParseLikeLF() {
        assertParses(
            "# Title\r\n\r\nBody text.",
            [
                EditorBlock(kind: .heading(level: 1), text: "Title"),
                EditorBlock(kind: .paragraph, text: "Body text."),
            ])
        // CRLF must not split a multi-line run apart with phantom blank lines.
        assertParses("line one\r\nline two", [EditorBlock(kind: .unknown, text: "line one\nline two")])
        XCTAssertTrue(markdownSurvivesRoundTrip("- item one\r\n- item two\r\n"))
    }

    // MARK: - Round-trip survival gate

    func testRealisticDocumentSurvivesRoundTrip() {
        let markdown = """
            # Project kickoff

            Welcome to the team documentation.

            - First item
            - Second item

            1. Step one
            2. Step two

            - [ ] Draft the spec
            - [x] Review the design

            > Remember to sync with the web team.

            ```swift
            let answer = 42
            ```

            | Name | Role |
            | --- | --- |
            | Ana | Dev |

            ![diagram](https://example.com/d.png)

            ---

            Done.
            """
        XCTAssertTrue(markdownSurvivesRoundTrip(markdown))
    }

    func testLoneOpeningFenceFailsRoundTripGate() {
        // An unclosed fence gains a closing fence line on serialize.
        XCTAssertFalse(markdownSurvivesRoundTrip("```"))
    }

    // MARK: - Pending attachment placeholders

    private var placeholderID: UUID { UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")! }
    private var placeholder: String { pendingAttachmentPlaceholderURL(for: placeholderID) }

    func testPendingAttachmentPlaceholderBecomesAnImageBlock() {
        // It has to classify, or `addsImage` — which verifies an insertion by re-parsing and
        // counting `.image` blocks — reports every queued photo as a failed insert, and the
        // resulting `.unknown` block drops the document out of live-write eligibility.
        assertParses("![](\(placeholder))", [EditorBlock(kind: .image(alt: "", url: placeholder))])
        assertParses("![Ana](\(placeholder))", [EditorBlock(kind: .image(alt: "Ana", url: placeholder))])
    }

    func testPendingAttachmentPlaceholderSurvivesTheRoundTripGate() {
        XCTAssertTrue(markdownSurvivesRoundTrip("Before\n\n![](\(placeholder))\n\nAfter"))
    }

    func testMarkdownReferencesPendingAttachmentSeesAnImageBlock() {
        XCTAssertTrue(markdownReferencesPendingAttachment("![](\(placeholder))"))
        XCTAssertTrue(markdownReferencesPendingAttachment("Text\n\n![a](\(placeholder))\n\nMore"))
    }

    func testMarkdownReferencesPendingAttachmentIgnoresOrdinaryContent() {
        XCTAssertFalse(markdownReferencesPendingAttachment(""))
        XCTAssertFalse(markdownReferencesPendingAttachment("![a](https://example.com/a.png)"))
        XCTAssertFalse(markdownReferencesPendingAttachment("Just a paragraph."))
    }

    func testMarkdownReferencesPendingAttachmentIgnoresAMentionThatIsNotAnImageBlock() {
        // The predicate holds a document's saves, and the only escape from that hold is
        // deleting the image leaf. A substring test would hold a document forever because
        // someone quoted the scheme in a code block — where there is no leaf to delete.
        XCTAssertFalse(markdownReferencesPendingAttachment("```\n![](\(placeholder))\n```"))
        XCTAssertFalse(markdownReferencesPendingAttachment("Type `\(placeholder)` to see it."))
        XCTAssertFalse(markdownReferencesPendingAttachment("A line mentioning \(placeholder) inline."))
        // Indented, so the image is `.unknown` rather than a block — nothing to resolve.
        XCTAssertFalse(markdownReferencesPendingAttachment("    ![](\(placeholder))"))
    }

    func testRewritingAPlaceholderReplacesOnlyThatImageDestination() {
        let resolved = "https://docs.example.org/media/key.jpg"
        let source = "# Title\n\n![Ana](\(placeholder))\n\nAfter"

        XCTAssertEqual(
            markdownRewritingPendingAttachment(source, localID: placeholderID, resolvedURL: resolved),
            "# Title\n\n![Ana](\(resolved))\n\nAfter")
    }

    func testRewritingLeavesOtherPlaceholdersAndOrdinaryImagesAlone() {
        let other = pendingAttachmentPlaceholderURL(for: UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!)
        let resolved = "https://docs.example.org/media/key.jpg"
        let source = "![](\(placeholder))\n\n![](\(other))\n\n![](https://example.com/a.png)"

        // A document with two queued photos resolves one at a time; the second placeholder is
        // what keeps the save held until its own upload lands.
        XCTAssertEqual(
            markdownRewritingPendingAttachment(source, localID: placeholderID, resolvedURL: resolved),
            "![](\(resolved))\n\n![](\(other))\n\n![](https://example.com/a.png)")
    }

    func testRewritingSkipsFencedAndInlineMentions() {
        let resolved = "https://docs.example.org/media/key.jpg"
        let source = "```\n![](\(placeholder))\n```\n\nSee \(placeholder) above."

        XCTAssertEqual(
            markdownRewritingPendingAttachment(source, localID: placeholderID, resolvedURL: resolved),
            source)
    }

    func testRewritingPreservesEveryOtherByteIncludingLineEndings() {
        let resolved = "https://docs.example.org/media/key.jpg"
        // Non-canonical markdown a draft can genuinely hold (server-authored bullets, blank-line
        // runs, CRLF). A parse-and-re-serialize rewrite would canonicalize all of it from a
        // background pass — content the user never touched.
        let source = "* one\r\n* two\r\n\r\n\r\n![](\(placeholder))\r\n\r\n3) three   "

        XCTAssertEqual(
            markdownRewritingPendingAttachment(source, localID: placeholderID, resolvedURL: resolved),
            "* one\r\n* two\r\n\r\n\r\n![](\(resolved))\r\n\r\n3) three   ")
    }

    func testRewritingLeavesTheAltTextAloneWhenItSpellsThePlaceholder() {
        let resolved = "https://docs.example.org/media/key.jpg"

        XCTAssertEqual(
            markdownRewritingPendingAttachment(
                "![\(placeholder)](\(placeholder))", localID: placeholderID, resolvedURL: resolved),
            "![\(placeholder)](\(resolved))")
    }

    func testRewritingAnAbsentPlaceholderIsAnIdentity() {
        let source = "# Title\n\n![](https://example.com/a.png)"
        XCTAssertEqual(
            markdownRewritingPendingAttachment(
                source, localID: placeholderID, resolvedURL: "https://docs.example.org/media/key.jpg"),
            source)
    }

    func testAPlaceholderSchemeThatNamesNoRecordStaysUnknown() {
        // The classification and the hold must agree by construction. A URL carrying the app's
        // privileged scheme but a shape `pendingAttachmentID` does not recognise would otherwise
        // be a real `.image` block that no hold engages on — pushed to the server as a URL no
        // client can resolve. Falling to `.unknown` round-trips it verbatim instead.
        let uuid = "11111111-1111-4111-8111-111111111111"
        for url in [
            "schrift-attachment://\(uuid)?x=1",
            "schrift-attachment:\(uuid)",
            "schrift-attachment://\(uuid)/x",
            "schrift-attachment:///\(uuid)",
            "schrift-attachment://not-a-uuid",
        ] {
            assertParses("![a](\(url))", [EditorBlock(kind: .unknown, text: "![a](\(url))")])
            XCTAssertFalse(markdownReferencesPendingAttachment("![a](\(url))"), "should not hold: \(url)")
        }
    }

    func testEveryPlaceholderImageBlockIsHeldByThePredicate() {
        // The invariant the two functions exist to keep: if it classifies as an image with our
        // scheme, the hold engages. Anything else is a leak.
        for url in [
            pendingAttachmentPlaceholderURL(for: placeholderID),
            "SCHRIFT-ATTACHMENT://\(placeholderID.uuidString.lowercased())",
            "schrift-attachment://\(placeholderID.uuidString)",
            "schrift-attachment://\(placeholderID.uuidString.lowercased())/",
        ] {
            let source = "![a](\(url))"
            let blocks = parseEditorBlocks(source)
            guard case .image = blocks.first?.kind else { continue }
            XCTAssertTrue(markdownReferencesPendingAttachment(source), "classified but unheld: \(url)")
        }
    }

    func testAnUppercaseSchemeIsHeldRatherThanPushed() {
        // `parseImageLine` classifies on `scheme?.lowercased()`, so this IS an image block. A
        // case-sensitive predicate would answer false, the hold would not engage, and the
        // placeholder would go to the server — the leak direction, opposite to the wedge below.
        let shouty = "SCHRIFT-ATTACHMENT://\(placeholderID.uuidString.lowercased())"
        assertParses("![](\(shouty))", [EditorBlock(kind: .image(alt: "", url: shouty))])

        XCTAssertTrue(markdownReferencesPendingAttachment("![](\(shouty))"))
        XCTAssertEqual(pendingAttachmentID(fromPlaceholderURL: shouty), placeholderID)
    }

    func testAnUppercaseSchemeIsAlsoRewritable() {
        // Held and rewritable must be the same set: held-but-not-rewritable is a permanent wedge.
        let shouty = "SCHRIFT-ATTACHMENT://\(placeholderID.uuidString.lowercased())"
        let resolved = "https://docs.example.org/media/key.jpg"

        let rewritten = markdownRewritingPendingAttachment(
            "![](\(shouty))", localID: placeholderID, resolvedURL: resolved)

        XCTAssertEqual(rewritten, "![](\(resolved))")
        XCTAssertFalse(markdownReferencesPendingAttachment(rewritten))
    }

    func testRewritingMatchesEverySpellingThePredicateHoldsOn() {
        // The predicate resolves a placeholder to a *record*, tolerating either case and a
        // trailing slash. A rewriter keyed on the canonical URL's bytes would hold a document on
        // these and never be able to release it — the two must agree on identity.
        let resolved = "https://docs.example.org/media/key.jpg"
        for spelling in [
            "schrift-attachment://\(placeholderID.uuidString)",
            "schrift-attachment://\(placeholderID.uuidString.lowercased())/",
        ] {
            let source = "![](\(spelling))"
            XCTAssertTrue(markdownReferencesPendingAttachment(source), "should hold: \(spelling)")
            let rewritten = markdownRewritingPendingAttachment(
                source, localID: placeholderID, resolvedURL: resolved)
            XCTAssertEqual(rewritten, "![](\(resolved))", "should rewrite: \(spelling)")
            XCTAssertFalse(markdownReferencesPendingAttachment(rewritten))
        }
    }

    func testRewritingLeavesADifferentRecordsPlaceholderAlone() {
        let other = UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!
        let source = "![](\(pendingAttachmentPlaceholderURL(for: other)))"

        XCTAssertEqual(
            markdownRewritingPendingAttachment(
                source, localID: placeholderID, resolvedURL: "https://docs.example.org/media/key.jpg"),
            source)
    }

    func testRewritingAgreesWithTheParserOnCROnlyLineEndings() {
        // `parseEditorBlocks` normalizes a lone CR to LF, so the predicate sees an image block
        // here. A rewriter splitting on "\n" alone would see one unparseable line and leave the
        // placeholder in place — held forever.
        let resolved = "https://docs.example.org/media/key.jpg"
        let source = "Before\r![](\(placeholder))\rAfter"

        XCTAssertTrue(markdownReferencesPendingAttachment(source))
        let rewritten = markdownRewritingPendingAttachment(source, localID: placeholderID, resolvedURL: resolved)
        XCTAssertEqual(rewritten, "Before\r![](\(resolved))\rAfter")
        XCTAssertFalse(markdownReferencesPendingAttachment(rewritten))
    }

    func testARewrittenDocumentNoLongerReferencesThePendingAttachment() {
        // The property the replay's conditional record removal rests on.
        let source = "![](\(placeholder))\n\nText"
        let rewritten = markdownRewritingPendingAttachment(
            source, localID: placeholderID, resolvedURL: "https://docs.example.org/media/key.jpg")

        XCTAssertTrue(markdownReferencesPendingAttachment(source))
        XCTAssertFalse(markdownReferencesPendingAttachment(rewritten))
    }
}
