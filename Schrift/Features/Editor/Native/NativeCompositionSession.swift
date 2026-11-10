import Observation
import UIKit

/// One UIKit marked-text composition, anchored to a same-block replacement
/// range captured before UIKit owns the marked range, plus the provisional
/// recovery entries that outlive a composition.
///
/// UIKit owns the provisional text in storage; the replica never sees it until
/// the commit. From its begin until its answer the composition owns the view:
/// the input coordinator holds every delivery, the surface defers restyles and
/// offset-based commands are refused, because document-wide UIKit offsets are
/// stale until reconciliation. The commit writes the composed
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

    /// The replica session's side (PR08b): begin, commit and cancel are posted
    /// in order, and the recovery file is written there.
    struct Port {
        /// False when the begin could not be posted: no composition starts.
        let begin: (_ blockID: String, _ range: Range<Int>) -> Bool
        let commit: (_ commandID: UUID, _ text: String) -> Void
        let cancel: () -> Void
        let writeRecoveries: ([ProvisionalRecovery]) -> Void
    }

    private let surface: NativeTextSurface
    private weak var view: NativeTextView?
    private let port: Port
    private let hasRecoveryStore: Bool
    /// Whether authoring is possible (not frozen or closed).
    private let canAuthor: () -> Bool

    private(set) var isActive = false
    /// A commit or cancel was posted and its result has not arrived: the
    /// surface stays frozen and input waits.
    private(set) var isResolving = false
    /// The last marked string UIKit reported, used when `unmarkText` commits
    /// without naming the text.
    private(set) var provisionalText = ""
    /// The active composition's entry and every unresolved recovery; written
    /// to disk only when there is a replica store.
    private var recoveries: [ProvisionalRecovery]
    private var commandID = UUID()
    private var blockID: String?
    /// The text of the commit in flight, kept for an orphaned result.
    private var committing: (id: UUID, text: String)?
    private var keepsRecoveryOnCancel = false

    /// Recovery the user still has to resolve, oldest first.
    var pendingRecoveries: [ProvisionalRecovery] {
        recoveries.filter { !((isActive || isResolving) && $0.commandID == commandID) }
    }

    init(
        surface: NativeTextSurface, view: NativeTextView, port: Port, recoveries: [ProvisionalRecovery],
        hasRecoveryStore: Bool, canAuthor: @escaping () -> Bool
    ) {
        self.surface = surface
        self.view = view
        self.port = port
        self.recoveries = recoveries
        self.hasRecoveryStore = hasRecoveryStore
        self.canAuthor = canAuthor
    }

    /// Called before UIKit applies a marked range. Returns false when the
    /// composition cannot be supported (a multi-block selection, an opaque or
    /// placeholder target, or an invalid range); the caller then keeps the
    /// preserved read-only refusal and never lets provisional text in. The
    /// begin is posted; a target the session cannot capture comes back as an
    /// orphaned commit.
    func begin(markedText: String) -> Bool {
        guard !isActive else {
            record(markedText, state: .composing)
            return true
        }
        guard let view, view.isEditable, canAuthor(), !isResolving, let target = replacementTarget(in: view) else {
            return false
        }
        guard port.begin(target.blockID, target.range) else { return false }
        surface.provisionalBlockID = target.blockID
        surface.holdForComposition(true)
        isActive = true
        blockID = target.blockID
        commandID = UUID()
        record(markedText, state: .composing)
        return true
    }

    /// Commits `text` (default: the last marked string) as one durable command,
    /// a barrier: the session's rebuild reconciles storage to the projection
    /// when the result arrives. UIKit must already have cleared its marked state.
    @discardableResult
    func commit(text: String? = nil) -> Bool {
        guard isActive else { return false }
        let replacement = text ?? provisionalText
        guard !replacement.isEmpty else { return cancel() }
        isActive = false
        isResolving = true
        provisionalText = ""
        blockID = nil
        committing = (commandID, replacement)
        port.commit(commandID, replacement)
        return true
    }

    /// No write. The session rebuilds and the caret returns to where the
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
        isActive = false
        isResolving = true
        provisionalText = ""
        blockID = nil
        keepsRecoveryOnCancel = keepingRecovery
        port.cancel()
        return true
    }

    /// The session's answer for the commit or cancel in flight. Returns the
    /// commit's outcome (nil for a cancel).
    func resolve(_ result: ReplicaResult.CompositionResult) -> Outcome? {
        guard isResolving else { return nil }
        isResolving = false
        let commit = committing
        committing = nil
        switch result {
        case .cancelled:
            if !keepsRecoveryOnCancel { remove(commandID) }
            keepsRecoveryOnCancel = false
            return nil
        case .committed:
            if let commit { remove(commit.id) }
            return .committed
        case .orphaned:
            guard let commit else { return nil }
            if let index = recoveries.firstIndex(where: { $0.commandID == commit.id }) {
                recoveries[index].text = commit.text
                recoveries[index].state = .orphaned
                save()
            }
            return .orphaned(commit.text)
        case .failed:
            // A failed append keeps the entry on disk: the text was not durably
            // written, so the next open offers recovery.
            return .failed
        }
    }

    /// Text the editor dropped (a rolled-back prediction, held keys) becomes
    /// an orphaned entry, like a commit whose target vanished.
    func recover(_ text: String, blockID: String) {
        guard !text.isEmpty else { return }
        recoveries.append(ProvisionalRecovery(commandID: UUID(), blockID: blockID, text: text, state: .orphaned))
        save()
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
        guard hasRecoveryStore else { return }
        port.writeRecoveries(recoveries)
    }

    /// The block-relative replacement range of the current selection. Both
    /// endpoints must sit inside one block's text: a cross-block selection is
    /// not a supported composition. An opaque block or one the writer has no
    /// schema for cannot compose either.
    private func replacementTarget(in view: NativeTextView) -> (blockID: String, range: Range<Int>)? {
        let selection = view.selectedRange
        guard selection.location >= 0, selection.length >= 0,
            selection.location <= surface.storage.length,
            selection.length <= surface.storage.length - selection.location,
            let entry = surface.rangeIndex.entry(atUTF16: selection.location),
            let position = surface.rangeIndex.position(for: entry.blockID),
            selection.location >= entry.textRange.location,
            NSMaxRange(selection) <= NSMaxRange(entry.textRange),
            !AttributedDocumentProjection.isPlaceholder(surface.blocks[position]),
            BlockNoteWriter.nativePropSchemas[surface.blocks[position].node] != nil,
            // Folded content is never edited (PR06b): the engine knows nothing of folding.
            !surface.isHidden(position: position)
        else { return nil }
        return (
            entry.blockID,
            (selection.location - entry.textRange.location)..<(NSMaxRange(selection) - entry.textRange.location)
        )
    }

}
