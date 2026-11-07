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
            blocks: projected.blocks.map(BlockSnapshot.init), storage: view.textStorage, traits: view.traitCollection,
            reprojectBlock: { [weak doc] id in
                guard let doc else { return nil }
                return Self.projectBlock(id, from: doc)
            })
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

    private static func projectBlock(_ id: String, from doc: YDoc) -> BlockSnapshot? {
        // Engine patches name top-level blocks. Look only at root/container
        // identity, not a writer's stricter validation of unrelated rich nodes.
        func children(_ type: YType) -> [YItem] {
            var result: [YItem] = []
            var item = type.start
            while let current = item {
                if !current.deleted && current.countable { result.append(current) }
                item = current.right
            }
            return result
        }
        guard let root = doc.share[BlockNoteYjs.fragmentField] else { return nil }
        let roots = children(root)
        guard roots.count == 1, case .type(let group) = roots[0].content,
            group.typeRef == .xmlElement(nodeName: "blockGroup")
        else { return nil }
        let matches = children(group).filter { item in
            guard case .type(let container) = item.content,
                container.typeRef == .xmlElement(nodeName: "blockContainer"),
                let candidate = BlockIndex.blockID(of: container)
            else { return false }
            return candidate.utf16.elementsEqual(id.utf16)
        }
        guard matches.count == 1 else { return nil }
        return BlockSnapshot(YBlockProjection.projectBlock(matches[0]))
    }
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
    private enum OpenResult: Sendable {
        case classic
        case state(Data)
    }
    private var pendingOpen: AsyncStream<OpenResult>.Continuation?
    private let waitForTimeout: @MainActor () async throws -> Void

    init(
        enabled: Bool = NativeEditorPreference.isEnabled(),
        waitForTimeout: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(3)) }
    ) {
        self.enabled = enabled
        self.route = enabled ? .loading : .classic
        self.waitForTimeout = waitForTimeout
    }

    func open(viewModel: EditorViewModel, isOffline: Bool) async {
        guard case .loading = route else { return }
        pendingOpen?.finish()
        generation += 1
        let request = generation
        guard canOpen(viewModel, isOffline: isOffline) else {
            route = .classic
            return
        }
        // A task-group race waits for cancelled children before returning. A
        // shared config read may not cooperate, so use a one-result stream and
        // cancel both owned tasks without holding the classic cache behind it.
        let (results, continuation) = AsyncStream<OpenResult>.makeStream(bufferingPolicy: .bufferingOldest(1))
        pendingOpen = continuation
        let fetch = Task { @MainActor [weak self] in
            defer { continuation.finish() }
            do {
                guard !Task.isCancelled else { return }
                let config = try await viewModel.client.serverConfig()
                guard !Task.isCancelled,
                    self?.canContinue(request: request, viewModel: viewModel, isOffline: isOffline) == true,
                    config.usesCollaborationYDocServer
                else {
                    continuation.yield(.classic)
                    return
                }
                let state = try await viewModel.client.collaborationYDocState(
                    documentID: viewModel.documentID, org: config.collaborationOrg)
                guard !Task.isCancelled else { return }
                continuation.yield(.state(state))
            } catch {
                continuation.yield(.classic)
            }
        }
        let waitForTimeout = self.waitForTimeout
        let timeout = Task { @MainActor in
            do {
                guard !Task.isCancelled else { return }
                try await waitForTimeout()
                guard !Task.isCancelled else { return }
                continuation.yield(.classic)
                continuation.finish()
            } catch {
                // Cancellation after fetch/close is not another result.
            }
        }
        defer {
            fetch.cancel()
            timeout.cancel()
            continuation.finish()
            if generation == request { pendingOpen = nil }
        }
        var iterator = results.makeAsyncIterator()
        guard let result = await iterator.next(), !Task.isCancelled, generation == request else { return }
        guard canOpen(viewModel, isOffline: isOffline), case .state(let state) = result else {
            route = .classic
            return
        }
        do { route = .native(try NativeEditorSession(state: state)) } catch { route = .classic }
    }

    private func canContinue(request: Int, viewModel: EditorViewModel, isOffline: Bool) -> Bool {
        generation == request && canOpen(viewModel, isOffline: isOffline)
    }

    private func canOpen(_ viewModel: EditorViewModel, isOffline: Bool) -> Bool {
        // Transport evidence only skips this optional prefetch. The classic
        // route keeps its existing cache/retry controls so it can recover.
        enabled && !isOffline && !viewModel.availability.showsOfflineStatus && !viewModel.isLocalDocument
            && !viewModel.isDocumentPendingDelete
            && !viewModel.isEditing && !viewModel.hasUnsavedLocalContent
            && viewModel.saveCoordinator.storedDraft(documentID: viewModel.documentID) == nil
            && viewModel.saveCoordinator.pendingSave(documentID: viewModel.documentID) == nil
    }

    func close() {
        generation += 1
        pendingOpen?.finish()
        pendingOpen = nil
        if case .native(let session) = route {
            session.close()
            route = .loading
        }
    }
}
