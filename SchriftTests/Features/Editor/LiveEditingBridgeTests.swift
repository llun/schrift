import XCTest

@testable import Schrift

/// `LiveEditingBridge` — the C1 coordinator that owns the BlockNote-id ⇄
/// `EditorBlock.id` identity map, decides engagement via
/// `EditorViewModel.canEngageLiveEditing`, diffs a projected replica against
/// the editor's current blocks, and drives `applyLiveRemoteChange`. Uses a
/// scripted `FakeReplicaProvider` (no real socket) and a real headless
/// `EditorViewModel`, loaded exactly like `EditorViewModelLiveTests`.
@MainActor
final class LiveEditingBridgeTests: XCTestCase {
    private let baseURL = URL(string: "https://docs.example.org/api/v1.0/")!
    private let documentID = UUID(uuidString: "8B1B1B1B-1B1B-4B1B-8B1B-1B1B1B1B1B1B")!

    private var cacheDirectory: URL!
    private var childrenSuiteName: String!
    private var draftSuiteNames: [String] = []

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveEditingBridgeTests-\(UUID().uuidString)", isDirectory: true)
        childrenSuiteName = "LiveEditingBridgeTests.children.\(UUID().uuidString)"
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

    // MARK: - Environment (mirrors EditorViewModelLiveTests)

