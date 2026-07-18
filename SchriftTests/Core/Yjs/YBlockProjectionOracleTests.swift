import XCTest

@testable import Schrift

/// Web-authored oracle fixtures for `YBlockProjection` (B5 Task 6) — replica
/// shapes the app's own encoder (`MarkdownYjs`/`BlockNoteYjs`) can never
/// produce, captured from real **yjs@13.6.31**, not hand-built:
///
/// 1. **Incremental typing**: many single-character `Y.XmlText.insert` calls,
///    then a bold `format()` applied over a middle span *after* the text was
///    already integrated as one merged `ContentString` item — which forces
///    yjs to physically split that item at the format boundaries — followed
///    by a further interior insert re-asserting the same bold mark (the
///    caret typing inside an already-bold run). The resulting wire update
///    carries **three separate `ContentString` items under the identical
///    open-bold state** ("ll" + "X" + "o W"), plus format markers at **fresh
///    clocks appended at the end of the client's clock sequence** (never
///    interleaved with the string clocks) and positioned only via
///    `origin`/`rightOrigin` — proof that `YBlockProjection.foldInline` must
///    reconstruct list order from origin chains, not clock order, and that
///    `appendRun`'s coalescing must re-fuse all three same-mark pieces into
///    one run ("llXo W"), not one run per underlying item.
/// 2. **Concurrent two-client formatting**: two `Y.Doc`s diverge from an
///    identical base (plain "the quick fox"), one bolds "quick" while the
///    other independently italicizes the overlapping "the quick", then their
///    diffs are cross-applied. This exercises B4's
///    `cleanupYTextAfterTransaction` on a *nested* (non-root) `YText` with
///    `_hasFormatting` — the only shape that fires it (a bare root type is
///    never a concrete `YText`). Both replicas settle to byte-identical
///    state; the captured mark **order** (italic before bold) is the real
///    YATA-resolved list order, not an assumption.
/// 3. **A gc'd doc**: three paragraph blocks, the middle one deleted with
///    `gc: true` (the doc's default) captured *after* gc ran. The deleted
///    container's own item survives as a `ContentDeleted` tombstone (so
///    surviving structs can still resolve origins into it), while its entire
///    subtree (paragraph, text, props) collapses into one anonymous `GC`
///    struct — confirmed by walking the oracle's own struct list. This
///    replaces Task 2's deferred `testDeletedBlocksAreSkipped`.
/// 4. **`Y.mergeUpdates` output**: three blocks added incrementally; the
///    *middle* block's own update is captured but never merged in (a relay
///    that dropped it). Merging the first and third updates leaves a genuine
///    clock gap for client 1, which `mergeUpdates` fills with a `Skip`
///    struct — the only realistic source of `Skip`s in this store, per
///    `docs/architecture.md`. Because yjs threads list-type siblings by
///    `origin`, not an explicit index, the third block's container item has
///    its origin *inside* the gap and can never integrate — it stays in
///    `pendingStructs` forever, exactly as if update A were applied and
///    update B were simply never sent. `project` must not throw or trap.
/// 5. **A nested list**: a `bulletListItem`'s `blockContainer` holds a
///    *second* child — a nested `blockGroup` with its own child bullet, the
///    shape BlockNote uses for indented sub-items. `BlockNoteYjs.encode`
///    can never build this (it always emits exactly one element child per
///    container), so it needs a real capture.
///
/// Toggle-heading and colored-text opaque/lossy cases already have hand-built
/// coverage from Task 2 (`YBlockProjectionTests.testHeadingToggleableTrueIsOpaque`,
/// `testColoredTextIsLossy`) via `BlockNoteYjs.encode`, which emits the exact
/// same map-entry wire shape a real web client would for those props — there
/// is no structural difference an oracle capture would add, so they are not
/// duplicated here.
///
/// ## Regeneration
///
/// Session-local node oracle (never committed — the repo's
/// zero-third-party-dependency rule): `npm install yjs@13.6.31` in a scratch
/// dir (Node v24), then run the consolidated capture script below and copy
/// the printed hex strings.
///
/// ```js
/// import * as Y from "yjs";
///
/// function baseDoc(clientID) {
///   const doc = new Y.Doc();
///   doc.clientID = clientID;
///   return doc;
/// }
///
/// function makeParagraphContainer(id, text) {
///   const container = new Y.XmlElement("blockContainer");
///   container.setAttribute("id", id);
///   const paragraph = new Y.XmlElement("paragraph");
///   paragraph.setAttribute("backgroundColor", "default");
///   paragraph.setAttribute("textColor", "default");
///   paragraph.setAttribute("textAlignment", "left");
///   const xmlText = new Y.XmlText(text);
///   paragraph.insert(0, [xmlText]);
///   container.insert(0, [paragraph]);
///   return container;
/// }
///
/// // Fixture 1: incremental typing + mid-span bold + an interior same-mark insert.
/// {
///   const doc = baseDoc(1);
///   const fragment = doc.getXmlFragment("document-store");
///   const blockGroup = new Y.XmlElement("blockGroup");
///   fragment.insert(0, [blockGroup]);
///   const blockContainer = new Y.XmlElement("blockContainer");
///   blockGroup.insert(0, [blockContainer]);
///   blockContainer.setAttribute("id", "11111111-1111-4111-8111-111111111111");
///   const paragraph = new Y.XmlElement("paragraph");
///   blockContainer.insert(0, [paragraph]);
///   paragraph.setAttribute("backgroundColor", "default");
///   paragraph.setAttribute("textColor", "default");
///   paragraph.setAttribute("textAlignment", "left");
///   const xmlText = new Y.XmlText();
///   paragraph.insert(0, [xmlText]);
///   const text = "Hello World";
///   for (let i = 0; i < text.length; i++) xmlText.insert(i, text[i]);
///   xmlText.format(2, 5, { bold: {} }); // "He" | bold("llo W") | "orld"
///   xmlText.insert(4, "X", { bold: {} }); // "He" | bold("llXo W") | "orld"
///   console.log(Buffer.from(Y.encodeStateAsUpdate(doc)).toString("hex"));
/// }
///
/// // Fixture 2: concurrent two-client formatting.
/// {
///   const a = baseDoc(1);
///   const fragment = a.getXmlFragment("document-store");
///   const blockGroup = new Y.XmlElement("blockGroup");
///   fragment.insert(0, [blockGroup]);
///   const blockContainer = new Y.XmlElement("blockContainer");
///   blockGroup.insert(0, [blockContainer]);
///   blockContainer.setAttribute("id", "11111111-1111-4111-8111-111111111111");
///   const paragraph = new Y.XmlElement("paragraph");
///   blockContainer.insert(0, [paragraph]);
///   paragraph.setAttribute("backgroundColor", "default");
///   paragraph.setAttribute("textColor", "default");
///   paragraph.setAttribute("textAlignment", "left");
///   const aText = new Y.XmlText("the quick fox");
///   paragraph.insert(0, [aText]);
///   const baseUpdate = Y.encodeStateAsUpdate(a);
///   const baseSV = Y.encodeStateVector(a);
///   const b = new Y.Doc();
///   b.clientID = 2;
///   Y.applyUpdate(b, baseUpdate);
///   const bText = b.getXmlFragment("document-store").toArray()[0].toArray()[0].toArray()[0].toArray()[0];
///   aText.format(4, 5, { bold: {} }); // client 1 bolds "quick"
///   bText.format(0, 9, { italic: {} }); // client 2 italicizes "the quick"
///   const updateAFromBase = Y.encodeStateAsUpdate(a, baseSV);
///   const updateBFromBase = Y.encodeStateAsUpdate(b, baseSV);
///   Y.applyUpdate(b, updateAFromBase);
///   Y.applyUpdate(a, updateBFromBase);
///   console.log(Buffer.from(Y.encodeStateAsUpdate(a)).toString("hex")); // == encodeStateAsUpdate(b)
/// }
///
/// // Fixture 3: gc'd doc, middle block deleted.
/// {
///   const doc = baseDoc(1);
///   const fragment = doc.getXmlFragment("document-store");
///   const blockGroup = new Y.XmlElement("blockGroup");
///   fragment.insert(0, [blockGroup]);
///   const c1 = makeParagraphContainer("11111111-1111-4111-8111-111111111111", "first");
///   const c2 = makeParagraphContainer("22222222-2222-4222-8222-222222222222", "middle (deleted)");
///   const c3 = makeParagraphContainer("33333333-3333-4333-8333-333333333333", "third");
///   blockGroup.insert(0, [c1, c2, c3]);
///   blockGroup.delete(1, 1); // gc:true is the doc default
///   console.log(Buffer.from(Y.encodeStateAsUpdate(doc)).toString("hex"));
/// }
///
/// // Fixture 4: mergeUpdates output (Skip-bearing), middle update dropped.
/// {
///   const doc = baseDoc(1);
///   const sv0 = Y.encodeStateVector(doc);
///   const fragment = doc.getXmlFragment("document-store");
///   const blockGroup = new Y.XmlElement("blockGroup");
///   fragment.insert(0, [blockGroup]);
///   const c1 = makeParagraphContainer("11111111-1111-4111-8111-111111111111", "first");
///   blockGroup.insert(0, [c1]);
///   const updateA = Y.encodeStateAsUpdate(doc, sv0);
///   const sv1 = Y.encodeStateVector(doc);
///   const c2 = makeParagraphContainer("22222222-2222-4222-8222-222222222222", "second (dropped)");
///   blockGroup.insert(1, [c2]);
///   Y.encodeStateAsUpdate(doc, sv1); // captured but never merged in
///   const sv2 = Y.encodeStateVector(doc);
///   const c3 = makeParagraphContainer("33333333-3333-4333-8333-333333333333", "third");
///   blockGroup.insert(2, [c3]);
///   const updateC = Y.encodeStateAsUpdate(doc, sv2);
///   console.log(Buffer.from(Y.mergeUpdates([updateA, updateC])).toString("hex"));
/// }
///
/// // Fixture 5: nested list.
/// {
///   const doc = baseDoc(1);
///   const fragment = doc.getXmlFragment("document-store");
///   const rootGroup = new Y.XmlElement("blockGroup");
///   fragment.insert(0, [rootGroup]);
///   const outerContainer = new Y.XmlElement("blockContainer");
///   outerContainer.setAttribute("id", "11111111-1111-4111-8111-111111111111");
///   rootGroup.insert(0, [outerContainer]);
///   const outerBullet = new Y.XmlElement("bulletListItem");
///   outerBullet.setAttribute("backgroundColor", "default");
///   outerBullet.setAttribute("textColor", "default");
///   outerBullet.setAttribute("textAlignment", "left");
///   outerBullet.insert(0, [new Y.XmlText("parent")]);
///   const nestedGroup = new Y.XmlElement("blockGroup");
///   const innerContainer = new Y.XmlElement("blockContainer");
///   innerContainer.setAttribute("id", "22222222-2222-4222-8222-222222222222");
///   const innerBullet = new Y.XmlElement("bulletListItem");
///   innerBullet.setAttribute("backgroundColor", "default");
///   innerBullet.setAttribute("textColor", "default");
///   innerBullet.setAttribute("textAlignment", "left");
///   innerBullet.insert(0, [new Y.XmlText("child")]);
///   innerContainer.insert(0, [innerBullet]);
///   nestedGroup.insert(0, [innerContainer]);
///   outerContainer.insert(0, [outerBullet, nestedGroup]);
///   console.log(Buffer.from(Y.encodeStateAsUpdate(doc)).toString("hex"));
/// }
/// ```
final class YBlockProjectionOracleTests: XCTestCase {

