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
}
