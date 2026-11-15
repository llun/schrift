import Synchronization
import UIKit
import XCTest

@testable import Schrift

/// PR15 §5A acceptance suite: whole-family preserve/read/edit/round-trip,
/// switch-off rollback & retained rich drafts, classic `BlockNoteYjs.applyEdit`
/// non-regression, new-doc/subpage & offline local-create migration, stale-cache
/// & Docs-6 offline guards, Reading<->Editing mode handoff & all-hidden
/// checklist settling, 10-cycle memory reclamation & sign-out purge, bounded
/// work counters, and `NativeEditorDiagnosticsStore` invariants.
@MainActor
final class NativeEditorAcceptanceTests: NativeEditingTestCase {
    private let owner = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!

    // MARK: - 1. Whole-Family Fixture & Round-Trip (72ebe1bb Contract)

    func testWholeFamilyFixturePreserveReadEditAndWebRoundTrip() async throws {
        let (state, siblingIDs) = try Self.makeWholeFamilyFixture()
        let session = try await NativeEditorSession.seed(state: state, clientID: 41)
        defer { Task { await session.close().value } }
        session.enableTyping(persist: { _, _ in })
        session.setEditing(true)

        // HeadlessSurface vs NativeTextSurface parity on initial projection.
        let headless = HeadlessSurface(blocks: session.surface.blocks)
        XCTAssertEqual(headless.blocks, session.surface.blocks)
        try await assertStorageMatchesProjection(session)

        // Check every registered family is present in the fixture projection.
        let nodes = Set(session.surface.blocks.map(\.node))
        for expected in [
            "paragraph", "heading", "bulletListItem", "numberedListItem", "checkListItem",
            "toggleListItem", "quote", "codeBlock", "divider", "table", "columnList",
            "image", "video", "audio", "file", "pdf", "mathBlock", "diagram",
        ] {
            XCTAssertTrue(nodes.contains(expected), "missing family \(expected) in whole-family fixture")
        }
        XCTAssertTrue(
            session.surface.blocks.contains { block in
                block.runs.contains { $0.inlineObject != nil }
            },
            "fixture must include inline objects (interlinkingLinkInline, mentionInline, math)")

        // Capture untouched sibling YItem IDs before editing.
        let untouchedBefore = await session.replicaDoc { doc in
            Self.containerItemIDs(in: doc, blockIDs: siblingIDs)
        }
        let expectedUntouched = try XCTUnwrap(untouchedBefore)
        XCTAssertEqual(expectedUntouched.count, siblingIDs.count)

        // 1) Edit prose paragraph.
        session.textView.selectedRange = NSRange(location: 0, length: 0)
        session.input?.textViewDidChangeSelection(session.textView)
        session.textView.insertText("Lead ")
        let settledProse = await session.settle()
        XCTAssertTrue(settledProse)
        XCTAssertTrue(session.surface.blocks[0].runs.map(\.text).joined().hasPrefix("Lead "))
        try await assertStorageMatchesProjection(session)

        // 2) Toggle a checklist item.
        XCTAssertTrue(session.input?.toggleCheckbox(blockID: "wf-check-1") == true)
        let settledCheck = await session.settle()
        XCTAssertTrue(settledCheck)
        let toggledCheck = try XCTUnwrap(session.surface.blocks.first { $0.id == "wf-check-1" })
        XCTAssertEqual(toggledCheck.props.first { $0.key == "checked" }?.value, .bool(true))

        // 3) Edit a 2x3 + merged-cell table via openTable.
        let maybeTableSession = await session.openTable("wf-table")
        let tableSession = try XCTUnwrap(maybeTableSession)
        tableSession.setEditing(true)
        tableSession.input?.showCell([tableSession.surface.blocks[0].id])
        tableSession.textView.selectedRange = NSRange(location: 0, length: 0)
        tableSession.input?.textViewDidChangeSelection(tableSession.textView)
        tableSession.textView.insertText("CellEdit ")
        let settledTable = await tableSession.settle()
        XCTAssertTrue(settledTable)
        await tableSession.close().value
        let maybeGrid = await session.tableGrid("wf-table", full: true)
        let grid = try XCTUnwrap(maybeGrid)
        XCTAssertTrue(grid.rows[0][0].paragraphs[0].runs.map(\.text).joined().hasPrefix("CellEdit "))
        XCTAssertEqual(grid.rows[1][0].colspan, 2, "merged cell colspan preserved")

        // 4) Edit a column inside a multi-column group via openColumn.
        let maybeColSession = await session.openColumn(group: "wf-cols-2", column: "wf-col-0")
        let colSession = try XCTUnwrap(maybeColSession)
        colSession.setEditing(true)
        colSession.textView.selectedRange = NSRange(location: 0, length: 0)
        colSession.input?.textViewDidChangeSelection(colSession.textView)
        colSession.textView.insertText("ColEdit ")
        let settledCol = await colSession.settle()
        XCTAssertTrue(settledCol)
        XCTAssertTrue(colSession.surface.blocks[0].runs.map(\.text).joined().hasPrefix("ColEdit "))
        await colSession.close().value
        let maybeColGroup = await session.columnGroup("wf-cols-2")
        let colGroup = try XCTUnwrap(maybeColGroup)
        XCTAssertEqual(colGroup.columns.count, 2)

        // 5) Edit a media block's caption prop.
        XCTAssertTrue(
            session.input?.setMediaProps(
                "wf-image", [ProjectedProp(key: "caption", value: .string("Updated caption"))]) == true)
        let settledMedia = await session.settle()
        XCTAssertTrue(settledMedia)

        // 6) Edit mathBlock source via openSource.
        let maybeMathSource = await session.openSource(.block(blockID: "wf-math"))
        let mathSource = try XCTUnwrap(maybeMathSource)
        mathSource.setEditing(true)
        mathSource.textView.selectedRange = NSRange(location: 0, length: mathSource.textView.textStorage.length)
        mathSource.input?.textViewDidChangeSelection(mathSource.textView)
        mathSource.textView.insertText("a^2 + b^2 = c^2")
        let settledMath = await mathSource.settle()
        XCTAssertTrue(settledMath)
        await mathSource.close().value

        // Verify untouched sibling YItem IDs survived byte-intact.
        let untouchedAfter = await session.replicaDoc { doc in
            Self.containerItemIDs(in: doc, blockIDs: siblingIDs)
        }
        XCTAssertEqual(untouchedAfter, expectedUntouched, "untouched sibling YItem IDs must survive intact")

        // Replay full Swift replica state into a fresh clean YDoc (web round-trip).
        let maybeExportedState = await session.replicaDoc { doc in
            try? YStateEncoder.encodeStateAsUpdate(doc)
        }
        let exportedState = try XCTUnwrap(maybeExportedState.flatMap { $0 })
        let cleanPeer = YDoc(clientID: 99, gc: true)
        defer { cleanPeer.destroy() }
        try cleanPeer.applyUpdate(YUpdateDecoder.decode(exportedState), origin: .remote)
        let cleanProjection = NativeBlockProjection.project(cleanPeer)
        let replicaBlocks = await session.replicaDoc {
            NativeBlockProjection.project($0).blocks.map(BlockSnapshot.init)
        }
        XCTAssertEqual(cleanProjection.blocks.map(BlockSnapshot.init), replicaBlocks)
        try await assertStorageMatchesProjection(session)

        // Companion preserved fixture: callout + pageBreak + auxiliary root + unknown mark/prop.
        let preservedState = try Self.makePreservedCompanionFixture()
        let preservedSession = try await NativeEditorSession.seed(state: preservedState, clientID: 42)
        defer { Task { await preservedSession.close().value } }
        XCTAssertFalse(preservedSession.canType, "companion fixture with pageBreak/unknowns stays preserved read-only")
        let maybeRoundTrippedPreserved = await preservedSession.replicaDoc { doc in
            try? YStateEncoder.encodeStateAsUpdate(doc)
        }
        let roundTrippedPreserved = try XCTUnwrap(maybeRoundTrippedPreserved.flatMap { $0 })
        let auxDoc = YDoc(clientID: 100, gc: true)
        defer { auxDoc.destroy() }
        try auxDoc.applyUpdate(YUpdateDecoder.decode(roundTrippedPreserved))
        let auxMap = auxDoc.get("auxiliaryMeta")
        XCTAssertEqual(auxMap.map["version"]?.content, .any([.string("keep-me")]))
        let auxProjected = NativeBlockProjection.project(auxDoc)
        XCTAssertTrue(auxProjected.blocks.contains { $0.block.node == "pageBreak" })
        XCTAssertTrue(auxProjected.blocks.contains { $0.block.node == "callout" })

        // Verify Markdown shadow parity on shadow-eligible subset.
        let shadowDoc = YDoc(clientID: 101, gc: true)
        defer { shadowDoc.destroy() }
        let shadowEligibleState = BlockNoteYjs.encode(
            [
                BlockNoteBlock(
                    node: "heading", props: [("level", .int(1))], runs: [InlineRun("Shadow Title")], id: "sh-1"),
                BlockNoteBlock(
                    node: "paragraph", props: [],
                    runs: [
                        InlineRun("Bold", marks: [("bold", "{}")]),
                        InlineRun(" and "),
                        InlineRun("code", marks: [("code", "{}")]),
                    ],
                    id: "sh-2"),
                BlockNoteBlock(
                    node: "numberedListItem", props: [("start", .int(4))], runs: [InlineRun("Fourth")], id: "sh-3"),
                BlockNoteBlock(
                    node: "checkListItem", props: [("checked", .bool(true))], runs: [InlineRun("Checked")], id: "sh-4"),
                BlockNoteBlock(node: "quote", props: [], runs: [InlineRun("Quoted")], id: "sh-5"),
                BlockNoteBlock(node: "divider", props: [], runs: [], id: "sh-6"),
            ],
            clientID: 55)
        try shadowDoc.applyUpdate(YUpdateDecoder.decode(shadowEligibleState))
        let shadow = try XCTUnwrap(NativeBlockProjection.markdownShadow(shadowDoc))
        XCTAssertTrue(shadow.contains("# Shadow Title"))
        XCTAssertTrue(shadow.contains("**Bold**"))
        XCTAssertTrue(shadow.contains("`code`"))
        XCTAssertTrue(shadow.contains("1. Fourth") || shadow.contains("4. Fourth"))
        XCTAssertTrue(shadow.contains("- [x] Checked"))
        XCTAssertTrue(shadow.contains("> Quoted"))
        XCTAssertTrue(shadow.contains("---"))
    }

