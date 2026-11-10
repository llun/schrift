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
            if ProcessInfo.processInfo.arguments.contains("--native-open") {
                NativeOpenFixture()
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
                let created = try NativeEditorSession(state: fixture)
                if ProcessInfo.processInfo.arguments.contains("--native-typing") {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    replicaDirectory = directory
                    let store = ReplicaStore(directory: directory)
                    let scope = ReplicaScope(
                        serverOrigin: "https://native-fixture.invalid", ownerUserID: UUID(), org: "docs",
                        documentID: UUID())
                    _ = try store.create(for: scope, checkpoint: fixture)
                    created.enableTyping { command, update in
                        try store.append(
                            update, for: scope, commandID: command.id,
                            baseRevision: command.baseRevision, origin: .local)
                    }
                }
                session = created
            } catch {
                failedToLoad = true
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

/// `--native-open`: the production `EditorView` → `NativeEditorOpen` route over
/// an owned replica, offline, with isolated stores under this host's sandbox.
/// Every request fails as offline, so no network is used. The stores survive
/// relaunch unless `--reset` is passed, which is what the relaunch test needs.
private struct NativeOpenFixture: View {
    @State private var model: EditorViewModel?
    private static let suite = "dev.llun.Schrift.NativeTestHost.open"
    private static let owner = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private static let documentID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

    var body: some View {
        NavigationStack {
            if let model {
                EditorView(
                    viewModel: model, reach: .restricted, serverHost: "native-fixture.invalid",
                    serverOrigin: "https://native-fixture.invalid", pinRow: Self.document, isOffline: true)
            } else {
                ProgressView()
            }
        }
        .overlay {
            if ProcessInfo.processInfo.arguments.contains("--native-ime") { SyntheticIMEControls() }
            if ProcessInfo.processInfo.arguments.contains("--native-tree") { TreeControls() }
        }
        .task {
            guard model == nil else { return }
            model = try? Self.makeModel()
        }
    }

    private static var document: Document {
        var abilities = DocumentAbilities()
        abilities.update = true
        return Document(
            id: documentID, title: "Native open fixture", excerpt: nil, abilities: abilities,
            linkReach: .restricted, linkRole: .editor, isFavorite: false, depth: 1, numchild: 0, path: "0001",
            createdAt: Date(), updatedAt: Date(), userRole: nil, creator: nil)
    }

    private static func makeModel() throws -> EditorViewModel {
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NativeOpenFixture", isDirectory: true)
        if ProcessInfo.processInfo.arguments.contains("--reset") {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        // The host's own sandbox; the shipping app never reads this switch here.
        UserDefaults.standard.set(true, forKey: NativeEditorPreference.key)
        SignedInUserStore(userDefaults: defaults).remember(owner)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineURLProtocol.self]
        let client = DocsAPIClient(
            baseURL: URL(string: "https://native-fixture.invalid/api/v1.0/")!,
            session: URLSession(configuration: configuration), cookieProvider: { [] })
        let replicaStore = ReplicaStore(
            directory: directory.appendingPathComponent("ReplicaDrafts"),
            ownershipStore: ReplicaOwnershipStore(userDefaults: defaults))
        let scope = ReplicaScope(
            serverOrigin: client.serverOrigin, ownerUserID: owner, org: "docs", documentID: documentID)
        if try replicaStore.manifest(for: scope) == nil {
            let style: [(key: String, value: YAnyValue)] = [
                ("backgroundColor", .string("default")), ("textColor", .string("default")),
                ("textAlignment", .string("left")),
            ]
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
            _ = try replicaStore.create(for: scope, checkpoint: BlockNoteYjs.encode(blocks, clientID: 1))
        }
        let content = DocumentContentCacheStore(directory: directory.appendingPathComponent("Content"))
        let children = DocumentChildrenCacheStore(userDefaults: defaults)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: PendingDraftStore(userDefaults: defaults), replicaStore: replicaStore,
            contentCache: content, createStore: PendingDocumentCreateStore(userDefaults: defaults),
            deleteStore: PendingDocumentDeleteStore(userDefaults: defaults),
            attachmentStore: PendingAttachmentStore(
                userDefaults: defaults, directory: directory.appendingPathComponent("Attachments")),
            listCache: DocumentCacheStore(userDefaults: defaults), childrenCache: children)
        return EditorViewModel(
            client: client, documentID: documentID, title: "Native open fixture", saveCoordinator: coordinator,
            signedInUser: SignedInUserStore(userDefaults: defaults), contentCache: content, childrenCache: children,
            listCache: DocumentCacheStore(userDefaults: defaults),
            availability: OnlineAvailability(userDefaults: defaults))
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
                    var lastRow: YItem?
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

/// Fails every request as offline, so the fixture never reaches a network.
private final class OfflineURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
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

/// `--native-tree`: puts the caret at the second bullet's start, as a tap
/// there would, and reads every block's depth back from the mounted storage
/// (the nesting is otherwise only an indent on screen).
private struct TreeControls: View {
    @State private var depths = ""

    var body: some View {
        VStack(spacing: 8) {
            Button("Caret in second") { Self.placeCaret(in: "owned-tree-2") }
                .accessibilityIdentifier("tree.caret")
            Button("Read tree") { depths = Self.depths() }
                .accessibilityIdentifier("tree.read")
            Text(depths).accessibilityIdentifier("tree.depths")
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

    @MainActor private static func depths() -> String {
        blocks().prefix(3).map { String($0.depth) }.joined(separator: ",")
    }
}
