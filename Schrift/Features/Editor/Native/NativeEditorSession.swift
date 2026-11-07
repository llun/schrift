import Foundation
import Observation

/// PR01's sole replica owner. It is deliberately separate from the live
/// collaboration manager: the classic bridge never attaches to this replica.
@MainActor
final class NativeEditorSession {
    private var doc: YDoc?
    let engine: DocumentEngine
    let textView: NativeTextView
    let surface: NativeTextSurface
    let hasUnsupportedRoot: Bool
    var isClosed: Bool { doc == nil }

    init(
        state: Data,
        makeReplica: () throws -> YDoc = { YDoc(clientID: UInt.random(in: 1...UInt(UInt32.max)), gc: true) }
    ) throws {
        let doc = try makeReplica()
        do {
            try doc.applyUpdate(YUpdateDecoder.decode(state), origin: .remote)
        } catch {
            doc.destroy()
            throw error
        }
        let projected = YBlockProjection.project(doc)
        let view = NativeTextView()
        let surface = NativeTextSurface(
            blocks: projected.blocks.map(BlockSnapshot.init), storage: view.textStorage, traits: view.traitCollection)
        self.doc = doc
        self.textView = view
        self.surface = surface
        self.hasUnsupportedRoot = projected.blocks.isEmpty && !projected.isFullyRenderable
        // The initial projection is installed before hooks accept transactions.
        self.engine = DocumentEngine(doc: doc, surface: surface)
    }

    func close() {
        guard let doc else { return }
        self.doc = nil
        doc.destroy()
    }

    isolated deinit { doc?.destroy() }
}

/// Captures the flag once. Failed/legacy/offline opens go to the classic
/// editor; a selected route never changes in response to a preference write.
@MainActor @Observable
final class NativeEditorOpen {
    enum Route {
        case loading, classic
        case native(NativeEditorSession)
    }
    let enabled: Bool
    private(set) var route: Route
    private var generation = 0

    init(enabled: Bool = NativeEditorPreference.isEnabled()) {
        self.enabled = enabled
        self.route = enabled ? .loading : .classic
    }

    func open(viewModel: EditorViewModel, isOffline: Bool) async {
        guard case .loading = route else { return }
        generation += 1
        let request = generation
        guard canOpen(viewModel, isOffline: isOffline) else {
            route = .classic
            return
        }
        do {
            let config = try await viewModel.client.serverConfig()
            guard !Task.isCancelled, generation == request else { return }
            guard config.usesCollaborationYDocServer, canOpen(viewModel, isOffline: isOffline) else {
                route = .classic
                return
            }
            let state = try await viewModel.client.collaborationYDocState(
                documentID: viewModel.documentID, org: config.collaborationOrg)
            guard !Task.isCancelled, generation == request else { return }
            guard canOpen(viewModel, isOffline: isOffline) else {
                route = .classic
                return
            }
            route = .native(try NativeEditorSession(state: state))
        } catch {
            guard !Task.isCancelled, generation == request else { return }
            route = .classic
        }
    }

    private func canOpen(_ viewModel: EditorViewModel, isOffline: Bool) -> Bool {
        enabled && !isOffline && !viewModel.availability.isOffline && !viewModel.isLocalDocument
            && !viewModel.isEditing && !viewModel.hasUnsavedLocalContent
            && viewModel.saveCoordinator.storedDraft(documentID: viewModel.documentID) == nil
            && viewModel.saveCoordinator.pendingSave(documentID: viewModel.documentID) == nil
    }

    func close() {
        generation += 1
        if case .native(let session) = route {
            session.close()
            route = .loading
        }
    }
}
