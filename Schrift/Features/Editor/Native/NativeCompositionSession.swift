import Observation
import UIKit

/// One UIKit marked-text composition, anchored to a same-block replacement
/// range captured before UIKit owns the marked range, plus the provisional
/// recovery entries that outlive a composition.
///
/// UIKit owns the provisional text in storage; the replica never sees it until
/// the commit. While a composition is active the surface is frozen (see
/// `NativeTextSurface.setCompositionDeferred`): remote patches are buffered,
/// restyles deferred and offset-based commands refused, because document-wide
/// UIKit offsets are stale until reconciliation. The commit writes the composed
/// string once as one durable command and then reconciles storage to the
/// projection. A target that was deleted or replaced is never redirected into
/// a new text under the same block id.
///
/// With a replica store, the provisional text is persisted beside the journal
/// (`ReplicaStore.writeProvisionalRecoveries`) on every marked-text change and
/// removed on commit or cancel. An orphaned commit, or an entry left by a crash
/// or relaunch mid-composition, stays in `pendingRecoveries` until the user
/// inserts, copies or discards it. Nothing is ever inserted automatically.
@MainActor @Observable
final class NativeCompositionSession {
    enum Outcome: Equatable {
        case committed
        /// The captured target disappeared. Nothing was written.
        case orphaned(String)
        case failed
    }

    private let engine: DocumentEngine
    private let surface: NativeTextSurface
    private weak var view: NativeTextView?
    private let persist: (NativeEditCommand, Data) throws -> Void
    private let recoveryStore: (store: ReplicaStore, scope: ReplicaScope)?

    private(set) var isActive = false
    /// The last marked string UIKit reported, used when `unmarkText` commits
    /// without naming the text.
    private(set) var provisionalText = ""
    /// The active composition's entry and every unresolved recovery; written
    /// to disk only when there is a replica store.
    private var recoveries: [ProvisionalRecovery]
    private var commandID = UUID()
    private var blockID: String?

    /// Recovery the user still has to resolve, oldest first.
    var pendingRecoveries: [ProvisionalRecovery] {
        recoveries.filter { !(isActive && $0.commandID == commandID) }
    }

    init(
        engine: DocumentEngine, surface: NativeTextSurface, view: NativeTextView,
        persist: @escaping (NativeEditCommand, Data) throws -> Void,
        recoveryStore: (store: ReplicaStore, scope: ReplicaScope)? = nil
    ) {
        self.engine = engine
        self.surface = surface
        self.view = view
        self.persist = persist
        self.recoveryStore = recoveryStore
        recoveries = recoveryStore.map { $0.store.provisionalRecoveries(for: $0.scope) } ?? []
    }

    /// Called before UIKit applies a marked range. Returns false when the
    /// composition cannot be supported (a multi-block selection, an opaque or
    /// placeholder target, or an invalid range); the caller then keeps the
    /// preserved read-only refusal and never lets provisional text in.
    func begin(markedText: String) -> Bool {
        guard !isActive else {
            record(markedText, state: .composing)
            return true
        }
        guard let view, view.isEditable, !engine.nativeWriteFailed, !engine.isDetached,
            let target = replacementTarget(in: view)
        else { return false }
        surface.provisionalBlockID = target.blockID
        do {
            try engine.compositionBegan(blockID: target.blockID, replacing: target.range)
        } catch {
            surface.provisionalBlockID = nil
            return false
        }
        isActive = true
        blockID = target.blockID
        commandID = UUID()
        record(markedText, state: .composing)
        return true
    }

