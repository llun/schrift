import UIKit

/// Begins/ends a system background-task assertion around each save so an
/// in-flight save gets background runtime to finish after the user leaves the
/// app. Injectable so tests (and previews) can avoid `UIApplication`.
struct BackgroundTaskProvider {
    let begin: @MainActor (String) -> Int
    let end: @MainActor (Int) -> Void

    static let uiApplication = BackgroundTaskProvider(
        begin: { name in
            UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: nil).rawValue
        },
        end: { rawValue in
            let identifier = UIBackgroundTaskIdentifier(rawValue: rawValue)
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
        }
    )

    static let noop = BackgroundTaskProvider(begin: { _ in 0 }, end: { _ in })
}

/// App-scoped save queue for document content.
///
/// Saves run in unstructured tasks owned by this object — not by any editor
/// screen — so navigating away, switching documents, or dismissing the editor
/// never cancels them. Per document, at most one save is in flight; newer
/// snapshots coalesce into a single "latest wins" queued slot. Every snapshot
/// is persisted to `PendingDraftStore` before any network call and cleared
/// only once that exact content has been saved, so edits survive suspension
/// and process death; `recoverDrafts()` replays them on the next launch.
@MainActor
@Observable
final class DocumentSaveCoordinator {
    struct PendingSave: Equatable, Sendable {
        let title: String
        let markdown: String
    }

    enum DocSaveState: Equatable, Sendable {
        case idle
        case saving
        case saved(Date)
        case failed(String)
    }

    private let client: DocsAPIClient
    private let draftStore: PendingDraftStore
    private let backgroundTasks: BackgroundTaskProvider

    private var states: [UUID: DocSaveState] = [:]
    private var inFlight: [UUID: Task<Void, Never>] = [:]
    private var inFlightContent: [UUID: PendingSave] = [:]
    private var queued: [UUID: PendingSave] = [:]
    private var hasRecoveredDrafts = false

    init(
        client: DocsAPIClient,
        draftStore: PendingDraftStore = PendingDraftStore(),
        backgroundTasks: BackgroundTaskProvider = .uiApplication
    ) {
        self.client = client
        self.draftStore = draftStore
        self.backgroundTasks = backgroundTasks
    }

    func state(for documentID: UUID) -> DocSaveState {
        states[documentID] ?? .idle
    }

    /// Content handed to the coordinator this session that the server hasn't
    /// confirmed yet (queued or in flight).
    func pendingSave(documentID: UUID) -> PendingSave? {
        queued[documentID] ?? inFlightContent[documentID]
    }

    /// Draft persisted by a previous session (or a failed save) that hasn't
    /// been replayed yet.
    func storedDraft(documentID: UUID) -> PendingDraft? {
        draftStore.draft(for: documentID)
    }

    func enqueue(documentID: UUID, title: String, markdown: String) {
        let save = PendingSave(title: title, markdown: markdown)
        draftStore.save(PendingDraft(documentID: documentID, title: title, markdown: markdown, updatedAt: Date()))
        if inFlight[documentID] != nil {
            queued[documentID] = save
            return
        }
        start(documentID: documentID, save: save)
    }

    /// Replays drafts left behind by a previous session. A draft is re-saved
    /// unless the document changed on the server after the draft was written —
    /// fresher edits made elsewhere win over a stale draft.
    func recoverDrafts() async {
        guard !hasRecoveredDrafts else { return }
        hasRecoveredDrafts = true
        for draft in draftStore.allDrafts() {
            guard inFlight[draft.documentID] == nil, queued[draft.documentID] == nil else { continue }
            do {
                let formatted = try await client.formattedContent(documentID: draft.documentID)
                // The session may have started editing/saving this document
                // while we awaited — a stale replay would clobber the newer
                // content and its draft. Re-check before acting.
                guard inFlight[draft.documentID] == nil,
                      queued[draft.documentID] == nil,
                      draftStore.draft(for: draft.documentID) == draft else { continue }
                if formatted.updatedAt <= draft.updatedAt.addingTimeInterval(pendingDraftClockTolerance) {
                    enqueue(documentID: draft.documentID, title: draft.title, markdown: draft.markdown)
                } else {
                    draftStore.remove(documentID: draft.documentID)
                }
            } catch let error as DocsAPIError where error == .notFound || error == .forbidden {
                draftStore.remove(documentID: draft.documentID)
            } catch {
                // Leave the draft for a later launch (e.g. offline right now).
            }
        }
    }

    private func start(documentID: UUID, save: PendingSave) {
        inFlightContent[documentID] = save
        states[documentID] = .saving
        let taskToken = backgroundTasks.begin("SchriftDocumentSave")
        inFlight[documentID] = Task {
            do {
                try await client.saveDocumentContent(documentID: documentID, title: save.title, markdown: save.markdown)
                finish(documentID: documentID, save: save, error: nil)
            } catch {
                finish(documentID: documentID, save: save, error: error)
            }
            backgroundTasks.end(taskToken)
        }
    }

    private func finish(documentID: UUID, save: PendingSave, error: Error?) {
        inFlight[documentID] = nil
        inFlightContent[documentID] = nil
        if error == nil {
            states[documentID] = .saved(Date())
            if let draft = draftStore.draft(for: documentID),
               draft.title == save.title, draft.markdown == save.markdown {
                draftStore.remove(documentID: documentID)
            }
        } else {
            states[documentID] = .failed("Couldn't save changes. Please try again.")
        }
        if let next = queued.removeValue(forKey: documentID) {
            if error == nil, next == save {
                return
            }
            start(documentID: documentID, save: next)
        }
    }
}
