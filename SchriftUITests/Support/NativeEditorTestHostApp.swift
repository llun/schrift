import SwiftUI

/// Disposable raw replicas exercise the production surface without an account,
/// network, save coordinator, or changes to the shipping app's launch arguments.
@main
struct NativeEditorTestHostApp: App {
    @State private var session: NativeEditorSession?
    @State private var localization = LocalizationStore()
    @State private var failedToLoad = false
    @State private var replicaDirectory: URL?
    /// `--native-media`: images (served by `MediaFixture`, never a network) and tables.
    @State private var images = MediaFixture.loader()
    private let fixture: Data

    init() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--native-diagnostics") || args.contains("--native-scroll-sampler") {
            NativeEditorDiagnosticsStore.shared.setForcedCollection(true)
        }
        if args.contains("--native-scroll-sampler") {
            fixture = ScrollSamplerFixture.state()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--native-media") {
            fixture = MediaFixture.state()
            return
        }
        let count = ProcessInfo.processInfo.arguments.contains("--native-large") ? 5_000 : 30
        var blocks = (0..<count).map { index in
            BlockNoteBlock(
                node: "paragraph",
                props: [
                    ("backgroundColor", .string("default")), ("textColor", .string("default")),
                    ("textAlignment", .string("left")),
                ],
                runs: [InlineRun("Paragraph \(index + 1): Select and copy 😀 e\u{301} 日本語 العربية.")],
                id: "fixture-\(index)")
        }
        blocks.insert(BlockNoteBlock(node: "table", props: [], runs: [], id: "preserved-table"), at: 1)
        // `--native-toggle`: a toggle list item with two children first (PR06b).
        if ProcessInfo.processInfo.arguments.contains("--native-toggle") {
            let style = blocks[0].props
            blocks.insert(
                BlockNoteBlock(
                    node: "toggleListItem", props: style, runs: [InlineRun("Toggle title")], id: "fixture-toggle",
                    children: [
                        BlockNoteBlock(
                            node: "paragraph", props: style, runs: [InlineRun("Folded child one")],
                            id: "fixture-toggle-1"),
                        BlockNoteBlock(
                            node: "paragraph", props: style, runs: [InlineRun("Folded child two")],
                            id: "fixture-toggle-2"),
                    ]), at: 0)
        }
        fixture = BlockNoteYjs.encode(blocks, clientID: 1)
    }

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--native-inline-objects") {
                NativeOpenFixture(mode: .inlineObjects)
                    .environment(localization)
            } else if ProcessInfo.processInfo.arguments.contains("--native-open") {
                NativeOpenFixture(mode: .standard)
                    .environment(localization)
            } else {
                readerFixture
            }
        }
    }

    private var readerFixture: some View {
        NavigationStack {
            if let session {
                NativeEditorView(
                    session: session,
                    title: session.input == nil ? "Native reader fixture" : "Native typing fixture",
                    serverOrigin: MediaFixture.origin)
            } else if failedToLoad {
                Text("Fixture failed to load")
            } else {
                ProgressView()
            }
        }
        .task {
            // Session construction creates UIKit selection interactions.
            // Do it from the mounted view lifecycle, not from App.init.
            guard session == nil || session?.isClosed == true else { return }
            do {
                if ProcessInfo.processInfo.arguments.contains("--native-typing") {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    replicaDirectory = directory
                    let store = ReplicaStore(directory: directory, interrupt: slowDisk)
                    let scope = ReplicaScope(
                        serverOrigin: "https://native-fixture.invalid", ownerUserID: UUID(), org: "docs",
                        documentID: UUID())
                    _ = try store.create(for: scope, checkpoint: fixture)
                    session = try await NativeEditorSession.restore(store: store, scope: scope, editable: true)
                    if ProcessInfo.processInfo.arguments.contains("--native-peer"), let session {
                        await PeerFixture.install(on: session)
                    }
                } else {
                    session = try await NativeEditorSession.inspect(state: fixture)
                }
            } catch {
                failedToLoad = true
            }
        }
        .overlay(alignment: .bottomLeading) {
            if ProcessInfo.processInfo.arguments.contains("--native-media") { ContentHeightReadout() }
            // `--native-readout` (PR10b): the block at the top of the text, polled.
            if ProcessInfo.processInfo.arguments.contains("--native-readout"), let session {
                TopBlockReadout(session: session)
            }
            if ProcessInfo.processInfo.arguments.contains("--native-scroll-sampler"), session != nil {
                ScrollSamplerOverlay()
            }
            if ProcessInfo.processInfo.arguments.contains("--native-diagnostics") {
                DiagnosticsReadoutOverlay()
            }
        }
        .environment(localization)
        .environment(images)
        .onDisappear {
            session?.close()
            // Test-only fixture bytes, never a shipping document's store.
            if let replicaDirectory { try? FileManager.default.removeItem(at: replicaDirectory) }
        }
    }
}

/// `--native-open` / `--native-inline-objects`: the production `EditorView` →
/// `NativeEditorOpen` route over an owned replica with isolated stores under
/// this host's sandbox. Every request stays local (`OfflineURLProtocol` or
/// `InlineObjectsURLProtocol`), so no real network is ever used. The stores
/// survive relaunch unless `--reset` is passed.
private struct NativeOpenFixture: View {
    enum Mode {
        case standard
        case inlineObjects
    }

    let mode: Mode
    @State private var model: EditorViewModel?
    @State private var openedDocument: Document?
    private static let suite = "dev.llun.Schrift.NativeTestHost.open"
    private static let owner = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private static let documentID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

    var body: some View {
        NavigationStack {
            if let model {
                EditorView(
                    viewModel: model,
                    reach: .restricted,
                    serverHost: mode == .inlineObjects ? InlineObjectsFixture.serverHost : "native-fixture.invalid",
                    serverOrigin: mode == .inlineObjects
                        ? InlineObjectsFixture.serverOrigin : "https://native-fixture.invalid",
                    pinRow: Self.document(mode: mode),
                    isOffline: mode == .standard,
                    onOpenDocument: mode == .inlineObjects ? { openedDocument = $0 } : nil
                )
                .navigationDestination(item: $openedDocument) { doc in
                    Text(doc.title ?? doc.id.uuidString)
                        .accessibilityIdentifier("inlineObjects.openedDocument")
                }
            } else {
                ProgressView()
            }
        }
        .overlay {
            if ProcessInfo.processInfo.arguments.contains("--native-ime") { SyntheticIMEControls() }
            if ProcessInfo.processInfo.arguments.contains("--native-tree") { TreeControls() }
            if ProcessInfo.processInfo.arguments.contains("--native-slow-disk") || mode == .inlineObjects {
                InFlightReadout()
            }
            if ProcessInfo.processInfo.arguments.contains("--native-selection") { SelectionReadout() }
        }
        .overlay(alignment: .bottomLeading) {
            if ProcessInfo.processInfo.arguments.contains("--native-diagnostics") { DiagnosticsReadoutOverlay() }
        }
        .task {
            guard model == nil else { return }
            model = try? Self.makeModel(mode: mode)
        }
    }

