import SwiftUI

/// Disposable raw replicas exercise the production surface without an account,
/// network, save coordinator, or changes to the shipping app's launch arguments.
@main
struct NativeEditorTestHostApp: App {
    @State private var session: NativeEditorSession?
    @State private var localization = LocalizationStore()
    @State private var failedToLoad = false
    @State private var replicaDirectory: URL?
    private let fixture: Data

    init() {
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
                    title: session.input == nil ? "Native reader fixture" : "Native typing fixture")
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
            let blocks = (0..<30).map { index in
                BlockNoteBlock(
                    node: "paragraph",
                    props: [
                        ("backgroundColor", .string("default")), ("textColor", .string("default")),
                        ("textAlignment", .string("left")),
                    ],
                    runs: [InlineRun("Owned paragraph \(index + 1).")], id: "owned-\(index)")
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

/// Fails every request as offline, so the fixture never reaches a network.
private final class OfflineURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
