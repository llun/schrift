import SwiftUI

/// Disposable fixture hosting the real Home navigation, editor and Options surfaces.
/// The shipping app has no launch-argument branches or test-network hooks.
struct OfflineControlsTestHost: View {
    private let defaults: UserDefaults
    private let path: OfflineFixturePath
    private let availability: OnlineAvailability
    private let client: DocsAPIClient
    private let coordinator: DocumentSaveCoordinator
    @State private var options: OptionsViewModel
    @State private var home: HomeViewModel
    @State private var loc: LocalizationStore
    @State private var appearance: AppearanceStore
    @State private var theme: ThemeStore

    init() {
        let suite = "SchriftOfflineControlsTestHost"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        self.defaults = defaults
        let path = OfflineFixturePath()
        self.path = path
        let monitor = ConnectivityMonitor(
            monitoring: NetworkPathMonitoring { update in
                path.update = update
                return {}
            })
        let availability = OnlineAvailability(connectivity: monitor, userDefaults: defaults)
        self.availability = availability
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineFixtureProtocol.self]
        let client = DocsAPIClient(
            baseURL: URL(string: "https://docs.example.org/api/v1.0/")!,
            session: URLSession(configuration: configuration),
            cookieProvider: { [] })
        self.client = client
        let cache = DocumentContentCacheStore()
        cache.remove(documentID: OfflineFixtureProtocol.documentID)
        if !ProcessInfo.processInfo.arguments.contains("--uncached") {
            cache.save(
                CachedDocumentContent(
                    documentID: OfflineFixtureProtocol.documentID, title: "Offline fixture",
                    markdown: OfflineFixtureProtocol.markdown,
                    syncedAt: Date()))
        }
        let lists = DocumentCacheStore(userDefaults: defaults)
        let document = try! JSONDecoder.docsAPI.decode(
            PaginatedResponse<Document>.self, from: OfflineFixtureProtocol.page
        )
        .results[0]
        lists.savePinnedDocuments([])
        lists.saveRecentDocuments([document])
        let children = DocumentChildrenCacheStore(userDefaults: defaults)
        children.save([], for: document.id)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: PendingDraftStore(userDefaults: defaults), contentCache: cache,
            createStore: PendingDocumentCreateStore(userDefaults: defaults),
            deleteStore: PendingDocumentDeleteStore(userDefaults: defaults), listCache: lists, childrenCache: children,
            serverOrigin: "https://docs.example.org", backgroundTasks: .noop)
        self.coordinator = coordinator
        _options = State(
            initialValue: OptionsViewModel(
                client: client, documentID: document.id, isFavorite: false, saveCoordinator: coordinator))
        _home = State(
            initialValue: HomeViewModel(
                client: client, cache: lists, saveCoordinator: coordinator, userDefaults: defaults,
                availability: availability))
        let loc = LocalizationStore(userDefaults: defaults)
        loc.language = .english
        _loc = State(initialValue: loc)
        let appearance = AppearanceStore(userDefaults: defaults)
        appearance.selected = ProcessInfo.processInfo.arguments.contains("--theme-dark") ? .dark : .light
        _appearance = State(initialValue: appearance)
        let theme = ThemeStore(userDefaults: defaults)
        for option in AppTheme.allCases where ProcessInfo.processInfo.arguments.contains("--theme-\(option.rawValue)") {
            theme.selected = option
        }
        _theme = State(initialValue: theme)
        if ProcessInfo.processInfo.arguments.contains("--theme-audit") {
            path.update?(true)
        } else if !ProcessInfo.processInfo.arguments.contains("--transport-failure") {
            path.update?(false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !ProcessInfo.processInfo.arguments.contains("--theme-audit") {
                HStack {
                    Button("Go offline") { path.update?(false) }.accessibilityIdentifier("fixture.offline")
                    Button("Go online") { path.update?(true) }.accessibilityIdentifier("fixture.online")
                    Button("Work Offline") {
                        defaults.set(!defaults.bool(forKey: "schrift.workOffline"), forKey: "schrift.workOffline")
                        availability.preferencesChanged()
                    }.accessibilityIdentifier("fixture.workOffline")
                }
                .buttonStyle(.bordered)
            }
            if ProcessInfo.processInfo.arguments.contains("--options-transitions") {
                // Keep this production surface mounted while the external fixture driver
                // changes availability, including Work Offline on a reachable path.
                OptionsSheetView(
                    viewModel: options, client: client, documentID: OfflineFixtureProtocol.documentID,
                    serverHost: "docs.example.org", shareURL: URL(string: "https://docs.example.org/docs/fixture/"),
                    saveCoordinator: coordinator, availability: availability, onShare: {})
            } else {
                MainTabView(
                    viewModel: home, serverHost: "docs.example.org", serverOrigin: "https://docs.example.org",
                    signInGeneration: 0)
            }
        }
        .defaultAppStorage(defaults)
        .environment(loc)
        .environment(appearance)
        .environment(theme)
        .environment(\.docsTheme, theme.selected)
        .tint(theme.selected.colors.textBrand)
        .environment(AttachmentLoader.inert())
        .environment(ImageLoader.inert())
        .environment(DocumentCollaborationManager.inert())
        .preferredColorScheme(appearance.selected.colorScheme)
        .environment(
            \.dynamicTypeSize,
            ProcessInfo.processInfo.arguments.contains("--theme-accessibility") ? .accessibility3 : .large)
    }
}