    private static func document(mode: Mode) -> Document {
        switch mode {
        case .standard:
            var abilities = DocumentAbilities()
            abilities.update = true
            return Document(
                id: documentID, title: "Native open fixture", excerpt: nil, abilities: abilities,
                linkReach: .restricted, linkRole: .editor, isFavorite: false, depth: 1, numchild: 0, path: "0001",
                createdAt: Date(), updatedAt: Date(), userRole: nil, creator: nil)
        case .inlineObjects:
            return InlineObjectsFixture.openDocument(canMention: InlineObjectsFixture.canMention)
        }
    }

    private static func makeModel(mode: Mode) throws -> EditorViewModel {
        let suiteName = mode == .inlineObjects ? InlineObjectsFixture.suite : suite
        let directoryName = mode == .inlineObjects ? InlineObjectsFixture.directoryName : "NativeOpenFixture"
        let docID = mode == .inlineObjects ? InlineObjectsFixture.documentID : documentID
        let ownerID = mode == .inlineObjects ? InlineObjectsFixture.owner : owner
        let defaults = UserDefaults(suiteName: suiteName)!
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)
        if ProcessInfo.processInfo.arguments.contains("--reset") {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        // The host's own sandbox; the shipping app never reads this switch here.
        UserDefaults.standard.set(true, forKey: NativeEditorPreference.key)
        SignedInUserStore(userDefaults: defaults).remember(ownerID)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses =
            mode == .inlineObjects ? [InlineObjectsURLProtocol.self] : [OfflineURLProtocol.self]
        let origin = mode == .inlineObjects ? InlineObjectsFixture.serverOrigin : "https://native-fixture.invalid"
        let client = DocsAPIClient(
            baseURL: URL(string: "\(origin)/api/v1.0/")!,
            session: URLSession(configuration: configuration), cookieProvider: { [] })
        let listCache = DocumentCacheStore(userDefaults: defaults)
        if mode == .inlineObjects, listCache.loadRecentDocuments() == nil {
            listCache.saveRecentDocuments(InlineObjectsFixture.seededDocuments, fetchedFor: ownerID)
        }
        let replicaStore = ReplicaStore(
            directory: directory.appendingPathComponent("ReplicaDrafts"),
            ownershipStore: ReplicaOwnershipStore(userDefaults: defaults), interrupt: slowDisk)
        let scope = ReplicaScope(
            serverOrigin: client.serverOrigin, ownerUserID: ownerID, org: "docs", documentID: docID)
        if try replicaStore.manifest(for: scope) == nil {
            let checkpoint = try makeInitialCheckpoint(mode: mode)
            _ = try replicaStore.create(for: scope, checkpoint: checkpoint)
        }
        let content = DocumentContentCacheStore(directory: directory.appendingPathComponent("Content"))
        let children = DocumentChildrenCacheStore(userDefaults: defaults)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: PendingDraftStore(userDefaults: defaults), replicaStore: replicaStore,
            contentCache: content, createStore: PendingDocumentCreateStore(userDefaults: defaults),
            deleteStore: PendingDocumentDeleteStore(userDefaults: defaults),
            attachmentStore: PendingAttachmentStore(
                userDefaults: defaults, directory: directory.appendingPathComponent("Attachments")),
            listCache: listCache, childrenCache: children)
        return EditorViewModel(
            client: client, documentID: docID,
            title: mode == .inlineObjects ? "Inline objects fixture" : "Native open fixture",
            saveCoordinator: coordinator,
            signedInUser: SignedInUserStore(userDefaults: defaults), contentCache: content, childrenCache: children,
            listCache: listCache,
            availability: OnlineAvailability(userDefaults: defaults))
    }

    private static func makeInitialCheckpoint(mode: Mode) throws -> Data {
        let style: [(key: String, value: YAnyValue)] = [
            ("backgroundColor", .string("default")), ("textColor", .string("default")),
            ("textAlignment", .string("left")),
        ]
        if mode == .inlineObjects {
            let blocks = [
                BlockNoteBlock(node: "paragraph", props: style, runs: [], id: "owned-0"),
                BlockNoteBlock(
                    node: "paragraph", props: style, runs: [InlineRun("Trailing paragraph.")], id: "owned-1"),
            ]
            var checkpoint = BlockNoteYjs.encode(blocks, clientID: 1)
            checkpoint = try TableFixture.inserting(into: checkpoint, after: "owned-0")
            checkpoint = try ColumnFixture.inserting(into: checkpoint, after: "owned-0")
            return checkpoint
        }
        if ProcessInfo.processInfo.arguments.contains("--native-checklist-only") {
            let checklistBlocks = [
                BlockNoteBlock(
                    node: "checkListItem", props: style + [("checked", .bool(false))],
                    runs: [InlineRun("Only task one")], id: "owned-check-1"),
                BlockNoteBlock(
                    node: "checkListItem", props: style + [("checked", .bool(true))],
                    runs: [InlineRun("Only task two")], id: "owned-check-2"),
            ]
            return BlockNoteYjs.encode(checklistBlocks, clientID: 1)
        }
        var blocks = (0..<30).map { index in
            BlockNoteBlock(
                node: "paragraph", props: style, runs: [InlineRun("Owned paragraph \(index + 1).")],
                id: "owned-\(index)")
        }
        // `--native-blocks`: one of each block type the typeable production
        // route accepts first (callout and page break would make it read-only).
        if ProcessInfo.processInfo.arguments.contains("--native-blocks") {
            blocks.insert(
                contentsOf: [
                    BlockNoteBlock(
                        node: "heading", props: style + [("level", .int(2)), ("isToggleable", .bool(false))],
                        runs: [InlineRun("Fixture heading")], id: "owned-heading"),
                    BlockNoteBlock(
                        node: "checkListItem", props: style + [("checked", .bool(false))],
                        runs: [InlineRun("Fixture task")], id: "owned-check"),
                    BlockNoteBlock(
                        node: "codeBlock", props: [("language", .string("swift"))],
                        runs: [InlineRun("let fixture = 1\nlet second = 2")], id: "owned-code"),
                    BlockNoteBlock(
                        node: "bulletListItem", props: style, runs: [InlineRun("Fixture bullet")],
                        id: "owned-bullet"),
                    BlockNoteBlock(
                        node: "numberedListItem", props: style + [("start", .int(3))],
                        runs: [InlineRun("Fixture third")], id: "owned-number-1"),
                    BlockNoteBlock(
                        node: "numberedListItem", props: style + [("start", .undefined)],
                        runs: [InlineRun("Fixture fourth")], id: "owned-number-2"),
                    BlockNoteBlock(
                        node: "quote",
                        props: [("backgroundColor", .string("default")), ("textColor", .string("default"))],
                        runs: [InlineRun("Fixture quote")], id: "owned-quote"),
                    BlockNoteBlock(node: "divider", props: [], runs: [], id: "owned-divider"),
                ], at: 0)
        }
        // `--native-tree`: two bullets first, for Tab.
        if ProcessInfo.processInfo.arguments.contains("--native-tree") {
            blocks.insert(
                contentsOf: [
                    BlockNoteBlock(
                        node: "bulletListItem", props: style, runs: [InlineRun("Tree first")], id: "owned-tree-1"),
                    BlockNoteBlock(
                        node: "bulletListItem", props: style, runs: [InlineRun("Tree second")], id: "owned-tree-2"),
                ], at: 0)
        }
        var checkpoint = BlockNoteYjs.encode(blocks, clientID: 1)
        // `--native-table` (PR11a): a web-shaped 2 × 2 table (a header row
        // and an empty cell) after the first paragraph.
        if ProcessInfo.processInfo.arguments.contains("--native-table") {
            checkpoint = try TableFixture.inserting(into: checkpoint, after: "owned-0")
        }
        // `--native-columns` (PR12a): a web-shaped group of two columns
        // after the first paragraph.
        if ProcessInfo.processInfo.arguments.contains("--native-columns") {
            checkpoint = try ColumnFixture.inserting(into: checkpoint, after: "owned-0")
        }
        // `--native-media-edit` (PR13a): a web-shaped captioned image and a
        // file after the first paragraph (no image loader: no request).
        if ProcessInfo.processInfo.arguments.contains("--native-media-edit") {
            checkpoint = try MediaEditFixture.inserting(into: checkpoint, after: "owned-0")
        }
        return checkpoint
    }
}

