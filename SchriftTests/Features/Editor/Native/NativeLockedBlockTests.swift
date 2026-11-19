import UIKit
import XCTest

@testable import Schrift

/// PR02: a document whose only non-modeled content is locked preserved cards
/// (opaque blocks) opens typeable. The cards keep their rendering and no native
/// edit touches them; a `.lossy` block or a document-level unknown still makes
/// the whole document read-only, with the same reason as before.
@MainActor
final class NativeLockedBlockTests: NativeEditingTestCase {
    /// A paragraph, an unknown block carrying a prop and text, and a paragraph.
    private func lockedSeed() -> [BlockNoteBlock] {
        [
            paragraph("before", "Before"),
            BlockNoteBlock(
                node: "futureBlock", props: [("x-future", .string("kept"))],
                runs: [InlineRun("Future content")], id: "future"),
            paragraph("after", "After"),
        ]
    }

    private func caret(_ harness: Harness, _ id: String, _ offset: Int) throws {
        setSelection(harness, NSRange(location: try location(harness.session, id, offset), length: 0))
    }

    /// The locked card's own XML, read from the replica.
    private func lockedXML(_ session: NativeEditorSession, _ id: String) async throws -> String {
        let xml = await session.replicaDoc { doc in YXMLString.block(doc, id: id) }
        return try XCTUnwrap(xml ?? nil, "the locked block is in the replica")
    }

    private func availableActions(_ harness: Harness) async -> [NativeBlockAction] {
        _ = harness.input.availableBlockActions()
        await harness.settle()
        return harness.input.availableBlockActions()
    }

    /// Every path that could change the card is refused, and the card's Yjs
    /// element is byte-identical afterwards.
    func testEveryRefusedPathOnALockedCardStaysRefused() async throws {
        let harness = try await makeHarness(lockedSeed())
        addTeardownBlock { await harness.close() }
        let session = harness.session
        XCTAssertTrue(session.canType)
        XCTAssertEqual(session.surface.blocks.map(\.isOpaque), [false, true, false])
        let before = try await lockedXML(session, "future")
        let original = session.textView.textStorage.string

        // Typing into the card and Return in it: refused with the notice.
        try caret(harness, "future", 0)
        session.textView.insertText("x")
        await harness.settle()
        XCTAssertEqual(session.input?.noticeKey, .native_editor_input_unavailable)
        session.textView.insertText("\n")
        await harness.settle()
        XCTAssertEqual(session.input?.noticeKey, .native_editor_input_unavailable)
        XCTAssertEqual(session.textView.textStorage.string, original)
        XCTAssertTrue(harness.log.commands.isEmpty)

        // Backspace at the card's start, and at the start of the block below
        // it: both would join into or delete the card, so both are quiet no-ops.
        for id in ["future", "after"] {
            try caret(harness, id, 0)
            session.textView.deleteBackward()
            await harness.settle()
        }
        // The Return above left its notice; a quiet no-op neither clears nor replaces it.
        XCTAssertEqual(session.input?.noticeKey, .native_editor_input_unavailable, "an unsupported join is quiet")
        XCTAssertEqual(session.textView.textStorage.string, original)
        XCTAssertTrue(harness.log.commands.isEmpty)

        // The block menu offers only what reads no content, and refuses the rest.
        try caret(harness, "future", 0)
        let actions = await availableActions(harness)
        XCTAssertEqual(actions, [.insertAbove, .insertBelow])
        let moveUp = await harness.run { harness.input.performBlockAction(.moveUp) }
        XCTAssertFalse(moveUp)
        let duplicate = await harness.run { harness.input.performBlockAction(.duplicate) }
        XCTAssertFalse(duplicate)
        let delete = await harness.run { harness.input.performBlockAction(.delete) }
        XCTAssertFalse(delete)
        XCTAssertTrue(harness.log.commands.isEmpty)

        // The engine's own guards refuse a direct call, not just the surface.
        let replaced = await harness.engine {
            (try? $0.replaceText(block: "future", range: 0..<0, with: "x")) == nil
        }
        XCTAssertTrue(replaced ?? false)
        let formatted = await harness.engine {
            (try? $0.formatRange(block: "future", range: 0..<0, marks: [TextMark(key: "bold", valueJSON: "{}")]))
                == nil
        }
        XCTAssertTrue(formatted ?? false)
        let split = await harness.engine { (try? $0.splitBlock(block: "future", at: 0, newID: "new")) == nil }
        XCTAssertTrue(split ?? false)
        let joined = await harness.engine { (try? $0.joinBlocks(block: "future")) == nil }
        XCTAssertTrue(joined ?? false)
        let turned = await harness.engine { (try? $0.setBlockType(block: "future", to: "paragraph")) == nil }
        XCTAssertTrue(turned ?? false)

        let after = try await lockedXML(session, "future")
        XCTAssertEqual(after, before, "the card is untouched")
        try await assertConsistent(harness, localCommands: 0)
    }

    /// A `.lossy` block (a known node with a non-default prop) still makes the
    /// whole document read-only, with the prop as the reason.
    func testALossyBlockStillMakesTheDocumentReadOnly() async throws {
        let state = BlockNoteYjs.encode(
            [
                paragraph("before", "Before"),
                BlockNoteBlock(
                    node: "paragraph",
                    props: Self.paragraphProps.map { $0.key == "textAlignment" ? ($0.key, .string("center")) : $0 },
                    runs: [InlineRun("Centered")], id: "centered"),
                paragraph("after", "After"),
            ], clientID: Self.seedClientID)

        let inspected = try await NativeEditorSession.inspect(state: state)
        addTeardownBlock { await inspected.close().value }
        XCTAssertFalse(inspected.canType)
        XCTAssertEqual(
            inspected.unfamiliarContent,
            NativeUnfamiliarBlock(node: "paragraph", reason: "prop:textAlignment"))
    }

    /// A document-level unknown (an unsupported auxiliary root) still makes the
    /// whole document read-only, even beside a locked card.
    func testAnUnsupportedAuxiliaryRootStillMakesTheDocumentReadOnly() async throws {
        let doc = YDoc(clientID: 7, gc: true)
        defer { doc.destroy() }
        try doc.applyUpdate(
            YUpdateDecoder.decode(BlockNoteYjs.encode(lockedSeed(), clientID: Self.seedClientID)), origin: .remote)
        try doc.transact { tx in
            try YWrite.mapSet(tx, on: doc.get("comments"), key: "c1", .any([.string("hello")]))
        }
        let state = try YStateEncoder.encodeStateAsUpdate(doc)

        let inspected = try await NativeEditorSession.inspect(state: state)
        addTeardownBlock { await inspected.close().value }
        XCTAssertFalse(inspected.canType)
        XCTAssertEqual(inspected.unfamiliarContent, NativeUnfamiliarBlock(node: "", reason: "unsupported root"))
    }
}