private final class OfflineFixturePath: @unchecked Sendable {
    // Installed synchronously at init, then only read on the main actor.
    var update: (@Sendable (Bool) -> Void)?
}

private final class OfflineFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let failures = OfflineFixtureFailures()
    static let documentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static var markdown: String {
        ProcessInfo.processInfo.arguments.contains("--theme-audit")
            ? """
            Make room for the work.

            Schrift should feel calm, familiar, and built for reading and writing.

            ## A clear hierarchy

            Let the document lead. Keep controls close when needed and quiet while reading.

            - [x] Use familiar controls
            - [ ] Keep the page uncluttered

            > Less interface. More document.

            The writing surface fills the available width. Only the normal text inset remains.

            Read the [project notes](https://docs.example.org/docs/notes/).
            """
            : "Cached readable body"
    }

    static let page = Data(
        """
        {"count":1,"results":[{"id":"11111111-1111-4111-8111-111111111111","title":"Offline fixture",
         "abilities":{"partial_update":true,"destroy":true},"link_reach":"restricted","link_role":"reader",
         "is_favorite":false,"depth":1,"numchild":0,"path":"0001","created_at":"2026-01-15T10:30:00Z",
         "updated_at":"2026-01-15T10:30:00Z"}]}
        """.utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let body: Data
        if path.contains("formatted-content") {
            if ProcessInfo.processInfo.arguments.contains("--transport-failure"), Self.failures.takeFirst() {
                client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
                return
            }
            body = try! JSONSerialization.data(withJSONObject: [
                "id": "11111111-1111-4111-8111-111111111111", "title": "Offline fixture", "content": Self.markdown,
                "created_at": "2026-01-15T10:30:00Z", "updated_at": "2026-01-15T10:30:00Z",
            ])
        } else if path.contains("children") || path.contains("accesses") {
            body = Data("{\"count\":0,\"results\":[]}".utf8)
        } else if path.contains("versions") {
            body = Data(
                "{\"versions\":[{\"version_id\":\"v1\",\"last_modified\":\"2026-01-15T10:30:00Z\",\"is_current\":true}]}"
                    .utf8)
        } else if path.contains("users/me") {
            body = Data(
                """
                {"id":"22222222-2222-4222-8222-222222222222", "email":"camille@example.org",
                 "full_name":"Camille Moreau", "short_name":"Camille", "language":"en"}
                """.utf8)
        } else if path.contains("config") {
            body = Data("{}".utf8)
        } else if path.contains("favorite_list") {
            body = Data("{\"count\":0,\"results\":[]}".utf8)
        } else {
            body = Self.page
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class OfflineFixtureFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var isFirst = true
    func takeFirst() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let first = isFirst
        isFirst = false
        return first
    }
}