/// `--native-media` (PR06e): paragraphs, same-origin images, tables and math
/// in turn. The image loader's transport is a local closure that answers
/// after a delay with a generated 3:1 PNG, so a download lands while the
/// reader is looking and the UI test can check that nothing moves.
private enum MediaFixture {
    static let origin = "https://native-fixture.invalid"

    @MainActor static func loader() -> ImageLoader {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NativeMediaFixture", isDirectory: true)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 200)).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 200))
        }
        return ImageLoader(
            scopeProvider: { ImageCacheScope(serverOrigin: origin, sessionID: "native-media-fixture") },
            cache: ImageCacheStore(directory: directory),
            fetch: { _, _ in
                try await Task.sleep(for: .milliseconds(1_200))
                return png
            }, cookieProvider: { _ in [] })
    }

    static func state() -> Data {
        let style: [(key: String, value: YAnyValue)] = [
            ("backgroundColor", .string("default")), ("textColor", .string("default")),
            ("textAlignment", .string("left")),
        ]
        var blocks: [BlockNoteBlock] = []
        var tables: [String] = []
        for index in 0..<12 {
            blocks.append(
                BlockNoteBlock(
                    node: "paragraph", props: style,
                    runs: [InlineRun("Media paragraph \(index + 1) with enough words to wrap onto a second line.")],
                    id: "media-p\(index)"))
            switch index % 3 {
            case 0:
                blocks.append(
                    BlockNoteBlock(
                        node: "image",
                        props: [
                            ("caption", .string("Fixture image \(index)")), ("name", .string("\(index).png")),
                            ("previewWidth", .undefined), ("showPreview", .bool(true)),
                            ("url", .string("\(origin)/media/\(index).png")),
                        ], runs: [], id: "media-img-\(index)"))
            case 1: tables.append("media-p\(index)")
            default:
                blocks.append(
                    BlockNoteBlock(
                        node: "mathBlock", props: [], runs: [InlineRun("e^{i\\pi} + 1 = 0")], id: "media-math-\(index)")
                )
            }
        }
        let doc = YDoc(clientID: 2, gc: true)
        defer { doc.destroy() }
        do {
            try doc.applyUpdate(YUpdateDecoder.decode(BlockNoteYjs.encode(blocks, clientID: 1)))
            guard let root = doc.share[BlockNoteYjs.fragmentField],
                case .type(let group)? = YBlockProjection.children(of: root, includeFormats: false).first?.content
            else { return BlockNoteYjs.encode(blocks, clientID: 1) }
            try doc.transact { tx in
                for after in tables {
                    let left = YBlockProjection.children(of: group, includeFormats: false).first { item in
                        guard case .type(let type) = item.content, case .any(let values)? = type.map["id"]?.content
                        else { return false }
                        return values.first == .string(after)
                    }
                    let container = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
                    try YWrite.insertAfter(tx, into: group, after: left, [.type(container)])
                    let table = YType(typeRef: .xmlElement(nodeName: "table"))
                    try YWrite.insertAfter(tx, into: container, after: nil, [.type(table)])
                    var lastRow: YItem? = nil
                    for row in 0..<5 {
                        let rowType = YType(typeRef: .xmlElement(nodeName: "tableRow"))
                        lastRow = try YWrite.insertAfter(tx, into: table, after: lastRow, [.type(rowType)])
                        var lastCell: YItem?
                        for column in 0..<3 {
                            let cell = YType(typeRef: .xmlElement(nodeName: row == 0 ? "tableHeader" : "tableCell"))
                            lastCell = try YWrite.insertAfter(tx, into: rowType, after: lastCell, [.type(cell)])
                            let paragraph = YType(typeRef: .xmlElement(nodeName: "tableParagraph"))
                            try YWrite.insertAfter(tx, into: cell, after: nil, [.type(paragraph)])
                            let text = YType(typeRef: .xmlText)
                            try YWrite.insertAfter(tx, into: paragraph, after: nil, [.type(text)])
                            try text.insert(0, row == 0 ? "Head \(column)" : "R\(row) C\(column)", nil)
                        }
                    }
                    try YWrite.mapSet(tx, on: container, key: "id", .any([.string("media-tbl-\(after)")]))
                }
            }
            return try YStateEncoder.encodeStateAsUpdate(doc)
        } catch {
            return BlockNoteYjs.encode(blocks, clientID: 1)
        }
    }
}

