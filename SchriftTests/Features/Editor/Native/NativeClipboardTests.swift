import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import Schrift

/// PR04b's plain-text clipboard, through the view's own `copy:`/`cut:`/
/// `paste:` actions: copy is one line per block and writes nothing; cut is copy
/// plus one range delete; paste is one command, newlines splitting blocks, and
/// rich content contributes only its plain text.
@MainActor
final class NativeClipboardTests: NativeEditingTestCase {
    func testCopyGivesOneLinePerBlockInEitherDirection() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        for (anchor, head) in [((Self.firstID, 6), (Self.thirdID, 5)), ((Self.thirdID, 5), (Self.firstID, 6))] {
            try select(harness, from: anchor, to: head)
            harness.view.copy(nil)
            await harness.settle()
            XCTAssertEqual(harness.pasteboard.string, "paragraph.\nSecond paragraph has bold words inside it.\nThird")
        }
        // From a block's end to the next block's start: one line break.
        let end = try location(harness.session, Self.firstID, 16)
        setSelection(harness, NSRange(location: end, length: 1))
        harness.view.copy(nil)
        await harness.settle()
        XCTAssertEqual(harness.pasteboard.string, "\n")
        // Through the end of the document: the last block's text, no trailing break.
        setSelection(harness, NSRange(location: 0, length: harness.view.textStorage.length))
        harness.view.copy(nil)
        await harness.settle()
        XCTAssertEqual(
            harness.pasteboard.string,
            "First paragraph.\nSecond paragraph has bold words inside it.\nThird paragraph.")
        try await assertConsistent(harness, localCommands: 0)
    }

    func testCopySkipsPreservedPlaceholdersAndKeepsEmojiCombiningAndRTL() async throws {
        let harness = try await makeHarness([
            paragraph("a", "a😀e\u{301}"), BlockNoteBlock(node: "table", props: [], runs: [], id: "table"),
            paragraph("rtl", "مرحبا"), paragraph("blank", ""),
        ])
        addTeardownBlock { await harness.close() }
        setSelection(harness, NSRange(location: 1, length: harness.view.textStorage.length - 1))
        harness.view.copy(nil)
        await harness.settle()
        XCTAssertEqual(harness.pasteboard.string, "😀e\u{301}\nمرحبا\n")
        try await assertConsistent(harness, localCommands: 0)
    }

    /// Nothing copyable (only a placeholder) leaves the pasteboard alone.
    func testCopyingOnlyAPlaceholderKeepsThePasteboard() async throws {
        let harness = try await makeHarness([
            paragraph("a", "Alpha"), BlockNoteBlock(node: "table", props: [], runs: [], id: "table"),
        ])
        addTeardownBlock { await harness.close() }
        harness.pasteboard.string = "kept"
        let table = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "table"))
        setSelection(harness, NSRange(location: table.textRange.location + 1, length: 3))
        harness.view.copy(nil)
        await harness.settle()
        harness.view.cut(nil)
        await harness.settle()
        XCTAssertEqual(harness.pasteboard.string, "kept")
        try await assertConsistent(harness, localCommands: 0)
    }

    /// While text is marked, storage offsets do not match the model: copy,
    /// like cut and paste, does nothing.
    func testCopyDuringCompositionDoesNothing() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        harness.pasteboard.string = "kept"
        setSelection(harness, NSRange(location: 2, length: 0))
        harness.view.setMarkedText("にほん", selectedRange: NSRange(location: 0, length: 3))
        XCTAssertEqual(harness.input.composition.isActive, true)
        XCTAssertEqual(harness.view.selectedRange.length, 3)
        harness.view.copy(nil)
        await harness.settle()
        harness.view.cut(nil)
        await harness.settle()
        harness.view.paste(nil)
        await harness.settle()
        XCTAssertEqual(harness.pasteboard.string, "kept")
        harness.view.unmarkText()
        await harness.settle()
        try await assertConsistent(harness, localCommands: 1)
    }

    /// A paste over either bound is refused whole with a notice; nothing is
    /// written, not even its first lines.
    func testAnOversizedPasteIsRefusedWhole() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let original = harness.view.textStorage.string
        setSelection(harness, NSRange(location: 2, length: 0))
        for text in [
            Array(repeating: "line", count: NativeClipboard.maxPasteLines + 1).joined(separator: "\r\n"),
            String(repeating: "x", count: NativeClipboard.maxPasteUTF16 + 1),
        ] {
            harness.pasteboard.string = text
            harness.view.paste(nil)
            await harness.settle()
            XCTAssertEqual(harness.input.noticeKey, .native_editor_paste_too_large)
            XCTAssertEqual(harness.view.textStorage.string, original)
        }
        try await assertConsistent(harness, localCommands: 0)
        // At the line bound it is one command.
        harness.pasteboard.string = Array(repeating: "l", count: NativeClipboard.maxPasteLines).joined(separator: "\n")
        harness.view.paste(nil)
        await harness.settle()
        XCTAssertNil(harness.input.noticeKey)
        XCTAssertEqual(harness.session.surface.blocks.count, 3 + NativeClipboard.maxPasteLines - 1)
        try await assertConsistent(harness, localCommands: 1)
    }

    func testCutIsCopyPlusOneRangeDelete() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try select(harness, from: (Self.secondID, 7), to: (Self.firstID, 6))
        harness.view.cut(nil)
        await harness.settle()
        XCTAssertEqual(harness.pasteboard.string, "paragraph.\nSecond ")
        XCTAssertEqual(texts(session), ["First paragraph has bold words inside it.", "Third paragraph."])
        XCTAssertEqual(lastRange(harness)?.replacement, "")
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: 6, length: 0))
        try await assertConsistent(harness, localCommands: 1)
    }

    /// Multi-line paste over a selection is one command; newlines (CRLF too)
    /// split blocks and the last line takes the selection's tail.
    func testMultiLinePasteOverASelectionIsOneCommand() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try select(harness, from: (Self.firstID, 6), to: (Self.secondID, 7))
        harness.pasteboard.string = "one\r\ntwo\n\nthree "
        harness.view.paste(nil)
        await harness.settle()
        let range = try XCTUnwrap(lastRange(harness))
        XCTAssertEqual(range.replacement, "one\ntwo\n\nthree ")
        XCTAssertEqual(range.newBlockIDs.count, 3)
        XCTAssertEqual(session.surface.blocks.map(\.id), [Self.firstID] + range.newBlockIDs + [Self.thirdID])
        XCTAssertEqual(
            texts(session), ["First one", "two", "", "three paragraph has bold words inside it.", "Third paragraph."])
        let last = try block(session, try XCTUnwrap(range.newBlockIDs.last))
        XCTAssertEqual(last.runs.first { $0.text == "bold words" }?.marks.map(\.key), ["bold"], "the tail keeps marks")
        let loc = try location(session, try XCTUnwrap(range.newBlockIDs.last), 6)
        XCTAssertEqual(
            harness.view.selectedRange,
            NSRange(location: loc, length: 0))
        try await assertConsistent(harness, localCommands: 1)
    }

    /// Copy then paste at a caret rebuilds the copied structure; a single
    /// pasted line inside one block is ordinary typing.
    func testCopyThenPasteAtACaretRoundTrips() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try select(harness, from: (Self.firstID, 0), to: (Self.secondID, 6))
        harness.view.copy(nil)
        await harness.settle()
        let thirdLoc = try location(session, Self.thirdID, 16)
        setSelection(harness, NSRange(location: thirdLoc, length: 0))
        harness.view.paste(nil)
        await harness.settle()
        XCTAssertEqual(texts(session).suffix(2), ["Third paragraph.First paragraph.", "Second"])
        try await assertConsistent(harness, localCommands: 1)

        harness.pasteboard.string = " pasted"
        harness.view.paste(nil)
        await harness.settle()
        XCTAssertEqual(texts(session).last, "Second pasted")
        XCTAssertEqual(harness.log.commands.last?.kind, .replace(range: 6..<6, replacement: " pasted"))
        try await assertConsistent(harness, localCommands: 2)
    }

    /// Rich content on the pasteboard contributes only its plain text: the
    /// pasted runs carry the marks at the caret, never the source's styles.
    func testRichPasteTakesOnlyThePlainText() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let rich = NSAttributedString(
            string: "Rich\ntext", attributes: [.font: UIFont.boldSystemFont(ofSize: 30), .foregroundColor: UIColor.red])
        let rtf = try rich.data(
            from: NSRange(location: 0, length: rich.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        harness.pasteboard.setItems([
            [UTType.rtf.identifier: rtf, UTType.utf8PlainText.identifier: "Rich\ntext"]
        ])
        let firstLoc = try location(session, Self.firstID, 5)
        setSelection(harness, NSRange(location: firstLoc, length: 0))
        harness.view.paste(nil)
        await harness.settle()
        XCTAssertEqual(texts(session)[0...1], ["FirstRich", "text paragraph."])
        XCTAssertTrue(session.surface.blocks[0...1].allSatisfy { $0.runs.allSatisfy(\.marks.isEmpty) })
        try await assertConsistent(harness, localCommands: 1)
    }

    /// The view's edit actions route exactly once: UIKit never applies a
    /// paste or a cut itself, and an empty pasteboard is a no-op.
    func testEditActionsRouteOnceAndNeverThroughUIKit() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        harness.pasteboard.items = []
        setSelection(harness, NSRange(location: 2, length: 0))
        harness.view.paste(nil)
        await harness.settle()
        harness.view.cut(nil)
        await harness.settle()
        harness.view.copy(nil)
        await harness.settle()
        XCTAssertNil(harness.pasteboard.string)
        try await assertConsistent(harness, localCommands: 0)

        harness.pasteboard.string = "a\nb"
        harness.view.pasteAndMatchStyle(nil)
        await harness.settle()
        XCTAssertEqual(texts(session)[0...1], ["Fia", "brst paragraph."])
        try await assertConsistent(harness, localCommands: 1)
    }

    // MARK: - PR06d lossless subtrees

    private var payloadType: String { BlockNoteSubtreePayload.pasteboardType }

    private func nested(_ block: BlockNoteBlock, _ children: [BlockNoteBlock]) -> BlockNoteBlock {
        var block = block
        block.children = children
        return block
    }

    /// The block ids a lossless paste added, in preorder: the engine mints them.
    private func pastedIDs(_ harness: Harness) async throws -> [String] {
        let before = Set(harness.session.surface.blocks.map(\.id))
        harness.view.paste(nil)
        await harness.settle()
        guard case .insertSubtrees? = harness.log.commands.last?.kind else {
            XCTFail("not a lossless paste")
            return []
        }
        return harness.session.surface.blocks.map(\.id).filter { !before.contains($0) }
    }

    private func caret(_ harness: Harness, _ id: String, _ offset: Int) throws {
        setSelection(harness, NSRange(location: try location(harness.session, id, offset), length: 0))
    }

    /// A bullet with an unknown mark, a link and an unknown prop over two
    /// nested levels, then an empty paragraph.
    private func richSeed() -> [BlockNoteBlock] {
        var rich = bullet("b", "")
        rich.runs = [
            InlineRun("Plain "), InlineRun("custom", marks: [("x-custom", #"{"v":1}"#), ("bold", "{}")]),
            InlineRun(" link", marks: [("link", #"{"href":"https://example.test/"}"#)]),
        ]
        rich.props += [("x-extra", .string("kept"))]
        return [
            paragraph("a", "Alpha"), nested(rich, [nested(bullet("b1", "Child"), [paragraph("b11", "Deep")])]),
            paragraph("c", "Gamma"), paragraph("empty", ""),
        ]
    }

    /// Copy block puts the lossless payload beside the plain text; a paste at
    /// a caret is one command inserting the subtree with fresh ids after the
    /// caret's block, or in place of an empty paragraph. Byte-identical
    /// payloads (only the ids differ) prove the round trip lossless.
    func testCopyBlockThenPasteRoundTripsLosslesslyWithFreshIDs() async throws {
        let harness = try await makeHarness(richSeed())
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try caret(harness, "b", 0)
        let copiedResult = await harness.run { harness.input.performBlockAction(.copy) }
        XCTAssertTrue(copiedResult)
        let copied = try XCTUnwrap(harness.pasteboard.data(forPasteboardType: payloadType))
        let bPayload = await session.engine { $0.subtreePayload(["b"]) }
        XCTAssertEqual(copied, bPayload)
        XCTAssertEqual(harness.pasteboard.string, "Plain custom link\nChild\nDeep")
        try await assertConsistent(harness, localCommands: 0)

        try caret(harness, "c", 2)
        let newIDs = try await pastedIDs(harness)
        guard case .insertSubtrees(let payload)? = harness.log.commands.last?.kind else {
            return XCTFail("not a lossless paste")
        }
        XCTAssertEqual(payload, copied)
        XCTAssertEqual(newIDs.count, 3)
        XCTAssertEqual(session.surface.blocks.map(\.id), ["a", "b", "b1", "b11", "c"] + newIDs + ["empty"])
        XCTAssertEqual(session.surface.blocks.map(\.depth), [0, 0, 1, 2, 0, 0, 1, 2, 0])
        var fresh = newIDs[...]
        let original = try XCTUnwrap(try BlockNoteSubtreePayload.decode(copied).first)
        let expected = try BlockNoteSubtreePayload.encode([original.replacingIDs(&fresh)])
        let actualPayload = await session.engine { $0.subtreePayload([newIDs[0]]) }
        XCTAssertEqual(actualPayload, expected, "every raw value, mark and prop")
        let loc = try location(session, newIDs[2], 4)
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: loc, length: 0))
        try await assertConsistent(harness, localCommands: 1)

        try caret(harness, "empty", 0)
        let second = try await pastedIDs(harness)
        XCTAssertTrue(Set(second).isDisjoint(with: newIDs), "every paste mints fresh ids")
        XCTAssertEqual(session.surface.blocks.map(\.id).suffix(4), [newIDs[2]] + second, "the empty block is replaced")
        try await assertConsistent(harness, localCommands: 2)
    }

    /// A selection of whole sibling subtrees copies them losslessly; part of
    /// a block, or a block whose visible children are left out, is plain only.
    func testOnlyWholeSubtreeSelectionsCarryAPayload() async throws {
        let harness = try await makeHarness(richSeed())
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try select(harness, from: ("b", 0), to: ("b11", 4))
        harness.view.copy(nil)
        await harness.settle()
        let bPayload = await session.engine { $0.subtreePayload(["b"]) }
        XCTAssertEqual(harness.pasteboard.data(forPasteboardType: payloadType), bPayload)
        try select(harness, from: ("c", 5), to: ("a", 0))
        harness.view.copy(nil)
        await harness.settle()
        let abcPayload = await session.engine { $0.subtreePayload(["a", "b", "c"]) }
        XCTAssertEqual(
            harness.pasteboard.data(forPasteboardType: payloadType), abcPayload)
        for (anchor, head) in [(("a", 1), ("c", 5)), (("b", 0), ("b", 17)), (("b1", 0), ("c", 5))] {
            try select(harness, from: anchor, to: head)
            harness.view.copy(nil)
            await harness.settle()
            XCTAssertNotNil(harness.pasteboard.string)
            XCTAssertNil(harness.pasteboard.data(forPasteboardType: payloadType), "\(anchor)–\(head): plain only")
        }
        try await assertConsistent(harness, localCommands: 0)
    }

    /// A folded toggle's title copies with its hidden children.
    func testCopyingAFoldedToggleCarriesItsHiddenChildren() async throws {
        let toggle = BlockNoteBlock(
            node: "toggleListItem", props: Self.paragraphProps, runs: [InlineRun("Title")], id: "t",
            children: [paragraph("c1", "Hidden one"), paragraph("c2", "Hidden two")])
        let harness = try await makeHarness([toggle, paragraph("x", "After")])
        addTeardownBlock { await harness.close() }
        try select(harness, from: ("t", 0), to: ("t", 5))
        harness.view.copy(nil)
        await harness.settle()
        XCTAssertEqual(harness.pasteboard.string, "Title")
        let payload = try XCTUnwrap(harness.pasteboard.data(forPasteboardType: payloadType))
        XCTAssertEqual(try BlockNoteSubtreePayload.decode(payload).first?.containerCount, 3)
        try await assertConsistent(harness, localCommands: 0)
    }

    private func pasteRefused(
        _ harness: Harness, _ payload: Data, notice: L10nKey, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let before = texts(harness.session)
        harness.pasteboard.setItems([[payloadType: payload, UTType.utf8PlainText.identifier: "plain"]])
        harness.view.paste(nil)
        await harness.settle()
        XCTAssertEqual(harness.input.noticeKey, notice, file: file, line: line)
        XCTAssertEqual(
            texts(harness.session), before, "nothing written, not even the plain text", file: file, line: line)
    }

    /// The payload is untrusted: garbage, a node BlockNote cannot hold, a
    /// container without an id and nesting past the bound are refused whole
    /// by the engine, whether pasted or sent as a command.
    func testMalformedPayloadsAreRefusedWithoutAWrite() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try caret(harness, Self.firstID, 2)
        var deep = paragraph("d17", "Deep")
        for level in (0..<17).reversed() { deep = nested(paragraph("d\(level)", "L\(level)"), [deep]) }
        let malformed = [
            Data([1, 2, 3]),
            BlockNoteYjs.encode([BlockNoteBlock(node: "fancyWidget", props: [], runs: [], id: "w")], clientID: 7),
            BlockNoteYjs.encode([paragraph("", "No id")], clientID: 7),
            BlockNoteYjs.encode([deep], clientID: 7),
        ]
        for payload in malformed {
            try await pasteRefused(harness, payload, notice: .native_editor_paste_unavailable)
            let error = await session.engine { engine -> DocumentEngineError? in
                do {
                    try engine.applyStructural(
                        NativeEditCommand(
                            id: UUID(), baseRevision: engine.revision, blockID: Self.firstID,
                            kind: .insertSubtrees(payload: payload))
                    ) { _ in XCTFail("refused before any write") }
                    return nil
                } catch {
                    return error as? DocumentEngineError
                }
            }
            XCTAssertEqual(error, .unsupportedNativeInput)
        }
        // An oversized payload is the engine's typed refusal (the too-large notice).
        let oversized = Data(count: BlockNoteSubtreePayload.maxBytes + 1)
        let oversizedError = await session.engine { engine -> DocumentEngineError? in
            do {
                try engine.applyStructural(
                    NativeEditCommand(
                        id: UUID(), baseRevision: engine.revision, blockID: Self.firstID,
                        kind: .insertSubtrees(payload: oversized))
                ) { _ in XCTFail("refused before any write") }
                return nil
            } catch {
                return error as? DocumentEngineError
            }
        }
        XCTAssertEqual(oversizedError, .payloadTooLarge)
        let one = BlockNoteYjs.encode([paragraph("p", "One")], clientID: 7)
        try await assertConsistent(harness, localCommands: 0)
        // A valid foreign payload (BlockNote's own document encoding) pastes.
        harness.pasteboard.setItems([[payloadType: one]])
        harness.view.paste(nil)
        await harness.settle()
        XCTAssertEqual(texts(session)[1], "One")
        try await assertConsistent(harness, localCommands: 1)
    }

    func testOversizedPayloadsAreRefusedWhole() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        try caret(harness, Self.firstID, 2)
        try await pasteRefused(
            harness, Data(count: BlockNoteSubtreePayload.maxBytes + 1), notice: .native_editor_paste_too_large)
        let many = (0...BlockNoteSubtreePayload.maxBlocks).map { paragraph("p\($0)", "P") }
        try await pasteRefused(harness, BlockNoteYjs.encode(many, clientID: 7), notice: .native_editor_paste_too_large)
        try await assertConsistent(harness, localCommands: 0)
    }

    /// Over a selection the plain text replaces it, as one range command.
    func testAPayloadOverASelectionPastesThePlainText() async throws {
        let harness = try await makeHarness(richSeed())
        addTeardownBlock { await harness.close() }
        let session = harness.session
        try caret(harness, "b1", 0)
        let copiedResult = await harness.run { harness.input.performBlockAction(.copy) }
        XCTAssertTrue(copiedResult)
        try select(harness, from: ("c", 1), to: ("c", 3))
        harness.view.paste(nil)
        await harness.settle()
        XCTAssertEqual(text(of: try block(session, "c")), "GChild")
        guard case .range? = harness.log.commands.last?.kind else { return XCTFail("not a plain range paste") }
        try await assertConsistent(harness, localCommands: 1)
    }

    // MARK: - Review: untrusted payloads

    /// Records every request URLSession's shared loading would make.
    private final class RecordingProtocol: URLProtocol {
        nonisolated(unsafe) static var requests: [URL] = []
        override class func canInit(with request: URLRequest) -> Bool {
            if let url = request.url { requests.append(url) }
            return false
        }
    }

    /// A pasted link keeps its text but not an href the editor would never
    /// write; an unknown mark carrying a URL goes, one without stays.
    func testPastedLinksAndUnknownURLMarksAreSanitized() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        var block = paragraph("p", "")
        block.runs = [
            InlineRun("evil", marks: [("link", #"{"href":"javascript:alert(1)"}"#)]),
            InlineRun("deep", marks: [("link", #"{"href":"schrift-evil://open"}"#)]),
            InlineRun("ok", marks: [("link", #"{"href":"https://example.test/"}"#)]),
            InlineRun("track", marks: [("x-track", #"{"u":"https://t.example/"}"#)]),
            InlineRun("kept", marks: [("x-plain", #"{"v":1}"#)]),
        ]
        try caret(harness, Self.firstID, 2)
        harness.pasteboard.setItems([[payloadType: BlockNoteYjs.encode([block], clientID: 7)]])
        let ids = try await pastedIDs(harness)
        let pasted = try self.block(session, try XCTUnwrap(ids.first))
        XCTAssertEqual(text(of: pasted), "evildeepoktrackkept", "the text stays")
        XCTAssertEqual(
            pasted.runs.filter { !$0.marks.isEmpty }.map { [$0.text] + $0.marks.map(\.key) },
            [["ok", "link"], ["kept", "x-plain"]])
        try await assertConsistent(harness, localCommands: 1)
    }

    /// A media URL prop must be http(s); a pasted image never loads anything
    /// (the native editor shows media as a placeholder, tap-to-load intact).
    func testPastedMediaURLsAreCheckedAndNeverFetched() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let session = harness.session
        func image(_ url: String) -> BlockNoteBlock {
            BlockNoteBlock(
                node: "image", props: [("url", .string(url)), ("caption", .string("")), ("name", .string("a.png"))],
                runs: [], id: "img")
        }
        try caret(harness, Self.firstID, 2)
        try await pasteRefused(
            harness, BlockNoteYjs.encode([image("javascript:alert(1)")], clientID: 7),
            notice: .native_editor_paste_unavailable)
        try await pasteRefused(
            harness, BlockNoteYjs.encode([image("file:///etc/passwd")], clientID: 7),
            notice: .native_editor_paste_unavailable)
        RecordingProtocol.requests = []
        URLProtocol.registerClass(RecordingProtocol.self)
        defer { URLProtocol.unregisterClass(RecordingProtocol.self) }
        harness.pasteboard.setItems([
            [payloadType: BlockNoteYjs.encode([image("https://images.example/a.png")], clientID: 7)]
        ])
        let ids = try await pastedIDs(harness)
        XCTAssertEqual(try self.block(session, try XCTUnwrap(ids.first)).node, "image")
        harness.view.layoutIfNeeded()
        XCTAssertEqual(RecordingProtocol.requests, [], "no fetch for a pasted image")
        try await assertConsistent(harness, localCommands: 1)
    }

    /// 2 MiB of tiny structs is refused from the decoded update's struct
    /// count, before any is integrated.
    func testAPayloadOfManyTinyStructsIsRefusedBeforeIntegration() async throws {
        func varUInt(_ value: Int) -> [UInt8] {
            var value = value
            var bytes: [UInt8] = []
            repeat {
                bytes.append(UInt8(value & 0x7f) | (value > 0x7f ? 0x80 : 0))
                value >>= 7
            } while value > 0
            return bytes
        }
        let count = BlockNoteSubtreePayload.maxStructs * 2
        // One client, `count` one-clock GC structs, an empty delete set.
        var bytes = varUInt(1) + varUInt(count) + varUInt(5) + varUInt(0)
        bytes.reserveCapacity(bytes.count + count * 2 + 1)
        for _ in 0..<count { bytes += [0, 1] }
        bytes += varUInt(0)
        let payload = Data(bytes)
        XCTAssertLessThanOrEqual(payload.count, BlockNoteSubtreePayload.maxBytes)
        XCTAssertNoThrow(try YUpdateDecoder.decode(payload), "a well-formed update")
        XCTAssertThrowsError(try BlockNoteSubtreePayload.decode(payload)) {
            XCTAssertEqual($0 as? BlockNoteSubtreePayload.Error, .tooLarge)
        }
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        try caret(harness, Self.firstID, 2)
        try await pasteRefused(harness, payload, notice: .native_editor_paste_too_large)
        try await assertConsistent(harness, localCommands: 0)
    }

    /// A collaborator's link with a scheme the editor never writes renders as
    /// plain text: no tappable `.link`, though the mark stays in the replica.
    func testOnlyAllowedSchemesBecomeTappableLinks() async throws {
        var linked = paragraph("p", "")
        linked.runs = [
            InlineRun("evil", marks: [("link", #"{"href":"javascript:alert(1)"}"#)]),
            InlineRun("deep", marks: [("link", #"{"href":"schrift-evil://open"}"#)]),
            InlineRun("web", marks: [("link", #"{"href":"https://example.test/"}"#)]),
            InlineRun("mail", marks: [("link", #"{"href":"mailto:a@example.test"}"#)]),
        ]
        let harness = try await makeHarness([linked])
        addTeardownBlock { await harness.close() }
        let storage = harness.view.textStorage
        func link(at offset: Int) throws -> URL? {
            storage.attribute(.link, at: try location(harness.session, "p", offset), effectiveRange: nil) as? URL
        }
        XCTAssertNil(try link(at: 1))
        XCTAssertNil(try link(at: 5))
        XCTAssertEqual(try link(at: 9), URL(string: "https://example.test/"))
        XCTAssertEqual(try link(at: 12), URL(string: "mailto:a@example.test"))
        XCTAssertEqual(try block(harness.session, "p").runs.filter { $0.marks.contains { $0.key == "link" } }.count, 4)
    }
}
