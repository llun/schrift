import Foundation
import UIKit
import XCTest

@testable import Schrift

/// PR01/PR02: a remote integrate that brings in content the native editor
/// cannot author stops typing (downgrade only, with the reason an open of such
/// a document shows), and the edits journaled before it still save — the
/// capture no longer needs a total Markdown shadow. An unknown block is a
/// locked preserved card and a `.lossy` block is a locked text block, so
/// neither downgrades.
@MainActor
final class ReplicaTypabilityTests: NativeEditingTestCase {
    private var cacheDirectory: URL!
    private var draftSuiteNames: [String] = []

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplicaTypabilityTests.\(UUID().uuidString)", isDirectory: true)
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

    /// A coordinator over the harness's own replica store, signed in as the
    /// scope's owner, so `enqueueReplica` captures the journal the editor wrote.
    private func makeCoordinator(_ harness: Harness) -> DocumentSaveCoordinator {
        let suite = "ReplicaTypabilityTests.\(UUID().uuidString)"
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

    /// The Docs 6 save pipeline: config, identity, then the body PATCH.
    private func stub(_ log: RequestRecorder, owner: UUID) {
        let ownerID = owner.uuidString
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let path = request.url?.absoluteString ?? ""  // `URL.path` drops the trailing slash
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

    /// Appends a block the native editor does not model (an unknown node) to
    /// `doc`, the way a web peer's newer client would.
    private func appendUnknownBlock(to doc: YDoc, id: String, node: String) throws {
        _ = try doc.transact(local: true) { tx in
            let root = doc.get(BlockNoteYjs.fragmentField)
            guard let existing = YBlockProjection.children(of: root, includeFormats: false).first,
                case .type(let group) = existing.content
            else { return }
            let afterContainer = YBlockProjection.children(of: group, includeFormats: false).last
            let container = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            _ = try YWrite.insertAfter(tx, into: group, after: afterContainer, [.type(container)])
            try YWrite.mapSet(tx, on: container, key: "id", .any([.string(id)]))
            let element = YType(typeRef: .xmlElement(nodeName: node))
            _ = try YWrite.insertAfter(tx, into: container, after: nil, [.type(element)])
        }
    }

    /// A peer's update that adds an unknown block to the shared seed.
    private func unknownBlockUpdate(clientID: UInt32) throws -> Data {
        let peer = try makeDoc(clientID: clientID)
        defer { peer.destroy() }
        try appendUnknownBlock(to: peer, id: "future", node: "futureBlock")
        return try YStateEncoder.encodeStateAsUpdate(peer)
    }

    private func caret(_ harness: Harness, _ blockID: String, _ offset: Int) throws {
        setSelection(harness, NSRange(location: try location(harness.session, blockID, offset), length: 0))
    }

    /// One block's own XML, read from the replica.
    private func blockXML(_ session: NativeEditorSession, _ id: String) async throws -> String {
        let xml = await session.replicaDoc { doc in YXMLString.block(doc, id: id) }
        return try XCTUnwrap(xml ?? nil, "\(id) is in the replica")
    }

    /// A document whose only non-modeled content is a locked card opens
    /// typeable on both routes; typing in the paragraphs around it journals and
    /// saves, and the card's Yjs element is unchanged.
    func testADocumentWithOnlyALockedCardOpensTypeableAndTypesAroundIt() async throws {
        let state = BlockNoteYjs.encode(
            [
                paragraph("before", "Before"),
                BlockNoteBlock(
                    node: "futureBlock", props: [("x-future", .string("kept"))],
                    runs: [InlineRun("Future content")], id: "future"),
                paragraph("after", "After"),
            ], clientID: Self.seedClientID)

        // The read-only route agrees with the replica build.
        let inspected = try await NativeEditorSession.inspect(state: state)
        addTeardownBlock { await inspected.close().value }
        XCTAssertTrue(inspected.canType)
        XCTAssertNil(inspected.unfamiliarContent)
        XCTAssertFalse(inspected.hasUnsupportedRoot)

        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }
        let session = harness.session
        XCTAssertTrue(session.canType)
        XCTAssertNil(session.unfamiliarContent)
        XCTAssertEqual(session.surface.blocks.map(\.id), ["before", "future", "after"])
        XCTAssertEqual(session.surface.blocks.map(\.isOpaque), [false, true, false])
        let before = try await blockXML(session, "future")

        try caret(harness, "before", 0)
        harness.view.insertText("A")
        await harness.settle()
        try caret(harness, "after", 5)
        harness.view.insertText("!")
        await harness.settle()
        XCTAssertEqual(text(of: try block(session, "before")), "ABefore")
        XCTAssertEqual(text(of: try block(session, "after")), "After!")
        let after = try await blockXML(session, "future")
        XCTAssertEqual(after, before, "the locked card is untouched")
        try await assertConsistent(harness, localCommands: 2)

        // The journaled edits save through the full pipeline; the shadow leaves
        // the card out, so the draft carries only what Markdown can spell.
        let coordinator = makeCoordinator(harness)
        let log = RequestRecorder()
        stub(log, owner: harness.scope.ownerUserID)
        let adapter = ReplicaSaveAdapter(store: harness.store, scope: harness.scope)
        try coordinator.enqueueReplica(adapter: adapter, title: "Doc")
        let draft = try XCTUnwrap(coordinator.storedDraft(documentID: harness.scope.documentID))
        XCTAssertTrue(draft.markdown.contains("ABefore"))
        XCTAssertTrue(draft.markdown.contains("After!"))
        XCTAssertFalse(draft.markdown.contains("Future content"), "the locked card is left out of the shadow")
        XCTAssertNotNil(draft.replica)
        await waitUntil { self.isSaved(coordinator.state(for: harness.scope.documentID)) }
        XCTAssertEqual(
            log.count(ofMethod: "PATCH", urlContaining: "/collaboration/ydoc/"), 2, "one PATCH per journaled edit")
        XCTAssertNil(try harness.store.outbox(for: harness.scope), "the journaled edits were sent")
    }

    /// Offline edits are journaled, then a reconnect integrates server state
    /// holding an unknown block: the capture must still succeed and send them.
    func testAnIntegrateThatAddsAnUnknownBlockStillLetsTheJournaledEditSave() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        XCTAssertTrue(harness.session.canType)
        try caret(harness, Self.firstID, 0)
        harness.view.insertText("A")
        await harness.settle()
        XCTAssertEqual(harness.log.commands.count, 1, "the local edit is journaled")

        harness.session.replica?.mailbox.post(.integrate(try unknownBlockUpdate(clientID: 21), reply: nil))
        await harness.settle()
        XCTAssertTrue(harness.session.canType, "the peer's unknown block is a locked card, not a downgrade")

        let coordinator = makeCoordinator(harness)
        let log = RequestRecorder()
        stub(log, owner: harness.scope.ownerUserID)
        let adapter = ReplicaSaveAdapter(store: harness.store, scope: harness.scope)
        try coordinator.enqueueReplica(adapter: adapter, title: "Doc")
        let draft = try XCTUnwrap(coordinator.storedDraft(documentID: harness.scope.documentID))
        XCTAssertTrue(draft.markdown.contains("AFirst paragraph."), "the lossy shadow keeps what Markdown can spell")
        XCTAssertNotNil(draft.replica)
        await waitUntil { self.isSaved(coordinator.state(for: harness.scope.documentID)) }
        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: "/collaboration/ydoc/"), 1)
        XCTAssertNil(try harness.store.outbox(for: harness.scope), "the journaled edit was sent")
        XCTAssertNil(coordinator.storedDraft(documentID: harness.scope.documentID))
    }

    /// After such an integrate the surface keeps authoring: the unknown block
    /// is a locked card, and typing elsewhere still journals.
    func testAnIntegrateThatAddsAnUnknownBlockKeepsTypingElsewhere() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        XCTAssertTrue(harness.session.canType)
        XCTAssertNil(harness.session.unfamiliarContent)

        harness.session.replica?.mailbox.post(.integrate(try unknownBlockUpdate(clientID: 22), reply: nil))
        await harness.settle()

        XCTAssertTrue(harness.session.canType, "a locked card does not take authoring away")
        XCTAssertNil(harness.session.unfamiliarContent)
        XCTAssertFalse(harness.input.isFrozen, "the surface keeps taking input")
        XCTAssertTrue(harness.view.isEditable)
        XCTAssertEqual(
            harness.session.surface.blocks.map(\.id), [Self.firstID, Self.secondID, Self.thirdID, "future"])
        XCTAssertEqual(harness.session.surface.blocks.last?.isOpaque, true)

        try caret(harness, Self.firstID, 0)
        harness.view.insertText("x")
        await harness.settle()
        XCTAssertEqual(harness.log.commands.count, 1, "the keystroke was journaled")
        XCTAssertEqual(text(of: try block(harness.session, Self.firstID)), "xFirst paragraph.")
        try await assertConsistent(harness, localCommands: 1)
    }

    /// A web peer centering a paragraph (a styled-only `.lossy` block, not an
    /// unknown node) does not take authoring away, stays unlocked, and typing
    /// elsewhere still journals.
    func testAPeerCenteringAParagraphKeepsTyping() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let peer = try makeDoc(clientID: 23)
        defer { peer.destroy() }
        let update = try BlockNoteWriter(doc: peer).setBlockType(
            block: Self.thirdID, to: "paragraph", props: [("textAlignment", .string("center"))])

        harness.session.replica?.mailbox.post(.integrate(update, reply: nil))
        await harness.settle()

        XCTAssertTrue(harness.session.canType, "a styled lossy block is not a downgrade")
        XCTAssertNil(harness.session.unfamiliarContent)
        XCTAssertFalse(harness.input.isFrozen, "the surface keeps taking input")
        XCTAssertEqual(harness.session.surface.blocks.last?.isLocked, false)

        try caret(harness, Self.firstID, 0)
        harness.view.insertText("x")
        await harness.settle()
        XCTAssertEqual(harness.log.commands.count, 1, "typing elsewhere still journals")
        try await assertConsistent(harness, localCommands: 1)
    }
}