/// `--native-slow-disk` (PR08b): every journal append takes 60 ms longer, so
/// typed keys run ahead of their appends (option A's predictions) and Return
/// waits for its barrier with keys held behind it. Test host only.
private let slowDisk: (@Sendable (ReplicaStore.Operation, ReplicaStore.Boundary) throws -> Void)? =
    ProcessInfo.processInfo.arguments.contains("--native-slow-disk")
    ? { @Sendable operation, boundary in
        if operation == .append, boundary == .payloadFlushed { Thread.sleep(forTimeInterval: 0.06) }
    } : nil

/// `--native-readout` (PR10b): the block at the top of the text, polled on
/// the main actor (the text view is UIKit; a `TimelineView` may render off main).
private struct TopBlockReadout: View {
    let session: NativeEditorSession
    @State private var top = "none"

    var body: some View {
        Text(top)
            .font(.caption2)
            .accessibilityIdentifier("nativeEditor.topBlock")
            .task {
                while !Task.isCancelled {
                    top = session.textView.topVisibleBlockID() ?? "none"
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
    }
}

/// `--native-peer` (PR10): two collaborators as a web client would publish
/// them, fed straight to the awareness controller (no socket): "Web Peer"
/// (client 7) at "fixture-2" offset 4 and, with `--native-toggle`, "Folded
/// Peer" (client 8) inside the folded toggle.
@MainActor
private enum PeerFixture {
    static func install(on session: NativeEditorSession) async {
        guard let replica = session.replica else { return }
        let awareness = NativeAwarenessController(replica: replica, timeout: .seconds(3_600))
        session.showAwareness(awareness)
        let spots: [(id: UInt, name: String, block: String, offset: Int)] = [
            (7, "Web Peer", "fixture-2", 4), (8, "Folded Peer", "fixture-toggle-1", 2),
        ]
        let positions = await withCheckedContinuation { (done: CheckedContinuation<[YRelativePositionJSON?], Never>) in
            replica.mailbox.post(
                .inspect { engine, _, _ in
                    done.resume(
                        returning: spots.map { spot in
                            engine?.awarenessPosition(EditorPosition(blockID: spot.block, offset: spot.offset))
                        })
                })
        }
        awareness.receive(
            zip(spots, positions).compactMap { spot, position in
                position.map {
                    AwarenessEntry(
                        clientID: spot.id, clock: 1,
                        stateJSON: LocalAwarenessState(
                            name: spot.name, color: "#000000", cursor: AwarenessCursor(anchor: $0, head: $0)
                        ).json(wireProtocol: .yWebSocket))
                }
            })
    }
}

/// Fails every request as offline, so the fixture never reaches a network.
private final class OfflineURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

/// `--native-inline-objects` (PR13c2): local fixture constants and mocked
/// `listAccesses` / `document` responses (never touches a real server).
private enum InlineObjectsFixture: Sendable {
    static let suite = "dev.llun.Schrift.NativeTestHost.inlineObjects"
    static let directoryName = "NativeInlineObjectsFixture"
    static let serverHost = "docs.example"
    static let serverOrigin = "https://docs.example"
    static let owner = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    static let documentID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    static let productRoadmapID = UUID(uuidString: "55555555-5555-4555-8555-555555555551")!
    static let architectureNotesID = UUID(uuidString: "55555555-5555-4555-8555-555555555552")!

    static var canMention: Bool {
        !ProcessInfo.processInfo.arguments.contains("--native-inline-objects-no-mention")
    }

    static func openDocument(canMention: Bool) -> Document {
        makeDocument(
            id: documentID, title: "Inline objects fixture", path: "0001", canUpdate: true, canMention: canMention)
    }

    static var seededDocuments: [Document] {
        [
            makeDocument(
                id: productRoadmapID, title: "Product Roadmap", path: "0002", canUpdate: true, canMention: true),
            makeDocument(
                id: architectureNotesID, title: "Architecture Notes", path: "0003", canUpdate: true, canMention: true),
        ]
    }

    static func makeDocument(
        id: UUID, title: String, path: String, canUpdate: Bool, canMention: Bool
    ) -> Document {
        var abilities = DocumentAbilities()
        abilities.update = canUpdate
        abilities.mention = canMention
        return Document(
            id: id, title: title, excerpt: nil, abilities: abilities, linkReach: .restricted,
            linkRole: .editor, isFavorite: false, depth: 1, numchild: 0, path: path,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            userRole: .editor, creator: owner)
    }

    static let accessesData: Data = Data(
        """
        [
          {
            "id": "99999999-0000-4000-8000-000000000001",
            "user": {
              "id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
              "email": "ada@docs.example",
              "full_name": "Ada Lovelace",
              "short_name": "Ada"
            },
            "team": null,
            "role": "editor",
            "abilities": {}
          },
          {
            "id": "99999999-0000-4000-8000-000000000002",
            "user": {
              "id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
              "email": "grace@docs.example",
              "full_name": "Grace Hopper",
              "short_name": "Grace"
            },
            "team": null,
            "role": "administrator",
            "abilities": {}
          },
          {
            "id": "99999999-0000-4000-8000-000000000003",
            "user": {
              "id": "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
              "email": "reader@docs.example",
              "full_name": "Reader User",
              "short_name": "Reader"
            },
            "team": null,
            "role": "reader",
            "abilities": {}
          },
          {
            "id": "99999999-0000-4000-8000-000000000004",
            "user": {
              "id": "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
              "email": "downgraded@docs.example",
              "full_name": "Downgraded Reader",
              "short_name": "Downgraded"
            },
            "team": null,
            "role": "editor",
            "max_role": "reader",
            "abilities": {}
          }
        ]
        """.utf8)

    static func documentData(for id: UUID) -> Data? {
        let doc: Document? =
            switch id {
            case documentID: openDocument(canMention: canMention)
            case productRoadmapID: seededDocuments[0]
            case architectureNotesID: seededDocuments[1]
            default: nil
            }
        guard let doc else { return nil }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(doc)
    }
}

private final class InlineObjectsURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, request.httpMethod == "GET" else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let path = url.path
        let docPrefix = "/api/v1.0/documents/"
        guard path.hasPrefix(docPrefix) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let remainder = String(path.dropFirst(docPrefix.count))
        let parts = remainder.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count == 2, parts[1] == "accesses",
            UUID(uuidString: String(parts[0])) == InlineObjectsFixture.documentID
        {
            respond(statusCode: 200, data: InlineObjectsFixture.accessesData, url: url)
            return
        }
        if parts.count == 1, let id = UUID(uuidString: String(parts[0])),
            let data = InlineObjectsFixture.documentData(for: id)
        {
            respond(statusCode: 200, data: data, url: url)
            return
        }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}

