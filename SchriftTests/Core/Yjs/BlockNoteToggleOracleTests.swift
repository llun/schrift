import XCTest

@testable import Schrift

/// PR06b: the native engine's toggle commands against real BlockNote 0.56.0
/// + yjs 13.6.33 captures (`BlockNoteToggleCaptures`). Each command runs
/// through `DocumentEngine.applyStructural` on a session over the capture's
/// seed; its one journaled update, applied to a fresh replica of the seed,
/// must give BlockNote's XML, and the session's surface must equal that
/// replica's projection. A toggle's open state is the command's `open` set,
/// as the coordinator passes it.
@MainActor
final class BlockNoteToggleOracleTests: XCTestCase {
    private func assertOracle(
        _ name: String, blockID: String, kind: NativeEditCommand.Kind, file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let capture = try XCTUnwrap(BlockNoteToggleCaptures.captures[name], file: file, line: line)
        let state = try XCTUnwrap(Data(base64Encoded: capture.seed), file: file, line: line)
        let session = try await NativeEditorSession.seed(state: state)
        addTeardownBlock { await session.close().value }
        XCTAssertTrue(
            session.surface.blocks.allSatisfy { !$0.isOpaque }, "toggles are native blocks", file: file, line: line)
        let updates = await session.engine { engine -> [Data] in
            let command = NativeEditCommand(id: UUID(), baseRevision: 0, blockID: blockID, kind: kind)
            var updates: [Data] = []
            do {
                try engine.applyStructural(command) { updates.append($0) }
            } catch {
                XCTFail("applyStructural failed: \(error)")
            }
            return updates
        }
        let unwrapUpdates = try XCTUnwrap(updates, file: file, line: line)
        XCTAssertEqual(unwrapUpdates.count, 1, file: file, line: line)
        let replica = YDoc(clientID: 9, gc: false)
        defer { replica.destroy() }
        try replica.applyUpdate(YUpdateDecoder.decode(state))
        try replica.applyUpdate(YUpdateDecoder.decode(try XCTUnwrap(unwrapUpdates.first)))
        XCTAssertEqual(YXMLString.fragment(replica), capture.xml, name, file: file, line: line)
        XCTAssertNil(replica.store.pendingStructs, file: file, line: line)
        session.replica?.mailbox.post(.setWritable(nil))
        await session.settle()
        XCTAssertEqual(
            session.surface.blocks, NativeBlockProjection.project(replica).blocks.map(BlockSnapshot.init),
            file: file, line: line)
    }

    func testSlashConversionsMatchUpdateBlock() async throws {
        try await assertOracle(
            "slash-toggle-list", blockID: "p", kind: .blockType(node: "toggleListItem", props: [], removing: 0..<0))
        try await assertOracle(
            "slash-toggle-heading", blockID: "p",
            kind: .blockType(
                node: "heading",
                props: [
                    ProjectedProp(key: "level", value: .int(1)), ProjectedProp(key: "isToggleable", value: .bool(true)),
                ],
                removing: 0..<0))
    }

    /// An open toggle's Enter goes into its children (`enter: "into-children"`):
    /// the text after the caret becomes a new first paragraph, in a new group
    /// when there is none; the children stay.
    func testEnterInAnOpenToggleStartsItsChildren() async throws {
        try await assertOracle("enter-open-new-body", blockID: "t", kind: .split(offset: 5, newID: "1", open: ["t"]))
        try await assertOracle("enter-open-end", blockID: "t", kind: .split(offset: 5, newID: "1", open: ["t"]))
        try await assertOracle("enter-open-heading", blockID: "t", kind: .split(offset: 5, newID: "1", open: ["t"]))
    }

    /// A closed toggle splits into a sibling (a toggle list item's split keeps
    /// its type, a toggle heading's is a paragraph) and keeps its children.
    func testEnterInAClosedToggleSplitsAndKeepsTheChildren() async throws {
        try await assertOracle("enter-closed-split", blockID: "t", kind: .split(offset: 5, newID: "1"))
        try await assertOracle("enter-closed-heading", blockID: "t", kind: .split(offset: 5, newID: "1"))
    }

    /// Enter at the start of non-empty content inserts an empty block above,
    /// before the into-children rule; an empty toggle resets first.
    func testEnterAtTheStartAndInAnEmptyToggle() async throws {
        try await assertOracle("enter-start-toggle", blockID: "t", kind: .split(offset: 0, newID: "1", open: ["t"]))
        try await assertOracle("enter-empty-toggle", blockID: "t", kind: .split(offset: 0, newID: "1", open: ["t"]))
        try await assertOracle("enter-empty-toggle-heading", blockID: "t", kind: .split(offset: 0, newID: "1"))
    }

    /// An empty child of an open toggle gets a new child after it
    /// (`emptyChildEnter: "stay"`); of a closed one, it outdents.
    func testEnterInAnEmptyChildFollowsTheParentsOpenState() async throws {
        try await assertOracle("enter-empty-child-open", blockID: "e", kind: .split(offset: 0, newID: "1", open: ["t"]))
        try await assertOracle("enter-empty-child-closed", blockID: "e", kind: .split(offset: 0, newID: "1"))
    }

    /// Backspace at a toggle's start resets it (`resetsTo`): a toggle heading
    /// to a heading, a toggle list item to a paragraph, children kept. A first
    /// child merges back into the toggle's title.
    func testBackspaceResetsThenMerges() async throws {
        try await assertOracle("backspace-toggle-heading", blockID: "t", kind: .join)
        try await assertOracle("backspace-toggle-list", blockID: "t", kind: .join)
        try await assertOracle("backspace-first-child", blockID: "c", kind: .join)
    }

    /// The classic projection and writer are unchanged: a toggle stays opaque
    /// there, and the classic schema table does not address a toggle list item.
    func testTheClassicContractIsUnchanged() throws {
        let capture = try XCTUnwrap(BlockNoteToggleCaptures.captures["enter-closed-split"])
        let doc = YDoc(clientID: 2, gc: false)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(try XCTUnwrap(Data(base64Encoded: capture.seed))))
        let classic = YBlockProjection.project(doc)
        XCTAssertEqual(classic.blocks.first?.fidelity, .opaque(reason: "nested children"))
        XCTAssertNotNil(NativeBlockProjection.markdownShadow(doc), "the native shadow spells it as the export does")
        XCTAssertThrowsError(try BlockNoteWriter(doc: doc).splitBlock(block: "t", at: 1, newID: "x")) {
            XCTAssertEqual($0 as? BlockNoteWriter.Error, .unsupportedBlockType("toggleListItem"))
        }
        let heading = try XCTUnwrap(BlockNoteToggleCaptures.captures["enter-empty-toggle-heading"])
        let headingDoc = YDoc(clientID: 2, gc: false)
        defer { headingDoc.destroy() }
        try headingDoc.applyUpdate(YUpdateDecoder.decode(try XCTUnwrap(Data(base64Encoded: heading.seed))))
        XCTAssertEqual(
            YBlockProjection.project(headingDoc).blocks.first?.fidelity, .opaque(reason: "toggleable heading"))
        XCTAssertFalse(NativeBlockProjection.project(headingDoc).blocks[0].block.fidelity.isOpaque)
    }
}
