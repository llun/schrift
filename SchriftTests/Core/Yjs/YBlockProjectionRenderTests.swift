import XCTest

@testable import Schrift

/// Tests for `YBlockProjection.editorBlock`/`projectedMarkdown` — B5 Task 4:
/// the render side of the read projection, and the self-verifying whole-
/// document markdown that round-trips through the editor's own
/// `parseEditorBlocks`/`serializeMarkdown` pair.
///
/// `testRoundTripsCanonicalCorpus` is THE load-bearing test: for every
/// markdown literal in the corpus, projecting it through the Yjs replica and
/// rendering it back must produce the *exact* string
/// `serializeMarkdown(parseEditorBlocks(md))` would — i.e. going all the way
/// out to a `YDoc` and back is invisible to a caller who only has the
/// original markdown, except at the two documented, unavoidable
/// canonicalization points (a bare code fence, and `*italic*` vs `_italic_`),
/// which are spelled out explicitly rather than loosened to a substring
/// check.
final class YBlockProjectionRenderTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a replica from markdown via the same pipeline a save uses
    /// (`MarkdownYjs.encode` → `YUpdateDecoder.decode` → `YDoc.applyUpdate`),
    /// then projects it. Mirrors `YBlockProjectionTests`'s private helper of
    /// the same name (Task 2) — duplicated here rather than shared, per that
    /// file's own precedent of keeping test doubles local.
    private func projectedDoc(fromMarkdown md: String) throws -> ProjectedDocument {
        let doc = YDoc(clientID: 99)
        try doc.applyUpdate(try YUpdateDecoder.decode(MarkdownYjs.encode(markdown: md, clientID: 1)))
        let projected = YBlockProjection.project(doc)
        doc.destroy()
        return projected
    }

    /// The "all-kinds" document from Task 2
    /// (`YBlockProjectionTests.testProjectsEveryModeledBlockKindRoundTrip`),
    /// transcribed verbatim (built from explicit `\n`s rather than a
    /// multi-line string literal, so there is no ambiguity about exactly
    /// which whitespace Swift's triple-quote dedent would produce).
    private let allKindsDoc =
        [
            "# Title", "",
            "Body **bold** _it_ ~~st~~ `co` [l](https://x.example/)", "",
            "- b", "",
            "1. n", "",
            "- [x] done", "",
            "> q", "",
            "```swift",
            "let x = 1",
            "```", "",
            "---", "",
            "![a](https://x.example/i.png)",
        ].joined(separator: "\n") + "\n"

    // MARK: - Test 1: the load-bearing corpus round trip

    func testRoundTripsCanonicalCorpus() throws {
        // (markdown, expectedOverride). `expectedOverride == nil` means "must
        // equal `serializeMarkdown(parseEditorBlocks(markdown))` exactly";
        // a non-nil override spells out an unavoidable canonicalization the
        // Yjs round trip introduces that the direct parse/serialize path
        // does not go through.
        let corpus: [(markdown: String, expectedOverride: String?)] = [
            // Every distinct markdown literal used by `MarkdownYjsTests`.
            // (`YjsEncoderTests` builds `BlockNoteBlock`s directly — it has
            // no markdown string literals to transcribe.)
            ("", nil),
            ("# H1", nil),
            ("plain", nil),
            ("- a\n- b", nil),
            ("1. a\n2. b", nil),
            ("- [ ] a", nil),
            ("> q", nil),
            (
                "```\ncode\n```",
                // Canonicalization: `MarkdownYjs.map` defaults an empty
                // codeBlock language to "text" before the block ever reaches
                // the Yjs replica (`let lang = language.isEmpty ? "text" :
                // language`), so the projector reads back an explicit,
                // real "text" language — it has no way to know the source
                // fence was bare. `serializeMarkdown(parseEditorBlocks(md))`
                // never goes through that mapping, so it keeps the bare
                // fence. This is the one canonicalization the task brief
                // calls out by name.
                "```text\ncode\n```\n"
            ),
            ("---", nil),
            ("![alt](https://example.com/a.png)", nil),
            ("![photo](https://example.com/p.jpg)", nil),
            ("### Three", nil),
            ("###### Six", nil),
            ("- [ ] todo", nil),
            ("- [x] done", nil),
            ("```swift\ncode\n```", nil),
            ("say **hi**", nil),
            ("# Title\n\nbody", nil),
            // All-kinds doc (Task 2's fixture).
            (allKindsDoc, nil),
            ("snake_case", nil),
            (
                "# a *lit* b",
                // Canonicalization: `InlineMark.italic` doesn't record which
                // token (`*` or `_`) authored it — that information is
                // already gone by the time `InlineMarkdown.parse` returns —
                // and `InlineMarkdownWriter` always spells italic with `_`
                // (`openToken`/`closeToken` for "italic" are unconditionally
                // "_"). This is the same canonicalization the real save path
                // already performs (`MarkdownYjs.encode` parses through the
                // same `InlineMarkdown.parse`), not something Task 4 adds.
                "# a _lit_ b\n"
            ),
            ("> see [link](https://example.com)", nil),
            // Checklist + nested marks: bold wrapping italic. Both reopen in
            // the same outer→inner order the writer itself chooses
            // (persistence tie broken by fixed priority: bold before
            // italic), and the source already spells italic with `_`, so
            // this one round-trips byte-identically too — no override
            // needed.
            ("- [ ] **_both_** done", nil),
        ]

        for (markdown, expectedOverride) in corpus {
            let document = try projectedDoc(fromMarkdown: markdown)
            let expected = expectedOverride ?? serializeMarkdown(parseEditorBlocks(markdown))
            XCTAssertEqual(
                YBlockProjection.projectedMarkdown(document), expected,
                "round-trip mismatch for markdown: \(markdown.debugDescription)")
        }
    }

    // MARK: - Test 2: a paragraph that reads like a list escapes

    func testParagraphThatLooksLikeAListEscapes() {
        let block = ProjectedBlock(
            id: "x", node: "paragraph", props: [], runs: [InlineRun("- item")], fidelity: .modeled)
        let document = ProjectedDocument(blocks: [block], isFullyRenderable: true, isFullyModeled: true)

        guard let markdown = YBlockProjection.projectedMarkdown(document) else {
            XCTFail("expected escalation to produce a rendered markdown, got nil")
            return
        }
        // Minimal emission ("- item") would read back as a bullet list item,
        // not the paragraph it actually is — the self-verify loop must catch
        // that and escalate to an escaped ("\- item") rendering instead.
        XCTAssertEqual(
            parseEditorBlocks(markdown).first?.kind, .paragraph,
            "unescaped emission would read as a bullet; escalation must have fired")
    }

    // MARK: - Test 3: an embedded newline can never be fixed by escaping

    func testParagraphWithEmbeddedNewlineIsNil() {
        let block = ProjectedBlock(id: "x", node: "paragraph", props: [], runs: [InlineRun("a\nb")], fidelity: .modeled)
        let document = ProjectedDocument(blocks: [block], isFullyRenderable: true, isFullyModeled: true)

        // "\n" is not in `InlineMarkdownWriter.escapableCharacters`, so
        // `escapeAll: true` cannot prevent the embedded newline from
        // splitting the rendered paragraph into two literal lines on
        // re-parse (which then reads back as `.unknown`, not `.paragraph`).
        // This is the "opaque; escalation cannot fix it" class the
        // self-verify loop exists to catch and reject, not paper over.
        XCTAssertNil(YBlockProjection.projectedMarkdown(document))
    }

    // MARK: - Test 4: italic flush against a bare letter goes opaque

    func testItalicAgainstLetterGoesOpaque() {
        let block = ProjectedBlock(
            id: "x", node: "paragraph", props: [],
            runs: [InlineRun("x", marks: [("italic", "{}")]), InlineRun("y")], fidelity: .modeled)
        let document = ProjectedDocument(blocks: [block], isFullyRenderable: true, isFullyModeled: true)

        // Minimal emission would place the closing "_" directly against the
        // bare letter "y": that position is both left- and right-flanking
        // and not followed by punctuation, so `canCloseUnderscore` (the same
        // rule the scanner itself enforces) rejects it as a valid closing
        // delimiter. `InlineMarkdownWriter.write` therefore already returns
        // nil for *this* block at `escapeAll: false` — neither "x" nor "y"
        // contains an escapable character, so `escapeAll: true` can't help
        // either. `editorBlock` returns nil on the very first, unescalated
        // pass, which is what upgrades the whole document to nil here: the
        // writer layer produces the nil, not `projectedMarkdown`'s re-parse
        // comparison (the observable document-level result — nil — is the
        // same either way).
        XCTAssertNil(YBlockProjection.projectedMarkdown(document))
    }

    // MARK: - Test 5: any opaque block makes the whole document nil

    func testOpaqueDocumentReturnsNil() {
        let block = ProjectedBlock(id: "x", node: "fancyThing", props: [], runs: [], fidelity: .opaque(reason: "nope"))
        let document = ProjectedDocument(blocks: [block], isFullyRenderable: false, isFullyModeled: false)

        XCTAssertNil(YBlockProjection.projectedMarkdown(document))
    }

    // MARK: - Test 6: `editorBlock` itself short-circuits on opaque fidelity

    // A deferred Minor from Task 4: `editorBlock`'s opaque check was previously
    // covered only transitively (every opaque case above goes through
    // `projectedMarkdown`, which checks `document.isFullyRenderable` before
    // ever calling `editorBlock`). This exercises the function directly.
    func testEditorBlockReturnsNilForOpaqueFidelity() {
        let block = ProjectedBlock(
            id: "x", node: "paragraph", props: [], runs: [InlineRun("hi")], fidelity: .opaque(reason: "nope"))
        XCTAssertNil(YBlockProjection.editorBlock(block, escapeAll: false))
        XCTAssertNil(YBlockProjection.editorBlock(block, escapeAll: true))
    }
}