    private func respond(statusCode: Int, data: Data, url: URL) {
        let response = HTTPURLResponse(
            url: url, statusCode: statusCode, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// `--native-ime`: the host's synthetic marked-text path. Each button sends the
/// UITextInput calls a Japanese keyboard makes to the mounted production
/// `NativeTextView`, while the real keyboard and first responder stay up. The
/// simulator's keyboards cannot be changed from a UI test, so this is the
/// layer between the unit tests and TestFlight.
private struct SyntheticIMEControls: View {
    var body: some View {
        VStack(spacing: 8) {
            Button("Compose にほん") { Self.mark("にほん") }
                .accessibilityIdentifier("ime.compose")
            Button("Convert 日本") { Self.mark("日本") }
                .accessibilityIdentifier("ime.convert")
            Button("Commit") { Self.textView()?.unmarkText() }
                .accessibilityIdentifier("ime.commit")
            Button("Compose かな") { Self.mark("かな") }
                .accessibilityIdentifier("ime.composeKana")
        }
        .buttonStyle(.bordered)
    }

    @MainActor private static func mark(_ text: String) {
        textView()?.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
    }

    @MainActor private static func textView() -> NativeTextView? { mountedTextView() }
}

@MainActor private func mountedTextView() -> NativeTextView? {
    func find(_ view: UIView) -> NativeTextView? {
        (view as? NativeTextView) ?? view.subviews.lazy.compactMap(find).first
    }
    return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        .lazy.compactMap(find).first
}

/// `--native-media`: the reader's content height, polled. TextKit 2 sizes
/// paragraphs it has not laid out from estimates, so this is how the UI test
/// sees whether an attachment paragraph's estimate was already its final
/// height (the S2 line heights). Touches pass through to the reader.
private struct ContentHeightReadout: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            Text(verbatim: mountedTextView().map { "\(Int($0.contentSize.height))" } ?? "")
                .font(.caption2)
                .accessibilityIdentifier("media.contentHeight")
        }
        .allowsHitTesting(false)
    }
}

/// `--native-slow-disk`: "idle" once every typed key reached the journal, so
/// the relaunch test terminates only after the slow appends (polled).
private struct InFlightReadout: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            Text(verbatim: mountedTextView()?.inputCoordinator?.hasInFlightWork == true ? "busy" : "idle")
                .font(.caption2)
                .accessibilityIdentifier("replica.inFlight")
        }
        .allowsHitTesting(false)
    }
}

/// `--native-selection`: the mounted editor's selection, polled, so a UI test can tell a selected
/// word from the caret a slow double tap leaves behind (at a caret Bold only arms typing marks, so
/// nothing is saved). The value is the selected text, `caret` when the selection is collapsed and
/// `none` when no editor is mounted.
private struct SelectionReadout: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            Text(verbatim: "selection")
                .font(.caption2)
                .accessibilityIdentifier("nativeEditor.selection")
                .accessibilityValue(Self.selection())
        }
        .allowsHitTesting(false)
    }

    @MainActor private static func selection() -> String {
        guard let view = mountedTextView() else { return "none" }
        let range = view.selectedRange
        guard range.length > 0, range.location + range.length <= view.textStorage.length else { return "caret" }
        return (view.textStorage.string as NSString).substring(with: range)
    }
}

/// `--native-tree`: puts the caret at the second bullet's start, as a tap
/// there would, and reads every block's depth (and the first three blocks'
/// text) back from the mounted storage (the nesting is otherwise only an
/// indent on screen).
private struct TreeControls: View {
    @State private var depths = ""
    @State private var texts = ""

    var body: some View {
        VStack(spacing: 8) {
            Button("Caret in second") { Self.placeCaret(in: "owned-tree-2") }
                .accessibilityIdentifier("tree.caret")
            Button("Read tree") {
                depths = Self.depths()
                texts = Self.texts()
            }
            .accessibilityIdentifier("tree.read")
            Text(depths).accessibilityIdentifier("tree.depths")
            Text(texts).accessibilityIdentifier("tree.texts")
        }
        .buttonStyle(.bordered)
    }

    @MainActor private static func blocks() -> [(id: String, location: Int, depth: Int)] {
        guard let storage = mountedTextView()?.textStorage else { return [] }
        var blocks: [(id: String, location: Int, depth: Int)] = []
        storage.enumerateAttribute(.nativeBlockID, in: NSRange(location: 0, length: storage.length)) {
            value, range, _ in
            guard let id = value as? String, blocks.last?.id != id else { return }
            let depth = storage.attribute(.nativeDepth, at: range.location, effectiveRange: nil) as? Int ?? 0
            blocks.append((id, range.location, depth))
        }
        return blocks
    }

    @MainActor private static func placeCaret(in blockID: String) {
        guard let view = mountedTextView(), let block = blocks().first(where: { $0.id == blockID }) else { return }
        view.selectedRange = NSRange(location: block.location, length: 0)
        view.delegate?.textViewDidChangeSelection?(view)
    }

    @MainActor private static func texts() -> String {
        (mountedTextView()?.textStorage.string ?? "").components(separatedBy: "\n").prefix(3).joined(separator: "|")
    }

    @MainActor private static func depths() -> String {
        blocks().prefix(3).map { String($0.depth) }.joined(separator: ",")
    }
}

