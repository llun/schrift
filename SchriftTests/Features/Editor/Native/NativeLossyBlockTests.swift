import Foundation
import UIKit
import XCTest

@testable import Schrift

/// Owner choice A1 for `.lossy` blocks:
/// - **Styled** (every lossy reason is a non-default value of `textColor`,
///   `backgroundColor` or `textAlignment`): opens typeable with `isLocked == false`
///   and keeps full editing (typing, marks, props, split, convert, slash menu,
///   move, indent/outdent, duplicate, delete), except merges into or out of it
///   are refused (joins in either direction and cross-boundary ranges).
/// - **Unknown-prop** (any other `.lossy` reason, e.g. `unknownProp:futureProp`
///   or a non-styling prop like `prop:emoji`): opens typeable with
///   `isLocked == true` and allows text editing only (typing, marks, same-schema
///   props, inline objects, character delete, copy/duplicate/whole-block delete),
///   while split, convert (slash menu hidden), merge, move/indent and
///   empty-paragraph replacement refuse it.
@MainActor
final class NativeLossyBlockTests: NativeEditingTestCase {
    private var cacheDirectory: URL!
    private var draftSuiteNames: [String] = []

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeLossyBlockTests.\(UUID().uuidString)", isDirectory: true)
        draftSuiteNames = []
    }

    override func tearDown() {
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: cacheDirectory)
        cacheDirectory = nil
        for suite in draftSuiteNames {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        super.tearDown()
    }

    /// A paragraph's props with `textAlignment` centered (appending a second
    /// `textAlignment` does not work).
    private func centeredProps() -> [(key: String, value: YAnyValue)] {
        Self.paragraphProps.map { $0.key == "textAlignment" ? ($0.key, .string("center")) : $0 }
    }

    /// A paragraph's props carrying an unknown prop `futureProp`.
    private func futureProps() -> [(key: String, value: YAnyValue)] {
        Self.paragraphProps + [("futureProp", .string("v1"))]
    }

    /// Styled-only seed: paragraph, centered paragraph, paragraph.
    private func styledSeed() -> [BlockNoteBlock] {
        [
            paragraph("before", "Before"),
            BlockNoteBlock(
                node: "paragraph", props: centeredProps(), runs: [InlineRun("Centered")], id: "centered"),
            paragraph("after", "After"),
        ]
    }

    /// Unknown-prop seed: paragraph, paragraph with `futureProp`, paragraph.
    private func unknownPropSeed() -> [BlockNoteBlock] {
        [
            paragraph("before", "Before"),
            BlockNoteBlock(
                node: "paragraph", props: futureProps(), runs: [InlineRun("Future")], id: "future"),
            paragraph("after", "After"),
        ]
    }

    private func caret(_ harness: Harness, _ id: String, _ offset: Int) throws {
        setSelection(harness, NSRange(location: try location(harness.session, id, offset), length: 0))
    }

    /// One block's own XML, read from the replica.
    private func blockXML(_ session: NativeEditorSession, _ id: String) async throws -> String {
        let xml = await session.replicaDoc { doc in YXMLString.block(doc, id: id) }
        return try XCTUnwrap(xml ?? nil, "\(id) is in the replica")
    }

    private func availableActions(_ harness: Harness) async -> [NativeBlockAction] {
        _ = harness.input.availableBlockActions()
        await harness.settle()
        return harness.input.availableBlockActions()
    }

    /// A coordinator over the harness's own replica store, signed in as the
    /// scope's owner, so `enqueueReplica` captures the journal the editor wrote.
    private func makeCoordinator(_ harness: Harness) -> DocumentSaveCoordinator {
        let suite = "NativeLossyBlockTests.\(UUID().uuidString)"
        draftSuiteNames.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        SignedInUserStore(userDefaults: defaults).remember(harness.scope.ownerUserID)
        let client = DocsAPIClient(
            baseURL: URL(string: "https://example.test/api/v1.0/")!, session: MockURLProtocol.makeSession(),
            cookieProvider: { [] })
        return DocumentSaveCoordinator(
            client: client, draftStore: PendingDraftStore(userDefaults: defaults),
            replicaStore: harness.store, contentCache: DocumentContentCacheStore(directory: cacheDirectory),
            listCache: DocumentCacheStore(userDefaults: defaults), backgroundTasks: .noop, sleep: neverSleep)
    }

    private func stub(_ log: RequestRecorder, owner: UUID) {
        let ownerID = owner.uuidString
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let path = request.url?.absoluteString ?? ""
            if path.hasSuffix("/config/") {
                return .init(
                    statusCode: 200, headers: [:], body: Data(#"{"RELEASE_VERSION":"6.0.0"}"#.utf8), error: nil)
            }
            if path.hasSuffix("/users/me/") {
                return .init(statusCode: 200, headers: [:], body: Data("{\"id\":\"\(ownerID)\"}".utf8), error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
    }

    private func isSaved(_ state: DocumentSaveCoordinator.DocSaveState) -> Bool {
        if case .saved = state { return true }
        return false
    }

    // MARK: - STYLED (known styling props: textColor, backgroundColor, textAlignment)

    /// A styled-only lossy document opens typeable on both routes, and the
    /// centered paragraph is NOT locked (`isLocked == false`).
    func testStyledBlockOpensTypeableAndUnlocked() async throws {
        let state = BlockNoteYjs.encode(styledSeed(), clientID: Self.seedClientID)

        let inspected = try await NativeEditorSession.inspect(state: state)
        addTeardownBlock { await inspected.close().value }
        XCTAssertTrue(inspected.canType)
        XCTAssertNil(inspected.unfamiliarContent)
        XCTAssertEqual(inspected.surface.blocks.map(\.isLocked), [false, false, false])

        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }
        let session = harness.session
        XCTAssertTrue(session.canType)
        XCTAssertNil(session.unfamiliarContent)
        XCTAssertEqual(session.surface.blocks.map(\.id), ["before", "centered", "after"])
        XCTAssertEqual(session.surface.blocks.map(\.isOpaque), [false, false, false])
        XCTAssertEqual(session.surface.blocks.map(\.isLocked), [false, false, false])
        XCTAssertEqual(text(of: try block(session, "centered")), "Centered")
        XCTAssertTrue(session.textView.isEditable)
    }

    /// Typing, marks, and a single-block range delete inside a styled paragraph
    /// all succeed and keep `textAlignment="center"`.
    func testStyledBlockTakesTypingMarksAndSingleBlockRangeDelete() async throws {
        let harness = try await makeHarness(styledSeed())
        addTeardownBlock { await harness.close() }
        let session = harness.session

        try caret(harness, "centered", 0)
        harness.view.insertText("A")
        await harness.settle()
        XCTAssertEqual(text(of: try block(session, "centered")), "ACentered")

        setSelection(harness, NSRange(location: try location(session, "centered", 0), length: 2))
        let bold = await harness.run { harness.input.toggleMark("bold") }
        XCTAssertTrue(bold)

        // A range delete inside the single styled block is allowed.
        setSelection(harness, NSRange(location: try location(session, "centered", 2), length: 2))
        harness.view.deleteBackward()
        await harness.settle()
        XCTAssertEqual(text(of: try block(session, "centered")), "ACtered")

        let xml = try await blockXML(session, "centered")
        XCTAssertTrue(xml.contains("textAlignment=\"center\""), "styling prop survives: \(xml)")
        XCTAssertTrue(xml.contains("<bold>"), "mark landed: \(xml)")
        try await assertConsistent(harness, localCommands: 3)
    }

    /// Return splits a styled paragraph normally.
    func testStyledBlockSplitsOnReturn() async throws {
        let harness = try await makeHarness(styledSeed())
        addTeardownBlock { await harness.close() }
        let session = harness.session

        try caret(harness, "centered", 4)
        harness.view.insertText("\n")
        await harness.settle()

        XCTAssertNil(harness.input.noticeKey)
        XCTAssertEqual(session.surface.blocks.count, 4)
        XCTAssertEqual(text(of: session.surface.blocks[1]), "Cent")
        XCTAssertEqual(text(of: session.surface.blocks[2]), "ered")
        try await assertConsistent(harness, localCommands: 1)
    }

    /// The slash menu opens in a styled paragraph and converts it.
    func testStyledBlockOpensSlashMenuAndConverts() async throws {
        let harness = try await makeHarness(styledSeed())
        addTeardownBlock { await harness.close() }
        let session = harness.session

        try caret(harness, "centered", 0)
        harness.view.insertText("/h1")
        await harness.settle()
        XCTAssertEqual(harness.input.slashMenuQuery, "h1")

        let heading = try XCTUnwrap(NativeInputCoordinator.slashItems.first { $0.id == "heading1" })
        let converted = await harness.run { harness.input.applySlashItem(heading) }
        XCTAssertTrue(converted)
        XCTAssertEqual(try block(session, "centered").node, "heading")
        XCTAssertEqual(text(of: try block(session, "centered")), "Centered")
        try await assertConsistent(harness, localCommands: 2)
    }

    /// A styled paragraph keeps move up/down and indent/outdent, preserving
    /// `textAlignment="center"`.
    func testStyledBlockMovesAndIndentsKeepingStyleProp() async throws {
        let harness = try await makeHarness(styledSeed())
        addTeardownBlock { await harness.close() }
        let session = harness.session

        try caret(harness, "centered", 0)
        let actions = await availableActions(harness)
        XCTAssertTrue(actions.contains(.moveUp))
        XCTAssertTrue(actions.contains(.moveDown))
        XCTAssertTrue(actions.contains(.indent))

        let movedUp = await harness.run { harness.input.performBlockAction(.moveUp) }
        XCTAssertTrue(movedUp)
        XCTAssertEqual(session.surface.blocks.map(\.id), ["centered", "before", "after"])
        let movedDown = await harness.run { harness.input.performBlockAction(.moveDown) }
        XCTAssertTrue(movedDown)
        XCTAssertEqual(session.surface.blocks.map(\.id), ["before", "centered", "after"])
        let indented = await harness.run { harness.input.performBlockAction(.indent) }
        XCTAssertTrue(indented)
        XCTAssertEqual(try block(session, "centered").depth, 1)
        let outdented = await harness.run { harness.input.performBlockAction(.outdent) }
        XCTAssertTrue(outdented)
        XCTAssertEqual(try block(session, "centered").depth, 0)

        let xml = try await blockXML(session, "centered")
        XCTAssertTrue(xml.contains("textAlignment=\"center\""), "styling prop survives moves: \(xml)")
        try await assertConsistent(harness, localCommands: 4)
    }

    /// Backspace joins into or out of a styled paragraph are quiet no-ops, and
    /// direct `joinBlocks` throws in both directions while `splitBlock` and
    /// `setBlockType` succeed.
    func testStyledBlockRefusesJoinsInBothDirections() async throws {
        let harness = try await makeHarness(styledSeed())
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let original = session.textView.textStorage.string

        for id in ["centered", "after"] {
            try caret(harness, id, 0)
            harness.view.deleteBackward()
            await harness.settle()
            XCTAssertNil(harness.input.noticeKey, "\(id): a refused join is quiet")
        }
        XCTAssertEqual(session.textView.textStorage.string, original)
        XCTAssertTrue(harness.log.commands.isEmpty)
        try await assertConsistent(harness, localCommands: 0)

        let joinOut = await harness.engine { (try? $0.joinBlocks(block: "centered")) == nil }
        XCTAssertTrue(joinOut ?? false, "direct joinBlocks out of styled block throws")
        let joinIn = await harness.engine { (try? $0.joinBlocks(block: "after")) == nil }
        XCTAssertTrue(joinIn ?? false, "direct joinBlocks into styled block throws")
        // Split and convert of a styled block are covered through the input paths
        // (Return, slash menu); a direct engine write here would be unjournaled.
    }

    /// A cross-boundary range delete/cut spanning a styled block is refused and
    /// leaves the pasteboard untouched.
    func testStyledBlockRefusesCrossBoundaryRangeDeleteAndCut() async throws {
        let harness = try await makeHarness(styledSeed())
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let original = session.textView.textStorage.string
        harness.pasteboard.string = "kept"

        try select(harness, from: ("before", 2), to: ("centered", 3))
        await harness.settle()
        harness.view.deleteBackward()
        await harness.settle()
        XCTAssertEqual(harness.input.noticeKey, .native_editor_range_unavailable)
        harness.view.cut(nil)
        await harness.settle()
        XCTAssertEqual(harness.pasteboard.string, "kept")

        try select(harness, from: ("centered", 2), to: ("after", 2))
        await harness.settle()
        harness.view.deleteBackward()
        await harness.settle()
        XCTAssertEqual(harness.input.noticeKey, .native_editor_range_unavailable)
        XCTAssertEqual(session.textView.textStorage.string, original)
        XCTAssertTrue(harness.log.commands.isEmpty)
        try await assertConsistent(harness, localCommands: 0)
    }

    /// Saving after typing inside a styled paragraph keeps `textAlignment="center"`.
    func testStyledBlockSaveKeepsTextAlignment() async throws {
        let harness = try await makeHarness(styledSeed())
        addTeardownBlock { await harness.close() }
        let session = harness.session

        try caret(harness, "centered", 0)
        harness.view.insertText("A")
        await harness.settle()
        XCTAssertEqual(harness.log.commands.count, 1)

        let coordinator = makeCoordinator(harness)
        let log = RequestRecorder()
        stub(log, owner: harness.scope.ownerUserID)
        let adapter = ReplicaSaveAdapter(store: harness.store, scope: harness.scope)
        try coordinator.enqueueReplica(adapter: adapter, title: "Doc")
        let draft = try XCTUnwrap(coordinator.storedDraft(documentID: harness.scope.documentID))
        XCTAssertTrue(draft.markdown.contains("ACentered"))
        await waitUntil { self.isSaved(coordinator.state(for: harness.scope.documentID)) }
        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: "/collaboration/ydoc/"), 1)
        XCTAssertNil(try harness.store.outbox(for: harness.scope))

        let xml = try await blockXML(session, "centered")
        XCTAssertTrue(xml.contains("textAlignment=\"center\""), "save keeps textAlignment: \(xml)")
    }

    // MARK: - UNKNOWN-PROP (unknown prop or non-styling lossy reason)

    /// A paragraph with an unknown prop opens typeable on both routes and is
    /// marked locked (`isLocked == true`, `isOpaque == false`).
    func testUnknownPropBlockOpensTypeableAndLocked() async throws {
        let state = BlockNoteYjs.encode(unknownPropSeed(), clientID: Self.seedClientID)

        let inspected = try await NativeEditorSession.inspect(state: state)
        addTeardownBlock { await inspected.close().value }
        XCTAssertTrue(inspected.canType)
        XCTAssertNil(inspected.unfamiliarContent)
        XCTAssertEqual(inspected.surface.blocks.map(\.isLocked), [false, true, false])

        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }
        let session = harness.session
        XCTAssertTrue(session.canType)
        XCTAssertNil(session.unfamiliarContent)
        XCTAssertEqual(session.surface.blocks.map(\.id), ["before", "future", "after"])
        XCTAssertEqual(session.surface.blocks.map(\.isOpaque), [false, false, false])
        XCTAssertEqual(session.surface.blocks.map(\.isLocked), [false, true, false])
        XCTAssertEqual(text(of: try block(session, "future")), "Future")
        XCTAssertTrue(session.textView.isEditable)
    }

    /// Typing, marks and deleting characters inside an unknown-prop paragraph
    /// work and keep `futureProp="v1"`.
    func testUnknownPropBlockTakesTextAndMarksKeepingProp() async throws {
        let harness = try await makeHarness(unknownPropSeed())
        addTeardownBlock { await harness.close() }
        let session = harness.session

        try caret(harness, "future", 0)
        harness.view.insertText("A")
        await harness.settle()
        XCTAssertEqual(text(of: try block(session, "future")), "AFuture")
        XCTAssertEqual(harness.log.commands.count, 1)

        setSelection(harness, NSRange(location: try location(session, "future", 0), length: 2))
        let bold = await harness.run { harness.input.toggleMark("bold") }
        XCTAssertTrue(bold)
        XCTAssertEqual(harness.log.commands.count, 2)

        try caret(harness, "future", 7)
        harness.view.deleteBackward()
        await harness.settle()
        XCTAssertEqual(text(of: try block(session, "future")), "AFutur")

        let xml = try await blockXML(session, "future")
        XCTAssertTrue(xml.contains("futureProp=\"v1\""), "unknown prop survives: \(xml)")
        XCTAssertTrue(xml.contains("<bold>"), "mark landed: \(xml)")
        try await assertConsistent(harness, localCommands: 3)
    }

    /// Return inside an unknown-prop paragraph is refused with the input notice
    /// and no command.
    func testUnknownPropBlockRefusesReturn() async throws {
        let harness = try await makeHarness(unknownPropSeed())
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let original = session.textView.textStorage.string

        try caret(harness, "future", 3)
        harness.view.insertText("\n")
        await harness.settle()
        XCTAssertEqual(harness.input.noticeKey, .native_editor_input_unavailable)
        XCTAssertEqual(session.textView.textStorage.string, original)
        XCTAssertTrue(harness.log.commands.isEmpty)
        try await assertConsistent(harness, localCommands: 0)
    }

    /// The slash menu does not open in an unknown-prop paragraph.
    func testUnknownPropBlockHidesSlashMenu() async throws {
        let harness = try await makeHarness(unknownPropSeed())
        addTeardownBlock { await harness.close() }
        let session = harness.session

        try caret(harness, "future", 0)
        harness.view.insertText("/")
        await harness.settle()
        XCTAssertEqual(text(of: try block(session, "future")), "/Future", "the slash is typed")
        XCTAssertNil(harness.input.slashMenuQuery, "the slash menu stays closed")
        try await assertConsistent(harness, localCommands: 1)
    }

    /// The block menu offers no move or indent on an unknown-prop paragraph,
    /// refuses move/indent/outdent, and keeps copy, duplicate and delete.
    func testUnknownPropBlockRefusesMoveAndIndentButKeepsCopyDuplicateDelete() async throws {
        let harness = try await makeHarness(unknownPropSeed())
        addTeardownBlock { await harness.close() }
        let session = harness.session

        try caret(harness, "future", 0)
        let actions = await availableActions(harness)
        XCTAssertEqual(actions, [.insertAbove, .insertBelow, .duplicate, .copy, .delete])

        let moveUp = await harness.run { harness.input.performBlockAction(.moveUp) }
        XCTAssertFalse(moveUp)
        let moveDown = await harness.run { harness.input.performBlockAction(.moveDown) }
        XCTAssertFalse(moveDown)
        let indent = await harness.run { harness.input.performBlockAction(.indent) }
        XCTAssertFalse(indent)
        let outdent = await harness.run { harness.input.performBlockAction(.outdent) }
        XCTAssertFalse(outdent)
        XCTAssertTrue(harness.log.commands.isEmpty)

        let duplicate = await harness.run { harness.input.performBlockAction(.duplicate) }
        XCTAssertTrue(duplicate, "duplicate copies the raw props")
        XCTAssertEqual(session.surface.blocks.filter(\.isLocked).count, 2, "the copy is locked too")
        let copy = await harness.run { harness.input.performBlockAction(.copy) }
        XCTAssertTrue(copy, "copy has a lossless payload")
        let delete = await harness.run { harness.input.performBlockAction(.delete) }
        XCTAssertTrue(delete, "delete removes the raw props whole")
        try await assertConsistent(harness, localCommands: 2)
    }

    /// Backspace joins into or out of an unknown-prop paragraph are quiet no-ops,
    /// cross-boundary range delete/cut is refused, and direct split/join/convert
    /// throw while text/marks succeed.
    func testUnknownPropBlockRefusesJoinsCrossBoundaryRangeAndDirectStructuralSeams() async throws {
        let harness = try await makeHarness(unknownPropSeed())
        addTeardownBlock { await harness.close() }
        let session = harness.session
        let original = session.textView.textStorage.string
        harness.pasteboard.string = "kept"

        for id in ["future", "after"] {
            try caret(harness, id, 0)
            harness.view.deleteBackward()
            await harness.settle()
            XCTAssertNil(harness.input.noticeKey, "\(id): a refused join is quiet")
        }

        try select(harness, from: ("before", 2), to: ("after", 2))
        await harness.settle()
        harness.view.deleteBackward()
        await harness.settle()
        XCTAssertEqual(harness.input.noticeKey, .native_editor_range_unavailable)
        harness.view.cut(nil)
        await harness.settle()
        XCTAssertEqual(harness.pasteboard.string, "kept")
        XCTAssertEqual(session.textView.textStorage.string, original)
        XCTAssertTrue(harness.log.commands.isEmpty)
        try await assertConsistent(harness, localCommands: 0)

        let split = await harness.engine { (try? $0.splitBlock(block: "future", at: 0, newID: "new")) == nil }
        XCTAssertTrue(split ?? false)
        let joined = await harness.engine { (try? $0.joinBlocks(block: "future")) == nil }
        XCTAssertTrue(joined ?? false)
        let joinedInto = await harness.engine { (try? $0.joinBlocks(block: "after")) == nil }
        XCTAssertTrue(joinedInto ?? false)
        let turned = await harness.engine { (try? $0.setBlockType(block: "future", to: "heading")) == nil }
        XCTAssertTrue(turned ?? false)
        // Typing and marks inside it are covered through the input paths above.
    }

    /// A media drop with `.replaceOrAfter` on an empty unknown-prop paragraph
    /// inserts after it rather than replacing it.
    func testMediaDropOnEmptyUnknownPropParagraphInsertsAfterIt() async throws {
        let harness = try await makeHarness([
            paragraph("lead", "Before"),
            BlockNoteBlock(node: "paragraph", props: futureProps(), runs: [], id: "empty"),
            paragraph("tail", "After"),
        ])
        addTeardownBlock { await harness.close() }
        let session = harness.session
        XCTAssertEqual(session.surface.blocks.map(\.isLocked), [false, true, false])

        var delivered: [String]?
        let posted = await harness.run {
            harness.input.insertMediaBatch(nodes: ["image"], at: "empty", placement: .replaceOrAfter) {
                delivered = $0
            }
        }
        XCTAssertTrue(posted)
        let blocks = session.surface.blocks
        XCTAssertEqual(blocks.map(\.node), ["paragraph", "paragraph", "image", "paragraph"])
        XCTAssertEqual(blocks[1].id, "empty", "the unknown-prop paragraph is not replaced")
        XCTAssertTrue(blocks[1].isLocked)
        XCTAssertEqual(blocks[2].id, try XCTUnwrap(delivered?.first))
        let xml = try await blockXML(session, "empty")
        XCTAssertTrue(xml.contains("futureProp=\"v1\""), "unknown prop survives: \(xml)")
        try await assertConsistent(harness, localCommands: 1)
    }

    /// A pasted subtree on an empty unknown-prop paragraph inserts after it
    /// rather than replacing it.
    func testSubtreePasteOnEmptyUnknownPropParagraphInsertsAfterIt() async throws {
        let harness = try await makeHarness([
            paragraph("lead", "Before"),
            BlockNoteBlock(node: "paragraph", props: futureProps(), runs: [], id: "empty"),
            paragraph("tail", "After"),
        ])
        addTeardownBlock { await harness.close() }
        let session = harness.session

        try caret(harness, "empty", 0)
        let payload = try BlockNoteSubtreePayload.encode([
            .element(
                "blockContainer", [("id", .string("pasted"))],
                [.element("paragraph", [], [.text([.run(InlineRun("Pasted"))])])])
        ])
        harness.pasteboard.setItems([[BlockNoteSubtreePayload.pasteboardType: payload]])
        harness.view.paste(nil)
        await harness.settle()

        let blocks = session.surface.blocks
        XCTAssertEqual(blocks.map(\.node), ["paragraph", "paragraph", "paragraph", "paragraph"])
        XCTAssertEqual(blocks[1].id, "empty", "the unknown-prop paragraph is not replaced")
        XCTAssertTrue(blocks[1].isLocked)
        XCTAssertEqual(text(of: blocks[2]), "Pasted")
        let xml = try await blockXML(session, "empty")
        XCTAssertTrue(xml.contains("futureProp=\"v1\""), "unknown prop survives: \(xml)")
        try await assertConsistent(harness, localCommands: 1)
    }

    /// Saving after typing inside an unknown-prop paragraph keeps `futureProp="v1"`.
    func testUnknownPropBlockSaveKeepsProp() async throws {
        let harness = try await makeHarness(unknownPropSeed())
        addTeardownBlock { await harness.close() }
        let session = harness.session

        try caret(harness, "future", 0)
        harness.view.insertText("A")
        await harness.settle()
        XCTAssertEqual(harness.log.commands.count, 1)

        let coordinator = makeCoordinator(harness)
        let log = RequestRecorder()
        stub(log, owner: harness.scope.ownerUserID)
        let adapter = ReplicaSaveAdapter(store: harness.store, scope: harness.scope)
        try coordinator.enqueueReplica(adapter: adapter, title: "Doc")
        let draft = try XCTUnwrap(coordinator.storedDraft(documentID: harness.scope.documentID))
        XCTAssertTrue(draft.markdown.contains("AFuture"))
        XCTAssertNotNil(draft.replica)
        await waitUntil { self.isSaved(coordinator.state(for: harness.scope.documentID)) }
        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: "/collaboration/ydoc/"), 1)
        XCTAssertNil(try harness.store.outbox(for: harness.scope))

        let xml = try await blockXML(session, "future")
        XCTAssertTrue(xml.contains("futureProp=\"v1\""), "raw bytes keep the unknown prop: \(xml)")
    }

    /// Relaunch restores text, `futureProp="v1"`, `isLocked == true` and `canType`.
    func testUnknownPropBlockRestoreKeepsTextPropAndCanType() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReplicaStore(directory: directory)
        let scope = ReplicaScope(
            serverOrigin: "https://example.test", ownerUserID: UUID(), org: "docs", documentID: UUID())
        _ = try store.create(
            for: scope, checkpoint: BlockNoteYjs.encode(unknownPropSeed(), clientID: Self.seedClientID))

        let first = try unwrapped(try await NativeEditorSession.restore(store: store, scope: scope, editable: true))
        XCTAssertTrue(first.canType)
        XCTAssertTrue(
            try XCTUnwrap(first.input).replace(
                range: NSRange(location: try location(first, "future", 0), length: 0), with: "A"))
        await first.settle()
        await first.close().value

        let reopened = try unwrapped(try await NativeEditorSession.restore(store: store, scope: scope, editable: true))
        addTeardownBlock { await reopened.close().value }
        XCTAssertTrue(reopened.canType)
        XCTAssertEqual(text(of: try block(reopened, "future")), "AFuture")
        XCTAssertTrue(try block(reopened, "future").isLocked)
        let xml = try await blockXML(reopened, "future")
        XCTAssertTrue(xml.contains("futureProp=\"v1\""), "unknown prop survives relaunch: \(xml)")
    }

    /// A peer typing inside the unknown-prop paragraph while the local user
    /// types elsewhere converges, with `futureProp="v1"` intact.
    func testUnknownPropBlockPeerTypingConvergesWithProp() async throws {
        let harness = try await makeHarness(unknownPropSeed())
        addTeardownBlock { await harness.close() }
        let session = harness.session

        try caret(harness, "before", 0)
        harness.view.insertText("L")
        await harness.settle()

        let peer = try makeDoc(unknownPropSeed(), clientID: 42)
        defer { peer.destroy() }
        let update = try BlockNoteWriter(doc: peer).replaceText(block: "future", range: 0..<0, with: "P")
        harness.session.replica?.mailbox.post(.integrate(update, reply: nil))
        await harness.settle()

        XCTAssertEqual(text(of: try block(session, "before")), "LBefore")
        XCTAssertEqual(text(of: try block(session, "future")), "PFuture")
        XCTAssertTrue(session.canType)
        let xml = try await blockXML(session, "future")
        XCTAssertTrue(xml.contains("futureProp=\"v1\""), "unknown prop survives merge: \(xml)")
        try await assertConsistent(harness, localCommands: 1)
    }

    /// A1's split: only non-default styling (incl. a callout's emoji) is the full-editing
    /// kind; an unknown prop, an unreadable value of another known prop, or a mix is text-only.
    func testLossyKindFollowsWhetherSchriftKnowsTheProp() {
        XCTAssertEqual(ProjectionFidelity.lossy(reasons: ["prop:textAlignment"]).lossyKind, .styled)
        XCTAssertEqual(
            ProjectionFidelity.lossy(reasons: ["prop:textColor", "prop:backgroundColor"]).lossyKind, .styled)
        XCTAssertEqual(ProjectionFidelity.lossy(reasons: ["prop:emoji", "prop:textColor"]).lossyKind, .styled)
        XCTAssertEqual(ProjectionFidelity.lossy(reasons: ["prop:start"]).lossyKind, .unknownProp)
        XCTAssertEqual(ProjectionFidelity.lossy(reasons: ["unknownProp:futureProp"]).lossyKind, .unknownProp)
        XCTAssertEqual(
            ProjectionFidelity.lossy(reasons: ["prop:textAlignment", "unknownProp:x"]).lossyKind, .unknownProp)
        XCTAssertEqual(ProjectionFidelity.lossy(reasons: []).lossyKind, .unknownProp)
        XCTAssertNil(ProjectionFidelity.modeled.lossyKind)
    }
}
