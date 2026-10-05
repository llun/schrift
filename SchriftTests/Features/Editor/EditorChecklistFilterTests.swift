import XCTest

@testable import Schrift

@MainActor
final class EditorChecklistFilterTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var directory: URL!
    private var drafts: PendingDraftStore!
    private var coordinator: DocumentSaveCoordinator!
    private let log = RequestRecorder()

    override func setUp() {
        super.setUp()
        suite = "EditorChecklistFilterTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        coordinator = nil
        super.tearDown()
    }

    private func load(_ markdown: String) async throws -> EditorViewModel {
        let client = DocsAPIClient(
            baseURL: URL(string: "https://docs.example.org/api/v1.0/")!,
            session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        drafts = PendingDraftStore(userDefaults: defaults)
        let cache = DocumentContentCacheStore(directory: directory)
        coordinator = DocumentSaveCoordinator(
            client: client, draftStore: drafts, contentCache: cache,
            createStore: PendingDocumentCreateStore(userDefaults: defaults),
            deleteStore: PendingDocumentDeleteStore(userDefaults: defaults), backgroundTasks: .noop)
        let model = EditorViewModel(
            client: client, documentID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            title: "Tasks", saveCoordinator: coordinator,
            contentCache: cache, childrenCache: DocumentChildrenCacheStore(userDefaults: defaults))
        let body = try JSONSerialization.data(withJSONObject: [
            "id": model.documentID.uuidString, "title": "Tasks", "content": markdown,
            "created_at": "2026-10-05T06:00:00Z", "updated_at": "2026-10-05T06:00:00Z",
        ])
        let log = log
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(
                statusCode: 200, headers: [:],
                body: request.url!.path.contains("formatted-content")
                    ? body : Data("{\"count\":0,\"results\":[]}".utf8), error: nil)
        }
        await model.load()
        XCTAssertTrue(model.hasLoadedContent)
        return model
    }

    func testFilterAndUneditedModeSwapsPreserveExactSourceEveryBlockAndNeverSave() async throws {
        // Deliberately noncanonical markdown catches a filter that overwrites rawMarkdown
        // with the reading projection or even the serializer's full-block normalization.
        let source = "- [X] Finished  \r\n- [ ] Next\r\n\r\nParagraph\r\n"
        let model = try await load(source)
        let blocks = model.blocks
        let encoded = BlockNoteYjs.encode(MarkdownYjs.blockNoteBlocks(from: blocks), clientID: 42)
        XCTAssertFalse(model.hidesCompletedChecklistItems)
        for _ in 0..<3 {
            model.setHidesCompletedChecklistItems(true)
            XCTAssertEqual(model.checklistReadingPresentation.hiddenCount, 1)
            XCTAssertEqual(model.blocks, blocks)
            XCTAssertEqual(model.currentMarkdown(), source)
            model.startEditing()
            XCTAssertEqual(model.checklistReadingPresentation.rows.map(\.block), blocks)
            XCTAssertEqual(model.blocks, blocks)
            model.finishEditing()
            XCTAssertEqual(model.checklistReadingPresentation.hiddenCount, 1)
            model.setHidesCompletedChecklistItems(false)
            XCTAssertEqual(model.checklistReadingPresentation.rows.map(\.block), blocks)
        }
        model.flushPendingChanges()
        XCTAssertEqual(model.rawMarkdown, source)
        XCTAssertEqual(BlockNoteYjs.encode(MarkdownYjs.blockNoteBlocks(from: model.blocks), clientID: 42), encoded)
        XCTAssertFalse(model.isDirty)
        XCTAssertNil(drafts.draft(for: model.documentID))
        XCTAssertNil(coordinator.pendingSave(documentID: model.documentID))
        await waitAndConfirmNever { self.log.count(ofMethod: "PATCH", urlContaining: "/documents/") > 0 }
    }

    func testRemoteUpdatesToHiddenBlocksAndNewBlocksAreVisibleWhenEditingOrRevealed() async throws {
        let model = try await load("- [x] Finished\n- [ ] Next")
        let ids = model.blocks.map(\.id)
        let added = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        model.setHidesCompletedChecklistItems(true)
        model.applyLiveRemoteChange(
            LiveChangeSet(changes: [
                .update(id: ids[0], kind: .checklistItem(checked: false), text: "Reopened remotely"),
                .update(id: ids[1], kind: .checklistItem(checked: true), text: "Completed remotely"),
                .insert(id: added, kind: .checklistItem(checked: true), text: "Added remotely", afterID: ids[1]),
            ]), projectedMarkdown: "- [ ] Reopened remotely\n- [x] Completed remotely\n- [x] Added remotely")
        XCTAssertEqual(model.checklistReadingPresentation.rows.map(\.id), [ids[0]])
        XCTAssertEqual(model.checklistReadingPresentation.hiddenCount, 2)
        model.startEditing()
        XCTAssertEqual(model.blocks.map(\.id), ids + [added])
        XCTAssertEqual(model.checklistReadingPresentation.rows.map(\.block), model.blocks)
        model.applyLiveRemoteChange(
            LiveChangeSet(changes: [.remove(id: ids[0])]),
            projectedMarkdown: "- [x] Completed remotely\n- [x] Added remotely")
        model.finishEditing()
        XCTAssertTrue(model.checklistReadingPresentation.rows.isEmpty)
        XCTAssertEqual(model.checklistReadingPresentation.hiddenCount, 2)
        model.setHidesCompletedChecklistItems(false)
        XCTAssertEqual(model.checklistReadingPresentation.rows.map(\.id), [ids[1], added])
        XCTAssertEqual(model.currentMarkdown(), "- [x] Completed remotely\n- [x] Added remotely")
        XCTAssertFalse(model.isDirty)
        XCTAssertNil(coordinator.pendingSave(documentID: model.documentID))
        XCTAssertNil(drafts.draft(for: model.documentID))
    }

    func testFilterRemainsEnabledWhenLastChecklistBecomesAParagraphAndANewItemArrives() async throws {
        let model = try await load("- [x] Finished")
        let id = try XCTUnwrap(model.blocks.first?.id)
        model.setHidesCompletedChecklistItems(true)
        model.applyLiveRemoteChange(
            LiveChangeSet(changes: [.update(id: id, kind: .paragraph, text: "Converted")]),
            projectedMarkdown: "Converted")
        XCTAssertFalse(model.checklistReadingPresentation.hasChecklistItems)
        XCTAssertEqual(model.checklistReadingPresentation.rows.map(\.id), [id])
        model.applyLiveRemoteChange(
            LiveChangeSet(changes: [.update(id: id, kind: .checklistItem(checked: true), text: "Converted back")]),
            projectedMarkdown: "- [x] Converted back")
        XCTAssertTrue(model.checklistReadingPresentation.rows.isEmpty)
        model.setHidesCompletedChecklistItems(false)
        XCTAssertEqual(model.checklistReadingPresentation.rows.map(\.id), [id])
    }

    func testPreferenceNeverForwardsALiveEditOrFlushesALiveSnapshot() async throws {
        let model = try await load("- [x] Finished\n- [ ] Next")
        let live = FilterLiveWriteSpy()
        model.liveWrite = live
        let original = model.blocks
        let source = model.rawMarkdown
        model.setHidesCompletedChecklistItems(true)
        model.setHidesCompletedChecklistItems(true)
        model.setHidesCompletedChecklistItems(false)
        XCTAssertEqual(live.forwardCount, 0)
        XCTAssertEqual(live.flushCount, 0)
        XCTAssertEqual(model.blocks, original)
        XCTAssertEqual(model.rawMarkdown, source)
        XCTAssertFalse(model.isDirty)
    }

    func testEditingVisibleContentSavesCompletedBlocksInTheirOriginalPositions() async throws {
        let model = try await load("- [x] Finished\n- [ ] Next\n- [x] Also finished")
        let ids = model.blocks.map(\.id)
        model.setHidesCompletedChecklistItems(true)
        model.startEditing(focusing: ids[1])
        model.updateText(blockID: ids[1], text: "Next edited")
        model.finishEditing()
        let expected = "- [x] Finished\n- [ ] Next edited\n- [x] Also finished\n"
        XCTAssertEqual(model.blocks.map(\.id), ids)
        XCTAssertEqual(model.rawMarkdown, expected)
        XCTAssertEqual(coordinator.pendingSave(documentID: model.documentID)?.markdown, expected)
        XCTAssertEqual(drafts.draft(for: model.documentID)?.markdown, expected)
        XCTAssertEqual(model.checklistReadingPresentation.rows.map(\.id), [ids[1]])
        model.setHidesCompletedChecklistItems(false)
        XCTAssertEqual(model.checklistReadingPresentation.rows.map(\.id), ids)
    }
}

@MainActor
private final class FilterLiveWriteSpy: EditorLiveWriteCoordinating {
    var isHandlingLocalEditsLive: Bool { true }
    var forwardCount = 0
    var flushCount = 0
    func forwardLocalEdit() -> Bool {
        forwardCount += 1
        return true
    }
    func flushPendingLiveSnapshot() { flushCount += 1 }
}