/// `--native-table` (PR11a): BlockNote 0.56's table shape, as the web writes
/// one (`tableHeader` row, `tableCell` row, every cell's default props).
/// `--native-media-edit` (PR13a): BlockNote 0.56's image and file blocks as
/// the web writes them (schema-ordered props, no content).
private enum MediaEditFixture {
    static func inserting(into state: Data, after blockID: String) throws -> Data {
        let doc = YDoc(clientID: 3, gc: true)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(state))
        guard let root = doc.share[BlockNoteYjs.fragmentField],
            case .type(let group)? = YBlockProjection.children(of: root, includeFormats: false).first?.content
        else { return state }
        let left = YBlockProjection.children(of: group, includeFormats: false).first { item in
            guard case .type(let type) = item.content else { return false }
            return BlockIndex.blockID(of: type) == blockID
        }
        let writer = BlockNoteWriter(doc: doc)
        func block(_ id: String, _ node: String, _ props: [String: String]) -> BlockNoteWriter.Copy {
            let fields = (MediaBlock.schemas[node] ?? []).map { field in
                (key: field.key, value: props[field.key].map { YAnyValue.string($0) } ?? field.value)
            }
            return .element("blockContainer", [("id", .string(id))], [.element(node, fields, [])])
        }
        try writer.insertBlocks(
            [
                block(
                    "owned-image", "image",
                    ["name": "harbour.png", "url": "https://images.example/harbour.png", "caption": "Old caption"]),
                block("owned-file", "file", ["name": "notes.txt", "url": "https://files.example/notes.txt"]),
            ], into: group, after: left)
        return try YStateEncoder.encodeStateAsUpdate(doc)
    }
}

private enum TableFixture {
    static func inserting(into state: Data, after blockID: String) throws -> Data {
        let doc = YDoc(clientID: 2, gc: true)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(state))
        guard let root = doc.share[BlockNoteYjs.fragmentField],
            case .type(let group)? = YBlockProjection.children(of: root, includeFormats: false).first?.content
        else { return state }
        let left = YBlockProjection.children(of: group, includeFormats: false).first { item in
            guard case .type(let type) = item.content else { return false }
            return BlockIndex.blockID(of: type) == blockID
        }
        try doc.transact { tx in
            func element(_ name: String, into parent: YType, after: YItem?, _ props: [(String, YAnyValue)]) throws
                -> (YItem?, YType)
            {
                let type = YType(typeRef: .xmlElement(nodeName: name))
                let item = try YWrite.insertAfter(tx, into: parent, after: after, [.type(type)])
                for (key, value) in props { try YWrite.mapSet(tx, on: type, key: key, .any([value])) }
                return (item, type)
            }
            let (_, container) = try element(
                "blockContainer", into: group, after: left, [("id", .string("owned-table"))])
            let (_, table) = try element("table", into: container, after: nil, [("textColor", .string("default"))])
            let cellProps: [(String, YAnyValue)] = [
                ("backgroundColor", .string("default")), ("colspan", .int(1)), ("rowspan", .int(1)),
                ("textAlignment", .string("left")), ("textColor", .string("default")),
            ]
            var lastRow: YItem?
            for (index, texts) in [["Name", "Role"], ["Ada", ""]].enumerated() {
                let (rowItem, row) = try element("tableRow", into: table, after: lastRow, [])
                lastRow = rowItem
                var lastCell: YItem?
                for text in texts {
                    let (cellItem, cell) = try element(
                        index == 0 ? "tableHeader" : "tableCell", into: row, after: lastCell, cellProps)
                    lastCell = cellItem
                    let (_, paragraph) = try element("tableParagraph", into: cell, after: nil, [])
                    if !text.isEmpty {
                        let xmlText = YType(typeRef: .xmlText)
                        try YWrite.insertAfter(tx, into: paragraph, after: nil, [.type(xmlText)])
                        try xmlText.insert(0, text, nil)
                    }
                }
            }
        }
        return try YStateEncoder.encodeStateAsUpdate(doc)
    }
}

/// `--native-columns` (PR12a): `@blocknote/xl-multi-column`'s group shape, as
/// the web writes one (`columnList` in the group, `column`s with `id` and
/// `width`, each holding a paragraph).
private enum ColumnFixture {
    static func inserting(into state: Data, after blockID: String) throws -> Data {
        let doc = YDoc(clientID: 3, gc: true)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(state))
        guard let root = doc.share[BlockNoteYjs.fragmentField],
            case .type(let group)? = YBlockProjection.children(of: root, includeFormats: false).first?.content
        else { return state }
        let left = YBlockProjection.children(of: group, includeFormats: false).first { item in
            guard case .type(let type) = item.content else { return false }
            return BlockIndex.blockID(of: type) == blockID
        }
        try doc.transact { tx in
            func element(_ name: String, into parent: YType, after: YItem?, _ props: [(String, YAnyValue)]) throws
                -> (YItem?, YType)
            {
                let type = YType(typeRef: .xmlElement(nodeName: name))
                let item = try YWrite.insertAfter(tx, into: parent, after: after, [.type(type)])
                for (key, value) in props { try YWrite.mapSet(tx, on: type, key: key, .any([value])) }
                return (item, type)
            }
            let (_, list) = try element("columnList", into: group, after: left, [("id", .string("owned-columns"))])
            var lastColumn: YItem?
            for (index, text) in ["Left", "Right"].enumerated() {
                let (columnItem, column) = try element(
                    "column", into: list, after: lastColumn,
                    [("id", .string("owned-column-\(index)")), ("width", .int(1))])
                lastColumn = columnItem
                let (_, container) = try element(
                    "blockContainer", into: column, after: nil, [("id", .string("owned-column-text-\(index)"))])
                let (_, paragraph) = try element(
                    "paragraph", into: container, after: nil,
                    [
                        ("backgroundColor", .string("default")), ("textAlignment", .string("left")),
                        ("textColor", .string("default")),
                    ])
                let xmlText = YType(typeRef: .xmlText)
                try YWrite.insertAfter(tx, into: paragraph, after: nil, [.type(xmlText)])
                try xmlText.insert(0, text, nil)
                // `--native-column-table`: a one-row table under the first column's paragraph.
                guard index == 0, ProcessInfo.processInfo.arguments.contains("--native-column-table") else { continue }
                let (_, tableContainer) = try element(
                    "blockContainer", into: column, after: column.start, [("id", .string("owned-column-table"))])
                let (_, table) = try element(
                    "table", into: tableContainer, after: nil, [("textColor", .string("default"))])
                let (_, row) = try element("tableRow", into: table, after: nil, [])
                var lastCell: YItem?
                for cellText in ["A", "B"] {
                    let (cellItem, cell) = try element(
                        "tableCell", into: row, after: lastCell,
                        [
                            ("backgroundColor", .string("default")), ("colspan", .int(1)), ("rowspan", .int(1)),
                            ("textAlignment", .string("left")), ("textColor", .string("default")),
                        ])
                    lastCell = cellItem
                    let (_, cellParagraph) = try element("tableParagraph", into: cell, after: nil, [])
                    let cellXML = YType(typeRef: .xmlText)
                    try YWrite.insertAfter(tx, into: cellParagraph, after: nil, [.type(cellXML)])
                    try cellXML.insert(0, cellText, nil)
                }
            }
        }
        return try YStateEncoder.encodeStateAsUpdate(doc)
    }
}

