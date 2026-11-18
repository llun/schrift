import Foundation
import UIKit
import XCTest

@testable import Schrift

/// PR01: a remote integrate that brings in content the native editor cannot
/// author stops typing (downgrade only, with the reason an open of such a
/// document shows), and the edits journaled before it still save — the capture
/// no longer needs a total Markdown shadow.
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
            listCache: DocumentCacheStore(userDefaults: defaults), backgroundTasks: .noop)
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
        XCTAssertFalse(harness.session.canType, "the peer's unknown block took authoring away")

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

    /// After such an integrate the session reports the open's reason and stops
    /// taking input: a further keystroke is refused, not journaled.
    func testAnIntegrateThatAddsAnUnknownBlockStopsTypingWithTheOpenReason() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        XCTAssertTrue(harness.session.canType)
        XCTAssertNil(harness.session.unfamiliarContent)

        harness.session.replica?.mailbox.post(.integrate(try unknownBlockUpdate(clientID: 22), reply: nil))
        await harness.settle()

        XCTAssertFalse(harness.session.canType)
        XCTAssertEqual(harness.session.unfamiliarContent?.node, "futureBlock")
        XCTAssertEqual(harness.session.unfamiliarContent?.reason, "unknownNode:futureBlock")
        XCTAssertTrue(harness.input.isFrozen, "the surface stopped taking input")
        XCTAssertFalse(harness.view.isEditable)

        try caret(harness, Self.firstID, 0)
        harness.view.insertText("x")
        await harness.settle()
        XCTAssertTrue(harness.log.commands.isEmpty, "the keystroke was refused, not journaled")
        XCTAssertEqual(text(of: try block(harness.session, Self.firstID)), "First paragraph.")
    }

    /// A web peer centering a paragraph (an unmodeled prop, not an unknown
    /// node) takes authoring away the same way, with the prop as the reason.
    func testAPeerCenteringAParagraphStopsTypingWithThePropReason() async throws {
        let harness = try await makeHarness()
        addTeardownBlock { await harness.close() }
        let peer = try makeDoc(clientID: 23)
        defer { peer.destroy() }
        let update = try BlockNoteWriter(doc: peer).setBlockType(
            block: Self.thirdID, to: "paragraph", props: [("textAlignment", .string("center"))])

        harness.session.replica?.mailbox.post(.integrate(update, reply: nil))
        await harness.settle()

        XCTAssertFalse(harness.session.canType)
        XCTAssertEqual(harness.session.unfamiliarContent?.reason, "prop:textAlignment")
        XCTAssertTrue(harness.input.isFrozen)
    }
}