    /// Commits `text` (default: the last marked string) as one durable command.
    /// UIKit must already have cleared its marked state; the engine's rebuild
    /// reconciles storage to the projection.
    @discardableResult
    func commit(text: String? = nil) -> Outcome {
        guard isActive else { return .failed }
        let replacement = text ?? provisionalText
        guard !replacement.isEmpty else { return cancel() ? .committed : .failed }
        let id = commandID
        isActive = false
        provisionalText = ""
        blockID = nil
        do {
            switch try engine.compositionCommitted(text: replacement, commandID: id, persist: persist) {
            case .committed:
                remove(id)
                restoreSelection()
                return .committed
            case .orphaned:
                if let index = recoveries.firstIndex(where: { $0.commandID == id }) {
                    recoveries[index].text = replacement
                    recoveries[index].state = .orphaned
                    save()
                }
                return .orphaned(replacement)
            }
        } catch {
            // A boundary refusal leaves the engine composing; end it so the
            // surface unfreezes. A failed append keeps the entry on disk: the
            // text was not durably written, so the next open offers recovery.
            if engine.isComposing { try? engine.compositionCancelled() }
            restoreSelection()
            return .failed
        }
    }

    /// No write. The engine rebuilds and the caret returns to where the
    /// composition began; the provisional entry is dropped.
    @discardableResult
    func cancel() -> Bool {
        end(keepingRecovery: false)
    }

    /// No write either, but the unconfirmed text stays as a pending recovery
    /// entry (focus loss that never reached `unmarkText`).
    @discardableResult
    func interrupt() -> Bool {
        end(keepingRecovery: true)
    }

    private func end(keepingRecovery: Bool) -> Bool {
        guard isActive else { return false }
        do {
            try engine.compositionCancelled()
        } catch {
            return false
        }
        isActive = false
        provisionalText = ""
        blockID = nil
        if !keepingRecovery { remove(commandID) }
        restoreSelection()
        return true
    }

    /// The user resolved a recovery entry (inserted, copied or discarded it).
    func resolveRecovery(_ recovery: ProvisionalRecovery) {
        remove(recovery.commandID)
    }

    private func record(_ text: String, state: ProvisionalRecovery.State) {
        provisionalText = text
        guard let blockID else { return }
        let entry = ProvisionalRecovery(commandID: commandID, blockID: blockID, text: text, state: state)
        if let index = recoveries.firstIndex(where: { $0.commandID == commandID }) {
            recoveries[index] = entry
        } else {
            recoveries.append(entry)
        }
        save()
    }

    private func remove(_ id: UUID) {
        guard recoveries.contains(where: { $0.commandID == id }) else { return }
        recoveries.removeAll { $0.commandID == id }
        save()
    }

    /// Recovery text is a convenience copy, never committed content: a failed
    /// write must not block typing, and the journal path reports disk failures.
    private func save() {
        guard let recoveryStore else { return }
        try? recoveryStore.store.writeProvisionalRecoveries(recoveries, for: recoveryStore.scope)
    }

    /// The block-relative replacement range of the current selection. Both
    /// endpoints must sit inside one block's text: a cross-block selection is
    /// not a supported composition.
    private func replacementTarget(in view: NativeTextView) -> (blockID: String, range: Range<Int>)? {
        let selection = view.selectedRange
        guard selection.location >= 0, selection.length >= 0,
            selection.location <= surface.storage.length,
            selection.length <= surface.storage.length - selection.location,
            let entry = surface.rangeIndex.entry(atUTF16: selection.location),
            let position = surface.rangeIndex.position(for: entry.blockID),
            selection.location >= entry.textRange.location,
            NSMaxRange(selection) <= NSMaxRange(entry.textRange),
            !AttributedDocumentProjection.isPlaceholder(surface.blocks[position])
        else { return nil }
        return (
            entry.blockID,
            (selection.location - entry.textRange.location)..<(NSMaxRange(selection) - entry.textRange.location)
        )
    }

    /// The engine resolves the caret against the replica, so a peer edit during
    /// the composition still lands the caret after the committed text.
    private func restoreSelection() {
        guard let view, let caret = (try? engine.currentSelection())?.head,
            let entry = surface.rangeIndex.entry(for: caret.blockID)
        else { return }
        let offset = min(max(0, caret.offset), entry.textRange.length)
        view.selectedRange = NSRange(location: entry.textRange.location + offset, length: 0)
    }
}
