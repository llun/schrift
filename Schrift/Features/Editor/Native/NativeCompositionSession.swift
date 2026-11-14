import Observation
import UIKit

/// One UIKit marked-text composition, anchored to a same-block replacement
/// range captured before UIKit owns the marked range, plus the provisional
/// recovery entries that outlive a composition.
///
/// UIKit owns the provisional text in storage; the replica never sees it until
/// the commit. From its begin until its commit or cancel the composition owns
/// the view: the input coordinator holds every delivery, the surface defers
/// restyles and offset-based commands are refused, because document-wide UIKit
/// offsets are stale until reconciliation. The commit is then shown at once as
/// a prediction and posted like a typed key (PR08b). The commit writes the composed
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
    /// A commit to show and post as a predicted command (PR08b).
    struct Commit {
        let id: UUID
        let blockID: String
        let range: Range<Int>
        let text: String
    }

    /// The replica session's side (PR08b): begin, commit and cancel are posted
    /// in order, and the recovery file is written there.
    struct Port {
        /// False when the begin could not be posted: no composition starts.
        let begin: (_ blockID: String, _ range: Range<Int>) -> Bool
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
    /// The last marked string UIKit reported, used when `unmarkText` commits
    /// without naming the text.
    private(set) var provisionalText = ""
    /// The active composition's entry and every unresolved recovery; written
    /// to disk only when there is a replica store.
    private var recoveries: [ProvisionalRecovery]
    private var commandID = UUID()
    private var target: (blockID: String, range: Range<Int>)?
    /// Commits posted and not answered: their entries stay on disk until then.
    private var committing: Set<UUID> = []

    /// Recovery the user still has to resolve, oldest first (a table
    /// surface's adopted entries after the document's own).
    var pendingRecoveries: [ProvisionalRecovery] {
        recoveries.filter { !(isActive && $0.commandID == commandID) && !committing.contains($0.commandID) }
            + adopted.keys.sorted { $0.uuidString < $1.uuidString }.flatMap { adopted[$0] ?? [] }
    }

    /// A table surface's entries (PR11c), by surface: the document writes them
    /// beside its own (`provisional.json` is one list), shows them, and a
    /// relaunch restores them as the document's.
    private var adopted: [UUID: [ProvisionalRecovery]] = [:]

    /// A table surface's composition hands its entries here instead of
    /// writing the recovery file itself.
    @ObservationIgnored var forward: (([ProvisionalRecovery]) -> Void)?

    func adopt(_ entries: [ProvisionalRecovery], from source: UUID) {
        guard adopted[source] ?? [] != entries else { return }
        adopted[source] = entries.isEmpty ? nil : entries
        save()
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
        guard let view, view.isEditable, canAuthor(), let target = replacementTarget(in: view) else {
            return false
        }
        guard port.begin(target.blockID, target.range) else { return false }
        surface.provisionalBlockID = target.blockID
        surface.holdForComposition(true)
        isActive = true
        self.target = target
        commandID = UUID()
        record(markedText, state: .composing)
        return true
    }

    /// Ends the composition with `text` (default: the last marked string):
    /// the caller shows it as a prediction and posts it. Nil when there is
    /// nothing to write (an empty commit cancels). UIKit must already have
    /// cleared its marked state.
    func commit(text: String? = nil) -> Commit? {
        guard isActive, let target else { return nil }
        let replacement = text ?? provisionalText
        guard !replacement.isEmpty else {
            cancel()
            return nil
        }
        end()
        committing.insert(commandID)
        return Commit(id: commandID, blockID: target.blockID, range: target.range, text: replacement)
    }

    /// No write; the provisional entry is dropped.
    @discardableResult
    func cancel() -> Bool {
        guard isActive else { return false }
        end()
        remove(commandID)
        port.cancel()
        return true
    }

    /// No write either, but the unconfirmed text stays as a pending recovery
    /// entry (focus loss that never reached `unmarkText`).
    @discardableResult
    func interrupt() -> Bool {
        guard isActive else { return false }
        end()
        port.cancel()
        return true
    }

    private func end() {
        isActive = false
        provisionalText = ""
        target = nil
    }

    /// A commit was answered (or rolled back, its text recovered): its
    /// provisional entry is no longer needed.
    func finish(_ commandID: UUID) {
        guard committing.remove(commandID) != nil else { return }
        remove(commandID)
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
        guard let blockID = target?.blockID else { return }
        let entry = ProvisionalRecovery(commandID: commandID, blockID: blockID, text: text, state: state)
        if let index = recoveries.firstIndex(where: { $0.commandID == commandID }) {
            recoveries[index] = entry
        } else {
            recoveries.append(entry)
        }
        save()
    }

    private func remove(_ id: UUID) {
        let isAdopted = adopted.values.contains { $0.contains { $0.commandID == id } }
        guard recoveries.contains(where: { $0.commandID == id }) || isAdopted else { return }
        recoveries.removeAll { $0.commandID == id }
        for (source, entries) in adopted {
            let kept = entries.filter { $0.commandID != id }
            adopted[source] = kept.isEmpty ? nil : kept
        }
        save()
    }

    /// Recovery text is a convenience copy, never committed content: a failed
    /// write must not block typing, and the journal path reports disk failures.
    private func save() {
        let allRecoveries =
            recoveries + adopted.keys.sorted { $0.uuidString < $1.uuidString }.flatMap { adopted[$0] ?? [] }
        if let forward {
            forward(allRecoveries)
            return
        }
        guard hasRecoveryStore else { return }
        port.writeRecoveries(allRecoveries)
    }

    /// The block-relative replacement range of the current selection. Both
    /// endpoints must sit inside one block's text: a cross-block selection is
    /// not a supported composition. An opaque block or one the writer has no
    /// schema for cannot compose either.
    private func replacementTarget(in view: NativeTextView) -> (blockID: String, range: Range<Int>)? {
        var selection = view.selectedRange
        guard selection.location >= 0, selection.length >= 0,
            selection.location <= surface.storage.length,
            selection.length <= surface.storage.length - selection.location,
            let entry = surface.rangeIndex.entry(atUTF16: selection.location),
            let position = surface.rangeIndex.position(for: entry.blockID)
        else { return nil }
        if SourceTarget.isSourceID(entry.blockID), selection.location <= NSMaxRange(entry.textRange),
            NSMaxRange(selection) > NSMaxRange(entry.textRange)
        {
            selection.length = NSMaxRange(entry.textRange) - selection.location
        }
        guard selection.location >= entry.textRange.location,
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
