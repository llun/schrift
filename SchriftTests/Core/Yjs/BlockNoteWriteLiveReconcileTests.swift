import XCTest

@testable import Schrift

/// The **live** reconcile (`BlockNoteWrite.applyEdit`, the writer path) against
/// the legacy reconcile (`applyEditLegacy`, the Docs 6 save) — the split gate of
/// plan decision 6. `BlockNoteWriteTests` pins from-empty byte identity and
/// `BlockNoteWriteOracleTests` pins the incremental document-level behaviour;
/// these pin what is specific to the writer path: the two fallbacks, the
/// `old`-relative prop reconcile, the live-id addressing, the code-block mark
/// rule, and a deterministic slice of the session-local parity lane.
final class BlockNoteWriteLiveReconcileTests: XCTestCase {

    // MARK: - Helpers

    private var baseProps: [(key: String, value: YAnyValue)] {
        [
            ("backgroundColor", .string("default")), ("textColor", .string("default")),
            ("textAlignment", .string("left")),
        ]
    }

    private func para(_ text: String, id: String) -> BlockNoteBlock {
        BlockNoteBlock(node: "paragraph", props: baseProps, runs: text.isEmpty ? [] : [InlineRun(text)], id: id)
    }

    private func heading(_ level: Int, _ text: String, id: String) -> BlockNoteBlock {
        BlockNoteBlock(
            node: "heading", props: baseProps + [("level", .int(level)), ("isToggleable", .bool(false))],
            runs: [InlineRun(text)], id: id)
    }

    private func checklist(_ text: String, checked: Bool, id: String) -> BlockNoteBlock {
        BlockNoteBlock(
            node: "checkListItem", props: baseProps + [("checked", .bool(checked))], runs: [InlineRun(text)], id: id)
    }

    private func block(from projected: ProjectedBlock) -> BlockNoteBlock {
        BlockNoteBlock(
            node: projected.node, props: projected.props.map { ($0.key, $0.value) }, runs: projected.runs,
            id: projected.id)
    }

    private func project(_ doc: YDoc, origin: String? = nil) -> [ProjectedBlock] {
        YBlockProjection.project(doc, interlinkingOrigin: origin).blocks
    }

    private func prop(_ blocks: [ProjectedBlock], _ key: String) -> YAnyValue? {
        blocks.first?.props.first { $0.key == key }?.value
    }

    // MARK: - Inline-node blocks fall back to the legacy reconcile

    /// The web editor's `interlinkingLinkInline` fixture (captured from real
    /// yjs@13.6.31 — see `YBlockProjectionInterlinkingLinkTests`): a paragraph
    /// `xmlText("before ") + interlinkingLinkInline(title: "My Page") + xmlText(" after")`.
    /// The projection folds the node into a run whose text is the title, while the
    /// live element counts it as one unit, so the writer's run-space offsets do not
    /// map to live offsets: the survivor must go through the legacy rebuild.
    private let interlinkingHex =
        "0110010007010e646f63756d656e742d73746f7265030a626c6f636b47726f757007000100030e626c6f636b436f6e7461696e65722800010102696401772431313131313131312d313131312d343131312d383131312d313131313131313131313131070001010309706172616772617068280001030f6261636b67726f756e64436f6c6f7201770764656661756c74280001030974657874436f6c6f7201770764656661756c74280001030d74657874416c69676e6d656e740177046c656674070001030604000107076265666f7265208701070316696e7465726c696e6b696e674c696e6b496e6c696e652800010f05646f63496401772432323232323232322d323232322d343232322d383232322d3232323232323232323232322800010f057469746c650177074d7920506167652800010f0864697361626c656401792800010f07747269676765720177012f87010f06040001140620616674657200"
    private let interlinkingOrigin = "https://docs.example.test"

    private func interlinkingReplica() throws -> YDoc {
        let doc = YDoc(clientID: 99)
        try doc.applyUpdate(try YUpdateDecoder.decode(Data(hex: interlinkingHex)))
        return doc
    }