    func testRealStateBinCaptureProjectsAndMatchesHeadlessSurfaceIfPresent() throws {
        let review = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".review")
        guard let state = try? Data(contentsOf: review.appendingPathComponent("state.bin")) else {
            throw XCTSkip(".review/state.bin not present")
        }
        let doc = YDoc(clientID: 7, gc: true)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(state))
        let projected = NativeBlockProjection.project(doc)
        XCTAssertFalse(projected.blocks.isEmpty)
        let snapshots = projected.blocks.map(BlockSnapshot.init)
        let textView = NativeTextView()
        let surface = NativeTextSurface(
            blocks: snapshots, storage: textView.textStorage, traits: textView.traitCollection)
        let headless = HeadlessSurface(blocks: snapshots)
        XCTAssertEqual(surface.blocks, headless.blocks)
        let fresh = AttributedDocumentProjection.attributedString(
            blocks: snapshots, traits: surface.traits, labels: surface.labels)
        XCTAssertEqual(surface.storage.string, fresh.string)
    }

    // MARK: - 2. Switch-Off Rollback & Retained Rich Drafts

    func testSwitchOffRollbackRetainsRichDraftAndLeavesUntouchedClassic() async throws {
        let env = makeAcceptanceEnvironment(autosaveInterval: .seconds(30))
        defer { env.clean() }
        let blocks = [
            BlockNoteBlock(
                node: "paragraph", props: Self.paragraphProps, runs: [InlineRun("Rich draft paragraph.")],
                id: "rb-1"),
            BlockNoteBlock(
                node: "checkListItem", props: Self.paragraphProps + [("checked", .bool(false))],
                runs: [InlineRun("Checklist item")], id: "rb-2"),
        ]
        let server = AcceptanceServerStub(owner: owner, state: BlockNoteYjs.encode(blocks, clientID: 1))
        server.install()

        // 1. Enable switch, author edits offline, flush into PendingDraft + ReplicaStore outbox.
        env.defaults.set(true, forKey: NativeEditorPreference.key)
        let open1 = NativeEditorOpen(preference: { NativeEditorPreference.isEnabled(env.defaults) })
        env.model.seedNativeMetadataIfNeeded()
        await open1.open(viewModel: env.model, isOffline: false, canUpdate: true)
        guard case .native(let session1) = open1.route else { return XCTFail("expected native session") }

        server.isOffline = true
        session1.textView.selectedRange = NSRange(location: 0, length: 0)
        session1.input?.textViewDidChangeSelection(session1.textView)
        session1.textView.insertText("Rich ")
        XCTAssertTrue(session1.input?.toggleCheckbox(blockID: "rb-2") == true)
        let settled = await session1.settle()
        XCTAssertTrue(settled)
        open1.updateTitle("Rich Retained Title", viewModel: env.model)
        open1.flushPendingSave()
        await waitUntil { env.model.saveCoordinator.storedDraft(documentID: env.documentID)?.replica != nil }
        open1.close()

        // 2. Disable switch: background sync still replays via applyCollaborationYDocUpdate (never classic markdown).
        env.defaults.set(false, forKey: NativeEditorPreference.key)
        server.isOffline = false
        await env.model.saveCoordinator.syncPendingDrafts()
        await waitUntil { !server.patchedUpdates.isEmpty && server.titles.contains("Rich Retained Title") }
        XCTAssertTrue(server.classicMarkdownPatches.isEmpty, "native draft must never downgrade to Markdown PATCH")

        // 3. Reopen while switch is OFF: owned document stays preserved read-only; classic enqueue no-ops.
        let relaunched = env.relaunch()
        let open2 = NativeEditorOpen(preference: { NativeEditorPreference.isEnabled(env.defaults) })
        defer { open2.close() }
        await open2.open(viewModel: relaunched, isOffline: true, canUpdate: true)
        guard case .native(let preservedSession) = open2.route else {
            return XCTFail("owned native document must reopen as preserved native read-only")
        }
        XCTAssertTrue(open2.isPreservedReadOnly)
        XCTAssertNil(preservedSession.input)
        XCTAssertFalse(relaunched.canStartEditing)
        let beforeDraft = env.model.saveCoordinator.storedDraft(documentID: env.documentID)
        relaunched.saveCoordinator.enqueue(documentID: env.documentID, title: "Clobber", markdown: "Classic clobber")
        XCTAssertEqual(env.model.saveCoordinator.storedDraft(documentID: env.documentID), beforeDraft)
        open2.close()

        // 4. Re-enable switch: the exact same replica resumes authoring.
        env.defaults.set(true, forKey: NativeEditorPreference.key)
        let relaunched2 = env.relaunch()
        let open3 = NativeEditorOpen(preference: { NativeEditorPreference.isEnabled(env.defaults) })
        defer { open3.close() }
        await open3.open(viewModel: relaunched2, isOffline: false, canUpdate: true)
        guard case .native(let resumed) = open3.route else { return XCTFail("expected resumed native session") }
        XCTAssertNotNil(resumed.input)
        XCTAssertFalse(open3.isPreservedReadOnly)
        XCTAssertTrue(resumed.surface.blocks[0].runs.map(\.text).joined().hasPrefix("Rich "))

        // 5. Untouched document opens in ClassicEditorView when switch is OFF.
        env.defaults.set(false, forKey: NativeEditorPreference.key)
        let untouched = makeAcceptanceEnvironment(defaults: env.defaults, directory: env.directory)
        let openUntouched = NativeEditorOpen(preference: { NativeEditorPreference.isEnabled(env.defaults) })
        defer { openUntouched.close() }
        await openUntouched.open(viewModel: untouched.model, isOffline: false, canUpdate: true)
        guard case .classic = openUntouched.route else {
            return XCTFail("untouched document with switch OFF must open classic")
        }
    }

    // MARK: - 3. Classic Editor & BlockNoteYjs.applyEdit Non-Regression

    func testClassicEditorAndBlockNoteApplyEditNonRegression() async throws {
        let env = makeAcceptanceEnvironment()
        defer { env.clean() }
        XCTAssertFalse(NativeEditorPreference.isEnabled(env.defaults), "default preference must remain OFF")

        // Build a rich YDoc baseline with callout + paragraph + auxiliary root.
        let doc = YDoc(clientID: 12, gc: true)
        defer { doc.destroy() }
        let baselineBlocks = [
            BlockNoteBlock(
                node: "paragraph", props: Self.paragraphProps, runs: [InlineRun("Classic line")], id: "cl-1"),
            BlockNoteBlock(
                node: "callout", props: [("backgroundColor", .string("default")), ("emoji", .string("💡"))],
                runs: [InlineRun("Keep callout")], id: "cl-2"),
        ]
        try doc.applyUpdate(YUpdateDecoder.decode(BlockNoteYjs.encode(baselineBlocks, clientID: 12)))
        try doc.transact { tx in
            let aux = doc.get("auxClassic")
            try YWrite.mapSet(tx, on: aux, key: "keep", .any([.string("preserved")]))
        }
        let oldProjected = YBlockProjection.project(doc).blocks.map { block in
            BlockNoteBlock(
                node: block.node, props: block.props.map { ($0.key, $0.value) }, runs: block.runs, id: block.id)
        }
        var newBlocks = oldProjected
        newBlocks[0].runs = [InlineRun("Classic edited line")]
        let update = try BlockNoteWrite.applyEdit(old: oldProjected, new: newBlocks, to: doc)
        XCTAssertFalse(update.isEmpty)
        let afterProjected = YBlockProjection.project(doc)
        XCTAssertEqual(afterProjected.blocks[0].runs.map(\.text).joined(), "Classic edited line")
        XCTAssertEqual(afterProjected.blocks[1].node, "callout")
        XCTAssertEqual(doc.get("auxClassic").map["keep"]?.content, .any([.string("preserved")]))

        // Classic EditorViewModel load + edit + save + checklist filter.
        let server = AcceptanceServerStub(owner: owner, state: Data([0, 0]))
        server.serverContent = "- [ ] Todo one\n- [x] Done two"
        server.install()
        let open = NativeEditorOpen(preference: { NativeEditorPreference.isEnabled(env.defaults) })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
        guard case .classic = open.route else { return XCTFail("must open classic with switch OFF") }
        await env.model.load()
        XCTAssertEqual(env.model.blocks.count, 2)
        env.model.setHidesCompletedChecklistItems(true)
        XCTAssertTrue(env.model.hidesCompletedChecklistItems)
        env.model.startEditing()
        XCTAssertTrue(env.model.isEditing)
        env.model.updateTitle("Classic Edited")
        env.model.saveNow()
        await waitUntil { server.titles.contains("Classic Edited") }
    }

    // MARK: - 4. New Document, Subpage & Offline Local-Create Migration

    func testNewDocumentSubpageAndOfflineLocalCreateMigration() async throws {
        let env = makeAcceptanceEnvironment(autosaveInterval: .milliseconds(50))
        defer { env.clean() }
        env.defaults.set(true, forKey: NativeEditorPreference.key)

        // Part A: Online new document entry intent + addSubpage + title-only & title+body saves.
        let server = AcceptanceServerStub(owner: owner, state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: 1))
        server.install()
        let entryIntent = NewDocumentEntryIntent()
        let model = EditorViewModel(
            client: env.model.client, documentID: env.documentID, title: "Untitled",
            saveCoordinator: env.model.saveCoordinator, entryIntent: entryIntent,
            signedInUser: SignedInUserStore(userDefaults: env.defaults),
            contentCache: DocumentContentCacheStore(directory: env.directory),
            childrenCache: DocumentChildrenCacheStore(userDefaults: env.defaults),
            listCache: DocumentCacheStore(userDefaults: env.defaults),
            autosaveInterval: .milliseconds(50),
            availability: OnlineAvailability(userDefaults: env.defaults),
            nativeEditorEnabled: { true })
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: model, isOffline: false, canUpdate: true)
        guard case .native(let session) = open.route else { return XCTFail("expected native session") }
        XCTAssertTrue(model.consumeNativeNewDocumentEntryIfNeeded(canEdit: true))
        XCTAssertTrue(model.consumeNativeInitialTitleFocus(isEditing: true, canEdit: true))
        XCTAssertFalse(
            model.consumeNativeInitialTitleFocus(isEditing: true, canEdit: true),
            "initial title focus must consume once")
        XCTAssertFalse(entryIntent.consume(), "entryIntent must consume once")
        open.updateTitle("Online New Doc", viewModel: model)
        await waitUntil { server.titles.contains("Online New Doc") }
        XCTAssertTrue(server.patchedUpdates.isEmpty, "title-only save must not emit empty Yjs PATCH")

        session.setEditing(true)
        session.textView.selectedRange = NSRange(location: 0, length: 0)
        session.input?.textViewDidChangeSelection(session.textView)
        session.textView.insertText("Body ")
        _ = await session.settle()
        open.updateTitle("Online New Doc 2", viewModel: model)
        open.flushPendingSave()
        await waitUntil { !server.patchedUpdates.isEmpty && server.titles.contains("Online New Doc 2") }

        await model.loadChildren()
        let addedChild = await model.addSubpage()
        XCTAssertNotNil(addedChild)
        XCTAssertEqual(model.mergedSubpages?.count, 1)
        open.close()

        // Part B: Offline createLocalDocument (root + child + queued attachment) -> atomic online migration.
        server.isOffline = true
        let coordinator = env.model.saveCoordinator
        let localRoot = coordinator.createLocalDocument(title: "", parentID: nil, ownerUserID: owner)
        let localChild = coordinator.createLocalDocument(
            title: "Child offline", parentID: localRoot.id, ownerUserID: owner)
        let localScope = ReplicaScope(
            serverOrigin: env.model.client.serverOrigin, ownerUserID: owner, org: "docs", documentID: localRoot.id)
        let localModel = EditorViewModel(
            client: env.model.client, documentID: localRoot.id, title: localRoot.title ?? "",
            saveCoordinator: coordinator,
            signedInUser: SignedInUserStore(userDefaults: env.defaults),
            contentCache: DocumentContentCacheStore(directory: env.directory),
            childrenCache: DocumentChildrenCacheStore(userDefaults: env.defaults),
            listCache: DocumentCacheStore(userDefaults: env.defaults),
            autosaveInterval: .milliseconds(50),
            availability: OnlineAvailability(userDefaults: env.defaults),
            nativeEditorEnabled: { true })

        let offlineOpen = NativeEditorOpen(preference: { true })
        defer { offlineOpen.close() }
        await offlineOpen.open(viewModel: localModel, isOffline: true, canUpdate: true)
        guard case .native(let localSession) = offlineOpen.route else {
            return XCTFail("local-created doc must open natively offline")
        }
        localSession.setEditing(true)
        localSession.textView.selectedRange = NSRange(location: 0, length: 0)
        localSession.input?.textViewDidChangeSelection(localSession.textView)
        localSession.textView.insertText("Offline Root Body ")
        _ = await localSession.settle()
        offlineOpen.updateTitle("Offline Root Renamed", viewModel: localModel)

        // Stage a native pending attachment tied to an image block in the local replica.
        var insertedIDs: [String] = []
        XCTAssertTrue(
            localSession.input?.insertMediaBatch(
                nodes: ["image"], at: localSession.surface.blocks[0].id, placement: .after,
                onApplied: { insertedIDs = $0 }) == true)
        _ = await localSession.settle()
        let imageBlockID = try XCTUnwrap(insertedIDs.first)
        let pngData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let attID = coordinator.queueNativeAttachment(
            scope: localScope,
            target: NativeMediaTarget(
                org: "docs",
                blockID: imageBlockID,
                slot: MediaBlock.Slot(node: "image", url: ""),
                fileName: "offline.png",
                contentType: "image/png"),
            data: pngData)
        XCTAssertNotNil(attID)
        offlineOpen.flushPendingSave()
        offlineOpen.close()

        // Verify zero requests used localRoot.id while offline.
        let localIDPath = localRoot.id.uuidString.lowercased()
        XCTAssertEqual(
            server.log.count(ofMethod: "GET", urlContaining: localIDPath)
                + server.log.count(ofMethod: "POST", urlContaining: localIDPath)
                + server.log.count(ofMethod: "PATCH", urlContaining: localIDPath),
            0,
            "localID must never be sent to HTTP routes")

        // Come online and migrate.
        server.isOffline = false
        let migratedRootID = UUID()
        let migratedChildID = UUID()
        server.createdIDsByTitle = ["Offline Root Renamed": migratedRootID, "Child offline": migratedChildID]
        await coordinator.syncPendingDrafts()

        await waitUntil {
            env.creates.create(for: localRoot.id) == nil
                && env.creates.create(for: localChild.id) == nil
        }
        let serverScope = ReplicaScope(
            serverOrigin: env.model.client.serverOrigin, ownerUserID: owner, org: "docs", documentID: migratedRootID)
        XCTAssertNil(
            try env.replicaStore.manifest(for: localScope), "localScope replica must be removed after migration")
        XCTAssertNil(coordinator.storedDraft(documentID: localRoot.id), "localID draft must be removed")
        XCTAssertEqual(coordinator.nativeOwnership(documentID: migratedRootID), .owned(serverScope))
        await waitUntil { server.uploadedAttachmentDocIDs.contains(migratedRootID) }
        XCTAssertTrue(
            server.uploadedAttachmentDocIDs.contains(migratedRootID),
            "attachment must upload under migrated serverID")
    }

    // MARK: - 5. Stale Cached Responses & Offline Docs-6 Guard

    func testStaleFormattedContentAndOfflineDocs6Guard() async throws {
        let offlineConnectivity = ConnectivityMonitor(
            monitoring: NetworkPathMonitoring { onChange in
                onChange(false)
                return {}
            })
        let env = makeAcceptanceEnvironment(connectivity: offlineConnectivity)
        defer { env.clean() }
        env.defaults.set(true, forKey: NativeEditorPreference.key)
        await waitUntil { env.model.availability.isOffline }

        env.model.saveCoordinator.noteServerConfig(ServerConfig(releaseVersion: "6.0.0", collaborationWsUrl: nil))
        DocumentContentCacheStore(directory: env.directory).save(
            CachedDocumentContent(
                documentID: env.documentID, title: "Docs 6 Cached", markdown: "Read only copy",
                syncedAt: Date(), serverUpdatedAt: Date()))
        await env.model.load()
        XCTAssertTrue(env.model.isNativeBaselineRequiredOffline)
        XCTAssertTrue(env.model.isNativeLimitedOfflineRead)
        XCTAssertFalse(env.model.canStartEditing)

        // Active native session resists late formatted-content clobber.
        let onlineEnv = makeAcceptanceEnvironment()
        defer { onlineEnv.clean() }
        onlineEnv.defaults.set(true, forKey: NativeEditorPreference.key)
        let server = AcceptanceServerStub(owner: owner, state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: 1))
        server.serverContent = "Stale server export"
        server.install()
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: onlineEnv.model, isOffline: false, canUpdate: true)
        guard case .native = open.route else { return XCTFail("expected native session") }
        open.updateTitle("Fresh Native Title", viewModel: onlineEnv.model)
        onlineEnv.model.rawMarkdown = "Initial native shadow"
        let formattedCountBefore = server.log.count(ofMethod: "GET", urlContaining: "formatted-content")
        await onlineEnv.model.load()
        await onlineEnv.model.refresh()
        XCTAssertTrue(onlineEnv.model.isNativeRouteActive)
        XCTAssertEqual(onlineEnv.model.title, "Fresh Native Title")
        XCTAssertEqual(onlineEnv.model.rawMarkdown, "Initial native shadow")
        XCTAssertEqual(
            server.log.count(ofMethod: "GET", urlContaining: "formatted-content"), formattedCountBefore)
        XCTAssertFalse(onlineEnv.model.isEditing)
    }

    // MARK: - 6. Reading <-> Editing Mode Handoff & All-Hidden Checklist Settling

    func testReadingEditingModeHandoffAndAllHiddenChecklistSettling() async throws {
        let blocks = [
            BlockNoteBlock(
                node: "checkListItem", props: Self.paragraphProps + [("checked", .bool(false))],
                runs: [InlineRun("Task A")], id: "chk-a",
                children: [
                    BlockNoteBlock(
                        node: "paragraph", props: Self.paragraphProps, runs: [InlineRun("Nested under Task A")],
                        id: "chk-a-child")
                ]),
            BlockNoteBlock(
                node: "checkListItem", props: Self.paragraphProps + [("checked", .bool(true))],
                runs: [InlineRun("Task B")], id: "chk-b"),
        ]
        let state = BlockNoteYjs.encode(blocks, clientID: 1)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = ReplicaStore(directory: tempDir)
        let scope = ReplicaScope(
            serverOrigin: "https://example.test", ownerUserID: owner, org: "docs", documentID: UUID())
        _ = try store.create(for: scope, checkpoint: state)
        let maybeSession = try await NativeEditorSession.restore(store: store, scope: scope, editable: true)
        let session = try XCTUnwrap(maybeSession)
        defer { Task { await session.close().value } }

        // Reading mode starts non-editable.
        session.setEditing(false)
        XCTAssertFalse(session.textView.isEditable)

        let revisionBeforeHide = session.revision
        let appliedHide = session.setChecklistPresentation(hidesCompleted: true, settlingIDs: [])
        XCTAssertTrue(appliedHide)
        XCTAssertEqual(session.revision, revisionBeforeHide, "Hide completed must not write Yjs")

        // Tick the last unchecked item ("chk-a"): settlingIDs keeps it visible during 450ms settle,
        // then finalizes into the all-hidden state once settled.
        XCTAssertTrue(session.input?.toggleCheckbox(blockID: "chk-a") == true, "expected checkbox toggle to apply")
        _ = await session.settle()
        _ = session.setChecklistPresentation(hidesCompleted: true, settlingIDs: ["chk-a"])
        XCTAssertFalse(session.surface.isHidden(blockID: "chk-a"), "settling item stays visible for 450ms")

        try await Task.sleep(for: .milliseconds(470))
        _ = session.setChecklistPresentation(hidesCompleted: true, settlingIDs: [])
        XCTAssertTrue(session.surface.isHidden(blockID: "chk-a"))
        XCTAssertTrue(session.surface.isHidden(blockID: "chk-a-child"))
        XCTAssertTrue(session.surface.isHidden(blockID: "chk-b"))

        // Show completed reveals all items.
        _ = session.setChecklistPresentation(hidesCompleted: false, settlingIDs: [])
        XCTAssertFalse(session.surface.isHidden(blockID: "chk-a"))
        XCTAssertFalse(session.surface.isHidden(blockID: "chk-b"))

        // Editing reveals all items; returning to Reading re-applies Hide completed.
        _ = session.setChecklistPresentation(hidesCompleted: true, settlingIDs: [])
        session.setEditing(true)
        XCTAssertTrue(session.textView.isEditable)
        _ = session.setChecklistPresentation(hidesCompleted: false, settlingIDs: [])
        XCTAssertFalse(session.surface.isHidden(blockID: "chk-a"))
        session.setEditing(false)
        XCTAssertFalse(session.textView.isEditable)
        _ = session.setChecklistPresentation(hidesCompleted: true, settlingIDs: [])
        XCTAssertTrue(session.surface.isHidden(blockID: "chk-a"))
        XCTAssertTrue(session.surface.isHidden(blockID: "chk-b"))
    }

    // MARK: - 7. 10-Cycle Memory Reclamation & Clean-Replica Sign-Out

    func testTenCycleMemoryReclamationAndCleanReplicaSignOut() async throws {
        NativeEditorDiagnosticsStore.shared.reset()
        NativeEditorDiagnosticsStore.shared.setForcedCollection(true)
        defer {
            NativeEditorDiagnosticsStore.shared.setForcedCollection(nil)
            NativeEditorDiagnosticsStore.shared.reset()
        }

        let s2State = Self.makeS2MixedFixture(paragraphCount: 5_000, attachmentStride: 25)
        weak var weakSession: NativeEditorSession?
        weak var weakView: NativeTextView?
        weak var weakInput: NativeInputCoordinator?
        weak var weakReplica: DocumentReplicaSession?

        for cycle in 0..<10 {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Cycle-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = ReplicaStore(directory: directory)
            let scope = ReplicaScope(
                serverOrigin: "https://docs.example", ownerUserID: owner, org: "docs", documentID: UUID())
            _ = try store.create(for: scope, checkpoint: s2State)
            let maybeSession = try await NativeEditorSession.restore(store: store, scope: scope, editable: true)
            let session = try XCTUnwrap(maybeSession)
            weakSession = session
            weakView = session.textView
            weakInput = session.input
            weakReplica = session.replica

            session.setEditing(true)
            session.textView.selectedRange = NSRange(location: 0, length: 0)
            session.input?.textViewDidChangeSelection(session.textView)
            session.textView.insertText("Cycle \(cycle) ")
            _ = await session.settle()
            let maybeTbl = await session.openTable("s2-tbl-1")
            let tbl = try XCTUnwrap(maybeTbl, "expected table surface to open")
            await tbl.close().value
            let maybeCols = await session.openColumn(group: "s2-cols-2", column: "s2-col-2-0")
            let cols = try XCTUnwrap(maybeCols, "expected column surface to open")
            await cols.close().value
            _ = await session.run { session.input?.undo() ?? false }
            _ = await session.run { session.input?.redo() ?? false }
            await session.close().value
        }

        // Allow main-runloop weak-reference autorelease pools to drain.
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(weakSession, "closed NativeEditorSession must deallocate")
        XCTAssertNil(weakView, "closed NativeTextView must deallocate")
        XCTAssertNil(weakInput, "closed NativeInputCoordinator must deallocate")
        XCTAssertNil(weakReplica, "closed DocumentReplicaSession must deallocate")

        let snapshot = NativeEditorDiagnosticsStore.shared.snapshot()
        XCTAssertLessThanOrEqual(snapshot.sessions.count, NativeEditorDiagnosticsStore.defaultMaxSessions)
        XCTAssertLessThanOrEqual(snapshot.recentSamples.count, NativeEditorDiagnosticsStore.defaultMaxSamples)
        XCTAssertEqual(snapshot.activeSessionCount, 0)

        // Sign-out clean-replica purge retains dirty outbox, provisional-recovery, conflicted & corrupt replicas.
        let env = makeAcceptanceEnvironment()
        defer { env.clean() }
        let origin = env.model.client.serverOrigin
        let cleanID = UUID()
        let dirtyID = UUID()
        let provisionalID = UUID()
        let conflictedID = UUID()
        let corruptID = UUID()

        func seed(_ id: UUID) throws -> ReplicaScope {
            let scope = ReplicaScope(serverOrigin: origin, ownerUserID: owner, org: "docs", documentID: id)
            _ = try env.replicaStore.create(for: scope, checkpoint: Data([0, 0]))
            _ = env.ownership.mark(scope)
            return scope
        }
        let cleanScope = try seed(cleanID)
        let dirtyScope = try seed(dirtyID)
        _ = try env.replicaStore.append(Data([1]), for: dirtyScope, commandID: UUID(), baseRevision: 0, origin: .local)
        let provisionalScope = try seed(provisionalID)
        try env.replicaStore.writeProvisionalRecoveries(
            [ProvisionalRecovery(commandID: UUID(), blockID: "b1", text: "Keep me", state: .composing)],
            for: provisionalScope)
        let conflictedScope = try seed(conflictedID)
        env.model.saveCoordinator.recordConflict(documentID: conflictedID, serverUpdatedAt: Date())
        let corruptScope = try seed(corruptID)
        let corruptFolder = env.replicaDirectory.appendingPathComponent(
            try corruptScope.directoryName(), isDirectory: true)
        try Data("bad".utf8).write(to: corruptFolder.appendingPathComponent("manifest.json"), options: .atomic)

        env.model.saveCoordinator.purgeCleanNativeReplicasOnSignOut(ownerUserID: owner)
        NativeEditorDiagnosticsStore.shared.reset()

        XCTAssertNil(try env.replicaStore.manifest(for: cleanScope), "clean replica must be purged on sign-out")
        XCTAssertEqual(env.ownership.owner(documentID: cleanID, serverOrigin: origin), .none)
        XCTAssertNotNil(try env.replicaStore.manifest(for: dirtyScope), "dirty outbox replica must remain")
        XCTAssertNotNil(try env.replicaStore.manifest(for: provisionalScope), "provisional replica must remain")
        XCTAssertNotNil(try env.replicaStore.manifest(for: conflictedScope), "conflicted replica must remain")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: corruptFolder.path), "unreadable replica folder must remain")
        XCTAssertTrue(NativeEditorDiagnosticsStore.shared.snapshot().sessions.isEmpty)
    }

    // MARK: - 8. Bounded Work Counters on 5,000-Block & S2 5,000/200 Fixtures

    func testBoundedWorkCountersOnLargeProseAndS2MixedFixtures() async throws {
        NativeEditorDiagnosticsStore.shared.reset()
        NativeEditorDiagnosticsStore.shared.setForcedCollection(true)
        defer {
            NativeEditorDiagnosticsStore.shared.setForcedCollection(nil)
            NativeEditorDiagnosticsStore.shared.reset()
        }

        // 1) 5,000-block prose fixture: single character insert -> 1 text patch, 0 full rebuilds.
        let proseBlocks = (0..<5_000).map { index in
            BlockNoteBlock(
                node: "paragraph", props: Self.paragraphProps,
                runs: [InlineRun("Prose block \(index)")], id: "prose-\(index)")
        }
        let proseSession = try await NativeEditorSession.seed(
            state: BlockNoteYjs.encode(proseBlocks, clientID: 1), clientID: 2)
        defer { Task { await proseSession.close().value } }
        proseSession.enableTyping(persist: { _, _ in })
        proseSession.setEditing(true)
        let beforeProse =
            NativeEditorDiagnosticsStore.shared.sessionSummary(for: proseSession.sessionSeq)?.counters
            ?? SurfaceWorkCounters()
        proseSession.textView.selectedRange = NSRange(location: 0, length: 0)
        proseSession.input?.textViewDidChangeSelection(proseSession.textView)
        proseSession.textView.insertText("X")
        let settledProse = await proseSession.settle()
        XCTAssertTrue(settledProse)
        let afterProse = try XCTUnwrap(
            NativeEditorDiagnosticsStore.shared.sessionSummary(for: proseSession.sessionSeq)?.counters)
        XCTAssertEqual(afterProse.textPatchCount - beforeProse.textPatchCount, 1)
        XCTAssertEqual(afterProse.fullStorageRebuildCount - beforeProse.fullStorageRebuildCount, 0)

        // 2) S2 5,000/200 mixed fixture + checkbox: single insert + toggle -> bounded patches & realised views <= 32.
        let s2State = Self.makeS2MixedFixture(paragraphCount: 5_000, attachmentStride: 25, includeChecklist: true)
        let s2Session = try await NativeEditorSession.seed(state: s2State, clientID: 3)
        defer { Task { await s2Session.close().value } }
        s2Session.enableTyping(persist: { _, _ in })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        s2Session.textView.frame = window.bounds
        window.addSubview(s2Session.textView)
        window.makeKeyAndVisible()
        s2Session.textView.layoutIfNeeded()

        s2Session.setEditing(true)
        let beforeS2 =
            NativeEditorDiagnosticsStore.shared.sessionSummary(for: s2Session.sessionSeq)?.counters
            ?? SurfaceWorkCounters()
        s2Session.textView.selectedRange = NSRange(location: 0, length: 0)
        s2Session.input?.textViewDidChangeSelection(s2Session.textView)
        s2Session.textView.insertText("Y")
        _ = await s2Session.settle()
        let midS2 = try XCTUnwrap(
            NativeEditorDiagnosticsStore.shared.sessionSummary(for: s2Session.sessionSeq)?.counters)
        XCTAssertEqual(midS2.textPatchCount - beforeS2.textPatchCount, 1)
        XCTAssertEqual(midS2.fullStorageRebuildCount - beforeS2.fullStorageRebuildCount, 0)

        XCTAssertTrue(s2Session.input?.toggleCheckbox(blockID: "s2-check-0") == true)
        _ = await s2Session.settle()
        s2Session.textView.layoutIfNeeded()
        let afterS2 = try XCTUnwrap(
            NativeEditorDiagnosticsStore.shared.sessionSummary(for: s2Session.sessionSeq)?.counters)
        XCTAssertEqual(afterS2.blockPatchCount - midS2.blockPatchCount, 1)
        XCTAssertEqual(afterS2.fullStorageRebuildCount - midS2.fullStorageRebuildCount, 0)
        XCTAssertGreaterThan(afterS2.realisedAttachmentViewCount, 0)
        XCTAssertLessThanOrEqual(afterS2.realisedAttachmentViewCount, 32)
        XCTAssertGreaterThan(afterS2.realisedControlViewCount, 0)
        XCTAssertLessThanOrEqual(afterS2.realisedControlViewCount, 32)
        window.isHidden = true
    }

    // MARK: - 9. NativeEditorDiagnosticsStore Unit Tests (Bounds, Percentiles, Zero-PII, Off-Mode)

    func testDiagnosticsStoreBoundedRingPercentilesZeroPIIAndOffModeEarlyReturn() throws {
        // Off-mode: early return before any work.
        let offStore = NativeEditorDiagnosticsStore(maxSamples: 8, maxSessions: 4, forcedCollection: false)
        XCTAssertFalse(offStore.isCollecting)
        let offSeq = offStore.beginSession()
        XCTAssertEqual(offSeq, 0)
        XCTAssertNil(offStore.beginInterval(.projection))
        offStore.recordDuration(.storageApply, durationMs: 12.5, sessionSeq: 1, byteCount: 64, itemCount: 1)
        offStore.recordWorkload(ReplicaWorkloadMetrics(rawBytes: 128, blockCount: 10), sessionSeq: 1)
        offStore.mutateCounters(sessionSeq: 1) { $0.textPatchCount += 1 }
        offStore.sampleMemory(sessionSeq: 1, steady: true)
        offStore.endSession(1)
        let offSnapshot = offStore.snapshot()
        XCTAssertEqual(offSnapshot.totalSampleCount, 0)
        XCTAssertTrue(offSnapshot.sessions.isEmpty)
        XCTAssertEqual(offSnapshot.activeSessionCount, 0)

        // Mailbox off-mode: posts do not collect wait timestamps.
        NativeEditorDiagnosticsStore.shared.setForcedCollection(false)
        defer { NativeEditorDiagnosticsStore.shared.setForcedCollection(nil) }
        let mailbox = ReplicaCommandMailbox()
        XCTAssertTrue(mailbox.post(.drain(surfaceID: UUID(), token: UUID())))
        XCTAssertNil(mailbox.tookMeasuringWaitMs())

        // On-mode: bounded ring + percentiles + zero PII.
        let store = NativeEditorDiagnosticsStore(maxSamples: 8, maxSessions: 3, forcedCollection: true)
        for index in 0..<5 {
            let seq = store.beginSession()
            XCTAssertGreaterThan(seq, 0)
            store.recordWorkload(
                ReplicaWorkloadMetrics(rawBytes: 100 + index, blockCount: 20 + index), sessionSeq: seq)
            store.endSession(seq)
        }
        let seq = store.beginSession()
        for value in [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0] {
            store.recordDuration(.inputToDisplay, durationMs: value, sessionSeq: seq, byteCount: 16, itemCount: 1)
        }
        let snap = store.snapshot()
        XCTAssertEqual(snap.sessions.count, 3, "sessions ring bounded to maxSessions")
        XCTAssertEqual(snap.recentSamples.count, 8, "samples ring bounded to maxSamples")
        let dist = try XCTUnwrap(snap.stageDistributions[NativeEditorStage.inputToDisplay.rawValue])
        XCTAssertEqual(dist.count, 8)
        XCTAssertEqual(dist.p50Ms, 6.0, accuracy: 0.001)
        XCTAssertEqual(dist.p95Ms, 10.0, accuracy: 0.001)
        XCTAssertEqual(dist.maxMs, 10.0, accuracy: 0.001)

        let json = store.sanitizedJSONString()
        XCTAssertTrue(json.contains("\"schemaVersion\" : 1"))
        XCTAssertFalse(json.contains("https://"))
        XCTAssertFalse(json.contains("title"))
        XCTAssertFalse(json.contains("markdown"))

        // Separate opt-in preference: native editor alone does not enable diagnostics collection.
        let prefSuite = "NativeEditorDiagnosticsPref.\(UUID())"
        let prefDefaults = UserDefaults(suiteName: prefSuite)!
        defer { prefDefaults.removePersistentDomain(forName: prefSuite) }
        XCTAssertFalse(NativeEditorDiagnosticsPreference.isEnabled(prefDefaults))
        let prefStore = NativeEditorDiagnosticsStore(maxSamples: 8, maxSessions: 4, userDefaults: prefDefaults)
        XCTAssertFalse(prefStore.isCollecting)
        prefDefaults.set(true, forKey: NativeEditorPreference.key)
        prefStore.refreshCollectionPreference(prefDefaults)
        XCTAssertFalse(prefStore.isCollecting, "native editor switch alone must not start collection")
        prefDefaults.set(true, forKey: NativeEditorDiagnosticsPreference.key)
        prefStore.refreshCollectionPreference(prefDefaults)
        XCTAssertTrue(prefStore.isCollecting)
        prefDefaults.set(false, forKey: NativeEditorPreference.key)
        prefStore.refreshCollectionPreference(prefDefaults)
        XCTAssertFalse(prefStore.isCollecting, "disabling native editor must disable collection")

        // minSessionSeq floor on reset() ignores pre-reset async teardown writes.
        let floorStore = NativeEditorDiagnosticsStore(maxSamples: 8, maxSessions: 4, forcedCollection: true)
        let staleSeq = floorStore.beginSession()
        floorStore.reset()
        floorStore.recordWorkload(ReplicaWorkloadMetrics(rawBytes: 42, blockCount: 1), sessionSeq: staleSeq)
        floorStore.mutateCounters(sessionSeq: staleSeq) { $0.textPatchCount += 1 }
        floorStore.recordDuration(.storageApply, durationMs: 5.0, sessionSeq: staleSeq)
        floorStore.sampleMemory(sessionSeq: staleSeq, steady: true)
        floorStore.endSession(staleSeq)
        let postResetSnap = floorStore.snapshot()
        XCTAssertTrue(postResetSnap.sessions.isEmpty)
        XCTAssertEqual(postResetSnap.totalSampleCount, 0)
        XCTAssertEqual(postResetSnap.activeSessionCount, 0)

        // Turning collection off mid-session still clears activeSessions on endSession and closes interval tokens.
        let toggleSeq = floorStore.beginSession()
        let openToken = floorStore.beginInterval(.remoteMerge)
        floorStore.setForcedCollection(false)
        floorStore.endInterval(.remoteMerge, token: openToken, sessionSeq: toggleSeq)
        floorStore.endSession(toggleSeq)
        XCTAssertEqual(floorStore.snapshot().activeSessionCount, 0)
        XCTAssertEqual(floorStore.snapshot().totalSampleCount, 0)
        XCTAssertEqual(floorStore.sessionSummary(for: toggleSeq)?.isOpen, false)

        // activeSessions is evicted alongside sessions past maxSessions.
        let capStore = NativeEditorDiagnosticsStore(maxSamples: 8, maxSessions: 2, forcedCollection: true)
        _ = capStore.beginSession()
        _ = capStore.beginSession()
        _ = capStore.beginSession()
        let capSnap = capStore.snapshot()
        XCTAssertEqual(capSnap.sessions.count, 2)
        XCTAssertEqual(capSnap.activeSessionCount, 2)

        // Mailbox FIFO wait accounting preserves order across on -> off -> on toggles.
        let fifoMailbox = ReplicaCommandMailbox()
        NativeEditorDiagnosticsStore.shared.setForcedCollection(true)
        XCTAssertTrue(fifoMailbox.post(.drain(surfaceID: UUID(), token: UUID())))
        NativeEditorDiagnosticsStore.shared.setForcedCollection(false)
        XCTAssertTrue(fifoMailbox.post(.drain(surfaceID: UUID(), token: UUID())))
        NativeEditorDiagnosticsStore.shared.setForcedCollection(true)
        XCTAssertTrue(fifoMailbox.post(.drain(surfaceID: UUID(), token: UUID())))
        XCTAssertNotNil(fifoMailbox.tookMeasuringWaitMs(), "tracked head A must report wait")
        XCTAssertNil(fifoMailbox.tookMeasuringWaitMs(), "untracked middle B must not consume A or C")
        XCTAssertNotNil(fifoMailbox.tookMeasuringWaitMs(), "tracked tail C must report wait")
        NativeEditorDiagnosticsStore.shared.setForcedCollection(nil)
    }

    func testTimeToEditRequiresFirstResponderReady() async throws {
        NativeEditorDiagnosticsStore.shared.reset()
        NativeEditorDiagnosticsStore.shared.setForcedCollection(true)
        defer {
            NativeEditorDiagnosticsStore.shared.setForcedCollection(nil)
            NativeEditorDiagnosticsStore.shared.reset()
        }

        let session = try await NativeEditorSession.seed(
            state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: 1), clientID: 2)
        defer { Task { await session.close().value } }
        session.enableTyping(persist: { _, _ in })

        // setEditing(true) without becoming first responder must NOT record timeToEdit.
        session.setEditing(true)
        try await Task.sleep(for: .milliseconds(30))
        let beforeFocus = NativeEditorDiagnosticsStore.shared.sessionSummary(for: session.sessionSeq)
        XCTAssertNil(beforeFocus?.stages[NativeEditorStage.timeToEdit.rawValue])

        // Once the textView actually becomes first responder (e.g. inside a window), timeToEdit records.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        session.textView.frame = window.bounds
        window.addSubview(session.textView)
        window.makeKeyAndVisible()
        XCTAssertTrue(session.textView.becomeFirstResponder())
        let afterFocus = NativeEditorDiagnosticsStore.shared.sessionSummary(for: session.sessionSeq)
        XCTAssertEqual(afterFocus?.stages[NativeEditorStage.timeToEdit.rawValue]?.count, 1)
        _ = session.textView.resignFirstResponder()
        window.isHidden = true
    }

    // MARK: - Helpers

    private func assertStorageMatchesProjection(
        _ session: NativeEditorSession, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let maybeBlocks = await session.replicaDoc { NativeBlockProjection.project($0).blocks.map(BlockSnapshot.init) }
        let blocks = try XCTUnwrap(maybeBlocks, file: file, line: line)
        XCTAssertEqual(session.surface.blocks, blocks, file: file, line: line)
        let fresh = AttributedDocumentProjection.attributedString(
            blocks: blocks, traits: session.surface.traits, labels: session.surface.labels)
        XCTAssertEqual(session.surface.storage.string, fresh.string, file: file, line: line)
    }

    private nonisolated static func containerItemIDs(in doc: YDoc, blockIDs: [String]) -> [String: YID] {
        var result: [String: YID] = [:]
        guard let root = doc.share[BlockNoteYjs.fragmentField],
            case .type(let group)? = YBlockProjection.children(of: root, includeFormats: false).first?.content
        else { return result }
        let wanted = Set(blockIDs)
        for item in YBlockProjection.children(of: group, includeFormats: false) {
            guard case .type(let type) = item.content,
                let id = BlockIndex.blockID(of: type),
                wanted.contains(id)
            else { continue }
            result[id] = item.id
        }
        return result
    }

    private static func makeWholeFamilyFixture() throws -> (Data, [String]) {
        let style: [(String, YAnyValue)] = [
            ("backgroundColor", .string("default")), ("textColor", .string("default")),
            ("textAlignment", .string("left")),
        ]
        let doc = YDoc(clientID: 1, gc: true)
        defer { doc.destroy() }
        let root = doc.get(BlockNoteYjs.fragmentField)
        try doc.transact { tx in
            func element(_ name: String, into parent: YType, after: YItem?, _ props: [(String, YAnyValue)]) throws
                -> (YItem?, YType)
            {
                let type = YType(typeRef: .xmlElement(nodeName: name))
                let item = try YWrite.insertAfter(tx, into: parent, after: after, [.type(type)])
                for (key, value) in props { try YWrite.mapSet(tx, on: type, key: key, .any([value])) }
                return (item, type)
            }
            func addTextBlock(
                into group: YType, after: YItem?, id: String, node: String, props: [(String, YAnyValue)], text: String
            ) throws -> YItem? {
                let (containerItem, container) = try element(
                    "blockContainer", into: group, after: after, [("id", .string(id))])
                let (_, content) = try element(node, into: container, after: nil, props)
                let xml = YType(typeRef: .xmlText)
                try YWrite.insertAfter(tx, into: content, after: nil, [.type(xml)])
                if !text.isEmpty { try xml.insert(0, text, nil) }
                return containerItem
            }

            let (_, rootGroup) = try element("blockGroup", into: root, after: nil, [])
            var cursor: YItem?

            // Paragraph with overlapping marks, colors, links, and inline objects.
            let (pItem, pContainer) = try element(
                "blockContainer", into: rootGroup, after: cursor, [("id", .string("wf-p1"))])
            cursor = pItem
            let (_, pNode) = try element("paragraph", into: pContainer, after: nil, style)
            let pXML = YType(typeRef: .xmlText)
            let pXMLItem = try YWrite.insertAfter(tx, into: pNode, after: nil, [.type(pXML)])
            try pXML.insert(0, "Alpha", ["bold": "{}", "textColor": NativeMark.colorValue("red")])
            try pXML.insert(5, " Beta", ["italic": "{}", "link": NativeMark.linkValue("https://docs.example")])

            // Append inline object siblings directly under the paragraph element after `pXML`.
            let interlink = YType(typeRef: .xmlElement(nodeName: NativeInlineObject.interlinkingLinkNodeName))
            let interlinkItem = try YWrite.insertAfter(tx, into: pNode, after: pXMLItem, [.type(interlink)])
            try YWrite.mapSet(
                tx, on: interlink, key: "docId", .any([.string("55555555-5555-4555-8555-555555555551")]))
            try YWrite.mapSet(tx, on: interlink, key: "blockId", .any([.string("")]))
            try YWrite.mapSet(tx, on: interlink, key: "disabled", .any([.bool(false)]))
            try YWrite.mapSet(tx, on: interlink, key: "trigger", .any([.string("/")]))
            try YWrite.mapSet(tx, on: interlink, key: "title", .any([.string("Roadmap")]))

            let mention = YType(typeRef: .xmlElement(nodeName: NativeInlineObject.userMentionNodeName))
            let mentionItem = try YWrite.insertAfter(tx, into: pNode, after: interlinkItem, [.type(mention)])
            try YWrite.mapSet(tx, on: mention, key: "userId", .any([.string("user-1")]))
            try YWrite.mapSet(tx, on: mention, key: "fullName", .any([.string("Ada")]))

            let inlineMath = YType(typeRef: .xmlElement(nodeName: NativeInlineObject.mathNodeName))
            _ = try YWrite.insertAfter(tx, into: pNode, after: mentionItem, [.type(inlineMath)])
            let inlineMathXML = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: inlineMath, after: nil, [.type(inlineMathXML)])
            try inlineMathXML.insert(0, "x^2", nil)

            // Headings H1-H3 + toggle heading.
            cursor = try addTextBlock(
                into: rootGroup, after: cursor, id: "wf-h1", node: "heading",
                props: style + [("level", .int(1)), ("isToggleable", .bool(false))], text: "Heading One")
            cursor = try addTextBlock(
                into: rootGroup, after: cursor, id: "wf-h2", node: "heading",
                props: style + [("level", .int(2)), ("isToggleable", .bool(true))], text: "Toggle Heading Two")
            cursor = try addTextBlock(
                into: rootGroup, after: cursor, id: "wf-h3", node: "heading",
                props: style + [("level", .int(3)), ("isToggleable", .bool(false))], text: "Heading Three")

            // Lists: bullet, numbered (start: 4), checklist, toggle with child.
            cursor = try addTextBlock(
                into: rootGroup, after: cursor, id: "wf-bullet", node: "bulletListItem", props: style, text: "Bullet")
            cursor = try addTextBlock(
                into: rootGroup, after: cursor, id: "wf-num", node: "numberedListItem",
                props: style + [("start", .int(4))], text: "Fourth")
            cursor = try addTextBlock(
                into: rootGroup, after: cursor, id: "wf-check-1", node: "checkListItem",
                props: style + [("checked", .bool(false))], text: "Todo item")
            let (togItem, togContainer) = try element(
                "blockContainer", into: rootGroup, after: cursor, [("id", .string("wf-toggle"))])
            cursor = togItem
            let (togNodeItem, togNode) = try element("toggleListItem", into: togContainer, after: nil, style)
            let togXML = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: togNode, after: nil, [.type(togXML)])
            try togXML.insert(0, "Toggle parent", nil)
            let (_, togGroup) = try element("blockGroup", into: togContainer, after: togNodeItem, [])
            _ = try addTextBlock(
                into: togGroup, after: nil, id: "wf-toggle-child", node: "paragraph", props: style,
                text: "Toggle child")

            // Quote, codeBlock, divider.
            cursor = try addTextBlock(
                into: rootGroup, after: cursor, id: "wf-quote", node: "quote",
                props: [("backgroundColor", .string("default")), ("textColor", .string("default"))], text: "Quote")
            cursor = try addTextBlock(
                into: rootGroup, after: cursor, id: "wf-code", node: "codeBlock",
                props: [("language", .string("swift"))], text: "let x = 1")
            let (divItem, divContainer) = try element(
                "blockContainer", into: rootGroup, after: cursor, [("id", .string("wf-divider"))])
            cursor = divItem
            _ = try element("divider", into: divContainer, after: nil, [])

            // 2x3 + merged-cell table.
            let (tblItem, tblContainer) = try element(
                "blockContainer", into: rootGroup, after: cursor, [("id", .string("wf-table"))])
            cursor = tblItem
            let (_, table) = try element("table", into: tblContainer, after: nil, [("textColor", .string("default"))])
            let cellProps: [(String, YAnyValue)] = [
                ("backgroundColor", .string("default")), ("colspan", .int(1)), ("rowspan", .int(1)),
                ("textAlignment", .string("left")), ("textColor", .string("default")),
            ]
            let (r0Item, r0) = try element("tableRow", into: table, after: nil, [])
            var lastC: YItem?
            for label in ["H1", "H2", "H3"] {
                let (cItem, cell) = try element("tableHeader", into: r0, after: lastC, cellProps)
                lastC = cItem
                let (_, tp) = try element("tableParagraph", into: cell, after: nil, [])
                let cXML = YType(typeRef: .xmlText)
                try YWrite.insertAfter(tx, into: tp, after: nil, [.type(cXML)])
                try cXML.insert(0, label, nil)
            }
            let (_, r1) = try element("tableRow", into: table, after: r0Item, [])
            let mergedProps: [(String, YAnyValue)] = [
                ("backgroundColor", .string("default")), ("colspan", .int(2)), ("rowspan", .int(1)),
                ("textAlignment", .string("left")), ("textColor", .string("default")),
            ]
            let (mcItem, mCell) = try element("tableCell", into: r1, after: nil, mergedProps)
            let (_, mTP) = try element("tableParagraph", into: mCell, after: nil, [])
            let mXML = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: mTP, after: nil, [.type(mXML)])
            try mXML.insert(0, "Merged", nil)
            let (_, rCell) = try element("tableCell", into: r1, after: mcItem, cellProps)
            let (_, rTP) = try element("tableParagraph", into: rCell, after: nil, [])
            let rXML = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: rTP, after: nil, [.type(rXML)])
            try rXML.insert(0, "C3", nil)

            // 2-column group (prose + nested table + image) and 3-column group.
            let (cols2Item, cols2) = try element(
                "columnList", into: rootGroup, after: cursor, [("id", .string("wf-cols-2"))])
            cursor = cols2Item
            let (col0Item, col0) = try element(
                "column", into: cols2, after: nil, [("id", .string("wf-col-0")), ("width", .int(1))])
            let col0P = try addTextBlock(
                into: col0, after: nil, id: "wf-col-p0", node: "paragraph", props: style, text: "Left col")
            let (ntItem, ntContainer) = try element(
                "blockContainer", into: col0, after: col0P, [("id", .string("wf-col-tbl"))])
            let (_, nTable) = try element("table", into: ntContainer, after: nil, [("textColor", .string("default"))])
            let (_, nRow) = try element("tableRow", into: nTable, after: nil, [])
            let (_, nCell) = try element("tableCell", into: nRow, after: nil, cellProps)
            let (_, nTP) = try element("tableParagraph", into: nCell, after: nil, [])
            let nXML = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: nTP, after: nil, [.type(nXML)])
            try nXML.insert(0, "Nested", nil)
            let (_, nImgContainer) = try element(
                "blockContainer", into: col0, after: ntItem, [("id", .string("wf-col-img"))])
            _ = try element(
                "image", into: nImgContainer, after: nil,
                [
                    ("textAlignment", .string("left")), ("backgroundColor", .string("default")),
                    ("name", .string("col.png")), ("url", .string("https://docs.example/col.png")),
                    ("caption", .string("")), ("showPreview", .bool(true)), ("previewWidth", .undefined),
                ])
            let (_, col1) = try element(
                "column", into: cols2, after: col0Item, [("id", .string("wf-col-1")), ("width", .int(1))])
            _ = try addTextBlock(
                into: col1, after: nil, id: "wf-col-p1", node: "paragraph", props: style, text: "Right col")

            let (cols3Item, cols3) = try element(
                "columnList", into: rootGroup, after: cursor, [("id", .string("wf-cols-3"))])
            cursor = cols3Item
            var last3: YItem?
            for idx in 0..<3 {
                let (cItem, c) = try element(
                    "column", into: cols3, after: last3, [("id", .string("wf-3c-\(idx)")), ("width", .int(1))])
                last3 = cItem
                _ = try addTextBlock(
                    into: c, after: nil, id: "wf-3c-p-\(idx)", node: "paragraph", props: style, text: "Col \(idx)")
            }

            // Media blocks: image, video, audio, file, pdf.
            for (id, node, name) in [
                ("wf-image", "image", "pic.png"),
                ("wf-video", "video", "clip.mp4"),
                ("wf-audio", "audio", "note.m4a"),
                ("wf-file", "file", "spec.txt"),
                ("wf-pdf", "pdf", "deck.pdf"),
            ] {
                let (mItem, mContainer) = try element(
                    "blockContainer", into: rootGroup, after: cursor, [("id", .string(id))])
                cursor = mItem
                let fields = (MediaBlock.schemas[node] ?? []).map { field in
                    if field.key == "name" { return ("name", YAnyValue.string(name)) }
                    if field.key == "url" { return ("url", YAnyValue.string("https://docs.example/\(name)")) }
                    return field
                }
                _ = try element(node, into: mContainer, after: nil, fields)
            }

            // mathBlock & diagram.
            cursor = try addTextBlock(
                into: rootGroup, after: cursor, id: "wf-math", node: "mathBlock", props: [], text: "e^{i\\pi}+1=0")
            cursor = try addTextBlock(
                into: rootGroup, after: cursor, id: "wf-diagram", node: "diagram",
                props: [("type", .string("mermaid"))], text: "graph TD; A-->B;")
        }
        return (
            try YStateEncoder.encodeStateAsUpdate(doc), ["wf-h1", "wf-quote", "wf-divider", "wf-pdf", "wf-diagram"]
        )
    }

    private static func makePreservedCompanionFixture() throws -> Data {
        let doc = YDoc(clientID: 2, gc: true)
        defer { doc.destroy() }
        let root = doc.get(BlockNoteYjs.fragmentField)
        try doc.transact { tx in
            let aux = doc.get("auxiliaryMeta")
            try YWrite.mapSet(tx, on: aux, key: "version", .any([.string("keep-me")]))

            let group = YType(typeRef: .xmlElement(nodeName: "blockGroup"))
            try YWrite.insertAfter(tx, into: root, after: nil, [.type(group)])

            let c1 = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            let c1Item = try YWrite.insertAfter(tx, into: group, after: nil, [.type(c1)])
            try YWrite.mapSet(tx, on: c1, key: "id", .any([.string("pr-callout")]))
            let callout = YType(typeRef: .xmlElement(nodeName: "callout"))
            try YWrite.insertAfter(tx, into: c1, after: nil, [.type(callout)])
            try YWrite.mapSet(tx, on: callout, key: "emoji", .any([.string("💡")]))
            try YWrite.mapSet(tx, on: callout, key: "customProp", .any([.string("keep-prop")]))
            let calloutXML = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: callout, after: nil, [.type(calloutXML)])
            try calloutXML.insert(0, "Preserved callout", ["customMark": "true"])

            let c2 = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            _ = try YWrite.insertAfter(tx, into: group, after: c1Item, [.type(c2)])
            try YWrite.mapSet(tx, on: c2, key: "id", .any([.string("pr-break")]))
            let pb = YType(typeRef: .xmlElement(nodeName: "pageBreak"))
            try YWrite.insertAfter(tx, into: c2, after: nil, [.type(pb)])
        }
        return try YStateEncoder.encodeStateAsUpdate(doc)
    }

    private static func makeS2MixedFixture(
        paragraphCount: Int, attachmentStride: Int, includeChecklist: Bool = false
    ) -> Data {
        let style: [(String, YAnyValue)] = [
            ("backgroundColor", .string("default")), ("textColor", .string("default")),
            ("textAlignment", .string("left")),
        ]
        let doc = YDoc(clientID: 1, gc: true)
        defer { doc.destroy() }
        let root = doc.get(BlockNoteYjs.fragmentField)
        try? doc.transact { tx in
            func element(_ name: String, into parent: YType, after: YItem?, _ props: [(String, YAnyValue)]) throws
                -> (YItem?, YType)
            {
                let type = YType(typeRef: .xmlElement(nodeName: name))
                let item = try YWrite.insertAfter(tx, into: parent, after: after, [.type(type)])
                for (key, value) in props { try YWrite.mapSet(tx, on: type, key: key, .any([value])) }
                return (item, type)
            }
            let (_, rootGroup) = try element("blockGroup", into: root, after: nil, [])
            var cursor: YItem?
            if includeChecklist {
                let (cItem, cContainer) = try element(
                    "blockContainer", into: rootGroup, after: cursor, [("id", .string("s2-check-0"))])
                cursor = cItem
                let (_, check) = try element(
                    "checkListItem", into: cContainer, after: nil, style + [("checked", .bool(false))])
                let xml = YType(typeRef: .xmlText)
                try YWrite.insertAfter(tx, into: check, after: nil, [.type(xml)])
                try xml.insert(0, "S2 task", nil)
            }
            for index in 0..<paragraphCount {
                let (pItem, pContainer) = try element(
                    "blockContainer", into: rootGroup, after: cursor, [("id", .string("s2-p-\(index)"))])
                cursor = pItem
                let (_, p) = try element("paragraph", into: pContainer, after: nil, style)
                let xml = YType(typeRef: .xmlText)
                try YWrite.insertAfter(tx, into: p, after: nil, [.type(xml)])
                try xml.insert(0, "S2 paragraph \(index)", nil)
                guard index % attachmentStride == 0 else { continue }
                let attIndex = index / attachmentStride
                switch attIndex % 5 {
                case 0:
                    let (item, container) = try element(
                        "blockContainer", into: rootGroup, after: cursor, [("id", .string("s2-img-\(attIndex)"))])
                    cursor = item
                    _ = try element(
                        "image", into: container, after: nil,
                        [
                            ("name", .string("\(attIndex).png")),
                            ("url", .string("https://docs.example/\(attIndex).png")),
                            ("showPreview", .bool(true)),
                        ])
                case 1:
                    let (item, container) = try element(
                        "blockContainer", into: rootGroup, after: cursor, [("id", .string("s2-tbl-\(attIndex)"))])
                    cursor = item
                    let (_, tbl) = try element(
                        "table", into: container, after: nil, [("textColor", .string("default"))])
                    let (_, row) = try element("tableRow", into: tbl, after: nil, [])
                    let (_, cell) = try element(
                        "tableCell", into: row, after: nil, [("colspan", .int(1)), ("rowspan", .int(1))])
                    let (_, tp) = try element("tableParagraph", into: cell, after: nil, [])
                    let cXML = YType(typeRef: .xmlText)
                    try YWrite.insertAfter(tx, into: tp, after: nil, [.type(cXML)])
                    try cXML.insert(0, "Cell \(attIndex)", nil)
                case 2:
                    let (item, list) = try element(
                        "columnList", into: rootGroup, after: cursor, [("id", .string("s2-cols-\(attIndex)"))])
                    cursor = item
                    var lastCol: YItem?
                    for colIdx in 0..<2 {
                        let (cItem, col) = try element(
                            "column", into: list, after: lastCol,
                            [("id", .string("s2-col-\(attIndex)-\(colIdx)")), ("width", .int(1))])
                        lastCol = cItem
                        let (_, cc) = try element(
                            "blockContainer", into: col, after: nil, [("id", .string("s2-col-p-\(attIndex)-\(colIdx)"))]
                        )
                        let (_, cp) = try element("paragraph", into: cc, after: nil, style)
                        let cXML = YType(typeRef: .xmlText)
                        try YWrite.insertAfter(tx, into: cp, after: nil, [.type(cXML)])
                        try cXML.insert(0, "Col \(colIdx)", nil)
                    }
                case 3:
                    let (item, container) = try element(
                        "blockContainer", into: rootGroup, after: cursor, [("id", .string("s2-math-\(attIndex)"))])
                    cursor = item
                    let (_, math) = try element("mathBlock", into: container, after: nil, [])
                    let xml = YType(typeRef: .xmlText)
                    try YWrite.insertAfter(tx, into: math, after: nil, [.type(xml)])
                    try xml.insert(0, "x+y", nil)
                default:
                    let (item, container) = try element(
                        "blockContainer", into: rootGroup, after: cursor, [("id", .string("s2-diag-\(attIndex)"))])
                    cursor = item
                    let (_, diag) = try element("diagram", into: container, after: nil, [("type", .string("mermaid"))])
                    let xml = YType(typeRef: .xmlText)
                    try YWrite.insertAfter(tx, into: diag, after: nil, [.type(xml)])
                    try xml.insert(0, "graph TD; A-->B;", nil)
                }
            }
        }
        return (try? YStateEncoder.encodeStateAsUpdate(doc)) ?? Data()
    }

    // MARK: - Environment & Server Stub

    private struct AcceptanceEnv {
        let model: EditorViewModel
        let defaults: UserDefaults
        let suite: String
        let directory: URL
        let ownership: ReplicaOwnershipStore
        let replicaStore: ReplicaStore
        let attachmentStore: PendingAttachmentStore
        let creates: PendingDocumentCreateStore
        let nativeSessions: NativeSessionRegistry
        let documentID: UUID
        var replicaDirectory: URL { directory.appendingPathComponent("ReplicaDrafts") }
        let makeModel: @MainActor () -> EditorViewModel
        @MainActor func relaunch() -> EditorViewModel { makeModel() }
        func clean() {
            MockURLProtocol.reset()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeAcceptanceEnvironment(
        defaults existingDefaults: UserDefaults? = nil,
        directory existingDirectory: URL? = nil,
        autosaveInterval: Duration = .seconds(10),
        connectivity: ConnectivityMonitor? = nil
    ) -> AcceptanceEnv {
        MockURLProtocol.reset()
        let suite = "NativeEditorAcceptanceTests.\(UUID())"
        let defaults = existingDefaults ?? UserDefaults(suiteName: suite)!
        let directory = existingDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let documentID = UUID()
        SignedInUserStore(userDefaults: defaults).remember(owner)
        let sharedAttachmentStore = PendingAttachmentStore(
            userDefaults: defaults, directory: directory.appendingPathComponent("attachments"))
        let nativeSessions = NativeSessionRegistry()
        let makeModel: @MainActor () -> EditorViewModel = {
            let client = DocsAPIClient(
                baseURL: URL(string: "https://docs.example.org/api/v1.0/")!, session: MockURLProtocol.makeSession(),
                cookieProvider: { [] })
            let content = DocumentContentCacheStore(directory: directory)
            let children = DocumentChildrenCacheStore(userDefaults: defaults)
            let ownership = ReplicaOwnershipStore(userDefaults: defaults)
            let replicaStore = ReplicaStore(
                directory: directory.appendingPathComponent("ReplicaDrafts"), ownershipStore: ownership)
            let attachmentStore = PendingAttachmentStore(
                userDefaults: defaults, directory: directory.appendingPathComponent("attachments"))
            let coordinator = DocumentSaveCoordinator(
                client: client, draftStore: PendingDraftStore(userDefaults: defaults), replicaStore: replicaStore,
                contentCache: content, createStore: PendingDocumentCreateStore(userDefaults: defaults),
                deleteStore: PendingDocumentDeleteStore(userDefaults: defaults),
                attachmentStore: attachmentStore,
                listCache: DocumentCacheStore(userDefaults: defaults), childrenCache: children,
                backgroundTasks: .noop)
            coordinator.nativeEditorEnabled = { NativeEditorPreference.isEnabled(defaults) }
            coordinator.nativeSessions = nativeSessions
            let availability =
                connectivity.map { OnlineAvailability(connectivity: $0, userDefaults: defaults) }
                ?? OnlineAvailability(userDefaults: defaults)
            return EditorViewModel(
                client: client, documentID: documentID, title: "Acceptance Title", saveCoordinator: coordinator,
                signedInUser: SignedInUserStore(userDefaults: defaults), contentCache: content,
                childrenCache: children, listCache: DocumentCacheStore(userDefaults: defaults),
                autosaveInterval: autosaveInterval, availability: availability,
                nativeEditorEnabled: { NativeEditorPreference.isEnabled(defaults) })
        }
        let model = makeModel()
        return AcceptanceEnv(
            model: model, defaults: defaults, suite: suite, directory: directory,
            ownership: ReplicaOwnershipStore(userDefaults: defaults),
            replicaStore: model.saveCoordinator.replicaStore,
            attachmentStore: sharedAttachmentStore,
            creates: PendingDocumentCreateStore(userDefaults: defaults),
            nativeSessions: nativeSessions,
            documentID: documentID, makeModel: makeModel)
    }
}

private final class AcceptanceServerStub: @unchecked Sendable {
    let log = RequestRecorder()
    private let lock = NSLock()
    private let owner: UUID
    private var _state: Data
    private var _serverTitle = "Acceptance Server Title"
    private var _serverContent = "First paragraph."
    private var _isOffline = false
    private var _patchedUpdates: [Data] = []
    private var _classicMarkdownPatches: [String] = []
    private var _titles: [String] = []
    private var _createdIDsByTitle: [String: UUID] = [:]
    private var _uploadedAttachmentDocIDs: [UUID] = []
    private var _children: [[String: Any]] = []

    init(owner: UUID, state: Data) {
        self.owner = owner
        self._state = state
    }

    var isOffline: Bool {
        get { locked { _isOffline } }
        set { locked { _isOffline = newValue } }
    }
    var serverContent: String {
        get { locked { _serverContent } }
        set { locked { _serverContent = newValue } }
    }
    var patchedUpdates: [Data] { locked { _patchedUpdates } }
    var classicMarkdownPatches: [String] { locked { _classicMarkdownPatches } }
    var titles: [String] { locked { _titles } }
    var createdIDsByTitle: [String: UUID] {
        get { locked { _createdIDsByTitle } }
        set { locked { _createdIDsByTitle = newValue } }
    }
    var uploadedAttachmentDocIDs: [UUID] { locked { _uploadedAttachmentDocIDs } }

    func install() {
        MockURLProtocol.stubHandler = { [weak self] request in
            guard let self else {
                return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
            }
            log.record(request)
            if isOffline {
                return .init(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
            }
            let path = request.url?.path ?? ""
            let jsonHeaders = ["Content-Type": "application/json"]
            if path.hasSuffix("/config") {
                let json = "{\"RELEASE_VERSION\":\"6.0.0\"}"
                return .init(statusCode: 200, headers: jsonHeaders, body: Data(json.utf8), error: nil)
            }
            if path.hasSuffix("/users/me") {
                let json =
                    "{\"id\":\"\(owner.uuidString.lowercased())\",\"email\":\"a@docs.example\",\"language\":\"en\"}"
                return .init(statusCode: 200, headers: jsonHeaders, body: Data(json.utf8), error: nil)
            }
            if request.httpMethod == "POST", path.hasSuffix("/documents") {
                let body = requestBody(request)
                let title =
                    (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["title"] as? String ?? "Untitled"
                let parentHint =
                    (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["parent_id"] as? String
                let resolvedID = locked { _createdIDsByTitle[title] ?? UUID() }
                let doc = makeDocumentJSON(
                    id: resolvedID, title: title, depth: parentHint == nil ? 1 : 2,
                    path: parentHint == nil ? "0001" : "00010001")
                return .init(
                    statusCode: 201, headers: jsonHeaders,
                    body: try! JSONSerialization.data(withJSONObject: doc), error: nil)
            }
            if request.httpMethod == "POST", path.contains("/documents/"), path.hasSuffix("/children") {
                let body = requestBody(request)
                let title =
                    (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["title"] as? String ?? ""
                let childID = locked { _createdIDsByTitle[title] ?? UUID() }
                let child = makeDocumentJSON(id: childID, title: title, depth: 2, path: "00010001")
                locked { _children.append(child) }
                return .init(
                    statusCode: 201, headers: jsonHeaders,
                    body: try! JSONSerialization.data(withJSONObject: child), error: nil)
            }
            if request.httpMethod == "POST", path.contains("/documents/"), path.contains("/attachment-upload") {
                if let docID = path.split(separator: "/").compactMap({ UUID(uuidString: String($0)) }).first {
                    locked { _uploadedAttachmentDocIDs.append(docID) }
                    let checkPath =
                        "/api/v1.0/documents/\(docID.uuidString.lowercased())/media-check/?key=\(docID.uuidString.lowercased())/attachments/offline.png"
                    let json = "{\"file\":\"\(checkPath)\"}"
                    return .init(statusCode: 201, headers: jsonHeaders, body: Data(json.utf8), error: nil)
                }
                let json = "{\"file\":\"/api/v1.0/documents/unknown/media-check/?key=offline.png\"}"
                return .init(statusCode: 201, headers: jsonHeaders, body: Data(json.utf8), error: nil)
            }
            if request.httpMethod == "GET", path.contains("/media-check") {
                let docID =
                    path.split(separator: "/").compactMap({ UUID(uuidString: String($0)) }).first?.uuidString
                    .lowercased() ?? "unknown"
                let json = "{\"status\":\"ready\",\"file\":\"/media/\(docID)/attachments/offline.png\"}"
                return .init(statusCode: 200, headers: jsonHeaders, body: Data(json.utf8), error: nil)
            }
            if path.contains("/collaboration/ydoc/") {
                if request.httpMethod == "GET" {
                    let state = locked { _state }
                    let body = try! JSONSerialization.data(withJSONObject: ["doc": state.base64EncodedString()])
                    return .init(statusCode: 200, headers: jsonHeaders, body: body, error: nil)
                }
                if request.httpMethod == "PATCH" {
                    let raw = requestBody(request)
                    let decoded =
                        (try? JSONSerialization.jsonObject(with: raw) as? [String: String])?["update"]
                        .flatMap { Data(base64Encoded: $0) } ?? raw
                    locked { _patchedUpdates.append(decoded) }
                    return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
                }
            }
            if path.contains("formatted-content") {
                let docID = path.split(separator: "/").compactMap({ UUID(uuidString: String($0)) }).first ?? UUID()
                let json: [String: Any] = [
                    "id": docID.uuidString.lowercased(),
                    "title": locked { _serverTitle },
                    "content": locked { _serverContent },
                    "created_at": "2026-11-07T10:00:00Z",
                    "updated_at": "2026-11-07T10:00:00Z",
                ]
                return .init(
                    statusCode: 200, headers: jsonHeaders,
                    body: try! JSONSerialization.data(withJSONObject: json), error: nil)
            }
            if path.hasSuffix("/children") {
                let children = locked { _children }
                let page: [String: Any] = ["count": children.count, "results": children]
                return .init(
                    statusCode: 200, headers: jsonHeaders,
                    body: try! JSONSerialization.data(withJSONObject: page), error: nil)
            }
            if request.httpMethod == "PATCH", path.contains("/documents/") {
                let body = requestBody(request)
                if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    if let title = obj["title"] as? String {
                        locked {
                            _serverTitle = title
                            _titles.append(title)
                        }
                    }
                    if let content = obj["content"] as? String {
                        locked { _classicMarkdownPatches.append(content) }
                    }
                }
                let docID = path.split(separator: "/").compactMap({ UUID(uuidString: String($0)) }).first ?? UUID()
                let doc = makeDocumentJSON(id: docID, title: locked { _serverTitle }, depth: 1, path: "0001")
                return .init(
                    statusCode: 200, headers: jsonHeaders,
                    body: try! JSONSerialization.data(withJSONObject: doc), error: nil)
            }
            let docID = path.split(separator: "/").compactMap({ UUID(uuidString: String($0)) }).first ?? UUID()
            let doc = makeDocumentJSON(id: docID, title: locked { _serverTitle }, depth: 1, path: "0001")
            return .init(
                statusCode: 200, headers: jsonHeaders,
                body: try! JSONSerialization.data(withJSONObject: doc), error: nil)
        }
    }

    private func makeDocumentJSON(id: UUID, title: String, depth: Int, path: String) -> [String: Any] {
        [
            "id": id.uuidString.lowercased(),
            "title": title,
            "excerpt": NSNull(),
            "abilities": ["update": true, "mention": true],
            "computed_link_reach": "restricted",
            "computed_link_role": NSNull(),
            "link_reach": "restricted",
            "link_role": "editor",
            "is_favorite": false,
            "depth": depth,
            "numchild": 0,
            "path": path,
            "created_at": "2026-11-07T10:00:00Z",
            "updated_at": "2026-11-07T10:00:00Z",
            "user_role": "owner",
            "creator": NSNull(),
        ]
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func requestBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read > 0 { data.append(buffer, count: read) } else { break }
        }
        return data
    }
}
