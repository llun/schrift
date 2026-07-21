import XCTest

@testable import Schrift

/// Records every socket the manager builds. Copied from
/// `DocumentCollaborationManagerTests`' private `SocketFactorySpy` (top-level
/// `private` is file-scoped in Swift, so it isn't reachable from this file) —
/// kept minimal since this suite only ever opens one document's socket.
private final class SocketFactorySpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _sockets: [FakeWebSocket] = []

    var factory: WebSocketFactory {
        { _ in
            let socket = FakeWebSocket()
            self.lock.withLock { self._sockets.append(socket) }
            return socket
        }
    }

    var sockets: [FakeWebSocket] { lock.withLock { _sockets } }
}

/// Task 6 end-to-end coverage: `LiveEditingBridge` wired onto the **real**
/// collaboration stack, exactly the seam `EditorView` wires (its
/// `.onChange(of: collaboration.replicaVersion(for:))` calls
/// `bridge.replicaDidChange()`). Drives `FakeWebSocket ->
/// CollaborationTransport -> DocumentCollaborationSession ->
/// DocumentCollaborationManager (replica) -> LiveEditingBridge ->
/// EditorViewModel`, with a real `EditorViewModel` loaded to clean state via
/// `MockURLProtocol` exactly like `EditorViewModelLiveTests`/
/// `LiveEditingBridgeTests`.
///
/// The four fixture hex strings below are **real yjs@13.6.31 updates**
/// (Node v24, `npm install yjs@13.6.31` in a session-local scratch dir —
/// never committed, per the repo's zero-third-party-dependency rule),
/// capturing a genuine incremental editing session: an initial 3-block
/// document, then a real `Y.XmlText` delete+insert changing one paragraph's
/// text, a real block insert, and a real block delete — each one a
/// state-vector-diffed delta (`Y.encodeStateAsUpdate(doc, sv)`), exactly the
/// shape a live peer's edits arrive as over the collaboration socket.
///
/// This is deliberate, not a shortcut: two independently-`MarkdownYjs.encode`d
/// full snapshots cannot be merged onto one live replica as an in-place edit
/// — each encode mints a fresh client id and a clock range starting at 0, so
/// delivering a second one to a replica that already integrated the first
/// either collides (same client id: the overlapping clock range is already
/// known and silently dropped) or duplicates (a different client id: the new
/// items arrive as unrelated siblings under the shared "document-store"
/// root, since two independently-built trees carry no origin references into
/// each other). Only a genuine YATA op sequence — a real local edit (C2, not
/// yet built) or an oracle capture of one — represents a coherent incremental
/// delta, which is exactly the technique the rest of `Core/Yjs`'s oracle
/// suite (`YBlockProjectionOracleTests`) already uses for shapes the app's
/// own encoder can't produce.
///
/// ## Regeneration
///
/// ```js
/// import * as Y from "yjs";
///
/// function hex(update) { return Buffer.from(update).toString("hex"); }
///
/// const doc = new Y.Doc();
/// doc.clientID = 1;
/// const sv0 = Y.encodeStateVector(doc);
///
/// const fragment = doc.getXmlFragment("document-store");
/// const blockGroup = new Y.XmlElement("blockGroup");
/// fragment.insert(0, [blockGroup]);
///
/// function makeContainer(id, node, text, extraAttrs) {
///   const container = new Y.XmlElement("blockContainer");
///   container.setAttribute("id", id);
///   const el = new Y.XmlElement(node);
///   el.setAttribute("backgroundColor", "default");
///   el.setAttribute("textColor", "default");
///   el.setAttribute("textAlignment", "left");
///   if (extraAttrs) for (const [k, v] of Object.entries(extraAttrs)) el.setAttribute(k, v);
///   const xmlText = new Y.XmlText(text);
///   el.insert(0, [xmlText]);
///   container.insert(0, [el]);
///   return { container, xmlText };
/// }
///
/// const H_ID = "11111111-1111-4111-8111-111111111111";
/// const P1_ID = "22222222-2222-4222-8222-222222222222";
/// const P2_ID = "33333333-3333-4333-8333-333333333333";
/// const P3_ID = "44444444-4444-4444-8444-444444444444";
///
/// const h = makeContainer(H_ID, "heading", "Doc", { level: 1, isToggleable: false });
/// const p1 = makeContainer(P1_ID, "paragraph", "First");
/// const p2 = makeContainer(P2_ID, "paragraph", "Second");
/// blockGroup.insert(0, [h.container, p1.container, p2.container]);
///
/// console.log("INITIAL", hex(Y.encodeStateAsUpdate(doc, sv0)));
/// const sv1 = Y.encodeStateVector(doc);
///
/// p1.xmlText.delete(0, p1.xmlText.length);
/// p1.xmlText.insert(0, "First changed");
/// console.log("TEXT_CHANGE", hex(Y.encodeStateAsUpdate(doc, sv1)));
/// const sv2 = Y.encodeStateVector(doc);
///
/// const p3 = makeContainer(P3_ID, "paragraph", "Third");
/// blockGroup.insert(3, [p3.container]);
/// console.log("INSERT", hex(Y.encodeStateAsUpdate(doc, sv2)));
/// const sv3 = Y.encodeStateVector(doc);
///
/// blockGroup.delete(2, 1); // removes P2 ("Second")
/// console.log("REMOVE", hex(Y.encodeStateAsUpdate(doc, sv3)));
/// ```
@MainActor
final class LiveEditingIntegrationTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!

    private var cacheDirectory: URL!
    private var childrenSuiteName: String!
    private var draftSuiteNames: [String] = []

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveEditingIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        childrenSuiteName = "LiveEditingIntegrationTests.children.\(UUID().uuidString)"
        draftSuiteNames = []
    }

    override func tearDown() {
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: cacheDirectory)
        UserDefaults(suiteName: childrenSuiteName)?.removePersistentDomain(forName: childrenSuiteName)
        for suiteName in draftSuiteNames {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    // MARK: - Environment (mirrors LiveEditingBridgeTests)

    private func makeEnvironment(remoteChangeDebounce: Duration = .milliseconds(600)) -> (
        viewModel: EditorViewModel, coordinator: DocumentSaveCoordinator, log: RequestRecorder
    ) {
        let log = RequestRecorder()
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let suiteName = "LiveEditingIntegrationTests.\(UUID().uuidString)"
        draftSuiteNames.append(suiteName)
        let draftStore = PendingDraftStore(userDefaults: UserDefaults(suiteName: suiteName)!)
        let contentCache = DocumentContentCacheStore(directory: cacheDirectory)
        let childrenCache = DocumentChildrenCacheStore(userDefaults: UserDefaults(suiteName: childrenSuiteName)!)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: draftStore, contentCache: contentCache, backgroundTasks: .noop)
        let viewModel = EditorViewModel(
            client: client,
            documentID: documentID,
            title: "Untitled document",
            saveCoordinator: coordinator,
            contentCache: contentCache,
            childrenCache: childrenCache,
            remoteChangeDebounce: remoteChangeDebounce
        )
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                let body = Data(
                    """
                    {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "Placeholder",
                    "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z"}
                    """.utf8)
                return .init(statusCode: 200, headers: [:], body: body, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: Data(), error: nil)
        }
        return (viewModel, coordinator, log)
    }

    private func makeManager(spy: SocketFactorySpy) -> DocumentCollaborationManager {
        let manager = DocumentCollaborationManager(
            serverBaseURL: baseURL,
            cookieProvider: { [] },
            featureEnabled: { true },
            isOffline: { false },
            serverConfigProvider: { nil },
            socketFactory: spy.factory,
            lingerSeconds: 0.05)
        manager.serverSupportsLiveCollaboration = true
        return manager
    }

    private func syncUpdateFrame(hex: String) -> Data {
        let payload = SyncMessage(step: .update, data: Data(hex: hex)).encodedPayload()
        return HocuspocusMessage(documentName: documentID.uuidString.lowercased(), type: .sync, payload: payload)
            .encoded()
    }

    /// The `.step2` reply to our own SyncStep1 — the realistic first inbound
    /// content frame in a session, and the one that fires `onInitialSync` so the
    /// manager marks the replica synced (Task 6's authority move: only a `.step2`
    /// makes the replica projectable/writable; a bare `.update` builds it but
    /// leaves it un-synced). The initial 3-block document is delivered through
    /// this; the incremental edits that follow stay `.update`, exactly as a real
    /// peer's stream arrives (step1 out → step2 in → updates…).
    private func syncStep2Frame(hex: String) -> Data {
        let payload = SyncMessage(step: .step2, data: Data(hex: hex)).encodedPayload()
        return HocuspocusMessage(documentName: documentID.uuidString.lowercased(), type: .sync, payload: payload)
            .encoded()
    }

    // MARK: - Fixtures (real yjs@13.6.31 captures — see the regeneration script above)

    private let initialHex =
        "011b010007010e646f63756d656e742d73746f7265030a626c6f636b47726f757007000100030e626c6f636b436f6e7461696e657207000101030768656164696e6707000102060400010303446f63280001020f6261636b67726f756e64436f6c6f7201770764656661756c74280001020974657874436f6c6f7201770764656661756c74280001020d74657874416c69676e6d656e740177046c65667428000102056c6576656c017d01280001020c6973546f67676c6561626c6501792800010102696401772431313131313131312d313131312d343131312d383131312d313131313131313131313131870101030e626c6f636b436f6e7461696e65720700010d03097061726167726170680700010e060400010f0546697273742800010e0f6261636b67726f756e64436f6c6f7201770764656661756c742800010e0974657874436f6c6f7201770764656661756c742800010e0d74657874416c69676e6d656e740177046c6566742800010d02696401772432323232323232322d323232322d343232322d383232322d32323232323232323232323287010d030e626c6f636b436f6e7461696e65720700011903097061726167726170680700011a060400011b065365636f6e642800011a0f6261636b67726f756e64436f6c6f7201770764656661756c742800011a0974657874436f6c6f7201770764656661756c742800011a0d74657874416c69676e6d656e740177046c6566742800011902696401772433333333333333332d333333332d343333332d383333332d33333333333333333333333300"
    private let textChangeHex = "010101268401140d4669727374206368616e6765640101011005"
    private let insertHex =
        "01080133870119030e626c6f636b436f6e7461696e6572070001330309706172616772617068070001340604000135055468697264280001340f6261636b67726f756e64436f6c6f7201770764656661756c74280001340974657874436f6c6f7201770764656661756c74280001340d74657874416c69676e6d656e740177046c6566742800013302696401772434343434343434342d343434342d343434342d383434342d3434343434343434343434340101011005"
    private let removeHex = "000101021005190d"
    /// A real yjs@13.6.31 delta removing the **first paragraph** ("First", index 1)
    /// from the initial 3-block document, computed against the initial state vector —
    /// so it applies directly on top of `initialHex` alone (unlike `removeHex`, which
    /// removes index 2 in the four-step fixture sequence). It shifts "Second" from
    /// index 2 to index 1, which is what makes a *stale* write baseline mis-position a
    /// local edit. Regeneration (appended to the script above):
    /// `blockGroup.delete(1, 1); hex(Y.encodeStateAsUpdate(doc, sv1))`.
    private let removeFirstParagraphHex = "000101010d0c"

    // MARK: - Tests

    func testLiveStreamDrivesEditorBlocksEndToEndWithIdentityAndCaretPreserved() async throws {
        let (viewModel, _, _) = makeEnvironment()
        await viewModel.load()
        XCTAssertTrue(viewModel.hasLoadedContent)

        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: documentID)
        await waitUntil { spy.sockets.count == 1 }

        let bridge = LiveEditingBridge(
            documentID: documentID, viewModel: viewModel, collaboration: manager, serverOrigin: nil)

        // -- Initial sync: the manager's replica integrates a real 3-block
        // document (heading "Doc" + two paragraphs) delivered over the socket.
        spy.sockets[0].deliver(message: syncStep2Frame(hex: initialHex))
        await waitUntil { manager.replicaVersion(for: self.documentID) == 1 }
        bridge.replicaDidChange()

        XCTAssertTrue(bridge.isEngaged)
        XCTAssertTrue(bridge.isApplyingLiveContent, "a clean, synced-to-the-stream doc is applying live content")
        XCTAssertEqual(viewModel.blocks.map(\.kind), [.heading(level: 1), .paragraph, .paragraph])
        XCTAssertEqual(viewModel.blocks.map(\.text), ["Doc", "First", "Second"])

        let headingID = viewModel.blocks[0].id
        let firstID = viewModel.blocks[1].id
        let secondID = viewModel.blocks[2].id

        // Focus + caret on "Second" -- the block the next remote change does NOT touch.
        viewModel.focusedBlockID = secondID
        viewModel.selection = NSRange(location: 3, length: 0)
        viewModel.cursorRequest = EditorViewModel.CursorRequest(blockID: secondID, offset: 3)
        let cursorRequestBefore = viewModel.cursorRequest

        // -- Incremental text change: a real `Y.XmlText` delete+insert turns
        // "First" into "First changed", delivered as a state-vector-diffed delta.
        spy.sockets[0].deliver(message: syncUpdateFrame(hex: textChangeHex))
        await waitUntil { manager.replicaVersion(for: self.documentID) == 2 }
        bridge.replicaDidChange()

        XCTAssertEqual(
            viewModel.blocks.map(\.id), [headingID, firstID, secondID],
            "every block keeps its EditorBlock.id across a text-only remote change")
        XCTAssertEqual(viewModel.blocks.map(\.text), ["Doc", "First changed", "Second"])
        XCTAssertEqual(viewModel.focusedBlockID, secondID, "focus stays on the untouched block")
        XCTAssertEqual(viewModel.selection, NSRange(location: 3, length: 0), "caret on the untouched block survives")
        // `CursorRequest.token` is a fresh UUID on every construction, so this
        // equality also proves no *new* CursorRequest was minted for the
        // untouched block -- `viewModel.cursorRequest` is the exact same value
        // set above, not a freshly-built one that merely matches by coincidence.
        XCTAssertEqual(
            viewModel.cursorRequest, cursorRequestBefore, "no fresh CursorRequest was minted for the untouched block"
        )

        // -- Insert: a real remote block insert appends "Third".
        spy.sockets[0].deliver(message: syncUpdateFrame(hex: insertHex))
        await waitUntil { manager.replicaVersion(for: self.documentID) == 3 }
        bridge.replicaDidChange()

        XCTAssertEqual(viewModel.blocks.map(\.text), ["Doc", "First changed", "Second", "Third"])
        XCTAssertEqual(
            Array(viewModel.blocks.map(\.id).prefix(3)), [headingID, firstID, secondID],
            "existing blocks keep their identity across a remote insert")
        let thirdID = viewModel.blocks[3].id

        // -- Remove: a real remote block delete drops "Second".
        spy.sockets[0].deliver(message: syncUpdateFrame(hex: removeHex))
        await waitUntil { manager.replicaVersion(for: self.documentID) == 4 }
        bridge.replicaDidChange()

        XCTAssertEqual(viewModel.blocks.map(\.text), ["Doc", "First changed", "Third"], "blocks converge, no crash")
        XCTAssertEqual(
            viewModel.blocks.map(\.id), [headingID, firstID, thirdID],
            "surviving blocks keep their identity across a remote remove")

        session?.stop()
    }

    func testFallbackRefetchIsSuppressedWhileBridgeIsApplyingLiveContentButNotWhenDirty() async throws {
        // A short debounce so the dirty branch's real (debounced) A5 revalidation
        // GET lands quickly once `noteRemoteChange()` is actually called below.
        let (viewModel, _, log) = makeEnvironment(remoteChangeDebounce: .milliseconds(20))
        await viewModel.load()
        let getsAfterLoad = log.count(ofMethod: "GET", urlContaining: "formatted-content")

        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: documentID)
        await waitUntil { spy.sockets.count == 1 }

        let bridge = LiveEditingBridge(
            documentID: documentID, viewModel: viewModel, collaboration: manager, serverOrigin: nil)
        spy.sockets[0].deliver(message: syncStep2Frame(hex: initialHex))
        await waitUntil { manager.replicaVersion(for: self.documentID) == 1 }
        bridge.replicaDidChange()

        // `EditorView`'s real `.onChange(of: collaboration.remoteChangeToken(for:))`
        // closure isn't reachable from XCTest (SwiftUI `.onChange` closures can't be
        // invoked directly), so this verifies the gate VALUE that closure keys on
        // instead of the closure itself: `isApplyingLiveContent == true` here is
        // exactly what makes the closure skip calling `viewModel.noteRemoteChange()`
        // altogether. Asserting "no GET fires" without ever calling
        // `noteRemoteChange()` would be tautological -- of course nothing fires a
        // request it never made -- so that call happens for real only on the dirty
        // branch below, where the gate is false and the call is expected to matter.
        XCTAssertTrue(bridge.isApplyingLiveContent, "a clean, synced-to-the-stream doc would suppress the fallback")

        // Once dirty, the gate must stop suppressing -- the fallback behaves
        // exactly as it did before this task: calling `noteRemoteChange()` for
        // real now actually fires a debounced GET.
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "a local edit")
        XCTAssertFalse(bridge.isApplyingLiveContent)
        viewModel.noteRemoteChange()
        await waitUntil { log.count(ofMethod: "GET", urlContaining: "formatted-content") > getsAfterLoad }

        session?.stop()
    }

    func testDirtyViewModelIsNotApplyingLiveContent() async throws {
        let (viewModel, _, _) = makeEnvironment()
        await viewModel.load()

        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: documentID)
        await waitUntil { spy.sockets.count == 1 }

        let bridge = LiveEditingBridge(
            documentID: documentID, viewModel: viewModel, collaboration: manager, serverOrigin: nil)
        spy.sockets[0].deliver(message: syncStep2Frame(hex: initialHex))
        await waitUntil { manager.replicaVersion(for: self.documentID) == 1 }
        bridge.replicaDidChange()
        XCTAssertTrue(bridge.isApplyingLiveContent, "clean and synced")

        // A real keystroke makes the view model dirty -- `isApplyingLiveContent`
        // is a FRESH check (`canEngageLiveEditing`), not the stale `isEngaged`
        // flag, so this must flip immediately without another `replicaDidChange()`.
        // This is the gate `EditorView` consults before suppressing the A5
        // fallback refetch (`viewModel.noteRemoteChange()`): while dirty, a REST
        // re-fetch must be allowed to run as it always has, never suppressed.
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "a local edit")
        XCTAssertTrue(viewModel.isDirty)
        XCTAssertFalse(bridge.isApplyingLiveContent, "a dirty view model is never treated as applying live content")

        session?.stop()
    }

    // MARK: - Write-side capstone (Task 7)
    //
    // The environment/fake helpers below mirror `LiveEditingBridgeTests`' helpers of the
    // same name -- Swift `private` is file-scoped, so they can't be reused directly.

    private func formattedBody(
        content: String, title: String = "Doc", updatedAt: String = "2026-01-15T10:30:00Z"
    ) -> Data {
        Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "\(title)", "content": "\(content)", "created_at": "2026-01-15T10:30:00Z", "updated_at": "\(updatedAt)"}
            """.utf8)
    }

    /// Loads `content` into a clean view model, ready for `canEngageLiveEditing` to be true.
    private func loadDocument(content: String) async -> (
        viewModel: EditorViewModel, coordinator: DocumentSaveCoordinator
    ) {
        let (viewModel, coordinator, _) = makeEnvironment()
        let body = formattedBody(content: content)
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: body, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: Data(), error: nil)
        }
        await viewModel.load()
        return (viewModel, coordinator)
    }

    /// Builds a `ProjectedDocument` from markdown via the same pipeline a save uses
    /// (`MarkdownYjs.encode` -> `YUpdateDecoder.decode` -> `YDoc.applyUpdate`). See
    /// `LiveEditingBridgeTests`' helper of the same name for the full rationale on
    /// `carryingIDsFrom` (simulating two snapshots of one evolving replica).
    private func projectedDoc(fromMarkdown md: String, carryingIDsFrom reference: ProjectedDocument? = nil) throws
        -> ProjectedDocument
    {
        let doc = YDoc(clientID: 99)
        try doc.applyUpdate(try YUpdateDecoder.decode(MarkdownYjs.encode(markdown: md, clientID: 1)))
        var projected = YBlockProjection.project(doc)
        doc.destroy()
        if let reference, reference.blocks.count == projected.blocks.count {
            for index in projected.blocks.indices {
                projected.blocks[index].id = reference.blocks[index].id
            }
        }
        return projected
    }

    /// A scripted `LiveReplicaProviding`: no socket, no real replica -- a per-document
    /// version counter and projection the test controls directly, plus the C2c write
    /// seam (`applyLocalEdit`/`encodeSnapshotForSave`/`replicaIsFailSafe`/`hasPendingStructs`).
    private final class FakeReplicaProvider: LiveReplicaProviding {
        private var versions: [UUID: Int] = [:]
        private var projections: [UUID: ProjectedDocument] = [:]

        func setVersion(_ version: Int, for documentID: UUID) {
            versions[documentID] = version
        }

        func setProjection(_ projection: ProjectedDocument?, for documentID: UUID) {
            if let projection {
                projections[documentID] = projection
            } else {
                projections.removeValue(forKey: documentID)
            }
        }

        func replicaVersion(for documentID: UUID) -> Int {
            versions[documentID] ?? 0
        }

        func projectedReplica(for documentID: UUID, interlinkingOrigin: String?) -> ProjectedDocument? {
            projections[documentID]
        }

        /// Stored, not auto-fired: the capstone drives `bridge.replicaDidChange()`
        /// directly, so it keeps explicit control of when the read-apply runs (the real
        /// manager fires this synchronously on integrate — see the C2c race test).
        private var replicaObserver: (() -> Void)?
        func setReplicaObserver(_ observer: (() -> Void)?, for documentID: UUID) {
            replicaObserver = observer
        }

        var snapshotData: Data?
        var failSafe = false
        var pendingStructsFlag = true
        private(set) var appliedEdits: [(old: [BlockNoteBlock], new: [BlockNoteBlock])] = []
        var applyResult: Result<Data, Error> = .success(Data([0x01]))

        func applyLocalEdit(old: [BlockNoteBlock], new: [BlockNoteBlock], for documentID: UUID) throws -> Data {
            appliedEdits.append((old, new))
            return try applyResult.get()
        }
        func encodeSnapshotForSave(for documentID: UUID) -> Data? { snapshotData }
        func replicaIsFailSafe(for documentID: UUID) -> Bool { failSafe }
        func hasPendingStructs(for documentID: UUID) -> Bool { pendingStructsFlag }
    }

    /// Captures method/url/body for every request issued after it is installed, so the
    /// capstone test can confirm the live-snapshot PATCH actually carries
    /// `"websocket": true` and that the downgrade's classic save is an ordinary,
    /// distinguishable content PATCH. `RequestRecorder` (used elsewhere in this file)
    /// only tracks method/url, not the body, which this test needs to tell the two
    /// content PATCHes apart.
    private final class BodyRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(method: String, url: String, body: Data?)] = []

        func record(_ request: URLRequest) {
            let entry = (request.httpMethod ?? "", request.url?.absoluteString ?? "", bodyData(from: request))
            lock.lock()
            entries.append(entry)
            lock.unlock()
        }

        func entries(ofMethod method: String, urlContaining substring: String) -> [(
            method: String, url: String, body: Data?
        )] {
            lock.lock()
            defer { lock.unlock() }
            return entries.filter { $0.method == method && $0.url.contains(substring) }
        }
    }

    /// The capstone: engage a live-write session, forward a local edit, apply a remote
    /// change (re-syncing the write baseline), let the debounced snapshot save land, then
    /// force a fail-safe downgrade and confirm the next edit persists through the classic
    /// path with no data loss and no false conflict. Drives the real `EditorViewModel` +
    /// `LiveEditingBridge` + `DocumentSaveCoordinator`, with `MockURLProtocol` standing in
    /// for the server -- proving Tasks 1-6 compose end to end.
    func testLiveSessionForwardsRemoteAppliesSnapshotsThenDowngradesOnFailSafe() async throws {
        // 1. Engage a clean, fully-synced, fully-modeled document.
        let (viewModel, _) = await loadDocument(content: "Alpha\\n\\nBeta")
        let provider = FakeReplicaProvider()
        provider.pendingStructsFlag = false
        provider.snapshotData = Data([0x01, 0x02])
        let projection = try projectedDoc(fromMarkdown: "Alpha\n\nBeta")
        provider.setProjection(projection, for: documentID)
        let bridge = LiveEditingBridge(
            documentID: documentID, viewModel: viewModel, collaboration: provider,
            serverOrigin: nil, snapshotInterval: .milliseconds(20))
        viewModel.liveWrite = bridge
        bridge.replicaDidChange()
        XCTAssertTrue(bridge.isEngaged)
        XCTAssertTrue(
            canEngageLiveWrite(
                canEngageLiveEditing: viewModel.canEngageLiveEditing,
                projection: provider.projectedReplica(for: documentID, interlinkingOrigin: nil)),
            "a clean, synced, fully-modeled document is live-write-eligible")

        // Every request from here on is recorded so steps 4 and 5 can inspect what
        // actually reached "the server".
        let requests = BodyRecorder()
        MockURLProtocol.stubHandler = { request in
            requests.record(request)
            return .init(statusCode: 200, headers: [:], body: Data(), error: nil)
        }

        // 2. A local edit forwards to the replica (and would broadcast); no classic dirty.
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Alpha!")
        XCTAssertEqual(provider.appliedEdits.count, 1)
        XCTAssertFalse(viewModel.isDirty)
        XCTAssertEqual(
            requests.entries(ofMethod: "PATCH", urlContaining: "/content/").count, 0,
            "no classic markdown enqueue -- the forward, not a REST save, carried the edit")

        // 3. The debounced snapshot runs and settles (`loadDocument`'s stub answers the PATCH
        //    200, so `finish` clears the write-ahead draft -- the gate is restored for step 4).
        await waitUntil { viewModel.saveState == .saved }

        let snapshotPatches = requests.entries(ofMethod: "PATCH", urlContaining: "/content/")
        XCTAssertEqual(snapshotPatches.count, 1, "the debounced snapshot fired exactly one content PATCH")
        if let body = snapshotPatches.first?.body,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        {
            XCTAssertEqual(json["websocket"] as? Bool, true, "a live snapshot save is tagged websocket: true")
            XCTAssertEqual(
                json["content"] as? String, provider.snapshotData?.base64EncodedString(),
                "the exact CRDT bytes the replica handed the bridge are what got PATCHed")
        } else {
            XCTFail("content PATCH body was not JSON")
        }
        let titlePatches = requests.entries(ofMethod: "PATCH", urlContaining: documentID.uuidString.lowercased())
            .filter { !$0.url.contains("/content/") }
        XCTAssertEqual(titlePatches.count, 1, "the live snapshot save also PATCHes the title")

        // 4. A remote change applies caret-preservingly and re-syncs the write baseline.
        provider.setProjection(
            try projectedDoc(fromMarkdown: "Alpha!\n\nBeta2", carryingIDsFrom: projection), for: documentID)
        provider.setVersion(1, for: documentID)
        bridge.replicaDidChange()
        XCTAssertEqual(viewModel.blocks.map(\.text), ["Alpha!", "Beta2"])

        // 5. Downgrade: `applyLocalEdit` now throws (a fail-safed replica). The gate still
        // passes (projection modeled, doc clean), so the throw is what forces the
        // fallback -- the next edit runs the classic dirty path without losing content.
        provider.applyResult = .failure(YIntegrationError.unexpectedCase)
        viewModel.updateText(blockID: viewModel.blocks[1].id, text: "Beta2 classic")
        XCTAssertTrue(viewModel.isDirty, "fail-safe ⇒ classic path resumes")
        XCTAssertEqual(viewModel.blocks[1].text, "Beta2 classic", "no content lost across the downgrade")

        // The downgraded edit must actually reach the server through the classic save
        // funnel, land cleanly, and raise no false conflict -- step 3's `persistLiveSnapshot`
        // baseline advance is what keeps this classic push from misreading the server as
        // having diverged out from under it.
        viewModel.flushPendingChanges()
        await waitUntil { viewModel.saveCoordinator.state(for: self.documentID) != .saving }
        XCTAssertEqual(viewModel.saveState, .saved, "the downgraded classic save landed")
        XCTAssertNil(viewModel.syncConflict, "no false conflict raised by the downgraded save")

        let allContentPatches = requests.entries(ofMethod: "PATCH", urlContaining: "/content/")
        XCTAssertEqual(
            allContentPatches.count, 2, "one live-snapshot PATCH (step 3) plus one classic downgrade PATCH")
        if let classicBody = allContentPatches.last?.body,
            let classicJSON = try? JSONSerialization.jsonObject(with: classicBody) as? [String: Any]
        {
            XCTAssertNil(classicJSON["websocket"], "the downgraded save is an ordinary classic PATCH, not tagged")
        } else {
            XCTFail("classic content PATCH body was not JSON")
        }

        // `EditorViewModel.liveWrite` is WEAK (the bridge holds the view model strongly), so
        // -- exactly as the view retains it in production -- the test must keep the bridge
        // alive across every `await` above, or `liveWrite` would go nil mid-test and every
        // forward after that point would silently downgrade for the wrong reason.
        withExtendedLifetime(bridge) {}
    }

    /// Regression for the C2c stale-`lastAppliedBlocks` race — the write path's one
    /// genuine correctness hazard. `applyReplicaUpdate` integrates a remote update and
    /// bumps `replicaVersion` in a single main-actor turn, but the read-apply that
    /// re-syncs the bridge's write baseline used to be *deferred* to a later turn
    /// (SwiftUI `.onChange(of: replicaVersion)`). A keystroke landing in that gap
    /// forwarded a local edit diffed against the *pre-update* projection, and
    /// `BlockNoteWrite.applyEdit` maps each `old[index].id` to the replica's live
    /// container **by position** — so after a structural remote change (here: a block
    /// removed, shifting the one the user edits from index 2 to index 1) the edit is
    /// mis-positioned, corrupting the very replica peers receive the broadcast from.
    ///
    /// The fix makes the read-apply synchronous with the integrate: the manager fires
    /// the bridge's registered observer in the same turn it bumps the version, so by the
    /// time any keystroke runs, the editor and `lastAppliedBlocks` already reflect the
    /// remote change. This test drives the **real** stack and deliberately does NOT call
    /// `bridge.replicaDidChange()` after delivering the remote update — that manual call
    /// stands in for the *deferred* `.onChange` the other tests model, and withholding it
    /// leaves the synchronous observer the fix adds as the only thing that can re-sync the
    /// baseline before the keystroke. Against the pre-fix code both assertions fail: the
    /// editor never merges the remote remove, and the shared replica ends up corrupt.
    func testLocalForwardAfterRemoteUpdateForwardsAgainstTheMergedReplicaNotAStaleBaseline() async throws {
        let (viewModel, _, _) = makeEnvironment()
        await viewModel.load()
        XCTAssertTrue(viewModel.hasLoadedContent)

        let spy = SocketFactorySpy()
        let manager = makeManager(spy: spy)
        let session = manager.session(for: documentID)
        await waitUntil { spy.sockets.count == 1 }

        let bridge = LiveEditingBridge(
            documentID: documentID, viewModel: viewModel, collaboration: manager, serverOrigin: nil)
        viewModel.liveWrite = bridge

        // -- Initial sync: engage on the real 3-block document [Doc, First, Second].
        spy.sockets[0].deliver(message: syncStep2Frame(hex: initialHex))
        await waitUntil { manager.replicaVersion(for: self.documentID) == 1 }
        bridge.replicaDidChange()  // models the deferred `.onChange` firing normally
        XCTAssertTrue(bridge.isEngaged)
        XCTAssertEqual(viewModel.blocks.map(\.text), ["Doc", "First", "Second"])
        let secondID = viewModel.blocks[2].id

        // The user taps into "Second" to edit it. Still clean, so still live-eligible.
        viewModel.startEditing()

        // -- A remote peer removes "First", shifting "Second" from index 2 to index 1.
        // The replica integrates it and bumps the version -- but this test deliberately
        // does NOT call `bridge.replicaDidChange()` here, reproducing the exact window in
        // which the deferred read-apply has not run yet.
        spy.sockets[0].deliver(message: syncUpdateFrame(hex: removeFirstParagraphHex))
        await waitUntil { manager.replicaVersion(for: self.documentID) == 2 }

        // -- The keystroke lands in that window. With the fix, delivering the remote
        // update above already fired the synchronous observer, so the editor and write
        // baseline are caught up to [Doc, Second] and this forwards correctly. Without it,
        // `old` still describes [Doc, First, Second] and the edit is mis-positioned.
        viewModel.updateText(blockID: secondID, text: "Second!")

        // 1. The editor merged the remote remove AND kept the local edit.
        XCTAssertEqual(
            viewModel.blocks.map(\.text), ["Doc", "Second!"],
            "the editor reflects the remote remove merged with the local edit")

        // 2. THE MONEY CHECK: the replica the broadcast derives from projects to the same
        // merged document -- no corruption reaches peers. The edit reached the shifted
        // container, rather than being lost or duplicated onto a stale position.
        let projected = manager.projectedReplica(for: documentID, interlinkingOrigin: nil)
        let rendered = try XCTUnwrap(projected.flatMap { YBlockProjection.renderedEditorDocument($0) })
        XCTAssertEqual(
            rendered.blocks.map(\.text), ["Doc", "Second!"],
            "the shared replica is the correct merge -- the local edit reached the right container")
        XCTAssertEqual(rendered.blocks.map(\.kind), [.heading(level: 1), .paragraph])

        session?.stop()
        withExtendedLifetime(bridge) {}
    }
}