    func testEditingABlockWithAnInlineNodeFallsBackToLegacyAndSucceeds() throws {
        let doc = try interlinkingReplica()
        defer { doc.destroy() }
        let projected = project(doc, origin: interlinkingOrigin)
        XCTAssertEqual(projected.first?.fidelity, .modeled)
        let old = block(from: projected[0])
        XCTAssertEqual(old.runs.count, 3)

        var new = old
        new.runs = [old.runs[0], old.runs[1], InlineRun(" later")]
        _ = try BlockNoteWrite.applyEdit(old: [old], new: [new], to: doc)

        XCTAssertEqual(project(doc, origin: interlinkingOrigin).map(\.runs), [new.runs])
    }

    func testEditingAnotherBlockInADocumentWithAnInlineNodeSucceeds() throws {
        let doc = try interlinkingReplica()
        defer { doc.destroy() }
        let inline = block(from: project(doc, origin: interlinkingOrigin)[0])
        let other = para("second", id: "33333333-3333-4333-8333-333333333333")
        _ = try BlockNoteWrite.applyEdit(old: [inline], new: [inline, other], to: doc)

        let seeded = project(doc, origin: interlinkingOrigin).map(block(from:))
        var edited = other
        edited.runs = [InlineRun("second!")]
        _ = try BlockNoteWrite.applyEdit(old: seeded, new: [inline, edited], to: doc)

        XCTAssertEqual(project(doc, origin: interlinkingOrigin).map(\.runs), [inline.runs, edited.runs])
    }

    // MARK: - Props are reconciled against `old`, not the live element

    /// A remote peer changes the heading level to 2 while the editor's `old` still
    /// shows 1 and its `new` is unchanged. The writer must not write 1 back: only
    /// props that differ between `old` and `new` are overrides.
    func testAPropTheEditorDidNotChangeIsNotWrittenBackOverARemoteValue() throws {
        let id = "11111111-1111-4111-8111-111111111111"
        let level1 = heading(1, "title", id: id)
        let level2 = heading(2, "title", id: id)
        let doc = YDoc(clientID: 42)
        defer { doc.destroy() }
        _ = try BlockNoteWrite.applyEdit(old: [], new: [level1], to: doc)
        _ = try BlockNoteWrite.applyEdit(old: [level1], new: [level2], to: doc)
        XCTAssertEqual(prop(project(doc), "level"), .int(2))

        _ = try BlockNoteWrite.applyEdit(old: [level1], new: [level1], to: doc)

        XCTAssertEqual(prop(project(doc), "level"), .int(2), "the editor's stale `old` must not win")
    }

    // MARK: - The writer path's own behaviour

    /// A same-type prop change writes only the changed prop, byte-for-byte as
    /// `BlockNoteWriter.setBlockType`'s in-place update does.
    func testChecklistToggleWritesOnlyTheChangedPropAndMatchesTheWriter() throws {
        let id = "44444444-4444-4444-4444-444444444444"
        let unchecked = checklist("task", checked: false, id: id)
        let checked = checklist("task", checked: true, id: id)

        let live = YDoc(clientID: 42)
        defer { live.destroy() }
        _ = try BlockNoteWrite.applyEdit(old: [], new: [unchecked], to: live)
        let update = try BlockNoteWrite.applyEdit(old: [unchecked], new: [checked], to: live)

        let writer = YDoc(clientID: 42)
        defer { writer.destroy() }
        _ = try BlockNoteWrite.applyEdit(old: [], new: [unchecked], to: writer)
        let writerUpdate = try BlockNoteWriter(doc: writer).setBlockType(
            block: id, to: "checkListItem", props: [("checked", .bool(true))])

        XCTAssertEqual(update, writerUpdate, "the live reconcile must be the writer's own in-place update")
        XCTAssertEqual(prop(project(live), "checked"), .bool(true))
    }

