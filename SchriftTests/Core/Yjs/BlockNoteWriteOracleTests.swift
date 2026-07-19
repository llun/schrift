import XCTest

@testable import Schrift

/// Document-level tests for the **incremental** B6 block differ
/// (`BlockNoteWrite.applyBlocks`). Where `BlockNoteWriteTests` pins the
/// from-empty path byte-for-byte against the golden encoder, these seed a live
/// replica (via `applyEdit(old: [], new: …)`) and then apply an *incremental*
/// `applyEdit(old: …, new: …)`, asserting the replica **projects** to `new`.
///
/// The diff is verified at the document/projection level, never at the
/// store-structure level: B6's within-block text edit is always
/// `YWrite.delete` + a self-describing `YWrite.insert(pieces)`, which
/// constructs different-but-equivalent items than yjs's `deleteText` yet is
/// correct at the document level (see `CLAUDE.md`, "The Yjs CRDT core" and the
/// Task 8 brief). The final `apply-to-oracle` lane cross-checks that a real
/// yjs peer, seeded from the same golden initial update, renders `new` from
/// B6's incremental update — and that a genuine yjs concurrent edit and B6's
/// edit converge.
final class BlockNoteWriteOracleTests: XCTestCase {

    // MARK: - Helpers

    /// The three base props every text block carries, in BlockNote order.
    private var baseProps: [(key: String, value: YAnyValue)] {
        [
            ("backgroundColor", .string("default")), ("textColor", .string("default")),
            ("textAlignment", .string("left")),
        ]
    }

    /// A one-run paragraph with the base props (empty text ⇒ no runs).
    private func para(_ text: String, id: String) -> BlockNoteBlock {
        BlockNoteBlock(node: "paragraph", props: baseProps, runs: text.isEmpty ? [] : [InlineRun(text)], id: id)
    }

    /// A paragraph with the base props carrying an arbitrary run list (for the
    /// store-level span-replace property test).
    private func paragraph(_ runs: [InlineRun], id: String) -> BlockNoteBlock {
        BlockNoteBlock(node: "paragraph", props: baseProps, runs: runs, id: id)
    }

