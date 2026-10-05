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
            contentCache: content, childrenCache: children,
            availability: OnlineAvailability(userDefaults: defaults))
        // No document is loaded or saved: this fixture only toggles local rows.
        vm.blocks = (0..<6).map { EditorBlock(kind: .checklistItem(checked: false), text: "Task \($0 + 1)") }
        vm.mode = .blocks
        if ProcessInfo.processInfo.arguments.contains("--checklist-filter") {
            defaults.set(true, forKey: "schrift.workOffline")
            let source: String
            if ProcessInfo.processInfo.arguments.contains("--all-completed") {
                source = "- [x] Finished one\n- [x] Finished two"
            } else if ProcessInfo.processInfo.arguments.contains("--long-checklist") {
                source = (1...80).map { "- [\($0.isMultiple(of: 2) ? "x" : " ")] Task \($0)" }.joined(separator: "\n")
            } else {
                source = """
                    Introduction

                    - [x] Finished one
                    - [ ] Next task
                    - [x] Finished two

                    1. First numbered
                    2. Second numbered

                    Tail paragraph
                    """
            }
            content.save(
                CachedDocumentContent(documentID: vm.documentID, title: "Checklist", markdown: source, syncedAt: Date())
            )
            children.save([], for: vm.documentID)
            vm.blocks = []
            vm.mode = .reading
        }
        _model = State(initialValue: vm)
    }

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--offline-controls") {
                OfflineControlsTestHost()
            } else if ProcessInfo.processInfo.arguments.contains("--reading-controls-audit") {
                ChecklistReadingControlsAuditHost()
                    .environment(loc)
            } else if ProcessInfo.processInfo.arguments.contains("--checklist-filter") {
                NavigationStack {
                    EditorView(
                        viewModel: model, reach: .restricted,
                        serverHost: "docs.example.org", serverOrigin: "https://docs.example.org"
                    )
                    .toolbar {
                        ToolbarItem(placement: .bottomBar) {
                            Button("Remote change") {
                                guard let item = model.blocks.first(where: { $0.kind == .checklistItem(checked: true) })
                                else { return }
                                var updated = model.blocks
                                let index = updated.firstIndex(where: { $0.id == item.id })!
                                updated[index].kind = .checklistItem(checked: false)
                                updated[index].text = "Reopened remotely"
                                model.applyLiveRemoteChange(
                                    LiveChangeSet(changes: [
                                        .update(id: item.id, kind: updated[index].kind, text: updated[index].text)
                                    ]), projectedMarkdown: serializeMarkdown(updated))
                            }
                            .accessibilityIdentifier("fixture.remoteChange")
                        }
                    }
                }
                .environment(loc)
                .environment(DocumentCollaborationManager.inert())
                .environment(AttachmentLoader.inert())
                .environment(ImageLoader.inert())
                .preferredColorScheme(.light)
            } else {
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
}

/// Isolates the new production chrome for an unfiltered accessibility audit.
/// Whole-editor flow/scroll tests still use the complete production screen.
private struct ChecklistReadingControlsAuditHost: View {
    @State private var hidden = false

    var body: some View {
        VStack {
            ChecklistReadingControls(hidesCompleted: $hidden, hiddenCount: hidden ? 2 : 0)
            Spacer()
        }
        .padding()
        .background(DocsColor.surfacePage)
    }
}