    /// Replica A toggles the checkbox through `applyEdit` while replica B types into
    /// the same item; after exchanging updates both ways B's text survives. The
    /// legacy reconcile converges too (a `mapSet` and a text insert commute), so this
    /// pins the writer path's convergence, not a legacy bug.
    func testConcurrentToggleAndTypingConverge() throws {
        let id = "44444444-4444-4444-4444-444444444444"
        let unchecked = checklist("task", checked: false, id: id)
        let checked = checklist("task", checked: true, id: id)
        let typed = checklist("task!", checked: false, id: id)

        for (name, apply) in [
            (
                "writer",
                { (doc: YDoc, old: [BlockNoteBlock], new: [BlockNoteBlock]) in
                    try BlockNoteWrite.applyEdit(old: old, new: new, to: doc)
                }
            ),
            (
                "legacy",
                { (doc: YDoc, old: [BlockNoteBlock], new: [BlockNoteBlock]) in
                    try BlockNoteWrite.applyEditLegacy(old: old, new: new, to: doc)
                }
            ),
        ] {
            let seed = YDoc(clientID: 1)
            _ = try BlockNoteWrite.applyEdit(old: [], new: [unchecked], to: seed)
            let state = try YStateEncoder.encodeStateAsUpdate(seed)
            seed.destroy()

            let a = YDoc(clientID: 2)
            let b = YDoc(clientID: 3)
            try a.applyUpdate(try YUpdateDecoder.decode(state))
            try b.applyUpdate(try YUpdateDecoder.decode(state))
            let toggle = try apply(a, [unchecked], [checked])
            let typing = try apply(b, [unchecked], [typed])
            try a.applyUpdate(try YUpdateDecoder.decode(typing))
            try b.applyUpdate(try YUpdateDecoder.decode(toggle))

            for doc in [a, b] {
                XCTAssertEqual(project(doc).first?.runs, [InlineRun("task!")], name)
                XCTAssertEqual(prop(project(doc), "checked"), .bool(true), name)
                doc.destroy()
            }
        }
    }

    /// `quote` has no writer intents, so a text edit falls back to the legacy
    /// reconcile instead of throwing (a throw would fail-safe the document).
    func testQuoteTextEditFallsBackToLegacy() throws {
        let id = "55555555-5555-4555-8555-555555555555"
        let quote = BlockNoteBlock(
            node: "quote", props: [("backgroundColor", .string("default")), ("textColor", .string("default"))],
            runs: [InlineRun("quoted")], id: id)
        var edited = quote
        edited.runs = [InlineRun("quoted!")]
        let doc = YDoc(clientID: 42)
        defer { doc.destroy() }
        _ = try BlockNoteWrite.applyEdit(old: [], new: [quote], to: doc)
        _ = try BlockNoteWrite.applyEdit(old: [quote], new: [edited], to: doc)
        XCTAssertEqual(project(doc).map(\.runs), [edited.runs])
    }

    /// `image` has no writer intents either; a prop change falls back to legacy.
    func testImagePropChangeFallsBackToLegacy() throws {
        let id = "66666666-6666-4666-8666-666666666666"
        let image = BlockNoteBlock(
            node: "image",
            props: [
                ("textAlignment", .string("left")), ("backgroundColor", .string("default")),
                ("name", .string("photo.jpg")), ("url", .string("https://docs.example.test/photo.jpg")),
                ("caption", .string("")), ("showPreview", .bool(true)), ("previewWidth", .undefined),
            ],
            runs: [], id: id)
        var captioned = image
        captioned.props = image.props.map { $0.key == "caption" ? ("caption", .string("a caption")) : $0 }
        let doc = YDoc(clientID: 42)
        defer { doc.destroy() }
        _ = try BlockNoteWrite.applyEdit(old: [], new: [image], to: doc)
        _ = try BlockNoteWrite.applyEdit(old: [image], new: [captioned], to: doc)
        XCTAssertEqual(prop(project(doc), "caption"), .string("a caption"))
    }

    /// The one intended difference the parity lane surfaced: a code block whose runs
    /// carry marks (a document BlockNote cannot produce — the projection reads it as
    /// opaque `marked code`) keeps them on the legacy path and drops them on the
    /// writer path, which is BlockNote's own rule for code blocks.
    func testCodeBlockDropsMarksOnTheWriterPathAndLegacyKeepsThem() throws {
        let id = "77777777-7777-4777-8777-777777777777"
        let marked = BlockNoteBlock(
            node: "codeBlock", props: [("language", .string("text"))],
            runs: [InlineRun("abc", marks: [("bold", "{}")])], id: id)
        var replaced = marked
        replaced.runs = [InlineRun("xyz", marks: [("bold", "{}")])]

        let live = YDoc(clientID: 42)
        defer { live.destroy() }
        _ = try BlockNoteWrite.applyEdit(old: [], new: [marked], to: live)
        _ = try BlockNoteWrite.applyEdit(old: [marked], new: [replaced], to: live)

        let legacy = YDoc(clientID: 42)
        defer { legacy.destroy() }
        _ = try BlockNoteWrite.applyEdit(old: [], new: [marked], to: legacy)
        _ = try BlockNoteWrite.applyEditLegacy(old: [marked], new: [replaced], to: legacy)

        XCTAssertEqual(project(live).first?.runs, [InlineRun("xyz")], "the writer drops marks in a code block")
        XCTAssertEqual(project(legacy).first?.runs, [replaced.runs[0]], "the legacy splice keeps them")
    }

