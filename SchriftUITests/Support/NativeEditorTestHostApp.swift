import SwiftUI

/// Disposable raw replicas exercise the production surface without an account,
/// network, save coordinator, or changes to the shipping app's launch arguments.
@main
struct NativeEditorTestHostApp: App {
    @State private var session: NativeEditorSession?
    @State private var localization = LocalizationStore()
    @State private var failedToLoad = false
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
                    NativeEditorView(session: session, title: "Native reader fixture")
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
                session = try? NativeEditorSession(state: fixture)
                failedToLoad = session == nil
            }
            .environment(localization)
            .onDisappear { session?.close() }
        }
    }
}
