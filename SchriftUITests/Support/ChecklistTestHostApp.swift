import SwiftUI

@main
struct ChecklistTestHostApp: App {
    @State private var model: EditorViewModel
    @State private var loc: LocalizationStore

    init() {
        let suite = "SchriftChecklistTestHost"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let localization = LocalizationStore(userDefaults: defaults)
        localization.language = .english
        _loc = State(initialValue: localization)
        let client = DocsAPIClient(baseURL: URL(string: "https://docs.example.org/api/v1.0/")!, cookieProvider: { [] })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        let content = DocumentContentCacheStore(directory: directory)
        let children = DocumentChildrenCacheStore(userDefaults: defaults)
        let coordinator = DocumentSaveCoordinator(
            client: client,
            draftStore: PendingDraftStore(userDefaults: defaults), contentCache: content,
            createStore: PendingDocumentCreateStore(userDefaults: defaults),
            deleteStore: PendingDocumentDeleteStore(userDefaults: defaults),
            attachmentStore: PendingAttachmentStore(userDefaults: defaults, directory: directory),
            listCache: DocumentCacheStore(userDefaults: defaults), childrenCache: children,
            serverOrigin: "https://docs.example.org", backgroundTasks: .noop)
        let vm = EditorViewModel(
            client: client, documentID: UUID(), title: "Checklist",
            saveCoordinator: coordinator, signedInUser: SignedInUserStore(userDefaults: defaults),
            contentCache: content, childrenCache: children)
        // No document is loaded or saved: this fixture only toggles local rows.
        vm.blocks = (0..<6).map { EditorBlock(kind: .checklistItem(checked: false), text: "Task \($0 + 1)") }
        vm.mode = .blocks
        _model = State(initialValue: vm)
    }

    var body: some Scene {
        WindowGroup {
            ScrollView {
                VStack(alignment: .leading, spacing: EditorBlockMetrics.blockSpacing) {
                    ForEach(Array(model.blocks.enumerated()), id: \.element.id) { index, block in
                        BlockEditorRow(
                            viewModel: model, block: block, index: index,
                            serverOrigin: "https://docs.example.org", isOffline: true)
                    }
                }
                .padding(20)
            }
            .environment(loc)
            .environment(AttachmentLoader.inert())
            .environment(ImageLoader.inert())
            .environment(
                \.dynamicTypeSize,
                ProcessInfo.processInfo.arguments.contains("--accessibility") ? .accessibility3 : .large
            )
            .preferredColorScheme(.light)
        }
    }
}