    /// The writer addresses the container's live id, not the caller's: the editor
    /// re-identifies a row after a remote structural change while the replica keeps
    /// the server's id. The survivor is still reconciled in place.
    func testWriterAddressesTheLiveIDWhenTheEditorIDDiffers() throws {
        let liveID = "11111111-1111-4111-8111-111111111111"
        let editorID = "99999999-9999-4999-8999-999999999999"
        let doc = YDoc(clientID: 42)
        defer { doc.destroy() }
        _ = try BlockNoteWrite.applyEdit(old: [], new: [para("hello", id: liveID)], to: doc)

        let stale = para("hello", id: editorID)
        var edited = stale
        edited.runs = [InlineRun("hello!")]
        _ = try BlockNoteWrite.applyEdit(old: [stale], new: [edited], to: doc)

        XCTAssertEqual(project(doc).map(\.id), [liveID], "the live id survives")
        XCTAssertEqual(project(doc).map(\.runs), [edited.runs])
    }

    // MARK: - A deterministic slice of the parity lane

    /// A fixed-seed slice of the session-local parity lane (the full lane ran 3000
    /// cases, 0 mismatches, and was never committed): random markdown edits applied
    /// to two identical replicas through `applyEditLegacy` and `applyEdit`, comparing
    /// the projected document. Deterministic — a failure reproduces from the seed.
    func testDeterministicParitySlice() throws {
        var rng = SeededGenerator(seed: 0xB5B_5B5B)
        var cases = 0
        for _ in 0..<30 {
            let old = randomDocument(&rng)
            let new = randomEdit(old, &rng)
            let legacy = YDoc(clientID: 1)
            let live = YDoc(clientID: 2)
            defer {
                legacy.destroy()
                live.destroy()
            }
            _ = try BlockNoteWrite.applyEdit(old: [], new: old, to: legacy)
            let state = try YStateEncoder.encodeStateAsUpdate(legacy)
            try live.applyUpdate(try YUpdateDecoder.decode(state))

            _ = try BlockNoteWrite.applyEditLegacy(old: old, new: new, to: legacy)
            _ = try BlockNoteWrite.applyEdit(old: old, new: new, to: live)

            XCTAssertEqual(project(legacy), project(live), "seed 0xB5B5B5B, case \(cases)")
            XCTAssertEqual(project(live).map(\.id), new.map(\.id), "case \(cases)")
            XCTAssertEqual(project(live).map(\.node), new.map(\.node), "case \(cases)")
            XCTAssertEqual(project(live).map(\.runs), new.map { normalized($0.runs) }, "case \(cases)")
            cases += 1
        }
        XCTAssertEqual(cases, 30)
    }

    /// The projection drops empty runs and merges adjacent runs with the same marks,
    /// so the expected `new` is normalised the same way before comparison.
    private func normalized(_ runs: [InlineRun]) -> [InlineRun] {
        var result: [InlineRun] = []
        for run in runs where !run.text.isEmpty {
            if let last = result.last,
                last.marks.map({ [$0.key, $0.valueJSON] }) == run.marks.map({ [$0.key, $0.valueJSON] })
            {
                result[result.count - 1] = InlineRun(last.text + run.text, marks: run.marks)
            } else {
                result.append(run)
            }
        }
        return result
    }

    // MARK: - Deterministic generator

    /// xorshift64*, the same PRNG the other B6 property tests use.
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