    /// A deterministic PRNG (xorshift64*) so the property test is fully
    /// reproducible — never `Date`/`SystemRandomNumberGenerator`. Mirrors the one
    /// in `TextSpanDiffTests` so the two exercise the *same* input corpus (there at
    /// the pure-diff level, here through the real store). A failure is reproducible
    /// from the printed seed alone.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
        mutating func next() -> UInt64 {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return state &* 2_685_821_657_736_338_717
        }
    }

    /// A small alphabet (plain ASCII plus a 2-UTF-16-unit emoji) and mark sets
    /// (booleans plus two distinct link hrefs, so format-crossing deletes and the
    /// "same key, different valueJSON" transition are exercised). Mirrors
    /// `TextSpanDiffTests`.
    private static let alphabet = ["a", "b", "c", " ", "😀", "x"]
    private static let markSets: [[(key: String, valueJSON: String)]] = [
        [],
        [("bold", "{}")],
        [("italic", "{}")],
        [("bold", "{}"), ("italic", "{}")],
        [("link", "{\"href\":\"a\"}")],
        [("link", "{\"href\":\"b\"}")],
    ]

    private func randomRuns(_ rng: inout SeededGenerator) -> [InlineRun] {
        let runCount = Int.random(in: 1...3, using: &rng)
        var runs: [InlineRun] = []
        for _ in 0..<runCount {
            let length = Int.random(in: 0...5, using: &rng)
            var text = ""
            for _ in 0..<length { text += Self.alphabet.randomElement(using: &rng)! }
            runs.append(InlineRun(text, marks: Self.markSets.randomElement(using: &rng)!))
        }
        return runs
    }

    /// Project `doc` and compare to expected blocks (node/id/runs). Props are
    /// intentionally not compared here — the projection sorts them, and the
    /// prop-specific tests assert the exact value they care about.
    private func assertProjects(
        _ doc: YDoc, to expected: [BlockNoteBlock], file: StaticString = #filePath, line: UInt = #line
    ) {
        let projected = YBlockProjection.project(doc).blocks
        XCTAssertEqual(projected.map(\.id), expected.map(\.id), "block ids", file: file, line: line)
        XCTAssertEqual(projected.map(\.node), expected.map(\.node), "block nodes", file: file, line: line)
        XCTAssertEqual(projected.map(\.runs), expected.map(\.runs), "block runs", file: file, line: line)
    }

    // MARK: - Step 1: incremental diff cases (document-level)

    func testTypingACharIntoAParagraph() throws {
        let a = para("hello", id: "11111111-1111-1111-1111-111111111111")
        let b = para("heXllo", id: "11111111-1111-1111-1111-111111111111")
        let doc = YDoc(clientID: 42)
        _ = try BlockNoteWrite.applyEdit(old: [], new: [a], to: doc)
        _ = try BlockNoteWrite.applyEdit(old: [a], new: [b], to: doc)
        assertProjects(doc, to: [b])
        doc.destroy()
    }

    func testInsertingASecondBlock() throws {
        let a = para("one", id: "11111111-1111-1111-1111-111111111111")
        let c = para("two", id: "22222222-2222-2222-2222-222222222222")
        let doc = YDoc(clientID: 42)
        _ = try BlockNoteWrite.applyEdit(old: [], new: [a], to: doc)
        _ = try BlockNoteWrite.applyEdit(old: [a], new: [a, c], to: doc)
        assertProjects(doc, to: [a, c])
        doc.destroy()
    }

    func testInsertingABlockInTheMiddle() throws {
        let a = para("one", id: "11111111-1111-1111-1111-111111111111")
        let b = para("mid", id: "22222222-2222-2222-2222-222222222222")
        let c = para("two", id: "33333333-3333-3333-3333-333333333333")
        let doc = YDoc(clientID: 42)
        _ = try BlockNoteWrite.applyEdit(old: [], new: [a, c], to: doc)
        _ = try BlockNoteWrite.applyEdit(old: [a, c], new: [a, b, c], to: doc)
        assertProjects(doc, to: [a, b, c])
        doc.destroy()
    }

    func testRemovingABlock() throws {
        let a = para("one", id: "11111111-1111-1111-1111-111111111111")
        let c = para("two", id: "22222222-2222-2222-2222-222222222222")
        let doc = YDoc(clientID: 42)
        _ = try BlockNoteWrite.applyEdit(old: [], new: [a, c], to: doc)
        _ = try BlockNoteWrite.applyEdit(old: [a, c], new: [a], to: doc)
        assertProjects(doc, to: [a])
        doc.destroy()
    }

    func testRemovingTheFirstOfThreeBlocks() throws {
        let a = para("one", id: "11111111-1111-1111-1111-111111111111")
        let b = para("two", id: "22222222-2222-2222-2222-222222222222")
        let c = para("three", id: "33333333-3333-3333-3333-333333333333")
        let doc = YDoc(clientID: 42)
        _ = try BlockNoteWrite.applyEdit(old: [], new: [a, b, c], to: doc)
        _ = try BlockNoteWrite.applyEdit(old: [a, b, c], new: [b, c], to: doc)
        assertProjects(doc, to: [b, c])
        doc.destroy()
    }

    func testChangingBlockKind() throws {
        let a = para("title", id: "11111111-1111-1111-1111-111111111111")
        let h = BlockNoteBlock(
            node: "heading",
            props: [
                ("backgroundColor", .string("default")), ("textColor", .string("default")),
                ("textAlignment", .string("left")), ("level", .int(1)), ("isToggleable", .bool(false)),
            ],
            runs: [InlineRun("title")], id: "11111111-1111-1111-1111-111111111111")
        let doc = YDoc(clientID: 42)
        _ = try BlockNoteWrite.applyEdit(old: [], new: [a], to: doc)
        _ = try BlockNoteWrite.applyEdit(old: [a], new: [h], to: doc)
        assertProjects(doc, to: [h])
        // The kind change is projected fully modeled — heading level 1, not toggleable.
        // `assertProjects` skips props, so pin the rebuilt element's prop *values*
        // explicitly (mirrors `testTogglingAChecklistProp`).
        let headingProps = YBlockProjection.project(doc).blocks.first?.props
        XCTAssertEqual(headingProps?.first { $0.key == "level" }?.value, .int(1))
        XCTAssertEqual(headingProps?.first { $0.key == "isToggleable" }?.value, .bool(false))
        XCTAssertEqual(YBlockProjection.project(doc).blocks.first?.fidelity, .modeled)
        doc.destroy()
    }

    func testTogglingAChecklistProp() throws {
        let unchecked = BlockNoteBlock(
            node: "checkListItem",
            props: [
                ("backgroundColor", .string("default")), ("textColor", .string("default")),
                ("textAlignment", .string("left")), ("checked", .bool(false)),
            ],
            runs: [InlineRun("task")], id: "44444444-4444-4444-4444-444444444444")
        var checked = unchecked
        checked.props = unchecked.props.map { $0.key == "checked" ? ("checked", .bool(true)) : $0 }
        let doc = YDoc(clientID: 42)
        _ = try BlockNoteWrite.applyEdit(old: [], new: [unchecked], to: doc)
        _ = try BlockNoteWrite.applyEdit(old: [unchecked], new: [checked], to: doc)
        assertProjects(doc, to: [checked])
        XCTAssertEqual(
            YBlockProjection.project(doc).blocks.first?.props.first { $0.key == "checked" }?.value, .bool(true))
        doc.destroy()
    }

    func testFormattingASpanBold() throws {
        let plain = para("hello world", id: "11111111-1111-1111-1111-111111111111")
        var bolded = plain
        bolded.runs = [
            InlineRun("hello "), InlineRun("world", marks: [("bold", "{}")]),
        ]
        let doc = YDoc(clientID: 42)
        _ = try BlockNoteWrite.applyEdit(old: [], new: [plain], to: doc)
        _ = try BlockNoteWrite.applyEdit(old: [plain], new: [bolded], to: doc)
        assertProjects(doc, to: [bolded])
        doc.destroy()
    }

    func testReorderingTwoBlocks() throws {
        let a = para("one", id: "11111111-1111-1111-1111-111111111111")
        let b = para("two", id: "22222222-2222-2222-2222-222222222222")
        let doc = YDoc(clientID: 42)
        _ = try BlockNoteWrite.applyEdit(old: [], new: [a, b], to: doc)
        _ = try BlockNoteWrite.applyEdit(old: [a, b], new: [b, a], to: doc)
        assertProjects(doc, to: [b, a])
        doc.destroy()
    }

    // MARK: - Step 5: apply-to-oracle + concurrent convergence
    //
    // These close the loop against **real yjs@13.6.31**: a genuine
    // yjs-authored base update (`U0`), B6's own incremental update
    // (`Ub`, emitted by `applyEdit` here and asserted byte-for-byte), and a
    // genuine yjs concurrent edit (`Uc`). The oracle confirmed offline that
    // applying `Ub` on top of `U0` renders "heXllo", and that `Ub` + `Uc`
    // converge to `[heXllo, world]` in either application order, byte-identically.
    //
    // ## Regeneration (session-local node oracle — never committed; the repo's
    // zero-third-party-dependency rule): `npm install yjs@13.6.31` (Node v24),
    // then:
    //
    // ```js
    // // Phase 1 — the yjs-authored base U0 and the yjs concurrent edit Uc.
    // import * as Y from "yjs";
    // const BASE_ID = "11111111-1111-4111-8111-111111111111";
    // const NEW_ID = "22222222-2222-4222-8222-222222222222";
    // function makeParagraphContainer(id, text) {
    //   const container = new Y.XmlElement("blockContainer");
    //   container.setAttribute("id", id);
    //   const paragraph = new Y.XmlElement("paragraph");
    //   paragraph.setAttribute("backgroundColor", "default");
    //   paragraph.setAttribute("textColor", "default");
    //   paragraph.setAttribute("textAlignment", "left");
    //   const xmlText = new Y.XmlText();
    //   if (text.length) xmlText.insert(0, text);
    //   paragraph.insert(0, [xmlText]);
    //   container.insert(0, [paragraph]);
    //   return container;
    // }
    // const base = new Y.Doc(); base.clientID = 1;
    // const fragment = base.getXmlFragment("document-store");
    // const blockGroup = new Y.XmlElement("blockGroup");
    // fragment.insert(0, [blockGroup]);
    // blockGroup.insert(0, [makeParagraphContainer(BASE_ID, "hello")]);
    // const U0 = Y.encodeStateAsUpdate(base), SV0 = Y.encodeStateVector(base);
    // const peer = new Y.Doc(); peer.clientID = 2;
    // Y.applyUpdate(peer, U0);
    // peer.getXmlFragment("document-store").toArray()[0]
    //   .insert(1, [makeParagraphContainer(NEW_ID, "world")]);
    // const Uc = Y.encodeStateAsUpdate(peer, SV0);
    // // U0 = 0109…00 ; Uc = 0108…00 (below).
    //
    // // Ub is captured from Swift: seed a YDoc(42) from U0, then
    // //   BlockNoteWrite.applyEdit(old: [hello], new: [heXllo]).hexString
    // // = 01012a00c401050106015800 (asserted in testAppliesB6UpdateToOracle).
    //
    // // Phase 2 — verify against the oracle.
    // function blocks(doc) {
    //   const group = doc.getXmlFragment("document-store").toArray()[0];
    //   return group.toArray().map((c) => ({
    //     id: c.getAttribute("id"), node: c.toArray()[0].nodeName,
    //     delta: c.toArray()[0].toArray()[0].toDelta() }));
    // }
    // const Ub = Buffer.from("01012a00c401050106015800", "hex");
    // const a = new Y.Doc(); Y.applyUpdate(a, U0); Y.applyUpdate(a, Ub);
    // // blocks(a) => [{id: BASE_ID, node: "paragraph", delta: [{insert:"heXllo"}]}]
    // const b = new Y.Doc(); Y.applyUpdate(b, U0); Y.applyUpdate(b, Ub); Y.applyUpdate(b, Uc);
    // const c = new Y.Doc(); Y.applyUpdate(c, U0); Y.applyUpdate(c, Uc); Y.applyUpdate(c, Ub);
    // // blocks(b) === blocks(c) => [heXllo, world]; and
    // // encodeStateAsUpdate(b) === encodeStateAsUpdate(c) (byte-identical).
    // ```

    private let baseID = "11111111-1111-4111-8111-111111111111"
    private let peerBlockID = "22222222-2222-4222-8222-222222222222"

    /// yjs-authored base: one paragraph "hello".
    private let baseUpdateHex =
        "0109010007010e646f63756d656e742d73746f7265030a626c6f636b47726f757007000100030e626c6f636b436f6e7461696e65720700010103097061726167726170680700010206040001030568656c6c6f280001020f6261636b67726f756e64436f6c6f7201770764656661756c74280001020974657874436f6c6f7201770764656661756c74280001020d74657874416c69676e6d656e740177046c6566742800010102696401772431313131313131312d313131312d343131312d383131312d31313131313131313131313100"

    /// yjs concurrent edit by client 2 (seeded from the base): append a second
    /// paragraph "world". A diff since the base state vector.
    private let peerConcurrentUpdateHex =
        "01080200870101030e626c6f636b436f6e7461696e657207000200030970617261677261706807000201060400020205776f726c64280002010f6261636b67726f756e64436f6c6f7201770764656661756c74280002010974657874436f6c6f7201770764656661756c74280002010d74657874416c69676e6d656e740177046c6566742800020002696401772432323232323232322d323232322d343232322d383232322d32323232323232323232323200"

    /// B6's Swift-authored incremental update for typing "X" into "hello" — the
    /// exact bytes `applyEdit` emits (asserted below), which the oracle verified
    /// renders "heXllo" when applied on top of `baseUpdateHex`.
    private let b6TypingUpdateHex = "01012a00c401050106015800"

    private func seededReplica(clientID: UInt = 42) throws -> YDoc {
        let doc = YDoc(clientID: clientID)
        try doc.applyUpdate(try YUpdateDecoder.decode(Data(hex: baseUpdateHex)))
        return doc
    }

    /// Apply-to-oracle: seed a replica from the yjs-authored base, apply B6's
    /// incremental edit, and assert both that the replica projects to the intended
    /// document *and* that the emitted update is byte-for-byte the one the oracle
    /// confirmed renders the same document on a real yjs peer.
    func testAppliesB6UpdateToOracle() throws {
        let old = para("hello", id: baseID)
        let new = para("heXllo", id: baseID)
        let doc = try seededReplica()
        assertProjects(doc, to: [old])  // the seed matches the oracle's base
        let update = try BlockNoteWrite.applyEdit(old: [old], new: [new], to: doc)
        assertProjects(doc, to: [new])
        XCTAssertEqual(
            update.hexString, b6TypingUpdateHex,
            "B6's incremental update must be the exact bytes the oracle rendered as \"heXllo\"")
        doc.destroy()
    }

    /// Concurrent convergence: a genuine yjs concurrent edit (append "world") and
    /// B6's edit (type "X" into "hello"), exchanged, converge to the same
    /// document the oracle settles on — verified in **both** application orders,
    /// mirroring the oracle's byte-identical convergence.
    func testConcurrentEditConvergesWithYjsPeer() throws {
        let hello = para("hello", id: baseID)
        let heXllo = para("heXllo", id: baseID)
        let world = para("world", id: peerBlockID)
        let peerUpdate = try YUpdateDecoder.decode(Data(hex: peerConcurrentUpdateHex))

        // Order 1: B6's edit first, then the peer's concurrent update arrives.
        let forward = try seededReplica()
        _ = try BlockNoteWrite.applyEdit(old: [hello], new: [heXllo], to: forward)
        try forward.applyUpdate(peerUpdate)
        assertProjects(forward, to: [heXllo, world])
        forward.destroy()

        // Order 2: the peer's update first, then B6 edits on top of it. `old` is
        // the current two-block projection; only the first block's text changes.
        let reverse = try seededReplica()
        try reverse.applyUpdate(peerUpdate)
        assertProjects(reverse, to: [hello, world])
        _ = try BlockNoteWrite.applyEdit(old: [hello, world], new: [heXllo, world], to: reverse)
        assertProjects(reverse, to: [heXllo, world])
        reverse.destroy()
    }

    // MARK: - Task 9 differential-fuzz findings

    /// **Regression test — B6 write-path surrogate-pair split, found by the Task 9
    /// differential fuzz (astral / surrogate-torture lane) and fixed in
    /// `TextSpanDiff`.**
    ///
    /// Replacing one astral-plane character with another that **shares its high
    /// surrogate** — here `"😀"` (U+1F600) → `"😃"` (U+1F603), both high surrogate
    /// `0xD83D` — used to drive `TextSpanDiff.diff` to split the surrogate pair:
    /// its prefix/suffix common-scan works in UTF-16 **units**, so it stopped
    /// between the shared high surrogate (kept) and the differing low surrogate
    /// (replaced). The inserted piece `String(decoding: [loneLowSurrogate], as:
    /// UTF16.self)` collapsed the lone low surrogate to `U+FFFD` (the yjs#248
    /// mechanism), and the retained lone high surrogate also rendered `U+FFFD`, so
    /// **both** code units corrupted.
    ///
    /// This is a **single-client** edit — no concurrency, no merge order — so it
    /// was *not* the "converges only when yjs converges" case. Before the fix,
    /// B6's own incremental update, applied by real **yjs@13.6.31**, rendered
    /// `"\u{FFFD}\u{FFFD}"`, **not** `"😃"` (confirmed against the node oracle;
    /// for client id 7 the emitted update was
    /// `0101070ac40704070503efbfbd0107010501` — delete one unit at index 1, then
    /// insert the 3-byte UTF-8 for `U+FFFD`). A user swapping one emoji for
    /// another that shares a high surrogate would silently corrupt their text on
    /// every peer.
    ///
    /// **Fix:** `TextSpanDiff` now snaps its delete/insert boundaries to
    /// code-**point** boundaries so a surrogate pair is never split (back the
    /// prefix scan up one unit, and back the suffix scan off one unit, when a
    /// boundary lands between a high and a low surrogate). This touches only the
    /// incremental text-replace path, not the byte-identity from-empty anchor, so
    /// the replica now projects the intended `"😃"`.
    func testEmojiSwapSharingHighSurrogateProjectsCorrectly() throws {
        let old = para("😀", id: baseID)  // U+1F600, high surrogate 0xD83D
        let new = para("😃", id: baseID)  // U+1F603, high surrogate 0xD83D
        let doc = YDoc(clientID: 7)
        _ = try BlockNoteWrite.applyEdit(old: [], new: [old], to: doc)
        _ = try BlockNoteWrite.applyEdit(old: [old], new: [new], to: doc)
        // After the code-point snap the replica projects to "😃", not "\u{FFFD}\u{FFFD}".
        assertProjects(doc, to: [new])
        doc.destroy()
    }

    /// The complementary clean case that **bounds** the bug above: inserting a
    /// whole astral character (never splitting a pair) round-trips correctly, so
    /// the defect is specifically the shared-high-surrogate *swap*, not emoji
    /// editing in general. Part of the Task 9 fuzz's astral coverage.
    func testInsertingAWholeEmojiRoundTrips() throws {
        let old = para("ab", id: baseID)
        let new = para("a😀b", id: baseID)  // insert a whole surrogate pair between a and b
        let doc = YDoc(clientID: 7)
        _ = try BlockNoteWrite.applyEdit(old: [], new: [old], to: doc)
        _ = try BlockNoteWrite.applyEdit(old: [old], new: [new], to: doc)
        assertProjects(doc, to: [new])
        doc.destroy()
    }

    // MARK: - Store-level span-replace property test

    /// The committed, CI-visible randomized coverage for B6's within-block text
    /// edit **through the real store**. `TextSpanDiffTests` exercises the same
    /// (old, new) run corpus against the *pure* `TextSpanDiff.diff` via an
    /// in-memory applier; this drives it through the genuine `YDoc` +
    /// `BlockNoteWrite.applyEdit` path (`YWrite.delete` + a self-describing
    /// `YWrite.insert`, incl. deleting interior `ContentFormat` items on a
    /// format-crossing delete) and asserts the *projected* document matches.
    ///
    /// For each seed: build a paragraph for `oldRuns` and one for `newRuns` under
    /// the **same** block id, seed a replica from the old block, apply the edit,
    /// and assert the projected paragraph's runs equal `newRuns` **as
    /// `MarkedText`** — normalization-invariant, since the projection may coalesce
    /// runs differently than the input while flattening to the same per-unit
    /// (char, marks) view. The mark alphabet includes bold/italic/link-href, and
    /// random edit positions land inside and across formatted spans, so
    /// format-crossing interior-`ContentFormat` deletes are exercised.
    func testSpanReplaceThroughRealStoreReproducesNewRunsAcrossRandomizedRuns() throws {
        let id = "55555555-5555-4555-8555-555555555555"
        for seed: UInt64 in 1...500 {
            var rng = SeededGenerator(seed: seed)
            let oldRuns = randomRuns(&rng)
            let newRuns = randomRuns(&rng)
            let paraOld = paragraph(oldRuns, id: id)
            let paraNew = paragraph(newRuns, id: id)

            let doc = YDoc(clientID: 99)
            defer { doc.destroy() }
            _ = try BlockNoteWrite.applyEdit(old: [], new: [paraOld], to: doc)
            _ = try BlockNoteWrite.applyEdit(old: [paraOld], new: [paraNew], to: doc)

            let projected = YBlockProjection.project(doc).blocks
            XCTAssertEqual(projected.count, 1, "seed \(seed): expected exactly one projected block")
            let projectedRuns = projected.first?.runs ?? []
            XCTAssertEqual(
                TextSpanDiff.marked(projectedRuns), TextSpanDiff.marked(newRuns),
                "seed \(seed): store span-replace did not reproduce new runs "
                    + "(projected \(projectedRuns) vs new \(newRuns))")
        }
    }
}