// MARK: - PR15 Step 4 Diagnostics & Corrected S2 Scroll Sampler

private struct DiagnosticsReadoutOverlay: View {
    @State private var json = ""

    var body: some View {
        HStack(spacing: 6) {
            Button("Refresh diagnostics") {
                json = NativeEditorDiagnosticsStore.shared.sanitizedJSONString()
            }
            .accessibilityIdentifier("nativeEditor.diagnostics.refresh")
            Text(verbatim: json.isEmpty ? "pending" : "ready")
                .font(.caption2)
                .accessibilityIdentifier("nativeEditor.diagnostics")
                .accessibilityValue(json.isEmpty ? "pending" : json)
        }
        .padding(6)
        .background(.ultraThinMaterial)
    }
}

private enum ScrollSamplerFixture {
    /// S2: 5,000 paragraphs interleaved with 200 mixed attachment blocks across
    /// images, tables, columns, math blocks, and diagrams.
    static func state() -> Data {
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
            for index in 0..<5_000 {
                let (pContainerItem, pContainer) = try element(
                    "blockContainer", into: rootGroup, after: cursor, [("id", .string("s2-p-\(index)"))])
                cursor = pContainerItem
                let (_, paragraph) = try element("paragraph", into: pContainer, after: nil, style)
                let xmlText = YType(typeRef: .xmlText)
                try YWrite.insertAfter(tx, into: paragraph, after: nil, [.type(xmlText)])
                try xmlText.insert(0, "S2 paragraph \(index + 1): steady viewport displacement.", nil)

                guard index % 25 == 0 else { continue }
                let attachmentIndex = index / 25
                switch attachmentIndex % 5 {
                case 0:
                    let (item, container) = try element(
                        "blockContainer", into: rootGroup, after: cursor,
                        [("id", .string("s2-img-\(attachmentIndex)"))])
                    cursor = item
                    _ = try element(
                        "image", into: container, after: nil,
                        [
                            ("caption", .string("Image \(attachmentIndex)")),
                            ("name", .string("\(attachmentIndex).png")),
                            ("previewWidth", .undefined),
                            ("showPreview", .bool(true)),
                            ("url", .string("\(MediaFixture.origin)/s2/\(attachmentIndex).png")),
                        ])
                case 1:
                    let (item, container) = try element(
                        "blockContainer", into: rootGroup, after: cursor,
                        [("id", .string("s2-tbl-\(attachmentIndex)"))])
                    cursor = item
                    let (_, table) = try element(
                        "table", into: container, after: nil, [("textColor", .string("default"))])
                    let cellProps: [(String, YAnyValue)] = [
                        ("backgroundColor", .string("default")), ("colspan", .int(1)), ("rowspan", .int(1)),
                        ("textAlignment", .string("left")), ("textColor", .string("default")),
                    ]
                    var lastRow: YItem?
                    for (r, rowTexts) in [["Col A", "Col B"], ["Val \(attachmentIndex)", "OK"]].enumerated() {
                        let (rowItem, row) = try element("tableRow", into: table, after: lastRow, [])
                        lastRow = rowItem
                        var lastCell: YItem?
                        for cellText in rowTexts {
                            let (cellItem, cell) = try element(
                                r == 0 ? "tableHeader" : "tableCell", into: row, after: lastCell, cellProps)
                            lastCell = cellItem
                            let (_, tp) = try element("tableParagraph", into: cell, after: nil, [])
                            let cellXML = YType(typeRef: .xmlText)
                            try YWrite.insertAfter(tx, into: tp, after: nil, [.type(cellXML)])
                            try cellXML.insert(0, cellText, nil)
                        }
                    }
                case 2:
                    let (item, list) = try element(
                        "columnList", into: rootGroup, after: cursor,
                        [("id", .string("s2-cols-\(attachmentIndex)"))])
                    cursor = item
                    var lastCol: YItem?
                    for (c, colText) in ["Left \(attachmentIndex)", "Right \(attachmentIndex)"].enumerated() {
                        let (colItem, col) = try element(
                            "column", into: list, after: lastCol,
                            [("id", .string("s2-col-\(attachmentIndex)-\(c)")), ("width", .int(1))])
                        lastCol = colItem
                        let (_, container) = try element(
                            "blockContainer", into: col, after: nil,
                            [("id", .string("s2-col-p-\(attachmentIndex)-\(c)"))])
                        let (_, p) = try element("paragraph", into: container, after: nil, style)
                        let xml = YType(typeRef: .xmlText)
                        try YWrite.insertAfter(tx, into: p, after: nil, [.type(xml)])
                        try xml.insert(0, colText, nil)
                    }
                case 3:
                    let (item, container) = try element(
                        "blockContainer", into: rootGroup, after: cursor,
                        [("id", .string("s2-math-\(attachmentIndex)"))])
                    cursor = item
                    let (_, math) = try element("mathBlock", into: container, after: nil, [])
                    let xml = YType(typeRef: .xmlText)
                    try YWrite.insertAfter(tx, into: math, after: nil, [.type(xml)])
                    try xml.insert(0, "\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}", nil)
                default:
                    let (item, container) = try element(
                        "blockContainer", into: rootGroup, after: cursor,
                        [("id", .string("s2-diag-\(attachmentIndex)"))])
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
}

@MainActor
private final class NativeScrollSampler: NSObject, ObservableObject {
    @Published var status = "idle"
    private var displayLink: CADisplayLink?
    private var previousFrames: [String: CGFloat] = [:]
    private var frameCount = 0
    private var jumpCount = 0
    private var reversalCount = 0
    private var maxReversalPt: CGFloat = 0
    private var maxBoundsError: CGFloat = 0
    private var maxRealisedAttachments = 0
    private var maxRealisedControls = 0
    private var reachedBottom = false
    private var isProgrammaticRun = false
    private var pendingRequestedDeltaY: CGFloat = 0
    private var previousContentOffsetY: CGFloat = 0

    func startObserving() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        status = "observing"
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func runProgrammaticSweep() {
        guard let textView = mountedTextView() else {
            status = "fail|noTextView"
            return
        }
        startObserving()
        frameCount = 0
        jumpCount = 0
        reversalCount = 0
        maxReversalPt = 0
        maxBoundsError = 0
        maxRealisedAttachments = 0
        maxRealisedControls = 0
        reachedBottom = false
        pendingRequestedDeltaY = 0
        previousFrames = [:]
        textView.setContentOffset(CGPoint(x: 0, y: -textView.adjustedContentInset.top), animated: false)
        textView.layoutIfNeeded()
        previousContentOffsetY = textView.contentOffset.y
        isProgrammaticRun = true
        status = "running"
    }

    @objc private func tick() {
        guard let textView = mountedTextView(), let window = textView.window,
            let controls = textView.blockControls
        else { return }
        // Measure visible attachment bounds vs provider/content bounds on every frame.
        let visibleAttachments = controls.visibleAttachmentViews
        maxRealisedAttachments = max(maxRealisedAttachments, visibleAttachments.count)
        maxRealisedControls = max(maxRealisedControls, controls.orderedControlViews.count)
        var currentFrames: [String: CGFloat] = [:]
        for attachmentView in visibleAttachments {
            let errW = abs(attachmentView.bounds.width - attachmentView.content.size.width)
            let errH = abs(attachmentView.bounds.height - attachmentView.content.size.height)
            maxBoundsError = max(maxBoundsError, max(errW, errH))
            let screenRect = attachmentView.convert(attachmentView.bounds, to: window)
            if screenRect.intersects(textView.convert(textView.bounds, to: window)) {
                currentFrames[attachmentView.content.blockID] = screenRect.minY
            }
        }
        if let layout = textView.textLayoutManager,
            let content = layout.textContentManager,
            let surface = controls.surface
        {
            layout.enumerateTextLayoutFragments(
                from: layout.textViewportLayoutController.viewportRange?.location ?? layout.documentRange.location,
                options: []
            ) { fragment in
                let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
                guard offset != NSNotFound, let entry = surface.rangeIndex.entry(atUTF16: offset) else { return true }
                let rectInTextView = fragment.layoutFragmentFrame
                let screenMinY = textView.convert(rectInTextView, to: window).minY
                if currentFrames[entry.blockID] == nil {
                    currentFrames[entry.blockID] = screenMinY
                }
                return rectInTextView.maxY < textView.contentOffset.y + textView.bounds.height
            }
        }

        let currentOffsetY = textView.contentOffset.y
        let maxOffsetY = max(
            -textView.adjustedContentInset.top,
            textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom)

        if !previousFrames.isEmpty {
            let commonDeltas = previousFrames.compactMap { id, prevY -> CGFloat? in
                guard let curY = currentFrames[id] else { return nil }
                return curY - prevY
            }
            if !commonDeltas.isEmpty {
                let sortedDeltas = commonDeltas.sorted()
                let minDelta = sortedDeltas.first ?? 0
                let maxDelta = sortedDeltas.last ?? 0
                if maxDelta - minDelta > 4.0 {
                    jumpCount += 1
                }
                let medianDelta = sortedDeltas[sortedDeltas.count / 2]
                if isProgrammaticRun && pendingRequestedDeltaY > 0 {
                    // Explicit requested displacement vs observed screen delta.
                    if medianDelta > 2.0 {
                        reversalCount += 1
                        maxReversalPt = max(maxReversalPt, medianDelta)
                    }
                    if abs(medianDelta - (-pendingRequestedDeltaY)) > 48.0 {
                        jumpCount += 1
                    }
                } else if textView.isDragging || textView.isDecelerating,
                    currentOffsetY > previousContentOffsetY + 2.0,
                    currentOffsetY > 0,
                    currentOffsetY < maxOffsetY - 2.0,
                    medianDelta > 4.0
                {
                    // During active downward touch fling, visible blocks must not jump backwards down screen.
                    reversalCount += 1
                    maxReversalPt = max(maxReversalPt, medianDelta)
                }
            }
        }
        frameCount += 1
        previousFrames = currentFrames
        previousContentOffsetY = currentOffsetY

        if currentOffsetY >= maxOffsetY - 2.0 && maxOffsetY > 0 {
            reachedBottom = true
        }

        if isProgrammaticRun {
            if currentOffsetY >= maxOffsetY - 2.0 {
                reachedBottom = true
                isProgrammaticRun = false
                pendingRequestedDeltaY = 0
                let passed =
                    reachedBottom && reversalCount <= 2 && maxReversalPt <= 24.0
                    && maxBoundsError <= 0.5 && maxRealisedAttachments <= 32
                let prefix = passed ? "pass" : "fail"
                status = String(
                    format:
                        "%@|jumps=%d|reversals=%d|maxReversalPt=%.2f|reachedBottom=%d|maxBoundsErr=%.2f|maxRealised=%d|maxControls=%d|frames=%d",
                    prefix, jumpCount, reversalCount, maxReversalPt, reachedBottom ? 1 : 0, maxBoundsError,
                    maxRealisedAttachments, maxRealisedControls, frameCount)
            } else {
                // Step at ~45% viewport height so consecutive frames keep overlapping blocks in common.
                let step = min(max(textView.bounds.height * 0.45, 320.0), maxOffsetY - currentOffsetY)
                pendingRequestedDeltaY = step
                textView.setContentOffset(CGPoint(x: 0, y: currentOffsetY + step), animated: false)
                textView.layoutIfNeeded()
            }
        }
    }
}

private struct ScrollSamplerOverlay: View {
    @StateObject private var sampler = NativeScrollSampler()

    var body: some View {
        HStack(spacing: 8) {
            Button("Run S2 sweep") {
                sampler.runProgrammaticSweep()
            }
            .accessibilityIdentifier("scrollSampler.run")
            Text(verbatim: sampler.status)
                .font(.caption2)
                .lineLimit(1)
                .accessibilityIdentifier("scrollSampler.status")
        }
        .padding(6)
        .background(.ultraThinMaterial)
        .onAppear { sampler.startObserving() }
        .onDisappear { sampler.stop() }
    }
}