    private func makeEnvironment(
        title: String = "Untitled document"
    ) -> (viewModel: EditorViewModel, coordinator: DocumentSaveCoordinator, draftStore: PendingDraftStore) {
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let suiteName = "LiveEditingBridgeTests.\(UUID().uuidString)"
        draftSuiteNames.append(suiteName)
        let draftStore = PendingDraftStore(userDefaults: UserDefaults(suiteName: suiteName)!)
        let contentCache = DocumentContentCacheStore(directory: cacheDirectory)
        let childrenCache = DocumentChildrenCacheStore(userDefaults: UserDefaults(suiteName: childrenSuiteName)!)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: draftStore, contentCache: contentCache, backgroundTasks: .noop)
        let viewModel = EditorViewModel(
            client: client,
            documentID: documentID,
            title: title,
            saveCoordinator: coordinator,
            contentCache: contentCache,
            childrenCache: childrenCache
        )
        return (viewModel, coordinator, draftStore)
    }

    private func formattedBody(
        content: String?, title: String = "Doc", updatedAt: String = "2026-01-15T10:30:00Z"
    ) -> Data {
        let contentJSON = content.map { "\"\($0)\"" } ?? "null"
        return Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "\(title)", "content": \(contentJSON), "created_at": "2026-01-15T10:30:00Z", "updated_at": "\(updatedAt)"}
            """.utf8)
    }

    private func stubLoad(content: String?) {
        let body = formattedBody(content: content)
        MockURLProtocol.stubHandler = { _ in .init(statusCode: 200, headers: [:], body: body, error: nil) }
    }

    /// Loads `content` into a clean view model, returning it alongside a
    /// coordinator, ready for `canEngageLiveEditing` to be true.
    private func loadDocument(content: String) async -> (
        viewModel: EditorViewModel, coordinator: DocumentSaveCoordinator
    ) {
        let (viewModel, coordinator, _) = makeEnvironment()
        stubLoad(content: content)
        await viewModel.load()
        return (viewModel, coordinator)
    }

    // MARK: - Replica projection helper (mirrors YBlockProjectionRenderTests)

    /// Builds a `ProjectedDocument` from markdown via the same pipeline a save
    /// uses (`MarkdownYjs.encode` → `YUpdateDecoder.decode` → `YDoc.applyUpdate`),
    /// so scripted fixtures are realistic rather than hand-built.
    ///
    /// `carryingIDsFrom` simulates two snapshots of *one evolving replica*
    /// (what the manager's real `projectedReplica` would hand the bridge across
    /// two successive live edits — the same underlying items, so the same
    /// BlockNote ids, unless a block was genuinely added/removed). Each call
    /// here builds an independent `YDoc` from scratch, so `MarkdownYjs.encode`
    /// mints fresh random BlockNote ids every time; when the reference document
    /// has the same block count, this overwrites the freshly-minted ids with
    /// the reference's, positionally, so a test can assert identity continuity
    /// the way it would actually hold across a real text edit.
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

    // MARK: - Fake seam

    /// A scripted `LiveReplicaProviding`: no socket, no real replica — just a
    /// per-document version counter and projection the test controls directly.
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

        /// The bridge's registered synchronous read-apply observer. Stored (not
        /// auto-fired on `setVersion`) so tests keep explicit control of *when* the
        /// re-apply runs; `fireReplicaObserver` models the real manager firing it in
        /// the same turn it integrates an update (see `DocumentCollaborationManager
        /// .replicaObservers`).
        private var replicaObserver: (() -> Void)?
        func setReplicaObserver(_ observer: (() -> Void)?, for documentID: UUID) {
            replicaObserver = observer
        }
        func fireReplicaObserver() { replicaObserver?() }

        // Added for the C2c write seam. The read-only tests never call these.
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

    // MARK: - Tests

    func testManagerConformsToTheWriteSeam() {
        // Compile-time proof the manager satisfies the extended protocol; a value
        // typed as the protocol must expose the write methods.
        let provider: LiveReplicaProviding = DocumentCollaborationManager.inert()
        XCTAssertNil(provider.encodeSnapshotForSave(for: documentID))
        XCTAssertFalse(provider.replicaIsFailSafe(for: documentID))
        XCTAssertTrue(provider.hasPendingStructs(for: documentID), "no replica ⇒ nothing safe to write on")
    }

    func testRemoteTextChangeAppliesToEditorBlocks() async throws {
        let (viewModel, _) = await loadDocument(content: "Alpha\\n\\nBeta\\n\\nGamma")
        let originalIDs = viewModel.blocks.map(\.id)
        let provider = FakeReplicaProvider()
        let bridge = LiveEditingBridge(
            documentID: documentID, viewModel: viewModel, collaboration: provider, serverOrigin: nil)

        // First engage: matching content, seeds the map, no diff to apply.
        let initialProjection = try projectedDoc(fromMarkdown: "Alpha\n\nBeta\n\nGamma")
        provider.setProjection(initialProjection, for: documentID)
        bridge.replicaDidChange()
        XCTAssertTrue(bridge.isEngaged)
        XCTAssertEqual(viewModel.blocks.map(\.id), originalIDs, "seeded map keeps identities from the first engage")

        // A remote edit changes only the middle paragraph's text (same replica,
        // so the same BlockNote ids for the untouched blocks).
        provider.setProjection(
            try projectedDoc(fromMarkdown: "Alpha\n\nBeta2\n\nGamma", carryingIDsFrom: initialProjection),
            for: documentID)
        bridge.replicaDidChange()

        XCTAssertTrue(bridge.isEngaged)
        XCTAssertEqual(viewModel.blocks.map(\.id), originalIDs, "untouched blocks keep their ids")
        XCTAssertEqual(viewModel.blocks.map(\.text), ["Alpha", "Beta2", "Gamma"])
    }

    func testDirtyViewModelMakesReplicaDidChangeANoOp() async throws {
        let (viewModel, _) = await loadDocument(content: "Alpha\\n\\nBeta")
        let provider = FakeReplicaProvider()
        let bridge = LiveEditingBridge(
            documentID: documentID, viewModel: viewModel, collaboration: provider, serverOrigin: nil)
        provider.setProjection(try projectedDoc(fromMarkdown: "Alpha\n\nBeta"), for: documentID)
        bridge.replicaDidChange()
        XCTAssertTrue(bridge.isEngaged)

        // A real keystroke, driven through the actual editing path.
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Alpha, mid-edit")
        XCTAssertTrue(viewModel.isDirty)
        let blocksBeforeChange = viewModel.blocks

        provider.setProjection(try projectedDoc(fromMarkdown: "Alpha remote change\n\nBeta"), for: documentID)
        bridge.replicaDidChange()

        XCTAssertFalse(bridge.isEngaged, "a dirty view model must never be engaged")
        XCTAssertEqual(viewModel.blocks, blocksBeforeChange, "the user's own keystrokes were not touched")
    }

    func testOpaqueOrPendingProjectionIsNoOp() async throws {
        let (viewModel, _) = await loadDocument(content: "Alpha")
        let blocksBefore = viewModel.blocks
        let provider = FakeReplicaProvider()
        let bridge = LiveEditingBridge(
            documentID: documentID, viewModel: viewModel, collaboration: provider, serverOrigin: nil)

        // No projection at all (not synced yet).
        bridge.replicaDidChange()
        XCTAssertFalse(bridge.isEngaged)
        XCTAssertEqual(viewModel.blocks, blocksBefore)

        // A not-fully-renderable projection (opaque block — a replica shape the
        // app can't display, e.g. an unknown node).
        let opaqueBlock = ProjectedBlock(
            id: "x", node: "fancyThing", props: [], runs: [], fidelity: .opaque(reason: "nope"))
        let opaqueDocument = ProjectedDocument(blocks: [opaqueBlock], isFullyRenderable: false, isFullyModeled: false)
        provider.setProjection(opaqueDocument, for: documentID)
        bridge.replicaDidChange()

        XCTAssertFalse(bridge.isEngaged)
        XCTAssertEqual(viewModel.blocks, blocksBefore, "an opaque/pending projection must never touch the editor")
    }

    /// A structurally renderable (`isFullyRenderable == true`) projection that
    /// still can't round-trip through markdown must be treated identically to an
    /// opaque/pending one: `replicaDidChange` must not touch the editor, AND
    /// `isApplyingLiveContent` must report `false` so the A5 REST fallback isn't
    /// suppressed. Before the fix, `isApplyingLiveContent` checked only
    /// `isFullyRenderable` (a purely structural check) while `replicaDidChange`
    /// additionally required `YBlockProjection.renderedEditorDocument` to
    /// succeed -- the two could disagree, stranding a document with neither a
    /// live apply nor a REST fallback. The embedded-newline fixture is the same
    /// shape `YBlockProjectionRenderTests.testParagraphWithEmbeddedNewlineIsNil`
    /// uses: escape escalation can never fix an embedded "\n", so the writer
    /// layer returns nil even though the projection itself isn't opaque.
    func testIsApplyingLiveContentFalseWhenProjectionNotRoundTrippable() async throws {
        let (viewModel, _) = await loadDocument(content: "Alpha")
        let blocksBefore = viewModel.blocks
        let provider = FakeReplicaProvider()
        let bridge = LiveEditingBridge(
            documentID: documentID, viewModel: viewModel, collaboration: provider, serverOrigin: nil)

        let block = ProjectedBlock(
            id: "x", node: "paragraph", props: [], runs: [InlineRun("a\nb")], fidelity: .modeled)
        let notRoundTrippable = ProjectedDocument(blocks: [block], isFullyRenderable: true, isFullyModeled: true)
        XCTAssertTrue(notRoundTrippable.isFullyRenderable, "sanity: the structural check alone passes")
        XCTAssertNil(
            YBlockProjection.renderedEditorDocument(notRoundTrippable),
            "sanity: it's the round-trip verification that actually fails")

        provider.setProjection(notRoundTrippable, for: documentID)

        XCTAssertFalse(
            bridge.isApplyingLiveContent,
            "the A5 suppression gate must not claim live content is being applied when it isn't")

        bridge.replicaDidChange()

        XCTAssertFalse(bridge.isEngaged)
        XCTAssertEqual(viewModel.blocks, blocksBefore, "an unrenderable projection must never touch the editor")
    }

    /// After a pause (local dirty edits) resolves back to clean, a further
    /// remote projection from the SAME evolving replica — same BlockNote ids,
    /// only text changed — resumes and applies directly.
    ///
    /// Before the fix, resuming from ANY pause force-reseeded the map purely
    /// by position, discarding BlockNote-id continuity outright (the pause
    /// branch reset `isSeeded`). That masked the realistic case exercised
    /// here: nothing invalidates the map while paused (the pause branch
    /// returns before touching it), and a save never reparses `blocks` (see
    /// `flushPendingChanges` — it PATCHes the current markdown and clears
    /// `isDirty`, nothing more), so the map is still exactly right when
    /// engagement resumes. This is the steady-state half of the staleness
    /// check: `Set(viewModel.blocks.map(\.id)) == Set(map.values)` holds
    /// straight through the pause, so no reseed fires and the resumed apply is
    /// an ordinary in-place update — like two engaged applies in a row. (C2,
    /// the write path, doesn't exist yet, so a local edit never touches the
    /// shared replica either — another reason the same BlockNote ids persist
    /// across a local-edit pause in practice.) The complementary case — a
    /// pause-free `install(...)` that DOES re-identify the blocks and forces a
    /// reseed — is `testInstallReidentifyingBlocksForcesReseedNotChurn`.
    func testReEngageAfterReturningToCleanResumesLiveUpdates() async throws {
        let log = RequestRecorder()
        let (viewModel, coordinator, _) = makeEnvironment()
        let body = formattedBody(content: "Alpha\\n\\nBeta")
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            switch request.httpMethod {
            case "GET" where url.contains("formatted-content"):
                return .init(statusCode: 200, headers: [:], body: body, error: nil)
            default:
                return .init(statusCode: 200, headers: [:], body: Data(), error: nil)
            }
        }
        await viewModel.load()

        let provider = FakeReplicaProvider()
        let bridge = LiveEditingBridge(
            documentID: documentID, viewModel: viewModel, collaboration: provider, serverOrigin: nil)
        let initialProjection = try projectedDoc(fromMarkdown: "Alpha\n\nBeta")
        provider.setProjection(initialProjection, for: documentID)
        bridge.replicaDidChange()
        XCTAssertTrue(bridge.isEngaged)

        // Pause: a local edit makes the view model dirty.
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Alpha locally edited")
        provider.setProjection(
            try projectedDoc(fromMarkdown: "Alpha remote\n\nBeta", carryingIDsFrom: initialProjection),
            for: documentID)
        bridge.replicaDidChange()
        XCTAssertFalse(bridge.isEngaged, "paused while dirty")

        // Return to clean: flush the edit through the real save pipeline.
        viewModel.flushPendingChanges()
        await waitUntil { coordinator.state(for: self.documentID) != .saving }
        XCTAssertFalse(viewModel.isDirty)
        XCTAssertTrue(viewModel.canEngageLiveEditing, "clean and idle again")

        // A new remote projection from the same replica applies directly — the
        // map still resolves its (unchanged) BlockNote ids, so no reseed is
        // needed and this is an ordinary in-place update.
        let idBeforeResume = viewModel.blocks[0].id
        provider.setProjection(
            try projectedDoc(
                fromMarkdown: "Alpha locally edited, then remote too\n\nBeta", carryingIDsFrom: initialProjection),
            for: documentID)
        bridge.replicaDidChange()

        XCTAssertTrue(bridge.isEngaged, "resumes after returning to clean")
        XCTAssertEqual(viewModel.blocks.map(\.id).first, idBeforeResume, "identity preserved across the pause")
        XCTAssertEqual(viewModel.blocks.first?.text, "Alpha locally edited, then remote too")
    }

    func testCaretPreservedForUntouchedFocusedBlock() async throws {
        let (viewModel, _) = await loadDocument(content: "Alpha\\n\\nBeta\\n\\nGamma")
        let idB = viewModel.blocks[1].id
        viewModel.focusedBlockID = idB
        viewModel.selection = NSRange(location: 2, length: 0)
        viewModel.cursorRequest = EditorViewModel.CursorRequest(blockID: idB, offset: 2)
        let cursorRequestBefore = viewModel.cursorRequest

        let provider = FakeReplicaProvider()
        let bridge = LiveEditingBridge(
            documentID: documentID, viewModel: viewModel, collaboration: provider, serverOrigin: nil)
        let initialProjection = try projectedDoc(fromMarkdown: "Alpha\n\nBeta\n\nGamma")
        provider.setProjection(initialProjection, for: documentID)
        bridge.replicaDidChange()

        // A remote change to a DIFFERENT block (Alpha), not the focused one (Beta) —
        // same replica, so Beta keeps its BlockNote id.
        provider.setProjection(
            try projectedDoc(fromMarkdown: "Alpha changed\n\nBeta\n\nGamma", carryingIDsFrom: initialProjection),
            for: documentID)
        bridge.replicaDidChange()

        XCTAssertEqual(viewModel.focusedBlockID, idB, "focus stays on the untouched block")
        XCTAssertEqual(viewModel.cursorRequest, cursorRequestBefore, "no fresh CursorRequest was minted")
        XCTAssertEqual(viewModel.selection, NSRange(location: 2, length: 0))
        XCTAssertEqual(viewModel.blocks.first(where: { $0.id == idB })?.text, "Beta")
    }

    func testFirstEngageWithMatchingContentEmitsNoChanges() async throws {
        let (viewModel, coordinator) = await loadDocument(content: "Alpha\\n\\nBeta")
        let blocksBefore = viewModel.blocks
        XCTAssertNil(coordinator.storedDraft(documentID: documentID))

        let provider = FakeReplicaProvider()
        let bridge = LiveEditingBridge(
            documentID: documentID, viewModel: viewModel, collaboration: provider, serverOrigin: nil)
        // Same content the editor is already showing.
        provider.setProjection(try projectedDoc(fromMarkdown: "Alpha\n\nBeta"), for: documentID)
        bridge.replicaDidChange()

        XCTAssertTrue(bridge.isEngaged)
        XCTAssertEqual(viewModel.blocks, blocksBefore, "no block churn — the diff was empty")
        XCTAssertEqual(viewModel.blocks.map(\.id), blocksBefore.map(\.id), "identities are untouched")
        XCTAssertNil(coordinator.storedDraft(documentID: documentID), "applyLiveRemoteChange writes no draft anyway")

        // Stronger check that `applyLiveRemoteChange` itself was never invoked (not just that
        // its net effect on `blocks` happened to be a no-op): a live apply always advances
        // `serverBaseline` to a `nil`-timestamped baseline (see its doc comment), so if the empty
        // diff had still been applied, a later genuinely-different edit would push with a baseline
        // carrying no server timestamp. Since the diff was skipped outright, the baseline is still
        // the one `load()` installed, which carries the real server `updated_at`.
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Genuinely different")
        viewModel.flushPendingChanges()
        await waitUntil { coordinator.pendingSave(documentID: self.documentID) != nil }
        let draft = coordinator.storedDraft(documentID: documentID)
        XCTAssertNotNil(
            draft?.baseline?.serverUpdatedAt,
            "baseline still carries load()'s server timestamp — the empty diff was never applied")
        await waitUntil { coordinator.state(for: self.documentID) != .saving }
    }

    /// Regression test for the caret-preservation bug found in C1 review: the
    /// identity map used to be gated by a boolean `isSeeded` flag that was only
    /// reset in `replicaDidChange()`'s pause branch — which runs only on a
    /// `replicaVersion` tick. `EditorViewModel.install(...)` (reached via a
    /// pull-to-refresh / server-wins reconcile) re-mints every `EditorBlock.id`
    /// without ever touching the bridge, ticking a replica version, or dropping
    /// `canEngageLiveEditing` — so the flag stayed `true`, the map went stale,
    /// and the next peer update reduced a text-only change to a full
    /// remove+insert, dropping SwiftUI identity, focus, and scroll. The fix
    /// replaces the flag with a self-contained staleness check (the map's value
    /// set vs. the editor's current block-id set) so a re-identification is
    /// caught regardless of what caused it or whether a replica version ticked.
    func testInstallReidentifyingBlocksForcesReseedNotChurn() async throws {
        let (viewModel, _) = await loadDocument(content: "Alpha\\n\\nBeta")
        let idsBeforeRefresh = viewModel.blocks.map(\.id)
        let provider = FakeReplicaProvider()
        let bridge = LiveEditingBridge(
            documentID: documentID, viewModel: viewModel, collaboration: provider, serverOrigin: nil)

        // First engage: matching content, seeds the map against the loaded blocks.
        let initialProjection = try projectedDoc(fromMarkdown: "Alpha\n\nBeta")
        provider.setProjection(initialProjection, for: documentID)
        bridge.replicaDidChange()
        XCTAssertTrue(bridge.isEngaged)

        // A pull-to-refresh reconcile installs a newer server body while the doc
        // stays clean. `install(...)` re-mints every `EditorBlock.id` for the
        // fresh parse — this never touches the bridge, never ticks
        // `replicaVersion`, and never drops `canEngageLiveEditing`.
        stubLoad(content: "Alpha\\n\\nBeta reworded")
        await viewModel.refresh()
        XCTAssertTrue(viewModel.canEngageLiveEditing, "the reconcile left the doc clean and idle")
        let reidentifiedIDs = viewModel.blocks.map(\.id)
        XCTAssertEqual(reidentifiedIDs.count, 2)
        XCTAssertNotEqual(reidentifiedIDs, idsBeforeRefresh, "sanity: install() actually re-minted the ids")

        // A peer update lands next, carrying the SAME BlockNote ids the bridge
        // originally seeded against (the replica the bridge was watching never
        // stopped evolving), with only the second paragraph's text changed once
        // more — the common case of a co-author's single keystroke.
        provider.setProjection(
            try projectedDoc(fromMarkdown: "Alpha\n\nBeta remote", carryingIDsFrom: initialProjection),
            for: documentID)
        bridge.replicaDidChange()

        XCTAssertTrue(bridge.isEngaged)
        XCTAssertEqual(
            viewModel.blocks.map(\.id), reidentifiedIDs,
            "a correct reseed pairs by position, so the post-refresh ids survive a text-only remote edit "
                + "instead of being replaced by yet another fresh set from a remove+insert churn")
        XCTAssertEqual(viewModel.blocks.map(\.text), ["Alpha", "Beta remote"])
    }

    /// Sanity companion to the regression test above: with no `install(...)` in
    /// between, two consecutive text-only remote edits in steady state must NOT
    /// reseed or churn identity — the staleness check is a no-op once the map
    /// already covers the editor's current blocks.
    func testSteadyStateDoesNotReseed() async throws {
        let (viewModel, _) = await loadDocument(content: "Alpha\\n\\nBeta\\n\\nGamma")
        let originalIDs = viewModel.blocks.map(\.id)
        let provider = FakeReplicaProvider()
        let bridge = LiveEditingBridge(
            documentID: documentID, viewModel: viewModel, collaboration: provider, serverOrigin: nil)

        let initialProjection = try projectedDoc(fromMarkdown: "Alpha\n\nBeta\n\nGamma")
        provider.setProjection(initialProjection, for: documentID)
        bridge.replicaDidChange()
        XCTAssertTrue(bridge.isEngaged)

        // First text-only remote edit.
        let secondProjection = try projectedDoc(
            fromMarkdown: "Alpha\n\nBeta2\n\nGamma", carryingIDsFrom: initialProjection)
        provider.setProjection(secondProjection, for: documentID)
        bridge.replicaDidChange()
        XCTAssertEqual(
            viewModel.blocks.map(\.id), originalIDs, "no reseed — the map already covered the current blocks")

        // Second text-only remote edit, same evolving replica.
        provider.setProjection(
            try projectedDoc(fromMarkdown: "Alpha\n\nBeta3\n\nGamma", carryingIDsFrom: secondProjection),
            for: documentID)
        bridge.replicaDidChange()

        XCTAssertTrue(bridge.isEngaged)
        XCTAssertEqual(
            viewModel.blocks.map(\.id), originalIDs,
            "identity survives two consecutive text-only edits with no install() in between")
        XCTAssertEqual(viewModel.blocks.map(\.text), ["Alpha", "Beta3", "Gamma"])
    }

    // MARK: - Write side (C2c)

    /// Engage read-mode first (so `lastAppliedBlocks` is captured), then return the bridge.
    private func engagedWriteBridge(content: String) async throws
        -> (viewModel: EditorViewModel, provider: FakeReplicaProvider, bridge: LiveEditingBridge)
    {
        let (viewModel, _) = await loadDocument(content: content)
        let provider = FakeReplicaProvider()
        provider.pendingStructsFlag = false
        provider.snapshotData = Data([0xAA])
        let projection = try projectedDoc(fromMarkdown: content.replacingOccurrences(of: "\\n", with: "\n"))
        provider.setProjection(projection, for: documentID)
        let bridge = LiveEditingBridge(
            documentID: documentID, viewModel: viewModel, collaboration: provider,
            serverOrigin: nil, snapshotInterval: .milliseconds(20))
        viewModel.liveWrite = bridge
        bridge.replicaDidChange()  // engage read-side ⇒ captures the write baseline
        XCTAssertTrue(bridge.isEngaged)
        return (viewModel, provider, bridge)
    }

    func testLocalEditForwardsToReplicaWithoutStartingAClassicSave() async throws {
        let (viewModel, provider, bridge) = try await engagedWriteBridge(content: "Alpha")
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Alpha edited")

        XCTAssertEqual(provider.appliedEdits.count, 1, "the keystroke was forwarded to the replica exactly once")
        XCTAssertEqual(provider.appliedEdits[0].new.map(\.node), ["paragraph"])
        XCTAssertFalse(viewModel.isDirty, "no classic dirty state in live mode")
        // `EditorViewModel.liveWrite` is WEAK (the bridge holds the view model strongly),
        // so — exactly as the view retains it in production — the test must keep the bridge
        // alive across the edit, or `liveWrite` would be nil and the edit would downgrade.
        withExtendedLifetime(bridge) {}
    }

    func testForwardOldBaselineIsTheLastAppliedProjectionAndAdvances() async throws {
        // `old` is the captured baseline (the projection), `new` is the current
        // id-stable blocks — and the baseline advances so a second forward's `old`
        // is the first forward's `new`, not the stale original.
        let (viewModel, provider, bridge) = try await engagedWriteBridge(content: "Alpha")
        viewModel.startEditing()
        let blockID = viewModel.blocks[0].id
        viewModel.updateText(blockID: blockID, text: "Alpha edited")
        viewModel.updateText(blockID: blockID, text: "Alpha edited twice")

        XCTAssertEqual(provider.appliedEdits.count, 2)
        XCTAssertEqual(
            provider.appliedEdits[0].old.map(\.runs), [InlineMarkdown.parse("Alpha")],
            "first forward's `old` is the captured baseline")
        XCTAssertEqual(
            provider.appliedEdits[1].old.map(\.runs), [InlineMarkdown.parse("Alpha edited")],
            "second forward's `old` is the advanced baseline — the first forward's `new`")
        XCTAssertEqual(
            provider.appliedEdits[1].new.map(\.runs), [InlineMarkdown.parse("Alpha edited twice")])
        XCTAssertEqual(
            provider.appliedEdits[0].new.map(\.id), provider.appliedEdits[1].old.map(\.id),
            "id-stable: the survivor keeps its id across forwards")
        withExtendedLifetime(bridge) {}
    }

    /// Guards the remote-resync -> forward interaction, the highest-stakes property in the
    /// write path and the one no other test pins: after a REMOTE change lands, the next LOCAL
    /// forward must diff against the RESYNCED (post-remote) baseline, not the stale pre-remote
    /// one. `replicaDidChange` re-syncs `lastAppliedBlocks` to the projection at the very end,
    /// after applying the remote change (`LiveEditingBridge.swift` ~176-181) — `forwardLocalEdit`
    /// then reads that stored baseline as `old` (~192-194). If the resync were ever dropped or
    /// moved above the remote apply, `old` would still describe the pre-remote document while
    /// `new` describes post-remote-plus-local content, and `applyLocalEdit` would compute a diff
    /// against the wrong base — a corrupted incremental update broadcast to every peer, silently
    /// (this test would be the only thing to catch it: nothing else composes a remote apply with
    /// a following local forward).
    func testForwardAfterRemoteChangeUsesTheResyncedBaseline() async throws {
        let (viewModel, _) = await loadDocument(content: "Alpha\\n\\nBeta")
        let provider = FakeReplicaProvider()
        provider.pendingStructsFlag = false
        provider.snapshotData = Data([0xAA])
        let bridge = LiveEditingBridge(
            documentID: documentID, viewModel: viewModel, collaboration: provider,
            serverOrigin: nil, snapshotInterval: .milliseconds(20))
        viewModel.liveWrite = bridge

        // 1. Engage read-mode and establish the initial write baseline (mirrors
        // `engagedWriteBridge`, but keeps a handle on `initialProjection` so step 2 can carry
        // its BlockNote ids forward, exactly like `testRemoteTextChangeAppliesToEditorBlocks`).
        let initialProjection = try projectedDoc(fromMarkdown: "Alpha\n\nBeta")
        provider.setProjection(initialProjection, for: documentID)
        bridge.replicaDidChange()
        XCTAssertTrue(bridge.isEngaged)
        let preRemoteBlocks = MarkdownYjs.blockNoteBlocks(from: viewModel.blocks)

        // 2. A REMOTE change lands through the bridge — same evolving replica (carried ids),
        // only the first paragraph's text changed.
        provider.setProjection(
            try projectedDoc(fromMarkdown: "Alpha remote\n\nBeta", carryingIDsFrom: initialProjection),
            for: documentID)
        bridge.replicaDidChange()
        XCTAssertTrue(bridge.isEngaged)
        XCTAssertEqual(viewModel.blocks.map(\.text), ["Alpha remote", "Beta"], "sanity: the remote edit landed")
        let postRemoteBlocks = MarkdownYjs.blockNoteBlocks(from: viewModel.blocks)
        XCTAssertNotEqual(postRemoteBlocks, preRemoteBlocks, "sanity: the projection actually moved")

        // 3. A LOCAL edit forwards next.
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Alpha remote then local")

        // 4. THE TEETH: `old` must be the resynced POST-remote projection, never the PRE-remote
        // baseline captured at step 1. If the resync regressed, the first assertion below fails
        // (and the second would spuriously pass, since `old` would equal `preRemoteBlocks`).
        XCTAssertEqual(provider.appliedEdits.count, 1)
        let old = provider.appliedEdits[0].old
        XCTAssertEqual(old, postRemoteBlocks, "forward's `old` must be the resynced post-remote baseline")
        XCTAssertNotEqual(old, preRemoteBlocks, "forward's `old` must not be the stale pre-remote baseline")
        withExtendedLifetime(bridge) {}
    }

    /// C2c Critical #2: the bridge registers a **synchronous** read-apply observer with the
    /// provider (via `registerReplicaObserver()`, which the view calls on each live-session
    /// acquisition — not at bridge construction), so a remote change re-syncs the write baseline
    /// the instant it integrates — not a deferred turn later. Unlike
    /// `testForwardAfterRemoteChangeUsesTheResyncedBaseline` (which drives the remote apply via
    /// a manual `bridge.replicaDidChange()`, modelling the deferred `.onChange`), this drives it
    /// **only** through the observer the fix registers (`fireReplicaObserver`, modelling the
    /// manager firing it in the same turn it integrates). If the bridge never registered, or the
    /// observer didn't re-apply, `old` would stay the pre-remote baseline and the forward would
    /// corrupt the broadcast — the real-replica end-to-end proof is
    /// `LiveEditingIntegrationTests`' race test.
    func testRemoteChangeViaTheSyncObserverResyncsTheBaselineBeforeAForward() async throws {
        let (viewModel, _) = await loadDocument(content: "Alpha\\n\\nBeta")
        let provider = FakeReplicaProvider()
        provider.pendingStructsFlag = false
        let bridge = LiveEditingBridge(
            documentID: documentID, viewModel: viewModel, collaboration: provider,
            serverOrigin: nil, snapshotInterval: .milliseconds(20))
        viewModel.liveWrite = bridge
        // The view registers the observer on session acquisition, not at bridge init; model
        // that so `provider.fireReplicaObserver()` below has an observer to fire.
        bridge.registerReplicaObserver()

        // Engage on the initial projection (first engage models the normal path).
        let initialProjection = try projectedDoc(fromMarkdown: "Alpha\n\nBeta")
        provider.setProjection(initialProjection, for: documentID)
        bridge.replicaDidChange()
        XCTAssertTrue(bridge.isEngaged)
        let preRemoteBlocks = MarkdownYjs.blockNoteBlocks(from: viewModel.blocks)

        // A remote change integrates. The manager would bump the version and fire the
        // registered observer in the SAME turn; modelled here by advancing the projection and
        // firing the observer, with NO manual `bridge.replicaDidChange()`.
        provider.setProjection(
            try projectedDoc(fromMarkdown: "Alpha remote\n\nBeta", carryingIDsFrom: initialProjection),
            for: documentID)
        provider.setVersion(1, for: documentID)
        provider.fireReplicaObserver()
        XCTAssertEqual(
            viewModel.blocks.map(\.text), ["Alpha remote", "Beta"],
            "the observer alone applied the remote change (no manual replicaDidChange)")
        let postRemoteBlocks = MarkdownYjs.blockNoteBlocks(from: viewModel.blocks)
        XCTAssertNotEqual(postRemoteBlocks, preRemoteBlocks, "sanity: the projection actually moved")

        // The next local forward must diff against the post-remote baseline the observer synced.
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Alpha remote then local")
        XCTAssertEqual(provider.appliedEdits.count, 1)
        XCTAssertEqual(
            provider.appliedEdits[0].old, postRemoteBlocks,
            "the observer-driven remote apply re-synced `old` to the post-remote projection")
        XCTAssertNotEqual(
            provider.appliedEdits[0].old, preRemoteBlocks, "`old` is never the stale pre-remote baseline")
        withExtendedLifetime(bridge) {}
    }

    /// C2c: a document that projects `isFullyRenderable` but NOT `isFullyModeled` (it has a
    /// lossy block that renders with export parity but cannot round-trip through
    /// `blockNoteBlocks(from:)`) is READ-live but never WRITE-live. `canEngageLiveWrite`'s extra
    /// `isFullyModeled` requirement is the guard, and this pins the boundary end-to-end at the
    /// bridge: the read side engages (the projection renders), yet a local keystroke downgrades
    /// to the classic path (`forwardLocalEdit` declines, no `applyLocalEdit`) so a lossy
    /// projection is never diffed and broadcast.
    func testLossyProjectionEngagesReadLiveButDowngradesLocalEditsToClassic() async throws {
        let (viewModel, _) = await loadDocument(content: "Alpha\\n\\nBeta")
        let provider = FakeReplicaProvider()
        provider.pendingStructsFlag = false
        let bridge = LiveEditingBridge(
            documentID: documentID, viewModel: viewModel, collaboration: provider,
            serverOrigin: nil, snapshotInterval: .milliseconds(20))
        viewModel.liveWrite = bridge

        // A projection that renders (read-live) but is NOT fully modeled — take a real
        // fully-modeled projection and flip the write-only flag, keeping it renderable.
        var lossy = try projectedDoc(fromMarkdown: "Alpha\n\nBeta")
        lossy.isFullyModeled = false
        XCTAssertTrue(lossy.isFullyRenderable, "sanity: the projection still renders")
        provider.setProjection(lossy, for: documentID)

        bridge.replicaDidChange()
        XCTAssertTrue(bridge.isEngaged, "a renderable projection engages the read side")
        XCTAssertTrue(bridge.isApplyingLiveContent, "read-live even though it is not write-live")
        XCTAssertFalse(
            canEngageLiveWrite(
                canEngageLiveEditing: viewModel.canEngageLiveEditing,
                projection: provider.projectedReplica(for: documentID, interlinkingOrigin: nil)),
            "a lossy projection is not write-eligible")

        // A local edit must downgrade to classic (the forward declines), never write-live.
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Alpha edited")
        XCTAssertEqual(
            provider.appliedEdits.count, 0, "a lossy projection never forwards a local edit to the replica")
        XCTAssertTrue(viewModel.isDirty, "the edit fell through to the classic dirty path")
        XCTAssertEqual(viewModel.blocks[0].text, "Alpha edited", "the edit is on screen for the classic save")
        withExtendedLifetime(bridge) {}
    }

    func testForwardingDoesNotLoopBackAsARemoteApply() async throws {
        let (viewModel, provider, bridge) = try await engagedWriteBridge(content: "Alpha")
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Alpha edited")
        // `applyLocalEdit` does not bump replicaVersion (C2a), so replicaDidChange never
        // re-fires; exactly one forward, and the editor's own text is intact.
        // Note: the real protection against a self-echo loop is C2a's echo suppression
        // (`applyLocalEdit` not bumping `replicaVersion`) plus the view wiring that observes
        // it — this unit test is a regression floor, since nothing here observes
        // `replicaVersion` and so a real loop can't manifest in this harness either way.
        XCTAssertEqual(provider.appliedEdits.count, 1)
        XCTAssertEqual(viewModel.blocks[0].text, "Alpha edited")
        withExtendedLifetime(bridge) {}
    }

    func testSnapshotDebounceRunsALiveSave() async throws {
        // `loadDocument`'s stub returns 200 for any request, so the snapshot's PATCH
        // succeeds; assert the terminal `.saved` state, not the transient write-ahead
        // draft (which `finish` clears on success — a flaky thing to poll).
        let (viewModel, provider, bridge) = try await engagedWriteBridge(content: "Alpha")
        provider.snapshotData = Data([0xBE, 0xEF])
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Alpha edited")

        // `state(for:) == .saved` cannot be spelled (DocSaveState.saved carries a Date);
        // the VM's payload-free SaveState projects it, and is `.saved` only when the
        // coordinator is `.saved` AND the VM is not dirty.
        await waitUntil { viewModel.saveState == .saved }
        // isDirty stayed false throughout, so nothing but `persistLiveSnapshot` could
        // have started this save — the debounced snapshot ran.
        XCTAssertFalse(viewModel.isDirty)
        withExtendedLifetime(bridge) {}
    }

    func testNilSnapshotNeverStartsASave() async throws {
        let (viewModel, provider, bridge) = try await engagedWriteBridge(content: "Alpha")
        provider.snapshotData = nil  // TOP SAFETY: half-synced / fail-safed ⇒ no PATCH
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Alpha edited")
        bridge.flushPendingLiveSnapshot()  // fire now; nothing to snapshot
        // Nothing enqueued, so the state never leaves `.idle` and no draft was written.
        XCTAssertEqual(viewModel.saveCoordinator.state(for: documentID), .idle)
        XCTAssertNil(viewModel.saveCoordinator.storedDraft(documentID: documentID))
    }

    func testFlushFiresThePendingSnapshotImmediately() async throws {
        // The debounce interval is 20 ms but flush fires it now, before the timer;
        // the PATCH lands, so the terminal state is `.saved`.
        let (viewModel, provider, bridge) = try await engagedWriteBridge(content: "Alpha")
        provider.snapshotData = Data([0xBE, 0xEF])
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Alpha edited")
        bridge.flushPendingLiveSnapshot()

        await waitUntil { viewModel.saveState == .saved }
        XCTAssertFalse(viewModel.isDirty)
    }

    func testThrowingApplyLocalEditDowngradesTheEditToClassic() async throws {
        // Projection stays modeled (gate passes), but `applyLocalEdit` throws — a
        // malformed replica that fail-safes. The `try?` guard downgrades to classic.
        let (viewModel, provider, bridge) = try await engagedWriteBridge(content: "Alpha")
        provider.applyResult = .failure(YIntegrationError.unexpectedCase)
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Alpha edited")

        // The edit reached the replica (the gate passed) and then threw, proving this is
        // the throw-downgrade — not a bridge that was never consulted.
        XCTAssertEqual(provider.appliedEdits.count, 1, "the forward was attempted before it threw")
        XCTAssertTrue(viewModel.isDirty, "a throwing/fail-safed replica falls back to the classic dirty path")
        XCTAssertEqual(viewModel.blocks[0].text, "Alpha edited", "the edit is on screen for the classic save")
        withExtendedLifetime(bridge) {}
    }
}