    private static let alphabet = ["a", "b", "c", " ", "😀"]
    private static let markSets: [[(key: String, valueJSON: String)]] = [
        [], [("bold", "{}")], [("italic", "{}")], [("link", "{\"href\":\"a\"}")],
    ]
    private static let nodes = [
        "paragraph", "heading", "bulletListItem", "checkListItem", "codeBlock", "quote", "divider", "image",
    ]

    /// A counter, not a random value: ids must be unique within a document, and a
    /// 32-bit draw can collide.
    private var nextID = 0
    private func randomID() -> String {
        nextID += 1
        return String(format: "%08x-1111-4111-8111-111111111111", nextID)
    }

    private func randomRuns(_ rng: inout SeededGenerator, node: String) -> [InlineRun] {
        guard node != "divider", node != "image" else { return [] }
        var runs: [InlineRun] = []
        for _ in 0..<Int.random(in: 0...3, using: &rng) {
            var text = ""
            for _ in 0..<Int.random(in: 0...4, using: &rng) { text += Self.alphabet.randomElement(using: &rng)! }
            // A code block drops marks on the writer path (the documented intended
            // difference), so the lane never gives one marks.
            let marks = node == "codeBlock" ? [] : Self.markSets.randomElement(using: &rng)!
            runs.append(InlineRun(text, marks: marks))
        }
        return runs
    }

    private func randomProps(_ rng: inout SeededGenerator, node: String) -> [(key: String, value: YAnyValue)] {
        switch node {
        case "heading":
            return baseProps + [("level", .int(Int.random(in: 1...3, using: &rng))), ("isToggleable", .bool(false))]
        case "checkListItem": return baseProps + [("checked", .bool(Bool.random(using: &rng)))]
        case "numberedListItem": return baseProps + [("start", .undefined)]
        case "codeBlock": return [("language", .string("text"))]
        case "quote": return [("backgroundColor", .string("default")), ("textColor", .string("default"))]
        case "divider": return []
        case "image":
            return [
                ("textAlignment", .string("left")), ("backgroundColor", .string("default")),
                ("name", .string("photo.jpg")), ("url", .string("https://docs.example.test/photo.jpg")),
                ("caption", .string("")), ("showPreview", .bool(true)), ("previewWidth", .undefined),
            ]
        default: return baseProps
        }
    }

    private func randomBlock(_ rng: inout SeededGenerator) -> BlockNoteBlock {
        let node = Self.nodes.randomElement(using: &rng)!
        return BlockNoteBlock(
            node: node, props: randomProps(&rng, node: node), runs: randomRuns(&rng, node: node),
            id: randomID())
    }

    private func randomDocument(_ rng: inout SeededGenerator) -> [BlockNoteBlock] {
        (0..<Int.random(in: 1...3, using: &rng)).map { _ in randomBlock(&rng) }
    }

    private func randomEdit(_ old: [BlockNoteBlock], _ rng: inout SeededGenerator) -> [BlockNoteBlock] {
        var new = old
        switch Int.random(in: 0...6, using: &rng) {
        case 0:  // text edit
            let index = Int.random(in: 0..<new.count, using: &rng)
            new[index].runs = randomRuns(&rng, node: new[index].node)
        case 1:  // prop change
            let index = Int.random(in: 0..<new.count, using: &rng)
            new[index].props = randomProps(&rng, node: new[index].node)
        case 2:  // kind change
            let index = Int.random(in: 0..<new.count, using: &rng)
            let node = Self.nodes.randomElement(using: &rng)!
            new[index].node = node
            new[index].props = randomProps(&rng, node: node)
            new[index].runs = randomRuns(&rng, node: node)
        case 3:  // insert
            new.insert(randomBlock(&rng), at: Int.random(in: 0...new.count, using: &rng))
        case 4:  // delete
            if new.count > 1 { new.remove(at: Int.random(in: 0..<new.count, using: &rng)) }
        case 5:  // move
            if new.count > 1 {
                let block = new.remove(at: Int.random(in: 0..<new.count, using: &rng))
                new.insert(block, at: Int.random(in: 0...new.count, using: &rng))
            }
        default:  // empty a block
            let index = Int.random(in: 0..<new.count, using: &rng)
            new[index].runs = []
        }
        return new
    }
}