    // MARK: - Helpers

    private func doc(fromHex hex: String, clientID: UInt = 99) throws -> YDoc {
        let doc = YDoc(clientID: clientID)
        try doc.applyUpdate(try YUpdateDecoder.decode(Data(hex: hex)))
        return doc
    }

    // MARK: - Fixture 1: incremental typing, mid-span bold over split ContentStrings

    private let incrementalTypingHex =
        "010f010007010e646f63756d656e742d73746f7265030a626c6f636b47726f757007000100030e626c6f636b436f6e7461696e65722800010102696401772431313131313131312d313131312d343131312d383131312d313131313131313131313131070001010309706172616772617068280001030f6261636b67726f756e64436f6c6f7201770764656661756c74280001030974657874436f6c6f7201770764656661756c74280001030d74657874416c69676e6d656e740177046c656674070001030604000107024865840109026c6c84010b036f205784010e046f726c64c60109010a04626f6c64027b7dc6010e010f04626f6c64046e756c6cc4010b010c015800"

    func testIncrementalTypingWithMidSpanBoldFoldsIntoThreeRuns() throws {
        let replica = try doc(fromHex: incrementalTypingHex)
        let projected = YBlockProjection.project(replica)
        replica.destroy()

        XCTAssertEqual(projected.blocks.count, 1)
        let block = projected.blocks[0]
        XCTAssertEqual(block.id, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(block.node, "paragraph")
        XCTAssertEqual(block.fidelity, .modeled, "expected .modeled, got \(block.fidelity)")
        XCTAssertTrue(projected.isFullyRenderable)
        XCTAssertTrue(projected.isFullyModeled)

        // The oracle's own toDelta(): [{"insert":"He"},
        // {"insert":"llXo W","attributes":{"bold":{}}}, {"insert":"orld"}].
        // Walking the oracle's settled item list confirms the middle run is
        // genuinely THREE separate ContentString items under the identical
        // open-bold state ("ll" + "X" + "o W", the "X" from the later
        // interior insert) -- exactly 3 runs here means `appendRun`
        // coalesced all three same-mark items into one run, not one run per
        // underlying item.
        XCTAssertEqual(
            block.runs,
            [
                InlineRun("He"),
                InlineRun("llXo W", marks: [(key: "bold", valueJSON: "{}")]),
                InlineRun("orld"),
            ])

        guard let markdown = YBlockProjection.projectedMarkdown(projected) else {
            XCTFail("expected the modeled block to render as markdown")
            return
        }
        let reparsedBlocks = parseEditorBlocks(markdown)
        XCTAssertEqual(reparsedBlocks.count, 1)
        XCTAssertEqual(reparsedBlocks[0].kind, .paragraph)
        XCTAssertEqual(InlineMarkdown.parse(reparsedBlocks[0].text), block.runs)
    }

    // MARK: - Fixture 2: concurrent two-client formatting (B4 cleanup output)

    private let concurrentFormattingHex =
        "02020200460108066974616c6963027b7dc601100111066974616c6963046e756c6c0d010007010e646f63756d656e742d73746f7265030a626c6f636b47726f757007000100030e626c6f636b436f6e7461696e65722800010102696401772431313131313131312d313131312d343131312d383131312d313131313131313131313131070001010309706172616772617068280001030f6261636b67726f756e64436f6c6f7201770764656661756c74280001030974657874436f6c6f7201770764656661756c74280001030d74657874416c69676e6d656e740177046c656674070001030604000107047468652084010b05717569636b8401100420666f78c6010b010c04626f6c64027b7dc60110011104626f6c64046e756c6c00"

    func testConcurrentTwoClientFormattingProjectsSettledMarks() throws {
        let replica = try doc(fromHex: concurrentFormattingHex)
        let projected = YBlockProjection.project(replica)
        replica.destroy()

        XCTAssertEqual(projected.blocks.count, 1)
        let block = projected.blocks[0]
        XCTAssertEqual(block.id, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(block.fidelity, .modeled, "expected .modeled, got \(block.fidelity)")
        XCTAssertTrue(projected.isFullyRenderable)
        XCTAssertTrue(projected.isFullyModeled)

        // Oracle's settled toDelta(): "the " italic, "quick" italic+bold,
        // " fox" plain -- both replicas converged to byte-identical state.
        // Mark ORDER (italic before bold) is the real YATA-resolved list
        // order (confirmed by walking the settled item list), not assumed:
        // client 2's italic-open sits at the very start of the text, client
        // 1's bold-open sits between "the " and "quick", so italic opens
        // first in the walk.
        XCTAssertEqual(
            block.runs,
            [
                InlineRun("the ", marks: [(key: "italic", valueJSON: "{}")]),
                InlineRun(
                    "quick", marks: [(key: "italic", valueJSON: "{}"), (key: "bold", valueJSON: "{}")]),
                InlineRun(" fox"),
            ])
    }

    // MARK: - Fixture 3: gc'd doc -- middle block deleted, GC struct present

    private let gcdMiddleBlockHex =
        "0113010007010e646f63756d656e742d73746f7265030a626c6f636b47726f757007000100030e626c6f636b436f6e7461696e6572070001010309706172616772617068070001020604000103056669727374280001020f6261636b67726f756e64436f6c6f7201770764656661756c74280001020974657874436f6c6f7201770764656661756c74280001020d74657874416c69676e6d656e740177046c6566742800010102696401772431313131313131312d313131312d343131312d383131312d31313131313131313131313181010101001687010d030e626c6f636b436f6e7461696e6572070001240309706172616772617068070001250604000126057468697264280001250f6261636b67726f756e64436f6c6f7201770764656661756c74280001250974657874436f6c6f7201770764656661756c74280001250d74657874416c69676e6d656e740177046c6566742800012402696401772433333333333333332d333333332d343333332d383333332d3333333333333333333333330101010d17"

    func testGCdMiddleBlockIsSkippedAndSurvivorsProjectInOrder() throws {
        // Replaces Task 2's deferred `testDeletedBlocksAreSkipped`: this is
        // the real yjs shape (a ContentDeleted tombstone for the deleted
        // container item itself, and its entire subtree collapsed into one
        // anonymous GC struct), not a hand-built delete-set frame.
        let replica = try doc(fromHex: gcdMiddleBlockHex)
        let projected = YBlockProjection.project(replica)
        replica.destroy()

        XCTAssertEqual(projected.blocks.count, 2, "the deleted middle block must not appear")
        XCTAssertEqual(
            projected.blocks.map(\.id),
            [
                "11111111-1111-4111-8111-111111111111",
                "33333333-3333-4333-8333-333333333333",
            ])
        XCTAssertEqual(projected.blocks.map(\.node), ["paragraph", "paragraph"])
        XCTAssertEqual(projected.blocks[0].runs, [InlineRun("first")])
        XCTAssertEqual(projected.blocks[1].runs, [InlineRun("third")])
        for block in projected.blocks {
            XCTAssertEqual(block.fidelity, .modeled, "\(block.id) expected .modeled, got \(block.fidelity)")
        }
        XCTAssertTrue(projected.isFullyRenderable)
        XCTAssertTrue(projected.isFullyModeled)
    }

    // MARK: - Fixture 4: mergeUpdates output -- a dropped middle update leaves a Skip

    private let mergedWithDroppedMiddleHex =
        "0112010007010e646f63756d656e742d73746f7265030a626c6f636b47726f757007000100030e626c6f636b436f6e7461696e6572070001010309706172616772617068070001020604000103056669727374280001020f6261636b67726f756e64436f6c6f7201770764656661756c74280001020974657874436f6c6f7201770764656661756c74280001020d74657874416c69676e6d656e740177046c6566742800010102696401772431313131313131312d313131312d343131312d383131312d3131313131313131313131310a1787010d030e626c6f636b436f6e7461696e6572070001240309706172616772617068070001250604000126057468697264280001250f6261636b67726f756e64436f6c6f7201770764656661756c74280001250974657874436f6c6f7201770764656661756c74280001250d74657874416c69676e6d656e740177046c6566742800012402696401772433333333333333332d333333332d343333332d383333332d33333333333333333333333300"

    func testMergedUpdateWithDroppedMiddleBlockProjectsOnlyTheSurvivingBlock() throws {
        // Third block's container item has its `origin` inside the Skip'd
        // gap (yjs threads list-type siblings by origin, not an explicit
        // index) -- it can never integrate without the missing middle
        // update, so it stays in pendingStructs forever. Applying this
        // merged (Skip-bearing) update must project *identically* to
        // applying update A and then update C sequentially (skipping B
        // entirely) -- verified against the oracle directly, both leave only
        // the first block visible with the third permanently pending.
        let mergedReplica = try doc(fromHex: mergedWithDroppedMiddleHex)
        XCTAssertNotNil(
            mergedReplica.store.pendingStructs,
            "the third block's item must be genuinely stranded, not silently dropped")
        let mergedProjected = YBlockProjection.project(mergedReplica)  // must not throw or trap
        mergedReplica.destroy()

        XCTAssertEqual(mergedProjected.blocks.count, 1)
        XCTAssertEqual(mergedProjected.blocks[0].id, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(mergedProjected.blocks[0].runs, [InlineRun("first")])
        XCTAssertTrue(mergedProjected.isFullyRenderable)
        XCTAssertTrue(mergedProjected.isFullyModeled)
    }

    // MARK: - Fixture 5: nested list -- a blockContainer with a nested blockGroup child

    private let nestedListHex =
        "0112010007010e646f63756d656e742d73746f7265030a626c6f636b47726f757007000100030e626c6f636b436f6e7461696e65722800010102696401772431313131313131312d313131312d343131312d383131312d31313131313131313131313107000101030e62756c6c65744c6973744974656d07000103060400010406706172656e74280001030f6261636b67726f756e64436f6c6f7201770764656661756c74280001030974657874436f6c6f7201770764656661756c74280001030d74657874416c69676e6d656e740177046c656674870103030a626c6f636b47726f75700700010e030e626c6f636b436f6e7461696e65720700010f030e62756c6c65744c6973744974656d070001100604000111056368696c64280001100f6261636b67726f756e64436f6c6f7201770764656661756c74280001100974657874436f6c6f7201770764656661756c74280001100d74657874416c69676e6d656e740177046c6566742800010f02696401772432323232323232322d323232322d343232322d383232322d32323232323232323232323200"

    func testNestedListBlockGroupIsOpaque() throws {
        let replica = try doc(fromHex: nestedListHex)
        let projected = YBlockProjection.project(replica)
        replica.destroy()

        // Only the OUTER container projects at the top level; the nested
        // blockGroup's own child is never separately visited.
        XCTAssertEqual(projected.blocks.count, 1)
        let block = projected.blocks[0]
        XCTAssertEqual(block.id, "11111111-1111-4111-8111-111111111111", "id stays legible even when opaque")
        guard case .opaque(let reason) = block.fidelity else {
            XCTFail("expected .opaque, got \(block.fidelity)")
            return
        }
        XCTAssertEqual(reason, "nested children")
        XCTAssertFalse(projected.isFullyRenderable)
        XCTAssertFalse(projected.isFullyModeled)
        XCTAssertNil(YBlockProjection.projectedMarkdown(projected))
    }
}
